import Testing
import Foundation
@testable import Vessel

@Suite("Contenido adicional de Epic")
struct LegendaryDLCParsingTests {
    @Test("Relaciona DLC de catálogo, app instalable y estado local")
    func parsesOwnedDLCs() {
        let output = #"""
        {
          "game": {
            "owned_dlc": [
              {
                "id": "catalog-2",
                "title": "Expansión Beta",
                "app_name": "BetaDLC",
                "installable": [{"appId": "BetaDLC"}]
              },
              {
                "id": "catalog-1",
                "title": "Contenido Alfa",
                "app_name": null,
                "installable": [{"appId": "AlphaDLC"}]
              },
              {
                "id": "catalog-3",
                "title": "Licencia integrada",
                "app_name": null,
                "installable": null
              }
            ]
          },
          "install": {
            "installed_dlc": [
              {"app_name": "BetaDLC", "title": "Expansión Beta", "install_size": 1024}
            ]
          }
        }
        """#

        let dlcs = LegendaryManager.parseDLCInfo(output)
        #expect(dlcs.map(\.title) == ["Contenido Alfa", "Expansión Beta", "Licencia integrada"])
        #expect(dlcs.map(\.appName) == ["AlphaDLC", "BetaDLC", nil])
        #expect(dlcs.map(\.installed) == [false, true, false])
        #expect(dlcs.map(\.isInstallable) == [true, true, false])
    }

    @Test("Tolera juegos sin instalación ni DLC")
    func handlesEmptyInfo() {
        #expect(LegendaryManager.parseDLCInfo(#"{"game":{"owned_dlc":[]},"install":null}"#).isEmpty)
        #expect(LegendaryManager.parseDLCInfo("respuesta inválida").isEmpty)
    }
}

@Suite("Contexto de lanzamiento de Epic")
struct LegendaryLaunchContextTests {
    @Test("Conserva el orden oficial y filtra entorno sensible o controlado por Vessel")
    func parsesAndSanitizesLaunchContext() {
        let output = #"""
        {
          "game_parameters": ["--game-flag"],
          "user_parameters": ["--user-flag"],
          "egl_parameters": ["-AUTH_LOGIN=unused", "-AUTH_PASSWORD=secret", "-EpicPortal"],
          "environment": {
            "GAME_LANGUAGE": "es",
            "PATH": "/untrusted/bin",
            "WINEPREFIX": "/untrusted/prefix",
            "DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib",
            "EPIC_AUTH_TOKEN": "must-not-leak"
          },
          "game_executable": "Melvor Idle.exe",
          "game_directory": "/Games/Melvor",
          "working_directory": "/Games/Melvor"
        }
        """#

        let context = LegendaryManager.parseLaunchContext(output)
        #expect(context?.arguments == [
            "--game-flag", "--user-flag", "-AUTH_LOGIN=unused",
            "-AUTH_PASSWORD=secret", "-EpicPortal"
        ])
        #expect(context?.environment == ["GAME_LANGUAGE": "es"])
        #expect(context?.gameExecutable == "Melvor Idle.exe")
        #expect(context?.workingDirectory == "/Games/Melvor")
    }

    @Test("Rechaza respuestas que no sean JSON")
    func rejectsInvalidLaunchContext() {
        #expect(LegendaryManager.parseLaunchContext("not-json") == nil)
    }
}

@Suite("Selección de plataforma de Epic")
struct LegendaryPlatformSelectionTests {
    @Test("Detecta la build de Mac sin perder la variante Windows del catálogo")
    func detectsCatalogPlatforms() {
        let object: [String: Any] = [
            "asset_infos": ["Windows": ["build_version": "1.WIN"],
                            "Mac": ["build_version": "1.MAC"]],
            "metadata": ["customAttributes": [
                "SupportedPlatforms": ["type": "STRING", "value": "Windows,Mac"]
            ]]
        ]
        #expect(LegendaryManager.availablePlatforms(in: object) == [.windows, .mac])
    }

    @Test("Una instalación nueva prefiere Mac y una Windows existente nunca se migra sola")
    func preservesInstalledPlatform() {
        let fresh = LegendaryManager.EpicGame(
            appName: "Anemone", title: "World of Goo", installed: false,
            nativeMacAvailable: true
        )
        let existing = LegendaryManager.EpicGame(
            appName: "Anemone", title: "World of Goo", installed: true,
            executablePath: "/Games/WorldOfGoo.exe", nativeMacAvailable: true,
            installedPlatform: "Windows"
        )
        #expect(fresh.effectivePlatform == .mac)
        #expect(existing.effectivePlatform == .windows)
    }

    @Test("La caché anterior sin campos de plataforma sigue siendo compatible")
    func decodesLegacyCache() throws {
        let data = Data(#"{"appName":"Legacy","title":"Legacy Game","installed":false}"#.utf8)
        let game = try JSONDecoder().decode(LegendaryManager.EpicGame.self, from: data)
        #expect(game.nativeMacAvailable == nil)
        #expect(game.installedPlatform == nil)
        #expect(game.effectivePlatform == .windows)
    }

    @Test("Resuelve el ejecutable nativo relativo usando el directorio oficial")
    func resolvesNativeExecutable() {
        let context = LegendaryManager.EpicLaunchContext(
            arguments: [], environment: [:],
            gameExecutable: "World Of Goo.app/Contents/MacOS/World Of Goo",
            gameDirectory: "/Native/Epic/WorldOfGoo",
            workingDirectory: nil
        )
        #expect(LegendaryManager.resolveNativeExecutable(context: context, fallback: "")
            == "/Native/Epic/WorldOfGoo/World Of Goo.app/Contents/MacOS/World Of Goo")
        #expect(LegendaryManager.resolveNativeExecutable(
            context: context,
            fallback: "/Installed/Verified.app/Contents/MacOS/Verified"
        ) == "/Installed/Verified.app/Contents/MacOS/Verified")
    }

    @Test("El lanzador devuelve y rastrea el proceso nativo real")
    @MainActor
    func launchesNativeProcess() throws {
        let context = LegendaryManager.EpicLaunchContext(
            arguments: [], environment: [:], gameExecutable: nil,
            gameDirectory: nil, workingDirectory: "/usr/bin"
        )
        let process = try LegendaryManager().launchNativeGame(
            context: context,
            fallbackExecutable: "/usr/bin/true"
        )
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
