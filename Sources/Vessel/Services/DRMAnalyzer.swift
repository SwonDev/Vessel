import Foundation

/// **Analizador universal de DRM** de un juego de Windows, SIN ejecutarlo. Sirve para cualquier
/// origen (Steam, GOG, itch, Humble, suelto) y clasifica lo que hay en disco.
///
/// Dos reglas de diseño que salieron de verificar la teoría contra juegos reales:
///
///  1. **El SteamStub se analiza en el exe que se va a LANZAR, no en todos.** `Palworld.exe` (408 KB)
///     es un *shim* lanzador CON SteamStub, mientras el binario real
///     (`Pal/Binaries/Win64/Palworld-Win64-Shipping.exe`, 148 MB) está LIMPIO → Palworld es DRM‑free
///     (PCGamingWiki coincide). Escanear todos los exes lo marcaría mal.
///  2. **Los marcadores de FICHERO sí exigen recorrer el árbol** (anti‑cheat, `Core/Activation64.dll`
///     de EA, `PlayGTAV.exe`, DRM legacy…): viven en subcarpetas, no junto al exe principal.
///
/// **Taxonomía de dos niveles** (el error que comete Bottles es mezclarlos): `Social/API` — Steamworks,
/// EOS, Galaxy — **NO es DRM y nunca se avisa** (5 juegos del usuario llevan EOSSDK, incluido Palworld,
/// y funcionan). `Protección` — Denuvo, anti‑cheat, DRM de cuenta — sí se avisa.
///
/// **Límite honesto**: la señal decisiva de muchos DRM vive FUERA del disco (token de Denuvo, licencia
/// por dispositivo de UWP, token de Epic/Battle.net en servidor). Un escáner de ficheros NO puede ser
/// completo por construcción → se complementa con `DRMDatabase`.
enum DRMAnalyzer {

    // MARK: - Taxonomía

    /// Protección real: impide (o compromete) ejecutar el juego como copia local independiente.
    enum Protection: String, Codable, Sendable, CaseIterable {
        case steamStub, denuvo, vmProtect, themida, enigma, armadillo
        case easyAntiCheat, battlEye, gameGuard, vanguard, xigncode
        case eaActivation, ubisoftConnect, rockstarLauncher
        case secuROM, safeDisc, starForce, tages, laserLock

        var label: String {
            switch self {
            case .steamStub: return "DRM de Steam (SteamStub/CEG)"
            case .denuvo: return "Denuvo Anti-Tamper"
            case .vmProtect: return "VMProtect"
            case .themida: return "Themida/WinLicense"
            case .enigma: return "Enigma Protector"
            case .armadillo: return "Armadillo"
            case .easyAntiCheat: return "Easy Anti-Cheat"
            case .battlEye: return "BattlEye"
            case .gameGuard: return "nProtect GameGuard"
            case .vanguard: return "Riot Vanguard"
            case .xigncode: return "XIGNCODE3"
            case .eaActivation: return "EA (activación)"
            case .ubisoftConnect: return "Ubisoft Connect"
            case .rockstarLauncher: return "Rockstar Games Launcher"
            case .secuROM: return "SecuROM"
            case .safeDisc: return "SafeDisc"
            case .starForce: return "StarForce"
            case .tages: return "TAGES"
            case .laserLock: return "LaserLock"
            }
        }

        /// Anti-cheat de modo KERNEL → imposible en macOS bajo Wine, hoy y previsiblemente siempre.
        /// (Dataset de Heroic para macOS: 1.166 juegos, **0 funcionando**.)
        var isKernelAntiCheat: Bool {
            [.easyAntiCheat, .battlEye, .gameGuard, .vanguard, .xigncode].contains(self)
        }
        /// DRM legacy con driver ring‑0 → imposible en macOS.
        var isRing0Legacy: Bool { [.secuROM, .safeDisc, .starForce, .tages, .laserLock].contains(self) }
    }

    /// SDK social/API: **NO es DRM**. Se detecta solo para informar y decidir si hace falta Goldberg.
    enum SocialAPI: String, Codable, Sendable {
        case steamworks, epicOnlineServices, gogGalaxy
        var label: String {
            switch self {
            case .steamworks: return "Steamworks (logros/nube)"
            case .epicOnlineServices: return "Epic Online Services"
            case .gogGalaxy: return "GOG Galaxy"
            }
        }
    }

    struct Report: Sendable {
        var protections: [Protection] = []
        var social: [SocialAPI] = []
        /// Ficheros que dispararon cada detección (para poder auditar y no ser una caja negra).
        var evidence: [String: String] = [:]

        /// Corre como copia local independiente: sin protección que lo impida.
        var isStandaloneCapable: Bool { protections.isEmpty }
        /// Necesita Goldberg (usa Steamworks pero no tiene DRM real).
        var needsGoldberg: Bool { social.contains(.steamworks) && protections.isEmpty }
        /// Muros imposibles en macOS (anti-cheat kernel o DRM legacy con driver).
        var macWalls: [Protection] { protections.filter { $0.isKernelAntiCheat || $0.isRing0Legacy } }

        var summary: String {
            if protections.isEmpty {
                let s = social.map(\.label).joined(separator: ", ")
                return s.isEmpty ? "DRM‑free (sin protecciones ni SDK)" : "DRM‑free · usa \(s) (no es DRM)"
            }
            return protections.map(\.label).joined(separator: " · ")
        }
    }

    // MARK: - Análisis

    /// Analiza el juego: `executable` es el que se LANZARÍA; `folder` la raíz del juego.
    static func analyze(folder: String, executable: String) -> Report {
        var r = Report()

        // 1) SteamStub — SOLO en el exe que se lanza (ver regla 1 de la doc).
        if SteamDRMScanner.hasSteamStub(executable)
            || SteamDRMScanner.hasLegacyValveRunMeBootstrap(executable) {
            r.protections.append(.steamStub)
            r.evidence[Protection.steamStub.rawValue] = (executable as NSString).lastPathComponent
        }

        // 2) Secciones del PE del exe lanzado (+ GameAssembly.dll: en Unity, Denuvo va AHÍ, no en el exe).
        var pes = [executable]
        let ga = "\((executable as NSString).deletingLastPathComponent)/GameAssembly.dll"
        if FileManager.default.fileExists(atPath: ga) { pes.append(ga) }
        for pe in pes {
            let sectionNames = peSectionNames(pe)
            let sections = Set(sectionNames)
            let leaf = (pe as NSString).lastPathComponent
            if !sections.isDisjoint(with: [".vmp0", ".vmp1", ".vmp2"]) { add(&r, .vmProtect, leaf) }
            if !sections.isDisjoint(with: [".themida", ".winlice", ".vlizer"]) { add(&r, .themida, leaf) }
            if !sections.isDisjoint(with: [".enigma1", ".enigma2"]) { add(&r, .enigma, leaf) }
            // Builds recientes de Enigma pueden borrar los nombres de casi toda la tabla de
            // secciones: Kunitsu-Gami conserva 11 secciones, pero solo `.rsrc` tiene nombre. En
            // ese layout la firma ASCII del propio protector sigue presente. Exigimos AMBAS
            // señales para no confundir una mención documental a Enigma dentro de un PE normal.
            let namedSections = sectionNames.filter { !$0.isEmpty }
            let opaqueSectionLayout = sectionNames.count >= 6
                && namedSections.count <= max(1, sectionNames.count / 4)
            if opaqueSectionLayout, containsASCII(pe, "Enigma Protector") {
                add(&r, .enigma, leaf)
            }
            if !sections.isDisjoint(with: [".securom", ".dsstext", ".cms_t", ".cms_d"]) { add(&r, .secuROM, leaf) }
            if sections.contains("stxt371") || sections.contains("stxt774") { add(&r, .safeDisc, leaf) }
            if !sections.isDisjoint(with: [".brick", ".sforce", ".sforce3"]) { add(&r, .starForce, leaf) }
            if hasArmadilloLinkerStamp(pe) { add(&r, .armadillo, leaf) }

            // Denuvo: el string `denuvo_atd` es EL marcador fiable (el literal "Denuvo" NO aparece).
            // Las secciones (.arch/.xtls/.ecode…) son solo una PUERTA, nunca conclusión: `.srdata`
            // está descartada a propósito por dar muchos falsos positivos.
            if containsASCII(pe, "denuvo_atd") { add(&r, .denuvo, leaf) }
        }

        // 3) Marcadores de FICHERO — exigen recorrer el árbol (ver regla 2).
        let files = fileIndex(of: folder)
        func hit(_ needles: [String]) -> String? { needles.first { files.contains($0) } }

        if let f = hit(["easyanticheat_setup.exe", "easyanticheat_eos_setup.exe", "easyanticheat_x64.dll",
                        "easyanticheat.exe", "easyanticheat_x86.dll"]) { add(&r, .easyAntiCheat, f) }
        if let f = hit(["beclient_x64.dll", "beservice_x64.exe", "beclient.dll", "bedaisy.sys"]) { add(&r, .battlEye, f) }
        if let f = hit(["gameguard.des"]) { add(&r, .gameGuard, f) }
        if let f = hit(["vgk.sys", "vgc.exe"]) { add(&r, .vanguard, f) }
        if let f = hit(["xhunter1.sys"]) { add(&r, .xigncode, f) }
        // EA: `Core\Activation64.dll` = "EA DRM Helper" (fiable). NO `EACore.dll` (es un IOC de
        // sideloading → 100 % falsos positivos) ni `installerdata.xml` (no prueba DRM).
        if let f = hit(["activation64.dll", "activation.dll"]) { add(&r, .eaActivation, f) }
        // Ubisoft: el loader vive en profundidad. `upc.exe` NO vale: es del cliente, no del juego.
        if let f = hit(["uplay_r1_loader64.dll", "uplay_r1_loader.dll", "upc_r2_loader64.dll"]) { add(&r, .ubisoftConnect, f) }
        if let f = hit(["playgtav.exe"]) { add(&r, .rockstarLauncher, f) }
        if let f = hit(["00000001.tmp", "clcd16.dll", "clcd32.dll", "secdrv.sys", "drvmgt.dll"]) { add(&r, .safeDisc, f) }
        if let f = hit(["cms16.dll", "cms_95.dll", "cms_nt.dll", "sintf32.dll", "sintf16.dll", "sintfnt.dll"]) { add(&r, .secuROM, f) }
        if let f = hit(["protect.dll", "protect.exe", "protect.x86", "protect.x64"]) { add(&r, .starForce, f) }
        if let f = hit(["devx.sys", "tagesclient.exe", "wave.aif"]) { add(&r, .tages, f) }
        if let f = hit(["nomouse.sp", "l16dll.dll"]) { add(&r, .laserLock, f) }

        // 4) SDK sociales — informativos, NUNCA una advertencia.
        if files.contains("steam_api64.dll") || files.contains("steam_api.dll") { r.social.append(.steamworks) }
        if files.contains(where: { $0.hasPrefix("eossdk-") }) { r.social.append(.epicOnlineServices) }
        if files.contains("galaxy64.dll") || files.contains("galaxy.dll") { r.social.append(.gogGalaxy) }

        r.protections = Array(Set(r.protections)).sorted { $0.rawValue < $1.rawValue }
        return r
    }

    // MARK: - Internos

    private static func add(_ r: inout Report, _ p: Protection, _ evidence: String) {
        r.protections.append(p)
        r.evidence[p.rawValue] = evidence
    }

    /// Índice de nombres de fichero (en minúscula) de todo el árbol. Acotado para no penalizar
    /// bibliotecas enormes: los marcadores viven cerca de la raíz o en carpetas conocidas.
    private static func fileIndex(of folder: String, maxEntries: Int = 20_000) -> Set<String> {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: folder) else { return [] }
        var out = Set<String>()
        var count = 0
        while let rel = en.nextObject() as? String {
            count += 1
            if count > maxEntries { break }
            out.insert(((rel as NSString).lastPathComponent).lowercased())
        }
        return out
    }

    /// Nombres de las secciones del PE (vacío si no es un PE válido).
    static func peSectionNames(_ path: String) -> [String] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 16384), data.count > 0x40 else { return [] }
        let b = [UInt8](data)
        func u16(_ o: Int) -> Int { o + 1 < b.count ? Int(b[o]) | (Int(b[o+1]) << 8) : 0 }
        func u32(_ o: Int) -> Int {
            o + 3 < b.count ? Int(b[o]) | (Int(b[o+1]) << 8) | (Int(b[o+2]) << 16) | (Int(b[o+3]) << 24) : 0
        }
        guard b[0] == 0x4D, b[1] == 0x5A else { return [] }
        let pe = u32(0x3C)
        guard pe > 0, pe + 24 < b.count, b[pe] == 0x50, b[pe+1] == 0x45 else { return [] }
        let n = u16(pe + 6), so = u16(pe + 20)
        var off = pe + 24 + so
        var names: [String] = []
        for _ in 0..<max(0, min(n, 96)) {
            guard off + 40 <= b.count else { break }
            names.append(String(decoding: b[off..<off+8].prefix { $0 != 0 }, as: UTF8.self).lowercased())
            off += 40
        }
        return names
    }

    /// Armadillo firma el PE con LinkerVersion 0x53/0x52 ('S','R' = Silicon Realms). Comprobación
    /// baratísima y fiable.
    private static func hasArmadilloLinkerStamp(_ path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 4096), data.count > 0x40 else { return false }
        let b = [UInt8](data)
        guard b[0] == 0x4D, b[1] == 0x5A else { return false }
        let pe = Int(b[0x3C]) | (Int(b[0x3D]) << 8) | (Int(b[0x3E]) << 16) | (Int(b[0x3F]) << 24)
        guard pe > 0, pe + 28 < b.count, b[pe] == 0x50, b[pe+1] == 0x45 else { return false }
        // Optional header: Magic(2) + MajorLinkerVersion(1) + MinorLinkerVersion(1)
        return b[pe + 24 + 2] == 0x53 && b[pe + 24 + 3] == 0x52
    }

    /// Busca una cadena ASCII en el fichero (mapeado). Para `denuvo_atd`, el marcador definitivo.
    private static func containsASCII(_ path: String, _ needle: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              let n = needle.data(using: .ascii) else { return false }
        return data.range(of: n) != nil
    }
}
