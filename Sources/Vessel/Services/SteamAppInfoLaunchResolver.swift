import Foundation

/// Lee la opción de lanzamiento predeterminada que el propio cliente Steam conserva en
/// `appcache/appinfo.vdf`. Así Vessel no tiene que adivinar entre ediciones paralelas de un depot.
///
/// El formato está versionado por Valve. Las versiones 39–41 usan KeyValues1 binario y la 41
/// añade una tabla de nombres al final del archivo. El lector es deliberadamente acotado: localiza
/// un AppID por el tamaño de cada registro y solo materializa su árbol, no los metadatos de toda la
/// biblioteca.
enum SteamAppInfoLaunchResolver {
    private static let signature: UInt32 = 0x07_56_44
    private static let supportedVersions: ClosedRange<UInt8> = 39...41

    private struct Fingerprint: Equatable {
        let path: String
        let size: UInt64
        let modificationTime: TimeInterval
    }

    private enum CachedResult {
        case executable(String)
        case missing

        var value: String? {
            switch self {
            case .executable(let value): value
            case .missing: nil
            }
        }
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var fingerprint: Fingerprint?
        private var results: [String: CachedResult] = [:]

        func result(for appID: String, fingerprint newFingerprint: Fingerprint) -> (Bool, String?) {
            lock.lock()
            defer { lock.unlock() }
            if fingerprint != newFingerprint {
                fingerprint = newFingerprint
                results.removeAll(keepingCapacity: true)
            }
            guard let result = results[appID] else { return (false, nil) }
            return (true, result.value)
        }

        func store(_ value: String?, for appID: String, fingerprint newFingerprint: Fingerprint) {
            lock.lock()
            defer { lock.unlock() }
            if fingerprint != newFingerprint {
                fingerprint = newFingerprint
                results.removeAll(keepingCapacity: true)
            }
            results[appID] = value.map(CachedResult.executable) ?? .missing
        }
    }

    private static let cache = Cache()

    /// Ejecutable Windows predeterminado del AppID, expresado como ruta relativa al depot.
    static func defaultWindowsExecutable(appID: String, appInfoPath: String) -> String? {
        guard let numericAppID = UInt32(appID), numericAppID > 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: appInfoPath),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modificationDate = attributes[.modificationDate] as? Date
        else { return nil }

        let fingerprint = Fingerprint(
            path: URL(fileURLWithPath: appInfoPath).standardizedFileURL.path,
            size: size,
            modificationTime: modificationDate.timeIntervalSince1970
        )
        let cached = cache.result(for: appID, fingerprint: fingerprint)
        if cached.0 { return cached.1 }

        let value = (try? Data(contentsOf: URL(fileURLWithPath: appInfoPath), options: .mappedIfSafe))
            .flatMap { parseDefaultWindowsExecutable(appID: numericAppID, data: $0) }
        cache.store(value, for: appID, fingerprint: fingerprint)
        return value
    }

    /// Convierte la ruta de Steam en una ruta local segura y existente dentro del depot.
    static func resolvedExecutable(
        relativePath: String,
        installRoot: String,
        fileManager: FileManager = .default
    ) -> String? {
        var relative = relativePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .replacingOccurrences(of: "\\", with: "/")
        while relative.hasPrefix("./") { relative.removeFirst(2) }
        while relative.contains("//") { relative = relative.replacingOccurrences(of: "//", with: "/") }

        guard !relative.isEmpty,
              !relative.hasPrefix("/"),
              !(relative.count >= 2 && relative[relative.index(after: relative.startIndex)] == ":"),
              (relative as NSString).pathExtension.caseInsensitiveCompare("exe") == .orderedSame
        else { return nil }

        let rootURL = URL(fileURLWithPath: installRoot, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidateURL = URL(fileURLWithPath: relative, relativeTo: rootURL)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let root = rootURL.path
        let candidate = candidateURL.path
        guard candidate.hasPrefix(root + "/") else { return nil }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return candidate
    }

    private static func parseDefaultWindowsExecutable(appID: UInt32, data: Data) -> String? {
        var header = Cursor(data: data, offset: 0, limit: data.count)
        guard let magic = header.readUInt32(),
              magic >> 8 == signature,
              let version = UInt8(exactly: magic & 0xff),
              supportedVersions.contains(version),
              header.skip(4) // universo
        else { return nil }

        let stringTable: [String]?
        if version >= 41 {
            guard let rawOffset = header.readUInt64(), rawOffset <= UInt64(data.count),
                  let table = readStringTable(data: data, offset: Int(rawOffset)) else { return nil }
            stringTable = table
        } else {
            stringTable = nil
        }

        var records = Cursor(data: data, offset: header.offset, limit: data.count)
        while let currentAppID = records.readUInt32() {
            if currentAppID == 0 { return nil }
            guard let rawSize = records.readUInt32(), let recordSize = Int(exactly: rawSize) else {
                return nil
            }
            let recordStart = records.offset
            let recordEnd = recordStart + recordSize
            guard recordEnd >= recordStart, recordEnd <= data.count else { return nil }

            if currentAppID == appID {
                let metadataSize = version >= 40 ? 60 : 40
                guard recordStart + metadataSize <= recordEnd else { return nil }
                var keyValues = Cursor(
                    data: data,
                    offset: recordStart + metadataSize,
                    limit: recordEnd
                )
                let endMarker: UInt8
                if keyValues.peekUInt32() == 0x56_4b_42_56 { // VBKV + CRC32
                    guard keyValues.skip(8) else { return nil }
                    endMarker = 11
                } else {
                    endMarker = 8
                }
                var nodeCount = 0
                guard let root = parseObject(
                    cursor: &keyValues,
                    stringTable: stringTable,
                    endMarker: endMarker,
                    depth: 0,
                    nodeCount: &nodeCount
                ) else { return nil }
                return selectDefaultWindowsExecutable(from: root)
            }

            records.offset = recordEnd
        }
        return nil
    }

    private static func readStringTable(data: Data, offset: Int) -> [String]? {
        var cursor = Cursor(data: data, offset: offset, limit: data.count)
        guard let rawCount = cursor.readUInt32(), rawCount <= 1_000_000 else { return nil }
        var table: [String] = []
        table.reserveCapacity(Int(rawCount))
        for _ in 0..<rawCount {
            guard let value = cursor.readCString() else { return nil }
            table.append(value)
        }
        return table
    }

    private indirect enum Value {
        case object([String: Value])
        case string(String)
        case scalar
    }

    private static func parseObject(
        cursor: inout Cursor,
        stringTable: [String]?,
        endMarker: UInt8,
        depth: Int,
        nodeCount: inout Int
    ) -> [String: Value]? {
        guard depth <= 64 else { return nil }
        var object: [String: Value] = [:]

        while let type = cursor.readUInt8() {
            if type == endMarker || type == 8 || type == 11 { return object }
            nodeCount += 1
            guard nodeCount <= 200_000,
                  let name = readKey(cursor: &cursor, stringTable: stringTable) else { return nil }

            switch type {
            case 0:
                guard let child = parseObject(
                    cursor: &cursor,
                    stringTable: stringTable,
                    endMarker: endMarker,
                    depth: depth + 1,
                    nodeCount: &nodeCount
                ) else { return nil }
                object[name] = .object(child)
            case 1:
                guard let value = cursor.readCString() else { return nil }
                object[name] = .string(value)
            case 2, 3, 4, 6:
                guard cursor.skip(4) else { return nil }
                object[name] = .scalar
            case 5:
                guard cursor.readWideCString() != nil else { return nil }
                object[name] = .scalar
            case 7, 10:
                guard cursor.skip(8) else { return nil }
                object[name] = .scalar
            default:
                return nil
            }
        }
        return nil
    }

    private static func readKey(cursor: inout Cursor, stringTable: [String]?) -> String? {
        guard let stringTable else { return cursor.readCString() }
        guard let rawIndex = cursor.readUInt32(), rawIndex < UInt32(stringTable.count) else { return nil }
        return stringTable[Int(rawIndex)]
    }

    private static func selectDefaultWindowsExecutable(from root: [String: Value]) -> String? {
        let appInfo: [String: Value]
        if case .object(let wrapped)? = value(named: "appinfo", in: root) {
            appInfo = wrapped
        } else {
            appInfo = root
        }
        guard case .object(let config)? = value(named: "config", in: appInfo),
              case .object(let launch)? = value(named: "launch", in: config) else { return nil }

        let ordered = launch.compactMap { key, value -> (Int, [String: Value])? in
            guard let index = Int(key), case .object(let entry) = value else { return nil }
            return (index, entry)
        }.sorted { $0.0 < $1.0 }

        for (_, entry) in ordered {
            guard case .string(let executable)? = value(named: "executable", in: entry),
                  !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            if case .object(let conditions)? = value(named: "config", in: entry),
               case .string(let osList)? = value(named: "oslist", in: conditions) {
                let operatingSystems = osList
                    .lowercased()
                    .split { $0 == "," || $0 == ";" || $0.isWhitespace }
                if !operatingSystems.contains(where: { $0 == "windows" }) { continue }
            }
            return executable
        }
        return nil
    }

    private static func value(named name: String, in object: [String: Value]) -> Value? {
        if let exact = object[name] { return exact }
        return object.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value
    }

    private struct Cursor {
        let data: Data
        var offset: Int
        let limit: Int

        mutating func readUInt8() -> UInt8? {
            guard offset < limit else { return nil }
            defer { offset += 1 }
            return data[data.startIndex + offset]
        }

        mutating func readUInt32() -> UInt32? {
            guard offset >= 0, offset + 4 <= limit else { return nil }
            let start = data.startIndex + offset
            let value = UInt32(data[start])
                | UInt32(data[start + 1]) << 8
                | UInt32(data[start + 2]) << 16
                | UInt32(data[start + 3]) << 24
            offset += 4
            return value
        }

        mutating func readUInt64() -> UInt64? {
            guard let low = readUInt32(), let high = readUInt32() else { return nil }
            return UInt64(low) | UInt64(high) << 32
        }

        func peekUInt32() -> UInt32? {
            var copy = self
            return copy.readUInt32()
        }

        mutating func skip(_ count: Int) -> Bool {
            guard count >= 0, offset >= 0, offset + count <= limit else { return false }
            offset += count
            return true
        }

        mutating func readCString() -> String? {
            let start = offset
            while offset < limit, data[data.startIndex + offset] != 0 { offset += 1 }
            guard offset < limit else { return nil }
            let bytes = data[(data.startIndex + start)..<(data.startIndex + offset)]
            offset += 1
            return String(data: bytes, encoding: .utf8)
        }

        mutating func readWideCString() -> String? {
            let start = offset
            while offset + 1 < limit {
                let index = data.startIndex + offset
                if data[index] == 0, data[index + 1] == 0 {
                    let bytes = data[(data.startIndex + start)..<index]
                    offset += 2
                    guard bytes.count.isMultiple(of: 2) else { return nil }
                    var units: [UInt16] = []
                    units.reserveCapacity(bytes.count / 2)
                    var byteOffset = bytes.startIndex
                    while byteOffset < bytes.endIndex {
                        units.append(UInt16(bytes[byteOffset]) | UInt16(bytes[byteOffset + 1]) << 8)
                        byteOffset += 2
                    }
                    return String(decoding: units, as: UTF16.self)
                }
                offset += 2
            }
            return nil
        }
    }
}
