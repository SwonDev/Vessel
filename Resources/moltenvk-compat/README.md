# MoltenVK de compatibilidad Vulkan nativa

Este directorio contiene el runtime `x86_64` que Vessel activa exclusivamente para juegos
Windows que usan Vulkan de forma nativa y demuestran estructuralmente requisitos que el perfil
público de MoltenVK no anuncia. La revisión `vessel.2` añade el contrato comprobado con id Tech:
subgrupos en vertex, samplers Tier 2, compatibilidad acotada de shaders y recomposición opt-in de
la superficie Metal al recuperar el foco.

- Upstream: MoltenVK `v1.4.1`, commit `db445ff2042d9ce348c439ad8451112f354b8d2a`.
- Arquitectura: `x86_64`, para Wine bajo Rosetta 2.
- Build: `MVK_USE_METAL_PRIVATE_API=1` y `MVK_IDTECH_FLOAT64_COMPAT=1` dentro de
  `GCC_PREPROCESSOR_DEFINITIONS`.
- Parches reproducibles, aplicados en orden:
  `docs/wine-patches/0008-moltenvk-tier2-sampler-contract.patch` y
  `docs/wine-patches/0009-moltenvk-idtech-vulkan-contract.patch`.
- Licencia: Apache-2.0; el archivo `LICENSE` del upstream está incluido dentro del ZIP.

El archivo se extrae en una caché versionada y Vessel verifica tanto el ZIP como la biblioteca
antes de usarla. El perfil oficial de MoltenVK se mantiene separado para DXVK y para los juegos
que no necesitan estas capacidades. El observador de foco permanece inactivo salvo que Vessel
inyecte `MVK_CONFIG_REFRESH_METAL_LAYER_ON_FOCUS=1` en un paquete id Tech ya verificado.

Comando de compilación reproducible desde el checkout upstream parcheado:

```sh
arch -x86_64 xcodebuild -project MoltenVKPackaging.xcodeproj \
  -scheme 'MoltenVK Package (macOS only)' -configuration Release \
  ARCHS=x86_64 ONLY_ACTIVE_ARCH=YES \
  'GCC_PREPROCESSOR_DEFINITIONS=$(inherited) MVK_USE_METAL_PRIVATE_API=1 MVK_IDTECH_FLOAT64_COMPAT=1' \
  build
```
