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

/*
 * Game wrapper para Vessel — fuerza entorno DXMT antes de lanzar el juego real.
 *
 * Instalación:
 *   1. Renombrar juego.exe -> juego_real.exe (solo si juego.exe es grande)
 *   2. Copiar este wrapper como juego.exe
 *
 * Runtime:
 *   1. Resuelve su propio path (ej: C:\...\TemtemSwarm.exe)
 *   2. Deriva el real: quita ".exe", añade "_real.exe" -> C:\...\TemtemSwarm_real.exe
 *   3. SetEnvironmentVariableW("WINEDLLOVERRIDES", DXMT overrides)
 *   4. CreateProcessW(real, args + flags Unity, hereda entorno)
 *   5. WaitForSingleObject y devuelve exit code
 */

#define DXMT_OVERRIDES L"d3d8=n,b; d3d9=n,b; d3d10=n,b; d3d10_1=n,b; d3d10core=n,b; d3d11=n,b; d3d12=b; d3d12core=b; dxgi=n,b; winemetal=n,b; nvapi64=n,b; nvngx=n,b; winedbg.exe=d"
#define UNITY_FLAGS L"-force-d3d11-no-singlethreaded -screen-fullscreen 0"

static FILE *dbg = NULL;

static void debug_open(const wchar_t *self_path)
{
    const wchar_t *flag = _wgetenv(L"VESSEL_GAME_WRAPPER_DEBUG");
    if (!flag || !*flag) return;

    wchar_t log_path[MAX_PATH];
    if (wcslen(self_path) + 16 >= MAX_PATH) return;
    wcscpy(log_path, self_path);

    wchar_t *slash = wcsrchr(log_path, L'\\');
    if (!slash) return;
    wcscpy(slash + 1, L"game-wrapper-debug.log");

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

/* Deriva el path del binario real: quita ".exe" y añade "_real.exe". */
static wchar_t *resolve_real_binary(wchar_t *out_self_path, size_t out_cap)
{
    wchar_t self[MAX_PATH];
    DWORD len = GetModuleFileNameW(NULL, self, MAX_PATH);
    if (len == 0 || len >= MAX_PATH) return NULL;

    if (out_self_path && wcslen(self) < out_cap) {
        wcscpy(out_self_path, self);
    }

    /* Encontrar el último '.' para quitar la extensión .exe */
    wchar_t *dot = wcsrchr(self, L'.');
    if (!dot) return NULL;

    /* Verificar que la extensión es .exe */
    if (_wcsicmp(dot, L".exe") != 0) return NULL;

    /* Truncar en el punto y añadir "_real.exe" */
    *dot = L'\0';

    size_t cap = wcslen(self) + 10; /* "_real.exe" + null */
    wchar_t *real = (wchar_t *)calloc(cap, sizeof(wchar_t));
    if (!real) return NULL;
    wcscpy(real, self);
    wcscat(real, L"_real.exe");
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
    debug_log(L"[game-wrapper] self=%ls\n", self_path);
    debug_log(L"[game-wrapper] real=%ls\n", real);

    /* Forzar WINEDLLOVERRIDES con DXMT en el entorno del proceso.
     * CreateProcessW con lpEnvironment=NULL hereda este entorno. */
    SetEnvironmentVariableW(L"WINEDLLOVERRIDES", DXMT_OVERRIDES);
    debug_log(L"[game-wrapper] WINEDLLOVERRIDES set to DXMT overrides\n");

    const wchar_t *tail = args_tail();
    debug_log(L"[game-wrapper] forwarded args=%ls\n", tail);

    /* Construir línea de comandos: "real.exe" -force-d3d11-no-singlethreaded -screen-fullscreen 0 <args> */
    size_t cap = wcslen(real) + wcslen(UNITY_FLAGS) + wcslen(tail) + 16;
    wchar_t *cmdline = (wchar_t *)calloc(cap, sizeof(wchar_t));
    if (!cmdline) {
        free(real);
        return 1;
    }
    _snwprintf(cmdline, cap, L"\"%ls\" %ls %ls", real, UNITY_FLAGS, tail);
    debug_log(L"[game-wrapper] invoking: %ls\n", cmdline);

    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    /* bInheritHandles=TRUE y lpEnvironment=NULL: el hijo hereda el entorno
     * del wrapper, que ahora tiene WINEDLLOVERRIDES con DXMT. */
    BOOL ok = CreateProcessW(
        real,       /* lpApplicationName */
        cmdline,    /* lpCommandLine */
        NULL,       /* lpProcessAttributes */
        NULL,       /* lpThreadAttributes */
        TRUE,       /* bInheritHandles */
        0,          /* dwCreationFlags */
        NULL,       /* lpEnvironment = heredar del padre (con WINEDLLOVERRIDES) */
        NULL,       /* lpCurrentDirectory */
        &si,
        &pi
    );

    if (!ok) {
        DWORD err = GetLastError();
        debug_log(L"[game-wrapper] CreateProcessW failed: %lu\n", err);
        free(cmdline);
        free(real);
        return 1;
    }

    debug_log(L"[game-wrapper] child launched pid=%lu\n", pi.dwProcessId);
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    debug_log(L"[game-wrapper] child exited with %lu\n", code);

    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    free(cmdline);
    free(real);
    if (dbg) fclose(dbg);

    return (int)code;
}
