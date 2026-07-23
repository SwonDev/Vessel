import Foundation

/// Vigila una carpeta del sistema de archivos y avisa cuando su contenido cambia.
/// Lo usamos para detectar **en tiempo real** los juegos que Steam instala o
/// desinstala dentro del bottle (`steamapps/`), sin tener que reiniciar Vessel.
@MainActor
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: Int32 = -1
    private var watchedPath: String?

    var isWatching: Bool { source != nil }

    func isWatching(path: String) -> Bool {
        source != nil && watchedPath == Self.normalized(path)
    }

    /// Empieza a vigilar `path`. `onChange` se llama (en el hilo principal) ante
    /// cualquier escritura/renombrado/borrado dentro de la carpeta. Es idempotente para la misma
    /// ruta: volver Vessel al primer plano no cancela y recrea innecesariamente el descriptor.
    func start(path: String, onChange: @escaping @MainActor () -> Void) {
        let normalizedPath = Self.normalized(path)
        guard !isWatching(path: normalizedPath) else { return }
        stop()
        let fd = open(normalizedPath, O_EVTONLY)
        guard fd >= 0 else { return }
        descriptor = fd
        watchedPath = normalizedPath
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
        watchedPath = nil
    }

    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    deinit {
        source?.cancel()
    }
}
