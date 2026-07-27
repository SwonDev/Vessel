# Serie reproducible de parches de motores

Este documento conserva el código propio que, antes de la consolidación, solo existía dentro de
`~/vessel-engine-rnd`. Los árboles completos, builds y prefijos de prueba eran regenerables y no se
incluyen en el archivo del proyecto.

## Wine

- Upstream: `https://gitlab.winehq.org/wine/wine.git`.
- Base: etiqueta `wine-11.10`, commit `2cac6ccf33c0807f374dc96f5a20e35a2da86157`.
- Estado local archivado: `9211fbd7f5319bdce57a52a6b13bb8dcb40b74ba` más tres diffs sin commit.

Aplicación, en orden:

```bash
git clone https://gitlab.winehq.org/wine/wine.git wine
cd wine
git checkout 2cac6ccf33c0807f374dc96f5a20e35a2da86157
git am ../vessel-mac/docs/wine-patches/local-base/0001-winemac-dxmt-client-view.patch
git am ../vessel-mac/docs/wine-patches/local-base/0002-d3dmetal-denuvo-rosetta.patch
git apply ../vessel-mac/docs/wine-patches/0011-ntdll-macos-rosetta-wx-fault-recovery.patch
git apply ../vessel-mac/docs/wine-patches/0012-winemac-d3dmetal-multi-surface.patch
git apply ../vessel-mac/docs/wine-patches/0013-winemac-forward-compatible-opengl.patch
```

Los dos primeros ficheros preservan commits locales completos. Los parches `0011` a `0013`
preservan exactamente los cambios que seguían sin commit en el árbol de I+D.

## DXMT

- Upstream: `https://github.com/3Shain/dxmt.git`.
- Base: `fd7763b9a5c19b4c225e35e248b4071c1de7b4bc`.
- Commit local archivado: `4947032e43b359801fd1fdf2cc818e966faed1ee`.

Aplicación, en orden:

```bash
git clone https://github.com/3Shain/dxmt.git dxmt
cd dxmt
git checkout fd7763b9a5c19b4c225e35e248b4071c1de7b4bc
git am ../vessel-mac/docs/dxmt-patches/0001-fullscreen-borderless-macos.patch
git apply ../vessel-mac/docs/dxmt-patches/0002-cross-process-headless-swapchain.patch
```

El primer fichero conserva el commit local de fullscreen borderless. El segundo contiene los dos
archivos que seguían modificados sin commit: el swapchain headless entre procesos y el puente de
superficies Wine 11.

## Verificación previa a compilar

En una reconstrucción nueva, ejecuta `git apply --check` para cada parche de tipo diff antes de
aplicarlo. Los artefactos binarios que Vessel superpone a motores administrados permanecen en
`Resources/` y la app valida sus SHA-256 antes de utilizarlos.
