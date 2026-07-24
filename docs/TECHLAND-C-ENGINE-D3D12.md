# C-Engine de Techland sobre D3D12 en macOS

Vessel conserva una ruta automática y sin configuración manual para los paquetes modernos del
C-Engine de Techland que distribuyen D3D11 y D3D12 como módulos cargados en tiempo de ejecución.
La aplicación no consulta el título ni el AppID para decidir la capa gráfica.

## Contrato observado

El ejecutable público es PE64 y enlaza la familia modular del motor:

- `engine_core_x64_rwdi.dll`;
- `engine_foundation_x64_rwdi.dll`;
- `engine_x64_rwdi.dll`, que contiene la firma interna `C-Engine`;
- `renderer_x64_rwdi.dll`, que selecciona dinámicamente `rd3d11_x64_rwdi.dll` o
  `rd3d12_x64_rwdi.dll`;
- `D3D12Core.dll`, el runtime distribuido que hace inequívoco el contrato D3D12 del paquete.

El PE principal no importa `d3d12.dll`. Tampoco lo hacen directamente las DLL de entrada del motor:
el backend `rd3d12` resuelve `D3D12CreateDevice`, `CreateDXGIFactory2` y
`D3D12SerializeRootSignature` dinámicamente. Por eso una detección limitada a la tabla de imports
del ejecutable interpretaría erróneamente el juego como un renderer desconocido.

Vessel ya resuelve este caso mediante su contrato genérico de runtime D3D12 distribuido, después de
descartar familias como Unity que tienen reglas más específicas. El resultado es `.d3d12`, capa
`GPTK/D3DMetal` y fallback restringido a esa misma capa. La prueba de caracterización reproduce el
paquete completo y también demuestra el límite negativo: los módulos opcionales D3D11/D3D12 sin
`D3D12Core.dll` siguen siendo ambiguos y no pueden cambiar por sí solos la ruta global.

## Validación real

El 24 de julio de 2026 se validó *Dying Light: The Beast* desde el botón «Jugar» de
`/Applications/Vessel.app`:

- la instalación reanudada terminó con `StateFlags=4`, build `23006686` y 69,05 GB;
- sin cambiar de vista, la fila pasó a «Instalado» y la acción primaria a «Jugar»;
- Vessel detectó Visual C++, .NET/Windows Desktop Runtime, XInput y XAudio2;
- el motor seleccionó `RendererMode("d3d12")` y `D3D_FEATURE_LEVEL_12_2`;
- el swapchain usó 3024×1964 y el render interno 1512×982, sin desbordamiento ni entrada
  desalineada;
- la compilación de pipelines terminó con cero PSO fallidos;
- el flujo alcanzó `Stage = 'Complete'` y mostró el menú principal estable;
- durante una sesión jugable real, el usuario confirmó movimiento fluido, buena respuesta y
  rendimiento sostenido, sin recortes, desbordamiento ni degradación gráfica visible.

El C-Engine crea un archivo llamado `crash_*.log` desde el inicio y se lo entrega a Crashpad como
adjunto preventivo. Su mera presencia no significa que el proceso haya fallado: en la validación
continuó registrando inicialización, memoria gráfica y transiciones de estado mientras el juego
permanecía activo.

## Límites de la corrección

- No se añaden argumentos de lanzamiento.
- No se escriben preferencias gráficas del juego.
- No se introduce una excepción por título, AppID o nombre comercial.
- No se modifica ningún motor Wine ni la ruta de otras familias.
- Un paquete incompleto o ambiguo conserva el fallback existente.

La cobertura reproducible vive en
`WineManagerGraphicsRoutingTests.testTechlandCEngineDynamicD3D12PackageKeepsExistingGPTKRoute`.
