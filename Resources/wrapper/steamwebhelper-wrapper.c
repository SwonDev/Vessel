#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/* `--single-process` (SIN `--disable-gpu`): el CEF de la build MODERNA de Steam (Chrome 126+,
 * jul-2026) renderiza su UI por **ANGLE→D3D11**, y en el motor unificado ese D3D11 es **DXMT→Metal**.
 * En MULTIPROCESO cada proceso (renderer/gpu) abre su propio swapchain D3D11 cross-process, que
 * DXMT no soporta (bug Issue #141) → `SwapChain11 … EGL_BAD_ALLOC` → ventana NEGRA. Con
 * `--single-process` el swapchain D3D11/DXMT vive en UN solo proceso → DXMT renderiza el CEF a
 * `D3D_FEATURE_LEVEL_11_1` y el login/biblioteca se pintan (VERIFICADO in-vivo 2026-07-02 23:31:
 * pantalla "Iniciando sesión" + `Logged On`). NO usar `--disable-gpu`: forzaría el software
 * (SwiftShader), que en la build nueva CRASHEA el proceso (0x80000003) bajo este Wine. NO usar
 * `--use-gl/--use-angle=swiftshader`: chocan con el `swiftshader-webgl` de Steam y dan negro.
 * (Requiere el `win32u.so` del build wow64, no el que hace dlopen directo de MoltenVK.) */
#define EXTRA_FLAGS  L"--single-process"
#define REAL_BINARY  L"steamwebhelper_real.exe"

static FILE *dbg = NULL;

static void debug_open(const wchar_t *self_path)
{
    const wchar_t *flag = _wgetenv(L"STEAMWEBHELPER_WRAPPER_DEBUG");
    if (!flag || !*flag) return;

    wchar_t log_path[MAX_PATH];
    if (wcslen(self_path) + 16 >= MAX_PATH) return;
    wcscpy(log_path, self_path);

    wchar_t *slash = wcsrchr(log_path, L'\\');
    if (!slash) return;
    wcscpy(slash + 1, L"wrapper-debug.log");

    dbg = _wfopen(log_path, L"a");
}

static void debug_log(const wchar_t *fmt, ...)
{
    if (!dbg) return;
    va_list ap;
    va_start(ap, fmt);
    vfwprintf(dbg, fmt, ap);
    va_end(ap);
    fflush(dbg);
}

static wchar_t *resolve_real_binary(wchar_t *out_self_dir, size_t out_cap)
{
    wchar_t self[MAX_PATH];
    DWORD len = GetModuleFileNameW(NULL, self, MAX_PATH);
    if (len == 0 || len >= MAX_PATH) return NULL;

    if (out_self_dir && wcslen(self) < out_cap) {
        wcscpy(out_self_dir, self);
    }

    wchar_t *slash = wcsrchr(self, L'\\');
    if (!slash) return NULL;
    *(slash + 1) = L'\0';

    size_t cap = wcslen(self) + wcslen(REAL_BINARY) + 1;
    wchar_t *real = (wchar_t *)calloc(cap, sizeof(wchar_t));
    if (!real) return NULL;
    wcscpy(real, self);
    wcscat(real, REAL_BINARY);
    return real;
}

static const wchar_t *args_tail(void)
{
    const wchar_t *cmd = GetCommandLineW();
    if (!cmd) return L"";

    int in_quotes = 0;
    while (*cmd) {
        wchar_t c = *cmd;
        if (c == L'"') in_quotes = !in_quotes;
        else if (c == L' ' && !in_quotes) break;
        ++cmd;
    }
    while (*cmd == L' ') ++cmd;
    return cmd;
}

int wmain(void)
{
    wchar_t self_path[MAX_PATH] = {0};
    wchar_t *real = resolve_real_binary(self_path, MAX_PATH);
    if (!real) {
        return 1;
    }

    debug_open(self_path);
    debug_log(L"[wrapper] self=%ls\n", self_path);
    debug_log(L"[wrapper] real=%ls\n", real);

    const wchar_t *tail = args_tail();
    debug_log(L"[wrapper] forwarded args=%ls\n", tail);

    size_t cap = wcslen(real) + wcslen(EXTRA_FLAGS) + wcslen(tail) + 8;
    wchar_t *cmdline = (wchar_t *)calloc(cap, sizeof(wchar_t));
    if (!cmdline) {
        free(real);
        return 1;
    }
    _snwprintf(cmdline, cap, L"\"%ls\" %ls %ls", real, EXTRA_FLAGS, tail);
    debug_log(L"[wrapper] invoking: %ls\n", cmdline);

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    BOOL ok = CreateProcessW(
        real,
        cmdline,
        NULL,
        NULL,
        TRUE,
        0,
        NULL,
        NULL,
        &si,
        &pi
    );

    if (!ok) {
        DWORD err = GetLastError();
        debug_log(L"[wrapper] CreateProcessW failed: %lu\n", err);
        free(cmdline);
        free(real);
        return 1;
    }

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    debug_log(L"[wrapper] child exited with %lu\n", code);

    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    free(cmdline);
    free(real);
    if (dbg) fclose(dbg);

    return (int)code;
}
