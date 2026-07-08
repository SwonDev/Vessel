// vessel-spawn — lanzador que DESACOPLA el proceso hijo de la identidad de la app padre
// (Vessel.app) usando la API `responsibility_spawnattrs_setdisclaim`, igual que hace el
// cx_loader de CrossOver y los navegadores. Sin esto, el CEF de Steam (Chromium) NO crea
// su ventana Cocoa cuando cuelga de una .app: macOS lo asocia a la app "responsable" y el
// proceso "browser" del CEF no puede componer a pantalla. El helper spawnea el comando con
// disclaim=1 y ESPERA (waitpid) para que el Process de Vessel lo trackee como si fuera Wine.
#include <spawn.h>
#include <sys/wait.h>
#include <stdio.h>
#include <unistd.h>

// API privada de libsystem (presente en runtime en todas las versiones de macOS modernas).
extern int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attrs, int disclaim);
extern char **environ;

int main(int argc, char *argv[]) {
    if (argc < 2) { fprintf(stderr, "uso: vessel-spawn <programa> [args...]\n"); return 2; }
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    responsibility_spawnattrs_setdisclaim(&attr, 1);   // el hijo es responsable de sí mismo
    pid_t pid;
    int rc = posix_spawn(&pid, argv[1], NULL, &attr, &argv[1], environ);
    posix_spawnattr_destroy(&attr);
    if (rc != 0) { fprintf(stderr, "vessel-spawn: posix_spawn falló (%d)\n", rc); return 1; }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) { /* reintentar si EINTR */ }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
