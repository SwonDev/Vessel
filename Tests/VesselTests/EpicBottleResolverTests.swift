import Foundation
import Testing
@testable import Vessel

@Suite("Aislamiento de prefijos Epic")
struct EpicBottleResolverTests {
    @Test("Una instalación antigua conserva el prefijo real que contiene sus archivos")
    func preservesLegacyInstalledPrefix() {
        let legacy = Bottle(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Epic Games"
        )
        let game = LegendaryManager.EpicGame(
            appName: "LegacyGame",
            title: "Legacy Game",
            installed: true,
            installPath: "\(legacy.prefixPath)/drive_c/Games/LegacyGame",
            executablePath: "\(legacy.prefixPath)/drive_c/Games/LegacyGame/game.exe"
        )

        #expect(EpicBottleResolver.existingBottle(for: game, in: [legacy])?.id == legacy.id)
    }

    @Test("Una instalación nueva no reutiliza el prefijo común")
    func newInstallDoesNotReuseSharedPrefix() {
        let legacy = Bottle(name: "Epic Games")
        let game = LegendaryManager.EpicGame(
            appName: "FreshGame",
            title: "Fresh Game",
            installed: false
        )

        #expect(EpicBottleResolver.existingBottle(for: game, in: [legacy]) == nil)
        let isolated = EpicBottleResolver.makeBottle(for: game, winePath: "/tmp/wine")
        #expect(isolated.managedStore == "epic")
        #expect(isolated.managedGameID == "FreshGame")
        #expect(isolated.name == "Epic · Fresh Game")
    }

    @Test("Reutiliza el prefijo aislado por appName aunque cambie el título")
    func reusesManagedPrefixByStableID() {
        let isolated = Bottle(
            name: "Epic · Título antiguo",
            managedStore: "epic",
            managedGameID: "StableAppName"
        )
        let game = LegendaryManager.EpicGame(
            appName: "StableAppName",
            title: "Título nuevo",
            installed: false
        )

        #expect(EpicBottleResolver.existingBottle(for: game, in: [isolated])?.id == isolated.id)
    }

    @Test("No confunde prefijos que solo comparten el comienzo del nombre")
    func rejectsPathPrefixCollision() {
        #expect(EpicBottleResolver.contains(path: "/tmp/Bottles/ABC/game", inPrefix: "/tmp/Bottles/ABC"))
        #expect(!EpicBottleResolver.contains(path: "/tmp/Bottles/ABCD/game", inPrefix: "/tmp/Bottles/ABC"))
    }

    @Test("Los bottles anteriores siguen decodificando sin metadatos de tienda")
    func decodesLegacyBottle() throws {
        let original = Bottle(name: "Anterior")
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "managedStore")
        object.removeValue(forKey: "managedGameID")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(Bottle.self, from: legacyData)
        #expect(decoded.managedStore == nil)
        #expect(decoded.managedGameID == nil)
    }
}

@Suite("Lanzamiento Epic delegado")
struct EpicDelegatedLaunchTests {
    @Test("Legendary recibe motor, prefijo y parámetros sin inyectar un separador al juego")
    func buildsDelegatedArguments() throws {
        let arguments = try #require(LegendaryManager.delegatedLaunchArguments(
            appName: "ExampleApp",
            winePath: "/Engines/wine",
            prefix: "/Bottles/Example",
            installedExecutable: "/Games/Example/game.exe",
            effectiveExecutable: "/Games/Example/game.exe",
            installPath: "/Games/Example",
            gameArguments: ["-force-d3d11", "-windowed"]
        ))

        #expect(arguments == [
            "launch", "ExampleApp",
            "--wine", "/Engines/wine",
            "--wine-prefix", "/Bottles/Example",
            "-force-d3d11", "-windowed"
        ])
    }

    @Test("Expresa un ejecutable alternativo como ruta relativa segura")
    func addsRelativeExecutableOverride() throws {
        let arguments = try #require(LegendaryManager.delegatedLaunchArguments(
            appName: "ExampleApp",
            winePath: "/Engines/wine",
            prefix: "/Bottles/Example",
            installedExecutable: "/Games/Example/game.exe",
            effectiveExecutable: "/Games/Example/bin/game-safe.exe",
            installPath: "/Games/Example",
            gameArguments: []
        ))

        #expect(arguments.contains("--override-exe"))
        #expect(arguments.last == "bin/game-safe.exe")
    }

    @Test("Usa el ejecutable detectado por Vessel si el catálogo no declara ninguno")
    func addsOverrideWhenInstalledExecutableIsMissing() throws {
        let arguments = try #require(LegendaryManager.delegatedLaunchArguments(
            appName: "ExampleApp",
            winePath: "/Engines/wine",
            prefix: "/Bottles/Example",
            installedExecutable: "",
            effectiveExecutable: "/Games/Example/bin/game.exe",
            installPath: "/Games/Example",
            gameArguments: []
        ))

        #expect(arguments.suffix(2) == ["--override-exe", "bin/game.exe"])
    }

    @Test("Rechaza overrides fuera de la instalación en vez de escapar del catálogo")
    func rejectsExternalExecutableOverride() {
        #expect(LegendaryManager.delegatedLaunchArguments(
            appName: "ExampleApp",
            winePath: "/Engines/wine",
            prefix: "/Bottles/Example",
            installedExecutable: "/Games/Example/game.exe",
            effectiveExecutable: "/tmp/untrusted.exe",
            installPath: "/Games/Example",
            gameArguments: []
        ) == nil)
    }

    @Test("Cae a la ruta directa si un argumento colisiona con Legendary")
    func rejectsLegendaryOptionCollision() {
        #expect(LegendaryManager.delegatedLaunchArguments(
            appName: "ExampleApp",
            winePath: "/Engines/wine",
            prefix: "/Bottles/Example",
            installedExecutable: "/Games/Example/game.exe",
            effectiveExecutable: "/Games/Example/game.exe",
            installPath: "/Games/Example",
            gameArguments: ["--offline"]
        ) == nil)
        #expect(LegendaryManager.delegatedLaunchArguments(
            appName: "ExampleApp",
            winePath: "/Engines/wine",
            prefix: "/Bottles/Example",
            installedExecutable: "/Games/Example/game.exe",
            effectiveExecutable: "/Games/Example/game.exe",
            installPath: "/Games/Example",
            gameArguments: ["--lang=es"]
        ) == nil)
        #expect(LegendaryManager.delegatedLaunchArguments(
            appName: "ExampleApp",
            winePath: "/Engines/wine",
            prefix: "/Bottles/Example",
            installedExecutable: "/Games/Example/game.exe",
            effectiveExecutable: "/Games/Example/game.exe",
            installPath: "/Games/Example",
            gameArguments: ["-vulkan"]
        ) == nil)
    }

    @Test("Activa el modo offline como opción de Legendary y no como argumento del juego")
    func addsAutomaticOfflineOption() throws {
        let arguments = try #require(LegendaryManager.delegatedLaunchArguments(
            appName: "ExampleApp",
            winePath: "/Engines/wine",
            prefix: "/Bottles/Example",
            installedExecutable: "/Games/Example/game.exe",
            effectiveExecutable: "/Games/Example/game.exe",
            installPath: "/Games/Example",
            gameArguments: ["-windowed"],
            offline: true
        ))

        #expect(arguments == [
            "launch", "ExampleApp",
            "--wine", "/Engines/wine",
            "--wine-prefix", "/Bottles/Example",
            "--offline", "-windowed"
        ])
    }

    @Test("La ruta directa solicita el mismo contexto offline de un solo uso")
    func buildsOfflineDirectContextArguments() {
        #expect(LegendaryManager.launchContextArguments(
            appName: "ExampleApp",
            offline: true
        ) == [
            "launch", "ExampleApp", "--dry-run", "--json", "--no-wine", "--offline"
        ])
    }
}

@Suite("Estado local de Epic")
struct EpicInstalledStateTests {
    @Test("Conserva las señales de reparación, offline y token de Legendary")
    func parsesLaunchPreflightSignals() throws {
        let data = try #require(#"""
        [{
          "app_name": "ExampleApp",
          "install_path": "/Games/Example",
          "executable": "game.exe",
          "install_size": 1234,
          "platform": "Windows",
          "needs_verification": true,
          "can_run_offline": false,
          "requires_ot": true
        }]
        """#.data(using: .utf8))

        let state = try #require(LegendaryManager.parseInstalledGames(from: data)["ExampleApp"])
        #expect(state.installPath == "/Games/Example")
        #expect(state.executable == "game.exe")
        #expect(state.installSizeBytes == 1234)
        #expect(state.platform == "Windows")
        #expect(state.needsVerification)
        #expect(state.canRunOffline == false)
        #expect(state.requiresOnlineToken == true)
    }

    @Test("Admite el diccionario persistido de installed.json aunque falte app_name")
    func parsesPersistentInstalledDictionary() throws {
        let data = try #require(#"""
        {
          "ExampleApp": {
            "install_path": "/Games/Example",
            "executable": "game.exe",
            "needs_verification": false,
            "can_run_offline": true,
            "requires_ot": false
          }
        }
        """#.data(using: .utf8))

        let state = try #require(LegendaryManager.parseInstalledGames(from: data)["ExampleApp"])
        #expect(!state.needsVerification)
        #expect(state.canRunOffline == true)
        #expect(state.requiresOnlineToken == false)
    }
}
