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

    private struct Image {
        let data: Data
        let optionalOffset: Int
        let optionalSize: Int
        let dataDirectoryOffset: Int
        let imageBase: UInt64
        let sections: [Section]

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

        func asciiString(atRVA rva: UInt32, maxLength: Int = 512) -> String? {
            guard let offset = fileOffset(forRVA: rva), offset < data.count else { return nil }
            let limit = min(data.count, offset + maxLength)
            var end = offset
            while end < limit, data[end] != 0 { end += 1 }
            guard end > offset, end < limit else { return nil }
            return String(data: data[offset..<end], encoding: .ascii)
        }
    }

    static func importedLibraries(atPath path: String) -> Set<String> {
        guard let image = image(atPath: path) else { return [] }
        let data = image.data

        var result: Set<String> = []

        // IMAGE_DIRECTORY_ENTRY_IMPORT = 1; cada IMAGE_IMPORT_DESCRIPTOR ocupa 20 bytes.
        if image.dataDirectoryOffset <= image.optionalOffset + image.optionalSize - 16,
           let importRVA = readUInt32(data, at: image.dataDirectoryOffset + 8),
           importRVA != 0,
           let importOffset = image.fileOffset(forRVA: importRVA) {
            for index in 0..<4_096 {
                let descriptor = importOffset + index * 20
                guard descriptor <= data.count - 20 else { break }
                let fields = stride(from: 0, to: 20, by: 4).compactMap {
                    readUInt32(data, at: descriptor + $0)
                }
                guard fields.count == 5 else { break }
                if fields.allSatisfy({ $0 == 0 }) { break }
                if let name = image.asciiString(atRVA: fields[3])?.lowercased() {
                    result.insert(name)
                }
            }
        }

        // IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT = 13; ImgDelayDescr ocupa 32 bytes.
        let delayDirectory = image.dataDirectoryOffset + 13 * 8
        if delayDirectory <= image.optionalOffset + image.optionalSize - 8,
           let delayRVA = readUInt32(data, at: delayDirectory),
           delayRVA != 0,
           let delayOffset = image.fileOffset(forRVA: delayRVA) {
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
                } else if UInt64(encodedName) >= image.imageBase,
                          UInt64(encodedName) - image.imageBase <= UInt64(UInt32.max) {
                    nameRVA = UInt32(UInt64(encodedName) - image.imageBase)
                } else {
                    nameRVA = nil
                }
                if let nameRVA,
                   let name = image.asciiString(atRVA: nameRVA)?.lowercased() {
                    result.insert(name)
                }
            }
        }

        return result
    }

    /// Símbolos que el PE publica en IMAGE_DIRECTORY_ENTRY_EXPORT.
    ///
    /// La lectura es intencionadamente acotada: solo sigue la tabla oficial de nombres exportados,
    /// nunca cadenas libres del binario. Sirve para reconocer módulos por contrato real sin ejecutar
    /// código de terceros durante el enrutado.
    static func exportedSymbols(atPath path: String) -> Set<String> {
        guard let image = image(atPath: path) else { return [] }
        let data = image.data
        let exportDirectory = image.dataDirectoryOffset
        guard exportDirectory <= image.optionalOffset + image.optionalSize - 8,
              let exportRVA = readUInt32(data, at: exportDirectory),
              exportRVA != 0,
              let exportOffset = image.fileOffset(forRVA: exportRVA),
              exportOffset <= data.count - 40,
              let nameCountValue = readUInt32(data, at: exportOffset + 24),
              let nameTableRVA = readUInt32(data, at: exportOffset + 32),
              let nameTableOffset = image.fileOffset(forRVA: nameTableRVA) else {
            return []
        }

        let nameCount = min(Int(nameCountValue), 65_536)
        guard nameCount > 0, nameTableOffset <= data.count - nameCount * 4 else { return [] }
        var result: Set<String> = []
        result.reserveCapacity(nameCount)
        for index in 0..<nameCount {
            guard let nameRVA = readUInt32(data, at: nameTableOffset + index * 4),
                  let name = image.asciiString(atRVA: nameRVA, maxLength: 4_096) else {
                continue
            }
            result.insert(name.lowercased())
        }
        return result
    }

    private static func image(atPath path: String) -> Image? {
        guard let data = try? Data(
            contentsOf: URL(fileURLWithPath: path),
            options: .mappedIfSafe
        ), data.count >= 0x40,
          let peOffsetValue = readUInt32(data, at: 0x3c) else {
            return nil
        }

        let peOffset = Int(peOffsetValue)
        guard peOffset >= 0x40, peOffset <= data.count - 24,
              data[peOffset] == 0x50, data[peOffset + 1] == 0x45,
              data[peOffset + 2] == 0, data[peOffset + 3] == 0,
              let sectionCountValue = readUInt16(data, at: peOffset + 6),
              let optionalSizeValue = readUInt16(data, at: peOffset + 20) else {
            return nil
        }

        let sectionCount = Int(sectionCountValue)
        let optionalSize = Int(optionalSizeValue)
        let optionalOffset = peOffset + 24
        guard sectionCount > 0, sectionCount <= 96,
              optionalSize > 0, optionalOffset <= data.count - optionalSize,
              let magic = readUInt16(data, at: optionalOffset) else {
            return nil
        }

        let dataDirectoryOffset: Int
        let imageBase: UInt64
        switch magic {
        case 0x10b: // PE32
            dataDirectoryOffset = optionalOffset + 96
            guard let base = readUInt32(data, at: optionalOffset + 28) else { return nil }
            imageBase = UInt64(base)
        case 0x20b: // PE32+
            dataDirectoryOffset = optionalOffset + 112
            guard let base = readUInt64(data, at: optionalOffset + 24) else { return nil }
            imageBase = base
        default:
            return nil
        }

        let sectionTableOffset = optionalOffset + optionalSize
        guard sectionTableOffset <= data.count - sectionCount * 40 else { return nil }
        var sections: [Section] = []
        sections.reserveCapacity(sectionCount)
        for index in 0..<sectionCount {
            let offset = sectionTableOffset + index * 40
            guard let virtualSize = readUInt32(data, at: offset + 8),
                  let virtualAddress = readUInt32(data, at: offset + 12),
                  let rawSize = readUInt32(data, at: offset + 16),
                  let rawPointer = readUInt32(data, at: offset + 20) else {
                return nil
            }
            sections.append(Section(
                virtualAddress: virtualAddress,
                virtualSize: virtualSize,
                rawSize: rawSize,
                rawPointer: rawPointer
            ))
        }

        return Image(
            data: data,
            optionalOffset: optionalOffset,
            optionalSize: optionalSize,
            dataDirectoryOffset: dataDirectoryOffset,
            imageBase: imageBase,
            sections: sections
        )
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
