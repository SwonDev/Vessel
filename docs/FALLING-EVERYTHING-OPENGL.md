# Falling Everything/poro sobre OpenGL en macOS

Vessel detecta de forma automática las builds Windows de la familia Falling Everything/poro que
cargan `opengl32.dll` dinámicamente. No depende del nombre del juego, del AppID ni de parámetros de
lanzamiento, y no cambia la ruta gráfica de otros ejecutables SDL2.

## Causa raíz

Estos binarios no importan `opengl32.dll` en su tabla PE: lo resuelven en tiempo de ejecución. Por
ello, una inspección basada únicamente en imports no encuentra API gráfica y el fallback genérico
puede confundirlos con un juego Direct3D dinámico. En pantallas Retina, esa ruta también duplica la
escala de la ventana y desacopla el área visible de la entrada.

## Detección estructural

La ruta se activa solo cuando coinciden todas estas señales independientes:

- ejecutable PE32;
- imports reales de `SDL2.dll`, `lua51.dll`, `fmod.dll` y `fmodstudio.dll`;
- presencia de esos cuatro runtimes junto al ejecutable;
- marcador de árbol de compilación `\\fallingeverything\\`;
- mensaje interno `Failed loading win32 opengl32.dll!`;
- símbolo RTTI `.?AVGraphicsOpenGL@poro@@`.

Una firma incompleta no puede cambiar ni el motor, ni la escala, ni una decisión aprendida. Una
coincidencia completa invalida únicamente overrides automáticos antiguos; una elección manual del
usuario conserva siempre prioridad.

## Enrutamiento aislado

Vessel selecciona `wine-unified-opengl`, deja `RetinaMode=n` en el bottle y conserva el tamaño que
el propio juego guarda. La misma regla se aplica tanto al lanzamiento directo como al modo Steam
real. No se reescribe el ejecutable ni su configuración, y el motor base queda intacto.

## Validación real

El 24 de julio de 2026 se validó *Noita* desde el botón «Jugar» de la Vessel instalada en
`/Applications/Vessel.app`:

- dos arranques completos consecutivos con `wine-unified-opengl`;
- `RetinaMode=n` aplicado antes de crear la ventana;
- menú completo, escala correcta y puntero alineado;
- cambio de foco Vessel→Noita sin desbordamiento ni corrupción visual;
- configuración persistente del juego conservada en 1280×720, modo ventana;
- dos cierres limpios desde el menú del juego.

Las pruebas unitarias cubren tanto la firma positiva completa como una huella incompleta que no
puede alterar el enrutamiento.
