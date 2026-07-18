import Foundation
import XCTest
@testable import Vessel

/// Tests de regresión de los bugs de correctness encontrados en la auditoría de lógica pura
/// (ver `docs/AUDITORIA-BUGS.md`). Cada uno reproduce el input que fallaba antes del arreglo.
@MainActor
final class AuditFixesTests: XCTestCase {

    // MARK: - SteamGridDBClient.searchURL — el término va como SEGMENTO DE RUTA (no ?term=)

    func testSearchURLUsesPathSegment() {
        let url = SteamGridDBClient.searchURL(base: "https://www.steamgriddb.com/api/v2", query: "Hades")
        XCTAssertEqual(url?.absoluteString, "https://www.steamgriddb.com/api/v2/search/autocomplete/Hades")
    }

    func testSearchURLPercentEncodesSpacesAndSlashes() {
        let url = SteamGridDBClient.searchURL(base: "https://x/api/v2", query: "Slay the Spire")
        XCTAssertEqual(url?.absoluteString, "https://x/api/v2/search/autocomplete/Slay%20the%20Spire")
        let slash = SteamGridDBClient.searchURL(base: "https://x/api/v2", query: "a/b")
        // El '/' del término NO debe crear un segmento nuevo.
        XCTAssertEqual(slash?.absoluteString, "https://x/api/v2/search/autocomplete/a%2Fb")
    }

    // MARK: - StandaloneMacExporter.xmlEscape — títulos con & < > " ' no rompen el Info.plist

    func testXMLEscapeAmpersandFirst() {
        XCTAssertEqual(StandaloneMacExporter.xmlEscape("Sam & Max"), "Sam &amp; Max")
    }

    func testXMLEscapeAllSpecials() {
        XCTAssertEqual(StandaloneMacExporter.xmlEscape("<a> \"b\" 'c'"),
                       "&lt;a&gt; &quot;b&quot; &apos;c&apos;")
    }

    func testXMLEscapePlainTextUnchanged() {
        XCTAssertEqual(StandaloneMacExporter.xmlEscape("DOOM II"), "DOOM II")
    }

    // MARK: - PhysicalMediaImporter.parseAutorunTarget — rutas entre comillas con espacios

    func testAutorunQuotedPathWithSpace() {
        XCTAssertEqual(PhysicalMediaImporter.parseAutorunTarget("\"Setup Game\\setup.exe\""),
                       "Setup Game/setup.exe")
    }

    func testAutorunUnquotedStripsArgs() {
        XCTAssertEqual(PhysicalMediaImporter.parseAutorunTarget("setup.exe /S"), "setup.exe")
    }

    func testAutorunBackslashNormalized() {
        XCTAssertEqual(PhysicalMediaImporter.parseAutorunTarget("dir\\setup.exe"), "dir/setup.exe")
    }

    func testAutorunPlainName() {
        XCTAssertEqual(PhysicalMediaImporter.parseAutorunTarget("autorun.exe"), "autorun.exe")
    }

    // MARK: - DRMFreeInstaller.parseContentDispositionFilename — no deja comilla colgando

    func testContentDispositionWithTrailingParam() {
        let cd = "attachment; filename=\"Game.exe\"; filename*=UTF-8''Game.exe"
        XCTAssertEqual(DRMFreeInstaller.parseContentDispositionFilename(cd), "Game.exe")
    }

    func testContentDispositionUnquoted() {
        XCTAssertEqual(DRMFreeInstaller.parseContentDispositionFilename("attachment; filename=Game.zip"), "Game.zip")
    }

    func testContentDispositionQuotedWithSpace() {
        XCTAssertEqual(DRMFreeInstaller.parseContentDispositionFilename("attachment; filename=\"My Game.msi\""), "My Game.msi")
    }

    func testContentDispositionNoFilename() {
        XCTAssertNil(DRMFreeInstaller.parseContentDispositionFilename("inline"))
    }

    // MARK: - DRMFreeInstaller.sanitize — sin trap por abs(Int.min)

    func testSanitizeKeepsAlphanumericAndSpaces() {
        XCTAssertEqual(DRMFreeInstaller.sanitize("Hello World 2"), "Hello World 2")
    }

    func testSanitizeStripsSpecials() {
        XCTAssertEqual(DRMFreeInstaller.sanitize("a/b:c*d"), "abcd")
    }

    func testSanitizeEmptyFallbackIsNonEmpty() {
        let out = DRMFreeInstaller.sanitize("★☆✦")
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.hasPrefix("juego-"))
    }
}
