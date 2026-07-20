import Foundation

/// Lector acotado de los directorios Import y Delay Import de un ejecutable PE.
///
/// No intenta ser un parser PE general. Su única responsabilidad es separar dependencias vinculadas
/// de simples cadenas incrustadas, para que el enrutado gráfico se base en evidencia real.
enum PEImportScanner {
    private struct Section {
        let virtualAddress: UInt32
        let virtualSize: UInt32
        let rawSize: UInt32
        let rawPointer: UInt32
    }

    static func importedLibraries(atPath path: String) -> Set<String> {
        guard let data = try? Data(
            contentsOf: URL(fileURLWithPath: path),
            options: .mappedIfSafe
        ), data.count >= 0x40,
          let peOffsetValue = readUInt32(data, at: 0x3c) else {
            return []
        }

        let peOffset = Int(peOffsetValue)
        guard peOffset >= 0x40, peOffset <= data.count - 24,
              data[peOffset] == 0x50, data[peOffset + 1] == 0x45,
              data[peOffset + 2] == 0, data[peOffset + 3] == 0,
              let sectionCountValue = readUInt16(data, at: peOffset + 6),
              let optionalSizeValue = readUInt16(data, at: peOffset + 20) else {
            return []
        }

        let sectionCount = Int(sectionCountValue)
        let optionalSize = Int(optionalSizeValue)
        let optionalOffset = peOffset + 24
        guard sectionCount > 0, sectionCount <= 96,
              optionalSize > 0, optionalOffset <= data.count - optionalSize,
              let magic = readUInt16(data, at: optionalOffset) else {
            return []
        }

        let dataDirectoryOffset: Int
        let imageBase: UInt64
        switch magic {
        case 0x10b: // PE32
            dataDirectoryOffset = optionalOffset + 96
            guard let base = readUInt32(data, at: optionalOffset + 28) else { return [] }
            imageBase = UInt64(base)
        case 0x20b: // PE32+
            dataDirectoryOffset = optionalOffset + 112
            guard let base = readUInt64(data, at: optionalOffset + 24) else { return [] }
            imageBase = base
        default:
            return []
        }

        let sectionTableOffset = optionalOffset + optionalSize
        guard sectionTableOffset <= data.count - sectionCount * 40 else { return [] }
        var sections: [Section] = []
        sections.reserveCapacity(sectionCount)
        for index in 0..<sectionCount {
            let offset = sectionTableOffset + index * 40
            guard let virtualSize = readUInt32(data, at: offset + 8),
                  let virtualAddress = readUInt32(data, at: offset + 12),
                  let rawSize = readUInt32(data, at: offset + 16),
                  let rawPointer = readUInt32(data, at: offset + 20) else {
                return []
            }
            sections.append(Section(
                virtualAddress: virtualAddress,
                virtualSize: virtualSize,
                rawSize: rawSize,
                rawPointer: rawPointer
            ))
        }

        func fileOffset(forRVA rva: UInt32) -> Int? {
            for section in sections {
                let start = UInt64(section.virtualAddress)
                let span = UInt64(max(section.virtualSize, section.rawSize))
                let value = UInt64(rva)
                guard value >= start, value < start + span else { continue }
                let offset = UInt64(section.rawPointer) + value - start
                guard offset < UInt64(data.count) else { return nil }
                return Int(offset)
            }
            return nil
        }

        func libraryName(atRVA rva: UInt32) -> String? {
            guard let offset = fileOffset(forRVA: rva), offset < data.count else { return nil }
            let limit = min(data.count, offset + 512)
            var end = offset
            while end < limit, data[end] != 0 { end += 1 }
            guard end > offset, end < limit,
                  let value = String(data: data[offset..<end], encoding: .ascii) else {
                return nil
            }
            return value.lowercased()
        }

        var result: Set<String> = []

        // IMAGE_DIRECTORY_ENTRY_IMPORT = 1; cada IMAGE_IMPORT_DESCRIPTOR ocupa 20 bytes.
        if dataDirectoryOffset <= optionalOffset + optionalSize - 16,
           let importRVA = readUInt32(data, at: dataDirectoryOffset + 8),
           importRVA != 0,
           let importOffset = fileOffset(forRVA: importRVA) {
            for index in 0..<4_096 {
                let descriptor = importOffset + index * 20
                guard descriptor <= data.count - 20 else { break }
                let fields = stride(from: 0, to: 20, by: 4).compactMap {
                    readUInt32(data, at: descriptor + $0)
                }
                guard fields.count == 5 else { break }
                if fields.allSatisfy({ $0 == 0 }) { break }
                if let name = libraryName(atRVA: fields[3]) { result.insert(name) }
            }
        }

        // IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT = 13; ImgDelayDescr ocupa 32 bytes.
        let delayDirectory = dataDirectoryOffset + 13 * 8
        if delayDirectory <= optionalOffset + optionalSize - 8,
           let delayRVA = readUInt32(data, at: delayDirectory),
           delayRVA != 0,
           let delayOffset = fileOffset(forRVA: delayRVA) {
            for index in 0..<4_096 {
                let descriptor = delayOffset + index * 32
                guard descriptor <= data.count - 32,
                      let attributes = readUInt32(data, at: descriptor),
                      let encodedName = readUInt32(data, at: descriptor + 4) else { break }
                let isEmpty = stride(from: 0, to: 32, by: 4).allSatisfy {
                    readUInt32(data, at: descriptor + $0) == 0
                }
                if isEmpty { break }
                let nameRVA: UInt32?
                if attributes & 1 != 0 {
                    nameRVA = encodedName
                } else if UInt64(encodedName) >= imageBase,
                          UInt64(encodedName) - imageBase <= UInt64(UInt32.max) {
                    nameRVA = UInt32(UInt64(encodedName) - imageBase)
                } else {
                    nameRVA = nil
                }
                if let nameRVA, let name = libraryName(atRVA: nameRVA) { result.insert(name) }
            }
        }

        return result
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset <= data.count - 2 else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64? {
        guard let low = readUInt32(data, at: offset),
              let high = readUInt32(data, at: offset + 4) else { return nil }
        return UInt64(low) | (UInt64(high) << 32)
    }
}
