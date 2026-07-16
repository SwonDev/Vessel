# Publicar actualizaciones de Vessel con Sparkle

Vessel usa **Sparkle 2.9.4** para auto-actualizarse (firma EdDSA + delta updates), embebido en
`Contents/Frameworks/Sparkle.framework` por `build_and_run.sh`. La app comprueba el `appcast.xml` del
repo una vez al día y con el menú **Vessel → Buscar actualizaciones…**.

## Configuración (ya hecha)
- **Feed**: `SUFeedURL = https://raw.githubusercontent.com/SwonDev/Vessel/main/appcast.xml` (Info.plist).
- **Clave pública EdDSA**: `SUPublicEDKey` en el Info.plist (la genera `generate_keys`).
- **Clave privada**: en el **llavero de login** de quien publica (SwonDev). NO está en el repo. Sin ella
  no se pueden firmar releases. Para migrar de equipo: `generate_keys -x clave-privada.txt` (exportar) y
  `generate_keys -f clave-privada.txt` (importar) — guardar ese fichero de forma segura, NUNCA en git.

> Con firma ad-hoc (sin Developer ID) Sparkle valida la integridad del update por su **firma EdDSA**
> (no por la firma de código). Es el modelo correcto para apps auto-distribuidas por GitHub.

## Publicar una versión nueva — automático (recomendado)

```bash
./release.sh 0.0.2 "Qué trae esta versión"
```

`release.sh` hace **todo el ciclo**: sube `VERSION.txt` (build entero incremental) → compila y monta el
`.app` → lo comprime → lo **firma** con la clave EdDSA del llavero → crea el **GitHub Release** con el
`.zip` (tag `vX.Y.Z`) → añade el `<item>` al `appcast.xml` → commit + push. Los usuarios reciben la
actualización solos por Sparkle.

- **Versionado**: `VERSION.txt` es la ÚNICA fuente de verdad (`X.Y.Z<TAB>N`). `build_and_run.sh` la lee
  para el `Info.plist`. La serie empezó en **0.0.1** y avanza 0.0.2, 0.0.3…
- Exige el árbol de git limpio (para que el release refleje exactamente lo commiteado).
- Re-publicar la misma versión reemplaza el asset y su `<item>` (no duplica).

## Publicar a mano (si hace falta)
Herramientas en `.build/artifacts/sparkle/Sparkle/bin/` (tras `swift build`).

1. **Sube la versión** en `build_and_run.sh` (Info.plist): `CFBundleShortVersionString` (X.Y.Z) y
   `CFBundleVersion` (entero incremental N).
2. **Compila y empaqueta**:
   ```bash
   ./build_and_run.sh
   ditto -c -k --sequesterRsrc --keepParent build/Vessel.app Vessel-X.Y.Z.zip
   ```
3. **Firma el zip**:
   ```bash
   .build/artifacts/sparkle/Sparkle/bin/sign_update Vessel-X.Y.Z.zip
   # → sparkle:edSignature="…" length="…"
   ```
4. **Sube el `.zip`** a un GitHub Release en `SwonDev/Vessel` (tag `vX.Y.Z`).
5. **Añade el `<item>`** al `appcast.xml` (plantilla dentro del propio fichero) con la versión, la URL del
   asset del release, la `edSignature` y el `length` del paso 3. Haz push a `main`.

**Atajo**: `generate_appcast <carpeta_con_todos_los_zips>` regenera el `appcast.xml` entero (lee las
firmas del llavero) — útil si mantienes varias versiones.

## Verificación local
```bash
codesign --verify --strict /Applications/Vessel.app
codesign --verify --strict /Applications/Vessel.app/Contents/Frameworks/Sparkle.framework
```
Y en la app: **Vessel → Buscar actualizaciones…** (con un `<item>` de versión mayor en el appcast debe
ofrecer la actualización; sin items, dice que ya estás al día).
