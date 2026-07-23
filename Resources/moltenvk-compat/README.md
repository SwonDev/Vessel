# MoltenVK de compatibilidad Vulkan nativa

Este directorio contiene el runtime `x86_64` que Vessel activa exclusivamente para juegos
Windows que usan Vulkan de forma nativa y declaran requisitos que el perfil público de MoltenVK
no anuncia (`wideLines` y más de 16 samplers por etapa).

- Upstream: MoltenVK `v1.4.1`, commit `db445ff2042d9ce348c439ad8451112f354b8d2a`.
- Arquitectura: `x86_64`, para Wine bajo Rosetta 2.
- Build: `MVK_USE_METAL_PRIVATE_API=1`.
- Parche: `docs/wine-patches/0008-moltenvk-tier2-sampler-contract.patch`.
- Licencia: Apache-2.0; el archivo `LICENSE` del upstream está incluido dentro del ZIP.

El archivo se extrae en una caché versionada y Vessel verifica tanto el ZIP como la biblioteca
antes de usarla. El perfil oficial de MoltenVK se mantiene separado para DXVK y para los juegos
que no necesitan estas capacidades.
