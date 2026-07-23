#include <ctype.h>
#include <CoreFoundation/CoreFoundation.h>
#include <crt_externs.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach/mach.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>

// WineHQ embeds a static CFBundleName in the Mach-O loader (normally "Wine").
// AppKit reads that value before the first Windows window is created and uses it
// as the process name shown by the Dock. CrossOver patches the same section in
// its loader; this tiny injected library provides the equivalent behaviour for
// upstream Wine engines without modifying the engine on disk.

typedef struct {
    char display_name[385];
    char preloader_alias[PATH_MAX];
} vessel_dock_identity;

static char *const *vessel_current_arguments(void) {
    char ***arguments = _NSGetArgv();
    return arguments ? *arguments : NULL;
}

static bool vessel_copy_string(char *destination, size_t capacity, const char *source) {
    if (!destination || capacity == 0 || !source) {
        return false;
    }
    const size_t length = strlen(source);
    if (length == 0 || length >= capacity) {
        return false;
    }
    memcpy(destination, source, length + 1);
    return true;
}

static const char *vessel_windows_basename(const char *path) {
    if (!path) {
        return NULL;
    }
    const char *slash = strrchr(path, '/');
    const char *backslash = strrchr(path, '\\');
    const char *separator = slash;
    if (!separator || (backslash && backslash > separator)) {
        separator = backslash;
    }
    return separator ? separator + 1 : path;
}

static bool vessel_has_exe_suffix(const char *value) {
    if (!value) {
        return false;
    }
    size_t length = strlen(value);
    while (length > 0 && (value[length - 1] == '"' || isspace((unsigned char)value[length - 1]))) {
        --length;
    }
    return length >= 4 && strncasecmp(value + length - 4, ".exe", 4) == 0;
}

static const char *vessel_executable_argument(char *const arguments[]) {
    const char *candidate = NULL;
    if (!arguments) {
        return NULL;
    }
    for (size_t index = 0; arguments[index]; ++index) {
        if (vessel_has_exe_suffix(arguments[index])) {
            // Los cargadores Wine pueden anteponer sus propios argumentos. El PE real es el último
            // argumento terminado en .exe y, en los hijos de Steam, normalmente también argv[0].
            candidate = arguments[index];
        }
    }
    return candidate;
}

static bool vessel_normalize_windows_path(
    const char *value,
    char *output,
    size_t capacity
) {
    if (!value || !output || capacity < 2) {
        return false;
    }
    while (*value == '"' || isspace((unsigned char)*value)) {
        ++value;
    }
    size_t length = strlen(value);
    while (length > 0 && (value[length - 1] == '"' || isspace((unsigned char)value[length - 1]))) {
        --length;
    }
    if (length == 0 || length >= capacity) {
        return false;
    }
    for (size_t index = 0; index < length; ++index) {
        unsigned char character = (unsigned char)value[index];
        if (character == '/') {
            character = '\\';
        }
        output[index] = (char)(character < 0x80 ? tolower(character) : character);
    }
    output[length] = '\0';
    return true;
}

static bool vessel_valid_display_name(const char *value) {
    if (!value || !*value || strlen(value) > 384) {
        return false;
    }
    for (const unsigned char *cursor = (const unsigned char *)value; *cursor; ++cursor) {
        if (*cursor < 0x20 || *cursor == 0x7f) {
            return false;
        }
    }
    return true;
}

static bool vessel_read_mapped_identity(
    const char *executable,
    vessel_dock_identity *identity
) {
    const char *map_path = getenv("VESSEL_DOCK_IDENTITY_MAP");
    if (!executable || !map_path || !*map_path || !identity) {
        return false;
    }

    int descriptor = open(map_path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) {
        return false;
    }
    struct stat information;
    const bool safe = fstat(descriptor, &information) == 0
        && S_ISREG(information.st_mode)
        && information.st_uid == geteuid()
        && (information.st_mode & (S_IWGRP | S_IWOTH)) == 0
        && information.st_size > 0
        && information.st_size <= (1024 * 1024);
    if (!safe) {
        close(descriptor);
        return false;
    }

    const size_t size = (size_t)information.st_size;
    char *contents = calloc(size + 1, 1);
    if (!contents) {
        close(descriptor);
        return false;
    }
    size_t offset = 0;
    while (offset < size) {
        ssize_t count = read(descriptor, contents + offset, size - offset);
        if (count <= 0) {
            break;
        }
        offset += (size_t)count;
    }
    close(descriptor);
    if (offset != size) {
        free(contents);
        return false;
    }

    char normalized_executable[PATH_MAX];
    if (!vessel_normalize_windows_path(
            executable,
            normalized_executable,
            sizeof(normalized_executable)
        )) {
        free(contents);
        return false;
    }

    bool matched = false;
    char *save_pointer = NULL;
    for (char *line = strtok_r(contents, "\n", &save_pointer);
         line;
         line = strtok_r(NULL, "\n", &save_pointer)) {
        char *first_tab = strchr(line, '\t');
        if (!first_tab) {
            continue;
        }
        *first_tab = '\0';
        char *display_name = first_tab + 1;
        char *second_tab = strchr(display_name, '\t');
        char *alias = NULL;
        if (second_tab) {
            *second_tab = '\0';
            alias = second_tab + 1;
        }
        size_t display_length = strlen(display_name);
        if (display_length > 0 && display_name[display_length - 1] == '\r') {
            display_name[display_length - 1] = '\0';
        }
        if (alias) {
            size_t alias_length = strlen(alias);
            if (alias_length > 0 && alias[alias_length - 1] == '\r') {
                alias[alias_length - 1] = '\0';
            }
        }

        char normalized_key[PATH_MAX];
        if (!vessel_normalize_windows_path(line, normalized_key, sizeof(normalized_key))
            || strcmp(normalized_key, normalized_executable) != 0
            || !vessel_valid_display_name(display_name)
            || !vessel_copy_string(
                identity->display_name,
                sizeof(identity->display_name),
                display_name
            )) {
            continue;
        }
        if (alias && alias[0] == '/') {
            (void)vessel_copy_string(
                identity->preloader_alias,
                sizeof(identity->preloader_alias),
                alias
            );
        }
        matched = true;
        break;
    }
    free(contents);
    return matched;
}

static bool vessel_derive_identity(
    const char *executable,
    vessel_dock_identity *identity
) {
    const char *basename = vessel_windows_basename(executable);
    if (!basename || !*basename || !identity) {
        return false;
    }
    size_t length = strlen(basename);
    while (length > 0 && (basename[length - 1] == '"' || isspace((unsigned char)basename[length - 1]))) {
        --length;
    }
    if (length >= 4 && strncasecmp(basename + length - 4, ".exe", 4) == 0) {
        length -= 4;
    }
    if (length == 0 || length >= sizeof(identity->display_name)) {
        return false;
    }

    if (strncasecmp(basename, "steamwebhelper", 14) == 0
        || (length == 5 && strncasecmp(basename, "steam", 5) == 0)) {
        return vessel_copy_string(
            identity->display_name,
            sizeof(identity->display_name),
            "Steam"
        );
    }

    for (size_t index = 0; index < length; ++index) {
        unsigned char character = (unsigned char)basename[index];
        identity->display_name[index] = character == '_' ? ' ' : (char)character;
    }
    identity->display_name[length] = '\0';
    return vessel_valid_display_name(identity->display_name);
}

static bool vessel_resolve_identity(
    char *const arguments[],
    vessel_dock_identity *identity
) {
    if (!identity) {
        return false;
    }
    memset(identity, 0, sizeof(*identity));

    const char *fixed_name = getenv("VESSEL_DOCK_APP_NAME");
    if (vessel_valid_display_name(fixed_name)) {
        const char *fixed_alias = getenv("VESSEL_DOCK_PRELOADER_ALIAS");
        if (!vessel_copy_string(
                identity->display_name,
                sizeof(identity->display_name),
                fixed_name
            )) {
            return false;
        }
        if (fixed_alias && fixed_alias[0] == '/') {
            (void)vessel_copy_string(
                identity->preloader_alias,
                sizeof(identity->preloader_alias),
                fixed_alias
            );
        }
        return true;
    }

    const char *dynamic = getenv("VESSEL_DOCK_DYNAMIC_IDENTITY");
    if (!dynamic || strcmp(dynamic, "1") != 0) {
        return false;
    }
    const char *executable = vessel_executable_argument(arguments);
    if (!executable) {
        return false;
    }
    return vessel_read_mapped_identity(executable, identity)
        || vessel_derive_identity(executable, identity);
}

static CFTypeRef vessel_bundle_value(
    CFBundleRef bundle,
    CFStringRef key
) {
    vessel_dock_identity identity;
    const char *display_name = vessel_resolve_identity(
        vessel_current_arguments(),
        &identity
    ) ? identity.display_name : NULL;
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

static const char *vessel_preloader_alias(
    const char *path,
    char *const arguments[]
) {
    static _Thread_local char resolved_alias[PATH_MAX];
    resolved_alias[0] = '\0';
    vessel_dock_identity identity;
    const bool has_alias = vessel_resolve_identity(arguments, &identity)
        && identity.preloader_alias[0] != '\0'
        && vessel_copy_string(
            resolved_alias,
            sizeof(resolved_alias),
            identity.preloader_alias
        );
    const char *alias = has_alias ? resolved_alias : NULL;
    const char *basename = path ? strrchr(path, '/') : NULL;
    basename = basename ? basename + 1 : path;

    const bool is_preloader = basename && strstr(basename, "preloader");
    const bool is_wine_loader = basename
        && (strcmp(basename, "wine") == 0 || strcmp(basename, "wine64") == 0);
    const bool is_wine_temporary_alias = basename
        && is_wine_loader
        && strstr(path, "/winetemp-");

    if (path
        && alias
        && *alias
        && strcmp(path, alias) != 0
        && (is_preloader || is_wine_loader || is_wine_temporary_alias)) {
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
    return execv(vessel_preloader_alias(path, arguments), arguments);
}

static int vessel_execve(
    const char *path,
    char *const arguments[],
    char *const environment[]
) {
    return execve(vessel_preloader_alias(path, arguments), arguments, environment);
}

static int vessel_link(const char *source, const char *destination) {
    // La variante Apple/GPTK crea primero un hard link temporal llamado `wine` y ejecuta después
    // ese enlace. Redirigir la fuente en el momento de `link(2)` hace que LaunchServices vea el
    // plist ya parcheado en disco, incluso cuando ntdll no ejecuta directamente `wine-preloader`.
    return linkat(
        AT_FDCWD,
        vessel_preloader_alias(source, vessel_current_arguments()),
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
        vessel_preloader_alias(path, arguments),
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
    vessel_dock_identity identity;
    const char *display_name = vessel_resolve_identity(
        vessel_current_arguments(),
        &identity
    ) ? identity.display_name : NULL;
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
