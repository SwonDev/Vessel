# Auditoría de bugs (lógica pura) — hallazgos

Registro vivo de bugs de **correctness** encontrados auditando la lógica pura de Vessel (parsers,
heurísticas, rutas). Cada entrada trae fichero:línea, mecanismo, reproducción y arreglo.

- **[ARREGLADO]** — corregido con test de regresión (commit indicado). Siempre en zona no-motor.
- **[PARA KIMI]** — vive en su zona (motor / `WineManager` y los servicios de Steam que está
  tocando); **no se toca** desde aquí para no interferir. Lo arregla él.
- **[PENDIENTE]** — cambio de comportamiento que no se puede verificar sin lanzar la app; se deja
  documentado para decidir con cuidado.

---

## ✅ Arreglados — commit `f561987` (con tests en `AuditFixesTests`)

### A1. SteamGridDBClient.search — el término iba como `?term=` en vez de segmento de ruta
`Sources/Vessel/Services/SteamGridDBClient.swift`. La API v2 espera `/search/autocomplete/{term}`
(término en el PATH). Con `?term=` respondía **404** y `guard statusCode == 200` lo tragaba → la
búsqueda de carátulas devolvía **siempre vacío**. Verificado con `curl` (path → 401 con auth, query
→ 404). Ahora se construye la URL por path con encoding. Test: `searchURL`.

### A2. StandaloneMacExporter — título sin escapar en el Info.plist (XML)
`StandaloneMacExporter.infoPlist`. `\(appName)` se incrustaba crudo en `<string>…</string>`; un
título con `&`/`<`/`>`/comillas (p. ej. juegos DOS de GOG como *"Sam & Max"*) generaba un plist
**mal formado** → el `.app` exportado no arrancaba bien. Añadido `xmlEscape`. Test: `xmlEscape*`.

### A3. PhysicalMediaImporter — ruta de `autorun.inf` entre comillas con espacios se truncaba
`PhysicalMediaImporter.findInstaller`. Cortaba en el primer espacio ANTES de quitar comillas →
`open="Setup Game\setup.exe"` quedaba en `Setup` → instalador no encontrado. Nuevo
`parseAutorunTarget` que respeta comillas. Test: `autorun*`.

### A4. DRMFreeInstaller — `Content-Disposition` dejaba comilla colgando + `abs(hashValue)` trap
`DRMFreeInstaller.filename` / `sanitize`. `filename="x.exe"; filename*=…` trimeaba comillas antes de
cortar en `;` → `x.exe"` → extensión corrupta → fallo al instalar `.exe`/`.msi`. Y `abs(s.hashValue)`
puede hacer trap con `Int.min`. Arreglados (cortar en `;` primero; `.magnitude`). Tests:
`contentDisposition*`, `sanitize*`.

---

## 🔒 Para Kimi (su zona — no tocado)

### K1. `injectLaunchOptionsIntoVDF` solo inyecta en la PRIMERA app
`Sources/Vessel/Services/SteamLaunchOptionsManager.swift` — `injectLaunchOptionsIntoVDF` (≈95–169),
lógica de fin de sección en la línea **160**. **Lo llama** `WineManager.swift` (~451, ~496, ~3358).

Al cerrarse el bloque de una app (`appBlockDepth` → 0), en la MISMA iteración el `}` de esa app
cumple `trimmed == "}" && !inAppBlock && appBlockDepth == 0` y marca `inAppsSection = false` →
el bucle deja de procesar apps. Solo la **primera** app de `"apps"` recibe LaunchOptions, pese a que
el docstring dice "todos los juegos".

Repro:
```
"apps" { "111" { "LaunchOptions" "" }   "222" { } }   → solo "111" recibe las flags
```
Arreglo mínimo (no cambia el caso de 1 app): flag `closedAppBlockHere` para no tratar ese `}` como
fin de sección. **Decisión de producto:** arreglarlo inyecta en TODAS las apps, sobrescribiendo las
LaunchOptions del usuario — decidir si inyectar solo en los AppID que Vessel gestiona.

### K2. `setInstalldir` usa un string escapado-para-VDF como *template* de regex
`Sources/Vessel/Services/SteamAppManifestWriter.swift:117–122`. **Lo llama** `WineManager.swift:2697`.
`replacingOccurrences(…, options: .regularExpression)` interpreta el `with:` como plantilla, donde
`$`/`\` son metacaracteres. Un `installdir` con `$` (p. ej. `Game$1X`) se reinterpreta → manifest
corrupto → Steam re-descarga el juego. Fix: `NSRegularExpression.escapedTemplate(for:)` o escapar
`\`→`\\` y `$`→`\$` en el reemplazo. (Confianza media: raro que la carpeta lleve `$`.)

### K3. `SteamLibraryImporter.mainGameExecutable` — heurística de ejecutable (3 detalles)
`Sources/Vessel/Services/SteamLibraryImporter.swift`. **Kimi está editando este fichero ahora**;
además el resultado afecta a la selección de ejecutable AL LANZAR (zona motor), así que se deja para él:
- **:186** `serverLike` usa `base.contains("server")` → falso positivo con `Observer.exe`
  (penalización −1000). Fix: límite de palabra / igualdad, no subcadena.
- **:216–217** el chequeo del hermano `<exe>_Data` usa el *stem en minúsculas* (`rel` viene de
  `path.lowercased()`) → en volúmenes case-sensitive no encuentra `MyGame_Data`. Fix: derivar el
  stem de `full` (caso original).
- **:240 / parseManifest** el regex de valor `"([^"]+)"` corta en la primera comilla escapada `\"`
  → nombres con comillas se truncan. Fix: `"((?:[^"\\]|\\.)*)"` + des-escape.

---

## 🕗 Pendientes (mi zona, pero cambio de comportamiento no verificable sin la app)

- **StandaloneMacExporter.swift:198** — la conf de DOSBox se referencia con `../` fijo, pero la
  profundidad de `relExeDir` es dinámica. Correcto para el layout GOG típico de 1 nivel
  (`GameRoot/DOSBOX/`); rompe si el exe está en la raíz (0) o anidado (2+). Fix: un `../` por
  componente, o escribir la conf junto al exe.
- **DRMDatabase.swift:259–260 / 135–137** — negative-cache: un fallo de red deja `antiCheatIndex`
  en `[:]` toda la sesión (nunca reintenta), y cachea en disco veredictos vacíos con TTL de 7 días
  → juegos con Denuvo/anti-cheat se reportan como "sin DRM conocido". Fix: no cachear resultados
  vacíos/fallidos; separar "cargado" de "contenido".
- **DRMAnalyzer.swift:145,151** — marcadores `protect.dll`/`protect.exe`/`activation.dll` demasiado
  genéricos (middleware común) → falso positivo de DRM → un juego DRM-free no se puede "generar".
  Fix: exigir nombres específicos (`protect.x86/.x64`, `activation64.dll`) o la ruta esperada.
- **EpicDRMFreeImporter** (confianza baja) — en `sync()`, un juego con `epicSaysStandalone == true`
  pero `isStandaloneCapable == false` y `protections` vacío no se importa ni se marca como bloqueado
  (se descarta en silencio). Solo real si esa combinación puede darse.

> Revisados y **correctos** (sin bugs): parsers PE de `DRMAnalyzer` (offsets/límites), anti Zip-Slip
> de `DRMFreeInstaller` (`enforceContainment`/`safeCopy`), `DRMFreeArchive` (SHA-256/manifiesto),
> `GogdlManager` (gameRoot/playTasks/paginación/token/swap binario), `GOGDRMFreeImporter`,
> `SteamAchievementsService`, y los modelos `CompatProfile`/`Bottle`/`PlayStatsStore`/`GameLaunchTracker`.
