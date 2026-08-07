import Foundation
import XCTest
@testable import Vessel

/// Caracteriza el estado en el que queda un bottle cuando el **primer bootstrap** del
/// cliente de Steam se interrumpe a medias.
///
/// El bootstrapper de Valve extrae su paquete por partes: `steamui.dll` aparece en disco
/// bastante antes de que el cliente esté completo (falta todavía el CEF, que es quien
/// pinta la interfaz). Si Vessel da por bootstrapeado ese estado intermedio, aplica la
/// configuración de cliente maduro —`steam.cfg` con `BootStrapperInhibitAll` y los flags
/// `-skipinitialbootstrap` / `-noverifyfiles`— y con ella Steam **ya no puede terminar de
/// instalarse ni repararse**: cada arranque muere con "Failed to load steamui.dll".
///
/// El estado además se realimenta: como `steamui.dll` sigue existiendo, todos los
/// arranques posteriores repiten la misma decisión y el usuario no sale nunca del error.
@MainActor
final class SteamClientBootstrapTests: XCTestCase {

    // MARK: - Utilidades

    /// Crea un bottle temporal con un árbol de Steam bajo su prefijo real y lo limpia al salir.
    private func makeBottle() -> Bottle {
        let bottle = Bottle(name: "VesselSteamBootstrapTest")
        addTeardownBlock { [path = bottle.prefixPath] in
            try? FileManager.default.removeItem(atPath: path)
        }
        return bottle
    }

    /// Instala el bootstrapper (`steam.exe`) sin nada más: lo que deja `SteamSetup.exe /S`.
    @discardableResult
    private func seedBootstrapper(in bottle: Bottle) throws -> String {
        let steamDirectory = "\(bottle.prefixPath)/drive_c/Program Files (x86)/Steam"
        try FileManager.default.createDirectory(
            atPath: steamDirectory,
            withIntermediateDirectories: true
        )
        try Data("MZ bootstrapper".utf8).write(to: URL(fileURLWithPath: "\(steamDirectory)/steam.exe"))
        return steamDirectory
    }

    /// Añade los artefactos que definen un cliente ya descargado por completo.
    private func seedFullClient(in steamDirectory: String) throws {
        try Data("steamui payload".utf8).write(
            to: URL(fileURLWithPath: "\(steamDirectory)/steamui.dll")
        )
        try Data("steamclient payload".utf8).write(
            to: URL(fileURLWithPath: "\(steamDirectory)/steamclient64.dll")
        )
        let cefDirectory = "\(steamDirectory)/bin/cef/cef.win64"
        try FileManager.default.createDirectory(
            atPath: cefDirectory,
            withIntermediateDirectories: true
        )
        try Data("steamwebhelper payload".utf8).write(
            to: URL(fileURLWithPath: "\(cefDirectory)/steamwebhelper.exe")
        )
    }

    // MARK: - Detección de bootstrap

    /// Un cliente a medio extraer (solo `steamui.dll`) NO puede darse por bootstrapeado.
    func testPartiallyExtractedClientIsNotBootstrapped() throws {
        let bottle = makeBottle()
        let steamDirectory = try seedBootstrapper(in: bottle)
        try Data("steamui payload".utf8).write(
            to: URL(fileURLWithPath: "\(steamDirectory)/steamui.dll")
        )

        XCTAssertFalse(
            WineManager().isSteamBootstrapped(in: bottle),
            "Con solo steamui.dll el cliente sigue incompleto: falta el CEF que pinta la interfaz."
        )
    }

    /// Un `steamui.dll` de cero bytes es una escritura a medias, no un cliente instalado.
    func testEmptySteamUIIsNotBootstrapped() throws {
        let bottle = makeBottle()
        let steamDirectory = try seedBootstrapper(in: bottle)
        try seedFullClient(in: steamDirectory)
        try Data().write(to: URL(fileURLWithPath: "\(steamDirectory)/steamui.dll"))

        XCTAssertFalse(
            WineManager().isSteamBootstrapped(in: bottle),
            "Un steamui.dll vacío es una extracción interrumpida."
        )
    }

    /// El cliente completo sí se reconoce (no se rompe el camino bueno).
    func testFullyExtractedClientIsBootstrapped() throws {
        let bottle = makeBottle()
        let steamDirectory = try seedBootstrapper(in: bottle)
        try seedFullClient(in: steamDirectory)

        XCTAssertTrue(
            WineManager().isSteamBootstrapped(in: bottle),
            "Con steamui.dll, steamclient64.dll y el CEF extraídos el cliente está listo."
        )
    }

    /// Un cliente de la era Gcenx (CEF `cef.win7x64`) también cuenta como completo.
    func testLegacyCEFLayoutIsBootstrapped() throws {
        let bottle = makeBottle()
        let steamDirectory = try seedBootstrapper(in: bottle)
        try Data("steamui payload".utf8).write(
            to: URL(fileURLWithPath: "\(steamDirectory)/steamui.dll")
        )
        try Data("steamclient payload".utf8).write(
            to: URL(fileURLWithPath: "\(steamDirectory)/steamclient.dll")
        )
        let cefDirectory = "\(steamDirectory)/bin/cef/cef.win7x64"
        try FileManager.default.createDirectory(
            atPath: cefDirectory,
            withIntermediateDirectories: true
        )
        try Data("steamwebhelper payload".utf8).write(
            to: URL(fileURLWithPath: "\(cefDirectory)/steamwebhelper.exe")
        )

        XCTAssertTrue(
            WineManager().isSteamBootstrapped(in: bottle),
            "El cliente clásico de 32 bits usa steamclient.dll y cef.win7x64."
        )
    }

    // MARK: - Política de steam.cfg

    /// Sobre un cliente incompleto NO puede escribirse el inhibidor del bootstrapper:
    /// es justo lo que impide que Steam termine de instalarse.
    func testSteamConfigIsNotWrittenOverAnIncompleteClient() throws {
        let bottle = makeBottle()
        let steamDirectory = try seedBootstrapper(in: bottle)
        try Data("steamui payload".utf8).write(
            to: URL(fileURLWithPath: "\(steamDirectory)/steamui.dll")
        )

        WineManager().ensureSteamConfig(in: bottle)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: "\(steamDirectory)/steam.cfg"),
            "BootStrapperInhibitAll sobre un cliente incompleto lo deja sin forma de repararse."
        )
    }

    /// Reparación de los bottles ya afectados: si el cliente está incompleto y arrastra un
    /// `steam.cfg` de una versión anterior, hay que retirarlo para que Steam se recomponga.
    func testSteamConfigIsRemovedFromAnAlreadyBrickedClient() throws {
        let bottle = makeBottle()
        let steamDirectory = try seedBootstrapper(in: bottle)
        try Data("steamui payload".utf8).write(
            to: URL(fileURLWithPath: "\(steamDirectory)/steamui.dll")
        )
        let configPath = "\(steamDirectory)/steam.cfg"
        try "BootStrapperInhibitAll=enable\n".write(
            toFile: configPath,
            atomically: true,
            encoding: .utf8
        )

        WineManager().ensureSteamConfig(in: bottle)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: configPath),
            "El bottle ya ladrillado debe auto-repararse al abrirlo con la versión corregida."
        )
    }

    // MARK: - Recuperación de bottles ya ladrillados

    /// Un cliente que en disco parece completo pero cuyos logs registran el fallo fatal debe
    /// reconocerse como averiado: es el estado en el que quedaron los bottles afectados.
    func testFatalUILoadFailureIsDetectedInSteamLogs() throws {
        let bottle = makeBottle()
        let steamDirectory = try seedBootstrapper(in: bottle)
        try seedFullClient(in: steamDirectory)
        let logsDirectory = "\(steamDirectory)/logs"
        try FileManager.default.createDirectory(
            atPath: logsDirectory,
            withIntermediateDirectories: true
        )
        try """
        [2026-08-06 21:14:03] Startup - updater built Jul 30 2026
        [2026-08-06 21:14:07] Failed to load steamui.dll
        """.write(
            toFile: "\(logsDirectory)/bootstrap_log.txt",
            atomically: true,
            encoding: .utf8
        )

        XCTAssertTrue(
            WineManager.steamClientReportsFatalUILoadFailure(steamDirectory: steamDirectory)
        )
    }

    /// Un cliente sano no debe dispararla (si no, se repararía en bucle sin motivo).
    func testHealthyLogsDoNotReportAFatalUILoadFailure() throws {
        let bottle = makeBottle()
        let steamDirectory = try seedBootstrapper(in: bottle)
        try seedFullClient(in: steamDirectory)
        let logsDirectory = "\(steamDirectory)/logs"
        try FileManager.default.createDirectory(
            atPath: logsDirectory,
            withIntermediateDirectories: true
        )
        try "[2026-08-06 21:14:07] Loaded steamui.dll OK\n".write(
            toFile: "\(logsDirectory)/bootstrap_log.txt",
            atomically: true,
            encoding: .utf8
        )

        XCTAssertFalse(
            WineManager.steamClientReportsFatalUILoadFailure(steamDirectory: steamDirectory)
        )
    }

    /// Sin logs (instalación recién hecha) tampoco se dispara.
    func testMissingLogsDoNotReportAFatalUILoadFailure() throws {
        let bottle = makeBottle()
        let steamDirectory = try seedBootstrapper(in: bottle)

        XCTAssertFalse(
            WineManager.steamClientReportsFatalUILoadFailure(steamDirectory: steamDirectory)
        )
    }

    /// Los logs se limpian tras tenerlos en cuenta, para no repetir la reparación en bucle,
    /// y sin tocar nada más del directorio de Steam.
    func testClearingLogsLeavesUserDataUntouched() throws {
        let bottle = makeBottle()
        let steamDirectory = try seedBootstrapper(in: bottle)
        try seedFullClient(in: steamDirectory)
        let logsDirectory = "\(steamDirectory)/logs"
        let steamappsDirectory = "\(steamDirectory)/steamapps"
        try FileManager.default.createDirectory(
            atPath: logsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            atPath: steamappsDirectory,
            withIntermediateDirectories: true
        )
        try "Failed to load steamui.dll\n".write(
            toFile: "\(logsDirectory)/bootstrap_log.txt",
            atomically: true,
            encoding: .utf8
        )
        try "\"AppState\"\n".write(
            toFile: "\(steamappsDirectory)/appmanifest_219990.acf",
            atomically: true,
            encoding: .utf8
        )

        WineManager.clearSteamClientLogs(steamDirectory: steamDirectory)

        XCTAssertFalse(
            WineManager.steamClientReportsFatalUILoadFailure(steamDirectory: steamDirectory)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: "\(steamappsDirectory)/appmanifest_219990.acf"
            ),
            "La limpieza solo puede tocar logs/, nunca los juegos instalados."
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: "\(steamDirectory)/steamui.dll")
        )
    }

    /// Con el cliente completo la configuración se sigue aplicando igual que antes.
    func testSteamConfigIsWrittenForACompleteClient() throws {
        let bottle = makeBottle()
        let steamDirectory = try seedBootstrapper(in: bottle)
        try seedFullClient(in: steamDirectory)

        WineManager().ensureSteamConfig(in: bottle)

        let contents = try String(
            contentsOfFile: "\(steamDirectory)/steam.cfg",
            encoding: .utf8
        )
        XCTAssertTrue(contents.contains("BootStrapperInhibitAll=enable"))
        XCTAssertTrue(contents.contains("BootStrapperForceSelfUpdate=disable"))
    }
}
