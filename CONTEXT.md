# Contexto para reanudar Vessel

## Estado canónico

Esta carpeta es la única copia de trabajo canónica de Vessel. El estado completo quedó consolidado
el 27 de julio de 2026 en la rama `codex/consolidated-vessel` y en la etiqueta
`archive-2026-07-27`.

- Repositorio principal: `https://github.com/SwonDev/Vessel.git`.
- Plataforma: macOS 15 o posterior, Apple Silicon, SwiftPM puro.
- Entorno validado: Xcode 26.6 y Swift 6.3.3.
- Validación de archivo: 398 pruebas XCTest y 100 pruebas Swift Testing aprobadas; 9 pruebas
  de integración real quedaron omitidas porque requieren juegos, ventanas o descargas.
- `DESIGN.md` sigue siendo la fuente de verdad visual.
- Los parches reproducibles de Wine y DXMT están descritos en `docs/ENGINE-PATCHES.md`.

Las ramas históricas se conservan dentro de `.git`; ya no necesitan worktrees separados. El único
cambio que vivía en el antiguo worktree `vessel-mac-integration` quedó guardado en la rama
`codex/engine-rd-phase5`.

## Qué no forma parte del archivo

No se conservan la app instalada, motores descargados, botellas Wine, juegos, cachés, logs,
prefijos de prueba, árboles de compilación ni la copia local de las fuentes públicas de CrossOver.
Todo ello era regenerable y ocupaba decenas de gigabytes. El código y los parches propios sí están
versionados en este repositorio.

## Primera comprobación al recuperar la carpeta

```bash
cd /ruta/a/vessel-mac
git status --short --branch
git fsck --full
xcodebuild -version
swift --version
swift package resolve
swift test
```

Si la carpeta se copió a un disco exFAT y se perdieron permisos o enlaces simbólicos, restaura el
repositorio en un volumen APFS desde `Backups/vessel-all-refs.bundle`:

```bash
git clone Backups/vessel-all-refs.bundle vessel-mac-restored
cd vessel-mac-restored
git switch codex/consolidated-vessel
swift test
```

La base de datos comunitaria independiente se restaura con:

```bash
git clone Backups/vessel-db.bundle Vessel_DB
```

## Volver a instalar Vessel

El script de empaquetado compila en release, construye `build/Vessel.app`, firma de forma ad hoc e
instala en `/Applications/Vessel.app`. Para instalar sin abrir la app automáticamente:

```bash
VESSEL_NO_LAUNCH=1 ./build_and_run.sh
```

En el primer uso, Vessel volverá a descargar los motores administrados que necesite. No debe buscar
ni reutilizar runtimes de CrossOver u otras aplicaciones.

## Antes de continuar el desarrollo

1. Lee `AGENTS.md` si aparece en una ubicación superior, además de `DESIGN.md` y este archivo.
2. Comprueba `git status`, las ramas y el grafo antes de editar.
3. Trabaja en una rama nueva fuera de `main` si hay otro agente o desarrollador activo.
4. Para compatibilidad de juegos, valida proceso, ventana, foco, logs y una sesión jugable; no des
   por resuelta una regresión solo porque no haya un crash explícito.
