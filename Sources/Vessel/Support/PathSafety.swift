import Foundation

/// Seguridad de rutas para operaciones DESTRUCTIVAS (borrado) y de extracción.
///
/// Centraliza la comprobación *"canonicalizar (resolver symlinks y `..`) + exigir subcarpeta
/// ESTRICTA"* que antes estaba **duplicada** a mano en varios sitios (`BottleDetailView`,
/// `GogdlManager`, `LocalGamesStore`, `DRMFreeInstaller`), cada uno con matices — y en algún caso
/// con un chequeo DÉBIL (`hasPrefix(raíz)` sin barra final ni canonicalizar, que dejaría borrar la
/// propia raíz o una carpeta *hermana* con el mismo prefijo).
///
/// Referencia: el **incidente de borrado de prefijo** (una desinstalación borró el prefijo entero
/// porque la ruta apuntaba a la raíz). Regla del proyecto: *"Seguridad de rutas SIEMPRE antes de
/// borrar: canonicalizar + subcarpeta estricta"*. Antes de cualquier `removeItem` de datos del
/// usuario, pasar SIEMPRE por aquí.
enum PathSafety {

    /// Ruta canónica: resuelve symlinks y `..`, y normaliza (`standardizedFileURL`). Para rutas
    /// inexistentes, `resolvingSymlinksInPath` resuelve solo los componentes que sí existen.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// `true` si `path` (canonicalizado) es descendiente **estricto** de `root` (canonicalizado):
    /// está dentro de `root/…`, NO es el propio `root`, y su último componente no está vacío.
    /// No toca el disco. Rechaza rutas hermanas con prefijo común (`/a/DRMFree` vs `/a/DRMFree-x`)
    /// gracias a la barra separadora, y cualquier `..`/symlink que escape del árbol.
    static func isStrictDescendant(_ path: String, of root: String) -> Bool {
        let target = canonical(path)
        let base = canonical(root)
        guard !base.isEmpty, !target.isEmpty else { return false }
        return target.hasPrefix(base + "/")
            && target != base
            && !(target as NSString).lastPathComponent.isEmpty
    }

    /// Devuelve la ruta **canónica** de `target` SOLO si es seguro borrarla: descendiente estricto
    /// de `root` **y** existe en disco. Si no, `nil` (el llamante NO debe borrar nada). Ésta es la
    /// puerta única para `removeItem` de datos del usuario: borrar exactamente lo que devuelve.
    static func resolvedIfSafeToDelete(_ target: String, under root: String,
                                       fileManager fm: FileManager = .default) -> String? {
        guard isStrictDescendant(target, of: root) else { return nil }
        let resolved = canonical(target)
        return fm.fileExists(atPath: resolved) ? resolved : nil
    }

    /// `true` si `path` (canonicalizado) está **contenido** en `base` (canonicalizado): igual a
    /// `base` (solo si `allowingBase`) o descendiente suyo. Defensa anti *Zip-Slip* y symlinks que
    /// escapan al copiar/extraer.
    static func isContained(_ path: String, in base: String, allowingBase: Bool = false) -> Bool {
        let target = canonical(path)
        let root = canonical(base)
        guard !root.isEmpty, !target.isEmpty else { return false }
        if target == root { return allowingBase }
        return target.hasPrefix(root + "/")
    }
}
