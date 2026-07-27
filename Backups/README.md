# Copias portátiles

Esta carpeta contiene dos bundles Git ignorados por el repositorio principal:

- `vessel-all-refs.bundle`: todas las ramas, etiquetas y objetos del proyecto Vessel.
- `vessel-db.bundle`: historial completo del repositorio independiente Vessel_DB.

Los bundles se verificaron al generarlos. Son la vía de recuperación recomendada si el disco
externo no conserva correctamente metadatos POSIX o si la carpeta `.git` resulta dañada.

```bash
git bundle verify Backups/vessel-all-refs.bundle
git clone Backups/vessel-all-refs.bundle vessel-mac-restored
git -C vessel-mac-restored switch codex/consolidated-vessel

git bundle verify Backups/vessel-db.bundle
git clone Backups/vessel-db.bundle Vessel_DB
```

No publiques estos ficheros como artefactos de una release: son copias de recuperación locales.
