import Foundation
import Observation

struct Bottle: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var windowsVersion: String
    var architecture: String
    var dxvkEnabled: Bool
    var dxmtEnabled: Bool
    var gptkEnabled: Bool
    var winePath: String
    var createdAt: Date
    var lastUsedAt: Date
    var notes: String
    var games: [GameInstall] = []

    init(
        id: UUID = UUID(),
        name: String,
        windowsVersion: String = "Windows 11",
        architecture: String = "win64",
        dxvkEnabled: Bool = true,
        dxmtEnabled: Bool = false,
        gptkEnabled: Bool = true,
        winePath: String = "/opt/homebrew/bin/wine64",
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.windowsVersion = windowsVersion
        self.architecture = architecture
        self.dxvkEnabled = dxvkEnabled
        self.dxmtEnabled = dxmtEnabled
        self.gptkEnabled = gptkEnabled
        self.winePath = winePath
        self.createdAt = Date()
        self.lastUsedAt = Date()
        self.notes = notes
    }

    var prefixPath: String {
        "\(NSHomeDirectory())/Library/Application Support/Vessel/Bottles/\(id.uuidString)"
    }

    var steamPath: String {
        "\(prefixPath)/drive_c/Program Files (x86)/Steam/steam.exe"
    }
}

struct GameInstall: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var executablePath: String
    var steamAppId: String?
    var installPath: String
    var installedAt: Date
    var lastPlayedAt: Date?
    var coverImageURL: String?

    init(
        id: UUID = UUID(),
        name: String,
        executablePath: String,
        steamAppId: String? = nil,
        installPath: String = "",
        coverImageURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.executablePath = executablePath
        self.steamAppId = steamAppId
        self.installPath = installPath
        self.installedAt = Date()
        self.lastPlayedAt = nil
        self.coverImageURL = coverImageURL
    }
}

/// Singleton observable. Almacena bottles y games en JSON en disco.
/// Reemplaza SwiftData para evitar errores de schema durante desarrollo.
@MainActor
@Observable
final class BottleStore {
    static let shared = BottleStore()

    private(set) var bottles: [Bottle] = []

    private let storeURL: URL

    init() {
        self.storeURL = URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/Vessel/bottles.json")
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        load()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            bottles = []
            return
        }
        do {
            let data = try Data(contentsOf: storeURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            bottles = try decoder.decode([Bottle].self, from: data)
        } catch {
            bottles = []
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(bottles)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // Silencioso: la app sigue funcionando en memoria
        }
    }

    func add(_ bottle: Bottle) {
        bottles.insert(bottle, at: 0)
        save()
    }

    func update(_ bottle: Bottle) {
        if let i = bottles.firstIndex(where: { $0.id == bottle.id }) {
            bottles[i] = bottle
            save()
        }
    }

    func delete(_ bottle: Bottle) {
        bottles.removeAll { $0.id == bottle.id }
        save()
    }

    func touch(_ bottleID: UUID) {
        if let i = bottles.firstIndex(where: { $0.id == bottleID }) {
            bottles[i].lastUsedAt = Date()
            save()
        }
    }

    func addGame(_ game: GameInstall, to bottleID: UUID) {
        if let i = bottles.firstIndex(where: { $0.id == bottleID }) {
            var newGame = game
            // installPath debe ser la carpeta del JUEGO, nunca el prefijo del bottle
            // (apuntarlo al prefijo causó borrar el prefijo entero al desinstalar). Si
            // viene vacío, se deriva de la carpeta del ejecutable.
            if newGame.installPath.isEmpty {
                newGame.installPath = (newGame.executablePath as NSString).deletingLastPathComponent
            }
            bottles[i].games.append(newGame)
            save()
        }
    }

    func deleteGame(_ gameID: UUID, from bottleID: UUID) {
        if let i = bottles.firstIndex(where: { $0.id == bottleID }) {
            bottles[i].games.removeAll { $0.id == gameID }
            save()
        }
    }

    func touchGame(_ gameID: UUID, in bottleID: UUID) {
        if let i = bottles.firstIndex(where: { $0.id == bottleID }),
           let j = bottles[i].games.firstIndex(where: { $0.id == gameID }) {
            bottles[i].games[j].lastPlayedAt = Date()
            bottles[i].lastUsedAt = Date()
            save()
        }
    }

    /// Corrige la ruta del ejecutable (y la carpeta) de un juego de Steam ya importado.
    /// AUTO-REPARACIÓN: si un escaneo previo guardó el exe equivocado (p. ej. el `server.exe`
    /// headless de un MMO), el re-escaneo lo endereza sin que el usuario tenga que reinstalar.
    /// Devuelve `true` si hubo cambio real.
    @discardableResult
    func fixGameExecutable(steamAppId: String, executablePath: String, installPath: String, in bottleID: UUID) -> Bool {
        guard let i = bottles.firstIndex(where: { $0.id == bottleID }),
              let j = bottles[i].games.firstIndex(where: { $0.steamAppId == steamAppId }),
              bottles[i].games[j].executablePath != executablePath else { return false }
        bottles[i].games[j].executablePath = executablePath
        if !installPath.isEmpty { bottles[i].games[j].installPath = installPath }
        save()
        return true
    }
}
