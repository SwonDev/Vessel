#include <ctype.h>
#include <CoreFoundation/CoreFoundation.h>
#include <crt_externs.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach/mach.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// WineHQ embeds a static CFBundleName in the Mach-O loader (normally "Wine").
// AppKit reads that value before the first Windows window is created and uses it
// as the process name shown by the Dock. CrossOver patches the same section in
// its loader; this tiny injected library provides the equivalent behaviour for
// upstream Wine engines without modifying the engine on disk.

static CFTypeRef vessel_bundle_value(
    CFBundleRef bundle,
    CFStringRef key
) {
    const char *display_name = getenv("VESSEL_DOCK_APP_NAME");
    if (display_name
        && *display_name
        && key
        && CFStringCompare(key, CFSTR("CFBundleName"), 0) == kCFCompareEqualTo) {
        // The API returns an unowned value. Keeping one process-lifetime instance is
        // intentional: CoreFoundation and AppKit cache the main-bundle dictionary too.
        static CFStringRef overridden_name = NULL;
        if (!overridden_name) {
            overridden_name = CFStringCreateWithCString(
                kCFAllocatorDefault,
                display_name,
                kCFStringEncodingUTF8
            );
        }
        if (overridden_name) {
            return overridden_name;
        }
    }

    return CFBundleGetValueForInfoDictionaryKey(bundle, key);
}

#define VESSEL_DYLD_INTERPOSE(replacement, replacee) \
    __attribute__((used)) static struct { \
        const void *replacement; \
        const void *replacee; \
    } vessel_interpose_##replacee \
    __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(uintptr_t)&replacement, \
        (const void *)(uintptr_t)&replacee \
    }

VESSEL_DYLD_INTERPOSE(
    vessel_bundle_value,
    CFBundleGetValueForInfoDictionaryKey
);

static const char *vessel_preloader_alias(const char *path) {
    const char *alias = getenv("VESSEL_DOCK_PRELOADER_ALIAS");
    const char *basename = path ? strrchr(path, '/') : NULL;
    basename = basename ? basename + 1 : path;

    const bool is_preloader = basename && strstr(basename, "preloader");
    const bool is_wine_temporary_alias = basename
        && (strcmp(basename, "wine") == 0 || strcmp(basename, "wine64") == 0)
        && strstr(path, "/winetemp-");

    if (path
        && alias
        && *alias
        && strcmp(path, alias) != 0
        && (is_preloader || is_wine_temporary_alias)) {
        struct stat source_info;
        struct stat alias_info;
        bool source_is_regular = stat(path, &source_info) == 0
            && S_ISREG(source_info.st_mode);
        bool alias_is_safe_copy = source_is_regular
            && lstat(alias, &alias_info) == 0
            && S_ISREG(alias_info.st_mode)
            && alias_info.st_uid == geteuid()
            && (alias_info.st_mode & (S_IWGRP | S_IWOTH)) == 0
            && alias_info.st_size == source_info.st_size;
        // Vessel crea antes del exec una copia privada con __info_plist ya parcheado. El helper
        // solo la acepta si pertenece al usuario, es regular, no es escribible por terceros y
        // conserva el tamaño del preloader original. Los motores antiguos mantienen el hard link
        // como fallback; nunca se sigue un symlink preexistente.
        if (alias_is_safe_copy
            || (source_is_regular
                && linkat(AT_FDCWD, path, AT_FDCWD, alias, 0) == 0)) {
            return alias;
        }
    }

    return path;
}

static int vessel_execv(const char *path, char *const arguments[]) {
    return execv(vessel_preloader_alias(path), arguments);
}

static int vessel_execve(
    const char *path,
    char *const arguments[],
    char *const environment[]
) {
    return execve(vessel_preloader_alias(path), arguments, environment);
}

static int vessel_link(const char *source, const char *destination) {
    // La variante Apple/GPTK crea primero un hard link temporal llamado `wine` y ejecuta después
    // ese enlace. Redirigir la fuente en el momento de `link(2)` hace que LaunchServices vea el
    // plist ya parcheado en disco, incluso cuando ntdll no ejecuta directamente `wine-preloader`.
    return linkat(
        AT_FDCWD,
        vessel_preloader_alias(source),
        AT_FDCWD,
        destination,
        0
    );
}

static int vessel_posix_spawn(
    pid_t *restrict process_identifier,
    const char *restrict path,
    const posix_spawn_file_actions_t *file_actions,
    const posix_spawnattr_t *restrict attributes,
    char *const arguments[restrict],
    char *const environment[restrict]
) {
    return posix_spawn(
        process_identifier,
        vessel_preloader_alias(path),
        file_actions,
        attributes,
        arguments,
        environment
    );
}

VESSEL_DYLD_INTERPOSE(vessel_execv, execv);
VESSEL_DYLD_INTERPOSE(vessel_execve, execve);
VESSEL_DYLD_INTERPOSE(vessel_link, link);
VESSEL_DYLD_INTERPOSE(vessel_posix_spawn, posix_spawn);

static const char *find_bytes(
    const char *haystack,
    size_t haystack_length,
    const char *needle,
    size_t needle_length
) {
    if (!haystack || !needle || needle_length == 0 || needle_length > haystack_length) {
        return NULL;
    }

    const size_t limit = haystack_length - needle_length;
    for (size_t index = 0; index <= limit; ++index) {
        if (memcmp(haystack + index, needle, needle_length) == 0) {
            return haystack + index;
        }
    }
    return NULL;
}

static size_t escaped_xml_length(const char *value) {
    size_t length = 0;
    for (const unsigned char *cursor = (const unsigned char *)value; *cursor; ++cursor) {
        switch (*cursor) {
            case '&': length += sizeof("&amp;") - 1; break;
            case '<': length += sizeof("&lt;") - 1; break;
            case '>': length += sizeof("&gt;") - 1; break;
            case '"': length += sizeof("&quot;") - 1; break;
            case '\'': length += sizeof("&apos;") - 1; break;
            default: length += 1; break;
        }
    }
    return length;
}

static void append_xml_escaped(char *output, size_t *offset, const char *value) {
    for (const unsigned char *cursor = (const unsigned char *)value; *cursor; ++cursor) {
        const char *replacement = NULL;
        size_t replacement_length = 0;
        switch (*cursor) {
            case '&': replacement = "&amp;"; replacement_length = sizeof("&amp;") - 1; break;
            case '<': replacement = "&lt;"; replacement_length = sizeof("&lt;") - 1; break;
            case '>': replacement = "&gt;"; replacement_length = sizeof("&gt;") - 1; break;
            case '"': replacement = "&quot;"; replacement_length = sizeof("&quot;") - 1; break;
            case '\'': replacement = "&apos;"; replacement_length = sizeof("&apos;") - 1; break;
            default:
                output[(*offset)++] = (char)*cursor;
                continue;
        }
        memcpy(output + *offset, replacement, replacement_length);
        *offset += replacement_length;
    }
}

static size_t compact_plist(
    char *output,
    const char *input,
    size_t input_length,
    const char *value_start,
    const char *value_end,
    const char *display_name
) {
    size_t output_length = 0;
    const char *cursor = input;
    const char *input_end = input + input_length;

    while (cursor < input_end && *cursor != '\0') {
        if (cursor == value_start) {
            append_xml_escaped(output, &output_length, display_name);
            cursor = value_end;
            continue;
        }

        // Whitespace between XML tags is cosmetic. Removing it creates enough
        // room for real game titles while keeping the section size unchanged.
        if (isspace((unsigned char)*cursor)
            && output_length > 0
            && output[output_length - 1] == '>') {
            const char *next = cursor;
            while (next < input_end && isspace((unsigned char)*next)) {
                ++next;
            }
            if (next < input_end && *next == '<') {
                cursor = next;
                continue;
            }
        }

        output[output_length++] = *cursor++;
    }

    return output_length;
}

__attribute__((constructor))
static void vessel_apply_dock_identity(void) {
    const char *display_name = getenv("VESSEL_DOCK_APP_NAME");
    if (!display_name || !*display_name) {
        return;
    }

    unsigned long section_length = 0;
    const struct mach_header_64 *header =
        (const struct mach_header_64 *)_NSGetMachExecuteHeader();
    char *plist = (char *)getsectiondata(
        header,
        "__TEXT",
        "__info_plist",
        &section_length
    );
    if (!plist || section_length == 0) {
        return;
    }

    static const char key[] = "<key>CFBundleName</key>";
    static const char opening[] = "<string>";
    static const char closing[] = "</string>";

    const char *key_position = find_bytes(plist, section_length, key, sizeof(key) - 1);
    if (!key_position) {
        return;
    }

    const size_t remaining_after_key = section_length - (size_t)(key_position - plist);
    const char *opening_position = find_bytes(
        key_position,
        remaining_after_key,
        opening,
        sizeof(opening) - 1
    );
    if (!opening_position) {
        return;
    }

    const char *value_start = opening_position + sizeof(opening) - 1;
    const size_t remaining_after_value = section_length - (size_t)(value_start - plist);
    const char *value_end = find_bytes(
        value_start,
        remaining_after_value,
        closing,
        sizeof(closing) - 1
    );
    if (!value_end) {
        return;
    }

    const size_t required_name_length = escaped_xml_length(display_name);
    if (required_name_length == 0 || required_name_length > 384) {
        return;
    }

    char *replacement = calloc(section_length, 1);
    if (!replacement) {
        return;
    }

    const size_t replacement_length = compact_plist(
        replacement,
        plist,
        section_length,
        value_start,
        value_end,
        display_name
    );
    if (replacement_length == 0 || replacement_length >= section_length) {
        free(replacement);
        return;
    }

    const vm_size_t page_size = (vm_size_t)vm_page_size;
    const vm_address_t start = (vm_address_t)plist & ~(page_size - 1);
    const vm_address_t end = ((vm_address_t)plist + section_length + page_size - 1)
        & ~(page_size - 1);
    const vm_size_t protected_length = end - start;
    kern_return_t protection_result = vm_protect(
            mach_task_self(),
            start,
            protected_length,
            FALSE,
            VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE | VM_PROT_COPY
        );
    if (protection_result != KERN_SUCCESS) {
        free(replacement);
        return;
    }

    memset(plist, 0, section_length);
    memcpy(plist, replacement, replacement_length);
    (void)vm_protect(
        mach_task_self(),
        start,
        protected_length,
        FALSE,
        VM_PROT_READ | VM_PROT_EXECUTE
    );
    free(replacement);
}
