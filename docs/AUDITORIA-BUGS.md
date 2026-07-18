# Auditoría de bugs (lógica pura) — hallazgos

Registro vivo de bugs de **correctness** encontrados auditando la lógica pura de Vessel (parsers,
heurísticas, rutas). Cada entrada trae fichero:línea, mecanismo, reproducción y arreglo sugerido.

- Los marcados **[PARA KIMI]** viven en su zona (motor / `WineManager` y lo que llama) — **no se
  tocan** desde aquí para no interferir; los arregla él.
- Los marcados **[ARREGLADO]** se corrigieron con test de regresión en el mismo commit.

---

## 1. [PARA KIMI] `injectLaunchOptionsIntoVDF` solo inyecta en la PRIMERA app

**Fichero:** `Sources/Vessel/Services/SteamLaunchOptionsManager.swift` — `injectLaunchOptionsIntoVDF`
(≈ líneas 95–169), lógica de fin de sección en la línea **160**.
**Lo llama:** `WineManager.swift` (3 sitios: ~451, ~496, ~3358) → **zona de Kimi**.

**Síntoma:** el docstring dice *"inyecta Launch Options en **todos los juegos**"*, pero solo la
**primera** app de la sección `"apps"` de `localconfig.vdf` recibe (o se le actualiza) `LaunchOptions`.
Las demás se saltan.

**Mecanismo:** al cerrarse el bloque de una app (`appBlockDepth` llega a 0), en la MISMA iteración
se evalúa la detección de fin de sección:

```swift
// línea 160
if trimmed == "}" && !inAppBlock && appBlockDepth == 0 {
    inAppsSection = false   // ← el '}' de la 1ª app se confunde con el cierre de "apps"
}
```

Como el `}` que acaba de cerrar la primera app cumple `trimmed == "}"`, `!inAppBlock` (ya se puso
`false`) y `appBlockDepth == 0`, se marca `inAppsSection = false` y el bucle deja de procesar apps.

**Reproducción (VDF con 2 apps):**
```
"apps"
{
    "111" { "LaunchOptions" "" }
    "222" { }
}
```
Resultado: solo `"111"` acaba con las flags; `"222"` queda intacta.

**Arreglo sugerido (mínimo, no cambia el caso de 1 app):** marcar que en esta iteración se cerró un
bloque de app y no tratar ese `}` como fin de sección:

```swift
var closedAppBlockHere = false
// ... dentro de "if appBlockDepth == 0 { ... }":
closedAppBlockHere = true
// ... condición de fin de sección:
if trimmed == "}" && !inAppBlock && appBlockDepth == 0 && !closedAppBlockHere {
    inAppsSection = false
}
```

**Ojo (decisión de producto, por eso lo dejo a Kimi):** arreglarlo hace que se inyecten las flags
en **todas** las apps, sobrescribiendo cualquier LaunchOptions que el usuario tuviera puesta. Hay que
decidir si eso es deseable (quizá inyectar solo en los AppID que Vessel gestiona).
