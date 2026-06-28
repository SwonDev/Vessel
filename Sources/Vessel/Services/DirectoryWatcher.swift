import Foundation

/// Vigila una carpeta del sistema de archivos y avisa cuando su contenido cambia.
/// Lo usamos para detectar **en tiempo real** los juegos que Steam instala o
/// desinstala dentro del bottle (`steamapps/`), sin tener que reiniciar Vessel.
@MainActor
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1

    var isWatching: Bool { source != nil }

    /// Empieza a vigilar `path`. `onChange` se llama (en el hilo principal) ante
    /// cualquier escritura/renombrado/borrado dentro de la carpeta. Idempotente:
    /// reemplaza cualquier vigilancia previa.
    func start(path: String, onChange: @escaping @MainActor () -> Void) {
        stop()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        descriptor = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .link],
            queue: .main
        )
        src.setEventHandler { onChange() }
        src.setCancelHandler { [descriptor] in
            if descriptor >= 0 { close(descriptor) }
        }
        source = src
        src.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    deinit {
        source?.cancel()
    }
}
