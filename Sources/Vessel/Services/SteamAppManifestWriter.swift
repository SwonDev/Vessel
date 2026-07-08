import Foundation

/// Hace que los juegos que **Vessel instaló** aparezcan **INSTALADOS** en la biblioteca del cliente de
/// Steam, para poder ejecutarlos DESDE Steam con Steam Cloud/actualizaciones/DLC/logros nativos (como
/// CrossOver). Los juegos instalados con SteamCMD no dejan su `appmanifest` en el `steamapps/` del
/// cliente, así que Steam no los ve.
///
/// Estrategia (en orden de preferencia):
///  1. **Copiar el appmanifest REAL que SteamCMD generó** dentro de la carpeta del juego
///     (`common/<dir>/steamapps/appmanifest_<appid>.acf`). Trae `StateFlags=4`, `buildid` e
///     `InstalledDepots` con los `manifest` IDs → Steam **reconoce los ficheros y NO los redescarga**.
///     Se ajusta el `installdir` a la carpeta real del cliente (SteamCMD pudo usar otro nombre) y se
///     copian también los depots COMPARTIDOS que referencie (p. ej. *Steamworks Common Redistributables*).
///  2. **Fallback**: un appmanifest mínimo con `StateFlags=4` (Steam lo muestra instalado y verifica los
///     ficheros al lanzarlo).
///
/// Idempotente y NO destructivo: si el cliente ya tiene un manifest *instalado* (bit 4 de StateFlags),
/// no lo toca. La única unión entre el modo Vessel y el Steam-CrossOver es esta biblioteca compartida.
enum SteamAppManifestWriter {

    @discardableResult
    nonisolated static func ensureManifests(in bottle: Bottle) -> Int {
        run(steamDirectory: bottle.steamDirectory,
            games: bottle.games.compactMap { g in
                guard let a = g.steamAppId, !a.isEmpty else { return nil }
                return (appId: a, name: g.name, installPath: g.installPath, exe: g.executablePath)
            },
            steamID64: SteamAccountService.currentSteamID64)
    }

    nonisolated static func run(steamDirectory: String,
                                games: [(appId: String, name: String, installPath: String, exe: String)],
                                steamID64: String) -> Int {
        let fm = FileManager.default
        let steamapps = "\(steamDirectory)/steamapps"
        let common = "\(steamapps)/common"
        guard fm.fileExists(atPath: common) else { return 0 }
        let clientDirs = Set((try? fm.contentsOfDirectory(atPath: common)) ?? [])
        let owner = steamID64.isEmpty ? "0" : steamID64

        var created = 0
        for g in games {
            guard let installdir = installDir(forPath: g.installPath, orExecutable: g.exe, common: common),
                  clientDirs.contains(installdir) else { continue }
            let manifestPath = "\(steamapps)/appmanifest_\(g.appId).acf"

            // Si el cliente ya tiene un manifest INSTALADO (bit 4), respetarlo.
            if let existing = try? String(contentsOfFile: manifestPath, encoding: .utf8),
               stateFlags(existing) & 4 != 0 { continue }

            let scmdDir = "\(common)/\(installdir)/steamapps"
            let scmdManifest = "\(scmdDir)/appmanifest_\(g.appId).acf"

            // 1) Manifest REAL de SteamCMD (con InstalledDepots) → Steam no redescarga.
            if let scmd = try? String(contentsOfFile: scmdManifest, encoding: .utf8) {
                let fixed = setInstalldir(scmd, to: installdir)
                if (try? fixed.write(toFile: manifestPath, atomically: true, encoding: .utf8)) != nil {
                    created += 1
                    copySharedManifests(fromDir: scmdDir, toSteamapps: steamapps, clientDirs: clientDirs)
                }
                continue
            }

            // 2) Fallback: manifest mínimo.
            let size = directorySize("\(common)/\(installdir)")
            let acf = minimalManifest(appId: g.appId, name: g.name, installdir: installdir, owner: owner, size: size)
            if (try? acf.write(toFile: manifestPath, atomically: true, encoding: .utf8)) != nil { created += 1 }
        }
        return created
    }

    // MARK: - Helpers

    /// Copia los appmanifests de depots COMPARTIDOS (p. ej. `228980` Steamworks Common Redistributables)
    /// que SteamCMD dejó junto al juego, si el cliente no los tiene y su `installdir` existe en common/.
    private nonisolated static func copySharedManifests(fromDir scmdDir: String, toSteamapps steamapps: String,
                                                        clientDirs: Set<String>) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: scmdDir) else { return }
        for e in entries where e.hasPrefix("appmanifest_") && e.hasSuffix(".acf") {
            let dest = "\(steamapps)/\(e)"
            if fm.fileExists(atPath: dest) { continue }   // ya está (el principal u otro juego lo puso)
            guard let content = try? String(contentsOfFile: "\(scmdDir)/\(e)", encoding: .utf8) else { continue }
            // Solo copiar si su installdir existe en el cliente (evita depots con carpeta ausente).
            if let dir = installdirValue(content), clientDirs.contains(dir) {
                try? content.write(toFile: dest, atomically: true, encoding: .utf8)
            }
        }
    }

    private nonisolated static func installDir(forPath installPath: String, orExecutable exe: String, common: String) -> String? {
        let marker = "/steamapps/common/"
        for path in [installPath, exe] where !path.isEmpty {
            guard let r = path.range(of: marker) else { continue }
            let tail = path[r.upperBound...]
            if let slash = tail.firstIndex(of: "/") {
                let dir = String(tail[..<slash]); if !dir.isEmpty { return dir }
            } else if !tail.isEmpty { return String(tail) }
        }
        return nil
    }

    private nonisolated static func stateFlags(_ manifest: String) -> Int {
        guard let m = manifest.range(of: #""StateFlags"\s+"\d+""#, options: .regularExpression) else { return 0 }
        let digits = String(manifest[m]).filter { $0.isNumber }   // solo el valor tiene dígitos
        return Int(digits) ?? 0
    }

    private nonisolated static func installdirValue(_ manifest: String) -> String? {
        guard let r = manifest.range(of: #""installdir"\s+"[^"]*""#, options: .regularExpression) else { return nil }
        let seg = manifest[r]
        guard let q = seg.range(of: #""[^"]*"$"#, options: .regularExpression) else { return nil }
        return String(seg[q]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Reescribe el campo `installdir` del manifest al valor dado (la carpeta real del cliente).
    private nonisolated static func setInstalldir(_ manifest: String, to dir: String) -> String {
        let esc = dir.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        if manifest.range(of: #""installdir"\s+"[^"]*""#, options: .regularExpression) != nil {
            return manifest.replacingOccurrences(of: #""installdir"\s+"[^"]*""#,
                                                 with: "\"installdir\"\t\t\"\(esc)\"",
                                                 options: .regularExpression)
        }
        return manifest
    }

    private nonisolated static func directorySize(_ path: String) -> UInt64 {
        guard let en = FileManager.default.enumerator(atPath: path) else { return 0 }
        var total: UInt64 = 0
        for case let file as String in en {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: "\(path)/\(file)"),
               let s = (attrs[.size] as? NSNumber)?.uint64Value { total += s }
        }
        return total
    }

    private nonisolated static func minimalManifest(appId: String, name: String, installdir: String,
                                                    owner: String, size: UInt64) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        return """
        "AppState"
        {
        \t"appid"\t\t"\(appId)"
        \t"universe"\t\t"1"
        \t"name"\t\t"\(esc(name))"
        \t"StateFlags"\t\t"4"
        \t"installdir"\t\t"\(esc(installdir))"
        \t"LastOwner"\t\t"\(owner)"
        \t"SizeOnDisk"\t\t"\(size)"
        \t"buildid"\t\t"0"
        \t"AutoUpdateBehavior"\t\t"1"
        \t"AllowOtherDownloadsWhileRunning"\t\t"0"
        \t"ScheduledAutoUpdate"\t\t"0"
        }
        """
    }
}
