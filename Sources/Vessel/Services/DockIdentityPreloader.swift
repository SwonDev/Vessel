import CryptoKit
import Foundation

/// Prepara una copia privada del preloader de Wine cuya identidad ya está presente en disco antes
/// del `exec`. LaunchServices lee `__TEXT,__info_plist` al registrar el proceso, antes de que se
/// ejecuten constructores o interposiciones dinámicas; por eso un cambio únicamente en memoria
/// llega demasiado tarde para el nombre mostrado por el Dock.
enum DockIdentityPreloader {
    enum PreparationError: LocalizedError, Equatable {
        case preloaderNotFound
        case unsupportedMachO
        case malformedMachO
        case missingInfoPlist
        case ambiguousInfoPlist
        case invalidInfoPlist
        case replacementTooLarge

        var errorDescription: String? {
            switch self {
            case .preloaderNotFound:
                return "No se encontró el preloader de Wine."
            case .unsupportedMachO:
                return "El preloader no es un Mach-O de 64 bits compatible."
            case .malformedMachO:
                return "La estructura Mach-O del preloader no es válida."
            case .missingInfoPlist:
                return "El preloader no contiene una sección __info_plist."
            case .ambiguousInfoPlist:
                return "El preloader contiene más de una sección __info_plist."
            case .invalidInfoPlist:
                return "El plist embebido del preloader no es válido."
            case .replacementTooLarge:
                return "La identidad del juego no cabe en el plist embebido del preloader."
            }
        }
    }

    private static let machHeader64Size = 32
    private static let segmentCommand64 = UInt32(0x19)
    private static let segmentCommand64Size = 72
    private static let section64Size = 80
    private static let machMagic64 = UInt32(0xFEEDFACF)

    static func bundleIdentifier(winePath: String, displayName: String) -> String {
        let material = Data("\(winePath)\u{0}\(displayName)".utf8)
        let digest = SHA256.hash(data: material)
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return "com.swondev.vessel.game.\(digest)"
    }

    /// Devuelve una copia byte a byte del ejecutable con el plist actualizado. La función es pura
    /// para poder probar el parser sin escribir ni ejecutar binarios reales.
    static func patchedExecutableData(
        _ executableData: Data,
        displayName: String,
        bundleIdentifier: String
    ) throws -> Data {
        let sectionRange = try infoPlistSectionRange(in: executableData)
        let rawSection = executableData.subdata(in: sectionRange)
        let plistData: Data
        if let terminator = rawSection.firstIndex(of: 0) {
            plistData = rawSection.prefix(upTo: terminator)
        } else {
            plistData = rawSection
        }

        guard !plistData.isEmpty,
              var dictionary = try PropertyListSerialization.propertyList(
                from: plistData,
                options: [],
                format: nil
              ) as? [String: Any] else {
            throw PreparationError.invalidInfoPlist
        }

        dictionary["CFBundleName"] = displayName
        dictionary["CFBundleIdentifier"] = bundleIdentifier

        let serialized: Data
        do {
            serialized = try PropertyListSerialization.data(
                fromPropertyList: dictionary,
                format: .xml,
                options: 0
            )
        } catch {
            throw PreparationError.invalidInfoPlist
        }

        guard let compacted = compactedPlist(serialized, fitting: sectionRange.count) else {
            throw PreparationError.replacementTooLarge
        }

        var result = executableData
        result.replaceSubrange(sectionRange, with: Data(repeating: 0, count: sectionRange.count))
        result.replaceSubrange(
            sectionRange.lowerBound..<(sectionRange.lowerBound + compacted.count),
            with: compacted
        )
        return result
    }

    /// Crea atómicamente el alias que usará el helper inyectado. El directorio es privado (0700),
    /// la copia conserva los permisos ejecutables del motor y el binario fuente nunca se modifica.
    static func prepareAlias(
        wineExecutable: URL,
        alias: URL,
        displayName: String,
        fileManager: FileManager = .default
    ) throws {
        guard let source = preloaderURL(
            for: wineExecutable,
            fileManager: fileManager
        ) else {
            throw PreparationError.preloaderNotFound
        }

        let sourceData = try Data(contentsOf: source, options: .mappedIfSafe)
        let patched = try patchedExecutableData(
            sourceData,
            displayName: displayName,
            bundleIdentifier: bundleIdentifier(
                winePath: wineExecutable.standardizedFileURL.path,
                displayName: displayName
            )
        )

        let parent = alias.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: parent.path
        )

        let temporary = parent.appendingPathComponent(".\(UUID().uuidString).preloader")
        defer { try? fileManager.removeItem(at: temporary) }

        try patched.write(to: temporary, options: .atomic)
        let sourceAttributes = try fileManager.attributesOfItem(atPath: source.path)
        let sourcePermissions = (sourceAttributes[.posixPermissions] as? NSNumber)?.intValue
            ?? 0o755
        try fileManager.setAttributes(
            [.posixPermissions: sourcePermissions & 0o755],
            ofItemAtPath: temporary.path
        )

        if fileManager.fileExists(atPath: alias.path) {
            try fileManager.removeItem(at: alias)
        }
        try fileManager.moveItem(at: temporary, to: alias)
    }

    private static func preloaderURL(
        for wineExecutable: URL,
        fileManager: FileManager
    ) -> URL? {
        let directory = wineExecutable
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        return ["wine-preloader", "wine64-preloader"]
            .map { directory.appendingPathComponent($0, isDirectory: false) }
            .first { candidate in
                var isDirectory: ObjCBool = false
                return fileManager.fileExists(
                    atPath: candidate.path,
                    isDirectory: &isDirectory
                ) && !isDirectory.boolValue
                    && fileManager.isExecutableFile(atPath: candidate.path)
            }
    }

    private static func infoPlistSectionRange(in data: Data) throws -> Range<Int> {
        guard data.count >= machHeader64Size,
              readUInt32(data, at: 0) == machMagic64 else {
            throw PreparationError.unsupportedMachO
        }
        guard let commandCountValue = readUInt32(data, at: 16),
              let commandsSizeValue = readUInt32(data, at: 20),
              commandCountValue <= 4_096 else {
            throw PreparationError.malformedMachO
        }

        let commandCount = Int(commandCountValue)
        let commandsSize = Int(commandsSizeValue)
        let commandsEnd = machHeader64Size + commandsSize
        guard commandsSize >= 0, commandsEnd <= data.count else {
            throw PreparationError.malformedMachO
        }

        var commandOffset = machHeader64Size
        var matches: [Range<Int>] = []
        for _ in 0..<commandCount {
            guard commandOffset + 8 <= commandsEnd,
                  let command = readUInt32(data, at: commandOffset),
                  let commandSizeValue = readUInt32(data, at: commandOffset + 4) else {
                throw PreparationError.malformedMachO
            }
            let commandSize = Int(commandSizeValue)
            guard commandSize >= 8,
                  commandOffset + commandSize <= commandsEnd else {
                throw PreparationError.malformedMachO
            }

            if command == segmentCommand64 {
                guard commandSize >= segmentCommand64Size,
                      fixedString(data, at: commandOffset + 8, length: 16) == "__TEXT",
                      let sectionCountValue = readUInt32(data, at: commandOffset + 64),
                      sectionCountValue <= 4_096 else {
                    commandOffset += commandSize
                    continue
                }

                let sectionCount = Int(sectionCountValue)
                let requiredSize = segmentCommand64Size + sectionCount * section64Size
                guard requiredSize <= commandSize else {
                    throw PreparationError.malformedMachO
                }

                for sectionIndex in 0..<sectionCount {
                    let sectionOffset = commandOffset
                        + segmentCommand64Size
                        + sectionIndex * section64Size
                    guard fixedString(data, at: sectionOffset, length: 16) == "__info_plist",
                          fixedString(data, at: sectionOffset + 16, length: 16) == "__TEXT" else {
                        continue
                    }
                    guard let fileOffsetValue = readUInt32(data, at: sectionOffset + 48),
                          let sectionSizeValue = readUInt64(data, at: sectionOffset + 40),
                          sectionSizeValue <= UInt64(Int.max) else {
                        throw PreparationError.malformedMachO
                    }
                    let fileOffset = Int(fileOffsetValue)
                    let sectionSize = Int(sectionSizeValue)
                    guard sectionSize > 0,
                          fileOffset <= data.count,
                          sectionSize <= data.count - fileOffset else {
                        throw PreparationError.malformedMachO
                    }
                    matches.append(fileOffset..<(fileOffset + sectionSize))
                }
            }
            commandOffset += commandSize
        }

        guard commandOffset == commandsEnd else {
            throw PreparationError.malformedMachO
        }
        guard let match = matches.first else {
            throw PreparationError.missingInfoPlist
        }
        guard matches.count == 1 else {
            throw PreparationError.ambiguousInfoPlist
        }
        return match
    }

    private static func compactedPlist(_ data: Data, fitting capacity: Int) -> Data? {
        guard var xml = String(data: data, encoding: .utf8) else { return nil }
        xml = xml.replacingOccurrences(
            of: ">\\s+<",
            with: "><",
            options: .regularExpression
        )
        var compacted = Data(xml.utf8)
        if compacted.count <= capacity { return compacted }

        // El DOCTYPE es informativo; PropertyListSerialization y CFBundle aceptan el plist XML
        // sin él. Se retira solo para títulos Unicode excepcionalmente largos.
        xml = xml.replacingOccurrences(
            of: "<!DOCTYPE[^>]+>\\s*",
            with: "",
            options: .regularExpression
        )
        compacted = Data(xml.utf8)
        return compacted.count <= capacity ? compacted : nil
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - MemoryLayout<UInt32>.size else {
            return nil
        }
        return data.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset <= data.count - MemoryLayout<UInt64>.size else {
            return nil
        }
        return data.withUnsafeBytes {
            UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
    }

    private static func fixedString(_ data: Data, at offset: Int, length: Int) -> String? {
        guard offset >= 0, length >= 0, offset <= data.count - length else { return nil }
        let bytes = data[offset..<(offset + length)].prefix { $0 != 0 }
        return String(bytes: bytes, encoding: .utf8)
    }
}
