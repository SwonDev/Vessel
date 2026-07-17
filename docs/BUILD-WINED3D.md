# Compilar Wine (y solo `wined3d.dll`) para el motor de Vessel

Receta **verificada** para compilar WineHQ desde la fuente oficial en un Mac Apple Silicon y
producir los `wined3d.dll` (PE de 32 y 64 bits) que usan los motores de Vessel. Sirve para
cualquier parche del motor: se compila **solo el DLL** que se toca, no las ~2 h de Wine entero.

Fuente: **WineHQ 11.10 limpio** (LGPL-2.1+) — <https://dl.winehq.org/wine/source/11.x/wine-11.10.tar.xz>.
Es la misma versión que `wine-osx64` y `wine-unified`, y sus DLLs cargan también en `wine-full`.
No se usa código de CrossOver: así el binario resultante es redistribuible sin más obligación que
la propia LGPL (ver `ENGINE-SOURCE.md`).

## Requisitos

```bash
brew install bison mingw-w64          # mingw compila los PE (i686 + x86_64)
```

`bison` es obligatorio: el del sistema es la **2.3** y Wine exige ≥ 3.0. No basta con instalarlo,
hay que **ponerlo delante en el PATH** (Homebrew no lo enlaza por defecto).

## Configure — las dos trampas que cuestan una tarde

```bash
export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/bin:$PATH"

CC="clang -arch x86_64" CXX="clang++ -arch x86_64" \
../wine-11.10/configure \
  --host=x86_64-apple-darwin --build=x86_64-apple-darwin \
  --enable-archs=i386,x86_64 --with-mingw \
  --without-x --without-freetype --without-gstreamer --without-vulkan \
  --without-gnutls --without-sane --without-usb --without-pcap --without-krb5 \
  --disable-tests
```

1. **`-arch x86_64` va en el COMPILADOR, no en `arch -x86_64 configure`.**
   Bajo `arch -x86_64`, `clang -v` sigue reportando `Target: arm64-apple-darwin` (clang se
   re-ejecuta nativo). El SDK entonces incluye a la vez `libkern/arm/_OSByteOrder.h` y
   `libkern/i386/_OSByteOrder.h`, chocan, y `tools/makedep` no compila
   (`error: _OSSwapInt64`). Con `CC="clang -arch x86_64"` el target es correcto.

2. **`--build=x86_64-apple-darwin` (no `aarch64`).**
   Si `build` es arm64, configure lo trata como cross y exige `--with-wine-tools` (las
   herramientas precompiladas en nativo). Poniendo `build=x86_64` las herramientas salen x86_64 y
   corren bajo Rosetta — que es justo lo que queremos, sin build previa.

3. **`--enable-archs=i386,x86_64`**, no `--enable-win64`. Con `--enable-win64` **no existe** el
   target `dlls/wined3d/i386-windows/wined3d.dll` (`No rule to make target`), y los juegos de
   32 bits necesitan ese.

4. Configure nativo en arm64 **no vale**: pide `aarch64-w64-mingw32` (PE de ARM64) o `lld`, que no
   están. El motor de Vessel es x86_64 de todos modos.

## Compilar solo el DLL

```bash
make -j8 dlls/wined3d/x86_64-windows/wined3d.dll
make -j8 dlls/wined3d/i386-windows/wined3d.dll
```

Un par de minutos por DLL. Salen SIN strip (~27–31 MB por los símbolos): antes de meterlos en un
motor conviene `strip` o compilar sin `-g`.

## Instalarlo en un motor — SIN romper nada

Nunca se pisa un motor existente: se clona y se prueba en la copia (misma regla que los motores
`*-mousefix`). Si sale bien, se distribuye como *drop-in* con marcador de versión, igual que
`DependencyManager.applyCryptoFix` (evita re-subir 2 GB).

```bash
EN="$HOME/Library/Application Support/Vessel/Engines"
ditto "$EN/wine-full" "$EN/wine-prueba"
cp build/dlls/wined3d/i386-windows/wined3d.dll   "$EN/wine-prueba/lib/wine/i386-windows/"
cp build/dlls/wined3d/x86_64-windows/wined3d.dll "$EN/wine-prueba/lib/wine/x86_64-windows/"
xattr -dr com.apple.quarantine "$EN/wine-prueba"
```

## Instrumentar (para diagnosticar de verdad)

Un `ERR(...)` sale siempre, sin `WINEDEBUG`. Es la forma de saber **qué condición falla** en vez de
suponerlo. Ejemplo real (`wined3d_glsl_blitter_create`, tarea #58):

```c
if (device->shader_backend != &glsl_shader_backend)
{
    ERR("VESSEL-DIAG: shader_backend %p != glsl %p\n", device->shader_backend, &glsl_shader_backend);
    return NULL;
}
```

Canal de traza en Wine 11: **`+d3d`** (no `+wined3d`).
