import Foundation
import XCTest
@testable import Vessel

/// Verifica la seguridad de rutas destructivas (`PathSafety`), que centraliza la comprobación
/// "canonicalizar + subcarpeta ESTRICTA" antes duplicada a mano en varios servicios/vistas.
///
/// Regresión crítica cubierta (ver incidente de borrado de prefijo): NUNCA se debe borrar la raíz
/// ni una carpeta *hermana* con prefijo común (`.../DRMFree` vs `.../DRMFree-evil`), ni dejar que
/// un `..` o un symlink escapen del árbol permitido.
final class PathSafetyTests: XCTestCase {

    private var root: String = ""
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = "\(NSTemporaryDirectory())PathSafetyTests-\(UUID().uuidString)"
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(atPath: root)
        try super.tearDownWithError()
    }

    @discardableResult
    private func makeDir(_ rel: String) throws -> String {
        let p = "\(root)/\(rel)"
        try fm.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    // MARK: - isStrictDescendant

    func testSubfolderIsStrictDescendant() throws {
        try makeDir("Steam/steamapps/common/MiJuego")
        let base = "\(root)/Steam/steamapps/common"
        XCTAssertTrue(PathSafety.isStrictDescendant("\(base)/MiJuego", of: base))
        XCTAssertTrue(PathSafety.isStrictDescendant("\(base)/MiJuego/Datos", of: base))
    }

    func testRootItselfIsNotStrictDescendant() {
        XCTAssertFalse(PathSafety.isStrictDescendant(root, of: root))
        XCTAssertFalse(PathSafety.isStrictDescendant("\(root)/", of: root))
    }

    func testParentIsNotStrictDescendant() {
        let base = "\(root)/a/b"
        XCTAssertFalse(PathSafety.isStrictDescendant("\(root)/a", of: base))
    }

    /// EL caso peligroso que el chequeo débil `hasPrefix(base)` (sin barra) dejaba pasar:
    /// una carpeta HERMANA con el mismo prefijo textual.
    func testSiblingWithSharedPrefixIsRejected() {
        let base = "\(root)/DRMFree"
        XCTAssertFalse(PathSafety.isStrictDescendant("\(root)/DRMFree-evil/juego", of: base))
        XCTAssertFalse(PathSafety.isStrictDescendant("\(root)/DRMFreeX", of: base))
    }

    func testDotDotEscapeIsRejected() {
        let base = "\(root)/games"
        XCTAssertFalse(PathSafety.isStrictDescendant("\(base)/../secret", of: base))
        XCTAssertFalse(PathSafety.isStrictDescendant("\(base)/sub/../../secret", of: base))
    }

    func testSymlinkEscapeIsRejected() throws {
        let base = try makeDir("games")
        let outside = try makeDir("outside")
        try "x".write(toFile: "\(outside)/loot", atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: "\(base)/escape", withDestinationPath: outside)
        // El symlink resuelve FUERA de la raíz permitida: ni es descendiente estricto de `base`,
        // ni el propio enlace ni nada bajo él es seguro de borrar.
        XCTAssertFalse(PathSafety.isStrictDescendant("\(base)/escape/loot", of: base))
        XCTAssertNil(PathSafety.resolvedIfSafeToDelete("\(base)/escape", under: base))
        XCTAssertNil(PathSafety.resolvedIfSafeToDelete("\(base)/escape/loot", under: base))
    }

    func testSymlinkStayingInsideIsAllowed() throws {
        let base = try makeDir("games")
        try makeDir("games/real")
        try fm.createSymbolicLink(atPath: "\(base)/link", withDestinationPath: "\(base)/real")
        XCTAssertTrue(PathSafety.isStrictDescendant("\(base)/link", of: base))
    }

    // MARK: - resolvedIfSafeToDelete

    func testSafeToDeleteReturnsCanonicalOfExistingSubfolder() throws {
        let base = try makeDir("common")
        let game = try makeDir("common/Juego")
        let resolved = PathSafety.resolvedIfSafeToDelete("\(base)/Juego", under: base)
        XCTAssertEqual(resolved, PathSafety.canonical(game))
    }

    func testSafeToDeleteNilForNonexistent() {
        let base = "\(root)/common"
        XCTAssertNil(PathSafety.resolvedIfSafeToDelete("\(base)/NoExiste", under: base))
    }

    func testSafeToDeleteNilForRootItself() throws {
        try makeDir("common")
        XCTAssertNil(PathSafety.resolvedIfSafeToDelete("\(root)/common", under: "\(root)/common"))
    }

    func testSafeToDeleteNilForSiblingPrefix() throws {
        try makeDir("DRMFree")
        try makeDir("DRMFree-evil/juego")
        XCTAssertNil(PathSafety.resolvedIfSafeToDelete("\(root)/DRMFree-evil/juego", under: "\(root)/DRMFree"))
    }

    func testSafeToDeleteResolvesInsideSymlinkToRealTarget() throws {
        let base = try makeDir("common")
        let real = try makeDir("common/real")
        try fm.createSymbolicLink(atPath: "\(base)/link", withDestinationPath: real)
        let resolved = PathSafety.resolvedIfSafeToDelete("\(base)/link", under: base)
        XCTAssertEqual(resolved, PathSafety.canonical(real))
    }

    // MARK: - isContained (anti Zip-Slip)

    func testContainedEqualBaseRespectsFlag() throws {
        let base = try makeDir("box")
        XCTAssertTrue(PathSafety.isContained(base, in: base, allowingBase: true))
        XCTAssertFalse(PathSafety.isContained(base, in: base, allowingBase: false))
    }

    func testContainedDescendantIsTrue() throws {
        let base = try makeDir("box")
        XCTAssertTrue(PathSafety.isContained("\(base)/a/b.txt", in: base))
    }

    func testContainedOutsideIsFalse() throws {
        let base = try makeDir("box")
        try makeDir("box-sibling")
        XCTAssertFalse(PathSafety.isContained("\(root)/box-sibling/x", in: base))
        XCTAssertFalse(PathSafety.isContained("\(base)/../escape", in: base, allowingBase: true))
    }

    // MARK: - canonical

    func testCanonicalResolvesDotDot() {
        XCTAssertEqual(PathSafety.canonical("\(root)/a/b/../c"), PathSafety.canonical("\(root)/a/c"))
    }
}
