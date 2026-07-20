# Backend DXVK aislado para Chowdren/SDL2 D3D9

Vessel distribuye una variante x86 de `d3d9.dll` basada en DXVK 1.10.3 exclusivamente para
runtimes Chowdren que incorporan SDL2 y usan su renderer D3D9. No sustituye el DXVK general del
bottle ni se aplica a SDL2 genérico, Direct3D 3D o motores que necesiten samplers de profundidad.

## Procedencia reproducible

- Proyecto original: <https://github.com/doitsujin/dxvk>
- Tag: `v1.10.3`
- Commit: `e4fd5e9e8d335e8a2c0814829207cbd421f7e40e`
- Parche Vessel: `docs/wine-patches/0004-dxvk-chowdren-moltenvk-samplers.patch`
- Artefacto: `d3d9-chowdren-x32-1.10.3-vessel.1.dll`
- SHA-256: `75956ab4e7ca36dcbcd29866a225c5e879dba916460cc674e4fd1d874c6d0351`

## Compilación

Con Meson, Ninja, MinGW-w64 y glslang instalados:

```sh
git clone --branch v1.10.3 --depth 1 https://github.com/doitsujin/dxvk.git
cd dxvk
git apply /ruta/a/0004-dxvk-chowdren-moltenvk-samplers.patch
meson setup build32 --cross-file build-win32.txt --buildtype release \
  -Denable_tests=false -Dbuild_id=false -Denable_dxgi=false \
  -Denable_d3d10=false -Denable_d3d11=false \
  -Dcpp_args="['-include','cstdint']"
meson compile -C build32
i686-w64-mingw32-strip -o d3d9-chowdren-x32-1.10.3-vessel.1.dll \
  build32/src/d3d9/d3d9.dll
```

## Motivo de los cambios

MoltenVK no implementa `geometryShader` ni `shaderCullDistance`; DXVK 1.10.3 las solicitaba aunque
esta carga 2D no las usa. Además, el traductor de shaders D3D9 declaraba en un mismo binding una
textura de color y otra de comparación de profundidad. Metal rechaza esa duplicidad. La variante
elimina únicamente el camino de profundidad para esta familia 2D y se selecciona mediante las
firmas estructurales `CHOWDREN_SDL_DEBUG`, `CHOWDREN_SDL_LOG`, `SDL_CreateRenderer`,
`SDL_Direct3D9GetAdapterIndex` y la importación PE real de `d3d9.dll`.

DXVK se distribuye bajo la licencia zlib/libpng incluida en `docs/licenses/DXVK.txt`.
