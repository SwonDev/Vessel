/* dpapi-seal.exe — helper PE mínimo para SELLAR/DESSELLAR con el DPAPI de Wine
 * (crypt32 CryptProtectData/CryptUnprotectData), usado para SEMBRAR el token de
 * auto-login del cliente de Steam en `local.vdf` (ConnectCache) sin depender del CEF.
 *
 * Lo ejecuta Vessel vía `wine` DENTRO del mismo prefijo, de modo que el cifrado lo
 * hace el propio crypt32 de Wine → compatibilidad byte a byte garantizada con lo que
 * el cliente de Steam espera. La entropía es el nombre de la cuenta (login), igual que
 * hace Steam (verificado con SteamJWT / mutabless/Steam-Token-Login).
 *
 *   Uso:  dpapi-seal.exe <seal|unseal> <entropy-login>
 *         (lee el HEX de entrada por stdin; escribe el HEX de salida por stdout)
 *   seal:   entrada = plaintext (hex del token)  → salida = blob DPAPI (hex)
 *   unseal: entrada = blob DPAPI (hex)           → salida = plaintext (hex)
 *
 * Compilar:  x86_64-w64-mingw32-gcc -O2 -s -o dpapi-seal.exe dpapi-seal.c -lcrypt32
 */
#include <windows.h>
#include <wincrypt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int hexval(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Lee todo stdin, ignora espacios/saltos, decodifica hex a bytes. Devuelve nº de bytes. */
static int read_hex_stdin(unsigned char *out, int max) {
    int n = 0, hi = -1, c;
    while ((c = getchar()) != EOF) {
        int v = hexval(c);
        if (v < 0) continue;            /* salta espacios, comillas, saltos */
        if (hi < 0) { hi = v; }
        else { if (n < max) out[n++] = (unsigned char)((hi << 4) | v); hi = -1; }
    }
    return n;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "uso: %s <seal|unseal> <entropy> (hex por stdin)\n", argv[0]);
        return 2;
    }
    int seal = strcmp(argv[1], "seal") == 0;

    static unsigned char in[1 << 20];
    int inlen = read_hex_stdin(in, sizeof(in));
    if (inlen <= 0) { fprintf(stderr, "sin datos de entrada\n"); return 3; }

    /* Entropía = login en UTF-8, SIN terminador nulo (como Steam / pywin32). */
    DATA_BLOB dataIn = { (DWORD)inlen, in };
    DATA_BLOB entropy = { (DWORD)strlen(argv[2]), (BYTE *)argv[2] };
    DATA_BLOB dataOut = { 0, NULL };

    /* En SEAL, la descripción se pasa por argv[3] (para replicar EXACTAMENTE la que usa Steam);
     * si no se pasa, NULL. En UNSEAL, se recupera la descripción real y se imprime por stderr. */
    LPWSTR descrOut = NULL;
    wchar_t descrIn[256] = {0};
    if (seal && argc >= 4) {
        int i = 0; for (; argv[3][i] && i < 255; i++) descrIn[i] = (wchar_t)(unsigned char)argv[3][i];
        descrIn[i] = 0;
    }
    BOOL ok = seal
        ? CryptProtectData(&dataIn, (argc >= 4 ? descrIn : NULL), &entropy, NULL, NULL, 0, &dataOut)
        : CryptUnprotectData(&dataIn, &descrOut, &entropy, NULL, NULL, 0, &dataOut);

    if (!ok) { fprintf(stderr, "crypt %s fallo: %lu\n", argv[1], (unsigned long)GetLastError()); return 1; }
    if (!seal && descrOut) {
        fprintf(stderr, "DESCR=");
        for (LPWSTR d = descrOut; *d; d++) fputc((int)(*d & 0xff), stderr);
        fprintf(stderr, "\n");
        LocalFree(descrOut);
    }

    for (DWORD i = 0; i < dataOut.cbData; i++) printf("%02x", dataOut.pbData[i]);
    printf("\n");
    if (dataOut.pbData) LocalFree(dataOut.pbData);
    return 0;
}
