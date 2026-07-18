import Foundation
import XCTest
@testable import Vessel

@MainActor
final class WineManagerGraphicsRoutingTests: XCTestCase {
    private func makePE32(named name: String, marker: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vessel-graphics-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        var data = Data(repeating: 0, count: 0x200)
        data[0] = 0x4d
        data[1] = 0x5a
        data[0x3c] = 0x80
        data[0x80] = 0x50
        data[0x81] = 0x45
        data[0x84] = 0x4c
        data[0x85] = 0x01
        data.append(Data(marker.utf8))
        try data.write(to: url)
        return url
    }

    func testPE32DynamicOpenGLUsesUnifiedOpenGLLayer() throws {
        let executable = try makePE32(named: "deadcells_gl.exe", marker: "Failed to init SDL: OpenGL Error")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let manager = WineManager()

        XCTAssertTrue(manager.isExecutable32Bit(executable.path))
        XCTAssertEqual(manager.detectGraphicsAPI(forExecutable: executable.path), .opengl)
        XCTAssertEqual(manager.resolvedGraphicsLayer(forExecutable: executable.path), .dxmt)
        XCTAssertEqual(manager.fallbackLayers(forExecutable: executable.path), [.dxmt])
    }
}
