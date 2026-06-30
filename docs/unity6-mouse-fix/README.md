# Fix del ratón en juegos Unity 6 bajo Wine (EnableMouseInPointer)

## El problema

Los juegos **Unity 6** (p. ej. Ancient Kingdoms, Steam AppID 2241380) abren ventana bajo
Wine/macOS pero **no responden al ratón ni al teclado**: el cursor se mueve, pero los clicks y
las teclas se ignoran. No se pueden usar menús.

**Causa raíz (confirmada en el `Player.log` del juego):**

```
<RI> Initializing input.
EnableMouseInPointer failed with the following error: Call not implemented.
Using Windows.Gaming.Input
```

Unity 6 llama a `EnableMouseInPointer()` para recibir eventos `WM_POINTER` en vez de los clásicos
`WM_MOUSE`. **Wine NO implementa esa API en ninguna versión** (ni en `master`: solo guarda un flag
y devuelve `TRUE`, pero no genera los eventos `WM_POINTER`). Sin esos eventos, Unity 6 ignora todo
el input. Afecta también a Mythic, Whisky y CrossOver < 26.

## El fix (`EnableMouseInPointer-9.x.patch`)

Parche **win32u-only**, portado del de Kron4ek a Wine 9.x. Es **aditivo y pequeño**:

1. `include/ntuser.h`: añade un campo `mouse_in_pointer` a `struct ntuser_thread_info`.
2. `dlls/win32u/input.c`: implementa `NtUserEnableMouseInPointer` / `NtUserIsMouseInPointerEnabled`
   (guardan/leen el flag por hilo).
3. `dlls/win32u/message.c`: en `NtUserMessageCall`, cuando el flag está activo, convierte
   `WM_LBUTTONDOWN/UP/MOUSEMOVE` → `WM_POINTERUPDATE` con los flags `POINTER_MESSAGE_FLAG_*`.

Solo se activa si el juego llama a `EnableMouseInPointer()`, así que **no afecta a otros juegos**.

## Estado de la verificación

- ✅ **Compila** sobre el source de 3Shain (`3Shain/wine`, tag `v9.9-mingw`, reporta `wine-9.11`).
  Con toolchain nuevo hacen falta 2 workarounds que NO forman parte de este parche:
  `-std=gnu17` en el compilador PE (mingw GCC 16 trata `bool` como palabra clave C23) y anular
  `CGWindowListCreateImageFromArray` en `winemac.drv/cocoa_window.m` (eliminada del SDK macOS 15).
- ✅ El motor compilado **NO entra en bucle de procesos** (autoconsistente; sin el desajuste de ABI
  que tiene un `win32u` suelto).
- ✅ El core funciona (`wine64 --version`).

## Por qué va UPSTREAM (a 3Shain) y no se integra a mano en Vessel

Un wine-dxmt **completo y funcional** necesita las piezas propias de 3Shain — `winemetal.so`
(puente DXMT→Metal) y el `d3d11` de DXMT — que **no están en el source público de Wine** y están
compiladas contra su motor exacto. Mezclarlas con un core recompilado a mano reintroduce el
desajuste de ABI. **Solo la pipeline de build de 3Shain produce todas las piezas encajando.**

→ Por eso el fix se contribuye a **`3Shain/wine`** (o `3Shain/dxmt`). Cuando lo integren y publiquen
una release, **Vessel auto-actualiza** el motor y el ratón de Unity 6 funcionará en todos los juegos.

## Cómo enviarlo

1. Abrir un issue/PR en https://github.com/3Shain/wine con este parche.
2. Título sugerido: *"Implement EnableMouseInPointer (WM_POINTER) so Unity 6 games receive mouse/keyboard input"*.
3. Cuerpo: el problema (arriba), el `Player.log`, y el parche adjunto.

Mientras tanto, Vessel **detecta y avisa** automáticamente cuando un juego está afectado
(`UnityInputCompat`, lee el `Player.log`), para que nada falle en silencio.
