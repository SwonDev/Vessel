# Motor de Vessel — fuente correspondiente y cumplimiento LGPL

Vessel distribuye un motor de traducción Win32→macOS basado en **Wine** y en varias librerías
de código abierto. Wine y algunas de esas librerías son **LGPL-2.1+**; este documento cumple la
obligación de la LGPL §6 de ofrecer la **fuente correspondiente** de los binarios que Vessel
descarga/empaqueta, y detalla los **parches** que aplicamos.

> Vessel **no** contiene ni redistribuye código propietario de terceros. El motor `wine-unified`
> es una build **limpia de WineHQ** (verificado: `bin/wine` reporta `wine-11.10` y no contiene
> símbolos de CodeWeavers/CrossOver). Los parches propios de Vessel se listan y publican aquí.

---

## 1. Wine (motor `wine-unified`) — LGPL-2.1+

- **Versión:** WineHQ **11.10** (`wine --version` → `wine-11.10`).
- **Fuente original (upstream):** <https://gitlab.winehq.org/wine/wine> — etiqueta `wine-11.10`.
  - Tarball: <https://dl.winehq.org/wine/source/11.x/wine-11.10.tar.xz>
- **Arquitectura:** `x86_64` (se ejecuta bajo **Rosetta 2** en Apple Silicon; corre juegos
  Windows x86/x64). Configurado con `--enable-archs=i386,x86_64`.
- **Binarios publicados:** repo público [`SwonDev/Vessel-Engines`](https://github.com/SwonDev/Vessel-Engines),
  release `engine-unified-v2` (`wine-unified.tar.zst`).

### Parches aplicados sobre WineHQ 11.10

Todos son modificaciones sobre fuente LGPL de Wine; la fuente correspondiente (WineHQ 11.10 + estos
parches) está disponible bajo la oferta escrita de la §4.

| Parche | Qué hace | Artefacto en este repo |
|---|---|---|
| `macdrv_dxmt_get_client_view` (client_view *lazy*) | Arregla la pantalla negra de DXMT en Wine 11 (crea la vista de cliente Metal bajo demanda). | build del motor (`win32u`/`winemac`) |
| `winemac` fullscreen (reescala client_view) | Fullscreen exclusivo D3D11 desde Steam: reescala la `CAMetalLayer` al pasar a pantalla completa. | `Resources/engine-steamfix/winemac.so`, `Resources/steam-engine/winemac.so` |
| `win32u` wow64 (render CEF por DXMT) | El proceso GPU del CEF de Steam (Chrome 126+) renderiza por **DXMT→Metal** en lugar de `dlopen` directo de MoltenVK (que crasheaba). | `Resources/engine-steamfix/win32u.so` |
| `bcrypt`/`secur32` con GnuTLS | Verificación de firmas **ECDSA** del login TLS de Steam (sin ellas el login se cuelga en "Iniciando sesión"). | `Resources/engine-steamfix/{bcrypt,secur32}.so` |
| `win32u` `EnableMouseInPointer` | Fix del ratón en juegos Unity (6.x y anteriores). | `docs/unity6-mouse-fix/EnableMouseInPointer-9.x.patch`, `Resources/mousefix{,-gptk}/win32u.so` |
| OpenGL *forward-compat* (motor `wine-unified-opengl`) | Aísla el fix OpenGL de *Hero of the Kingdom II* para no tocar el motor base. | `Resources/opengl-engine/winemac.so` |
| Fix **W^X / JIT** para Rosetta | Permite el JIT de Wine bajo el modelo W^X de Apple Silicon/Rosetta. | integrado en la build del motor |
| `ddraw` `SetDisplayMode` no pierde superficies | Los juegos de DirectDraw de los 90 que cambian de modo de pantalla y nunca llaman a `Restore()` dejaban de dibujar para siempre (todo `Flip` → `DDERR_SURFACELOST`). Verificado con *War Wind* (1996). | `docs/wine-patches/0002-ddraw-no-perder-superficies-en-SetDisplayMode-propio.patch`, `Resources/engine-ddrawfix/{i386,x86_64}-windows/ddraw.dll` |

> Los `*.so` publicados en `Resources/` son los **binarios objeto** de estos parches (para
> aplicarlos en caliente sin re-descargar el motor). El **código fuente** correspondiente es
> WineHQ 11.10 con los cambios descritos; disponible según la §4.

---

## 2. Librerías del motor — versiones, licencias y fuentes

El motor empaqueta estas librerías en `lib/` (todas `x86_64`, con dependencias `@loader_path`):

| Librería | Versión | Licencia | Fuente |
|---|---|---|---|
| **GnuTLS** | 3.8.13 | LGPL-2.1+ | <https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-3.8.13.tar.xz> |
| **Nettle** | 4.0 (`libnettle.9`, `libhogweed.7`) | LGPL-3+ / GPL-2+ | <https://ftp.gnu.org/gnu/nettle/nettle-4.0.tar.gz> |
| **FreeType** | 2.14.3 | FTL / GPL-2 (dual) | <https://download.savannah.gnu.org/releases/freetype/freetype-2.14.3.tar.xz> |
| **wine-mono** | 11.2.0 | MIT / LGPL (componentes) | <https://github.com/wine-mono/wine-mono/releases/tag/wine-mono-11.2.0> |
| **DXMT** | (3Shain) | Apache-2.0 / MIT | <https://github.com/3Shain/dxmt> |
| **MoltenVK** | — | Apache-2.0 | <https://github.com/KhronosGroup/MoltenVK> |
| **libpng / brotli / bzip2 / zlib / gmp** | (deps de freetype/gnutls) | zlib / MIT / BSD / LGPL | fuentes upstream respectivas |

### Notas de build (Rosetta x86_64, macOS Apple Silicon)

- **GnuTLS 3.8.13** se cross-compila para `x86_64` con `--disable-hardware-acceleration`
  (la crypto acelerada por ASM x86 no enlaza en cross; el símbolo `__ctx_init` falla), enlazada
  contra **Nettle 4.0** (GnuTLS 3.8.13 requiere sus símbolos, ausentes en Nettle 3.9).
- **Nettle 4.0** se cross-compila con `--host=x86_64-apple-darwin --build=aarch64-apple-darwin`.
- **FreeType 2.14.3** se compila con la misma *feature set* que la 2.13.3 previa
  (zlib+bzip2+png+brotli, **sin** harfbuzz); ABI estable (soname 6), *drop-in*.
- Validación: GnuTLS 3.8.13 negocia un **handshake TLS 1.3 real** (AES-256-GCM + ECDHE-RSA)
  contra `api.steampowered.com`; FreeType reporta `FT_Library_Version = 2.14.3`; `wine-11.10`
  arranca limpio con toda la cadena.

---

## 3. Cómo reconstruir el motor

1. Descarga WineHQ 11.10 del *upstream* (§1) y aplica los parches de la tabla de la §1.
2. Compila para `x86_64` con `--enable-archs=i386,x86_64` e integra **DXMT** en el `d3d11`
   *builtin* (`lib/wine/x86_64-windows`).
3. Compila las librerías de la §2 para `x86_64` (ver notas de build) y colócalas en `lib/` con
   `install_name`/deps a `@loader_path`.
4. Quita *quarantine* (`xattr -d com.apple.quarantine`) y firma ad-hoc (`codesign --sign -`)
   todos los Mach-O.

---

## 4. Oferta escrita de fuente correspondiente (LGPL §6)

Para cualquier binario LGPL que Vessel distribuya (Wine y las librerías LGPL de la §2), SwonDev
ofrece la **fuente correspondiente completa** — el upstream indicado más los parches de este
documento — durante al menos tres años. Solicítala abriendo una *issue* en
<https://github.com/SwonDev/Vessel> o en <https://github.com/SwonDev/Vessel-Engines>.

Los parches propios de Vessel sobre Wine se publican en este repositorio (`Resources/` y
`docs/`) y se ofrecen bajo los mismos términos LGPL-2.1+ que el Wine que modifican.
