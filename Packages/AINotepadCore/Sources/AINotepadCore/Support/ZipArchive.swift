import Foundation

/// ZIP arşivindeki bir dosya: arşiv içindeki yolu (`/` ile, ör. `word/document.xml`) ve içeriği.
public struct ZipEntry: Sendable, Equatable {
    public let path: String
    public let data: Data

    public init(path: String, data: Data) {
        self.path = path
        self.data = data
    }
}

/// Dosyaları sıkıştırmadan ("stored") tek bir ZIP arşivine yazar: Office belgeleri (DOCX) bu kapsayıcıdır. Dosya adları
/// UTF-8 işaretlidir; tarih sabittir (1980-01-01), aynı girdi her zaman aynı baytları verir. Tek dosya ya da arşiv 4 GB'ı
/// aşamaz (ZIP64 yok); toplantı belgeleri bunun çok altındadır. Saf fonksiyondur.
public func storedZipArchive(entries: [ZipEntry]) -> Data {
    var archive: Data = Data()
    var centralDirectory: Data = Data()
    for entry in entries {
        let name: Data = Data(entry.path.utf8)
        let checksum: UInt32 = crc32(data: entry.data)
        let size: UInt32 = UInt32(entry.data.count)
        let localHeaderOffset: UInt32 = UInt32(archive.count)
        // Yerel dosya başlığı ve içerik.
        archive.appendLittleEndian(UInt32(0x0403_4B50))
        archive.appendLittleEndian(zipVersion)
        archive.appendLittleEndian(zipUTF8NamesFlag)
        archive.appendLittleEndian(UInt16(0))
        archive.appendLittleEndian(zipDOSTime)
        archive.appendLittleEndian(zipDOSDate)
        archive.appendLittleEndian(checksum)
        archive.appendLittleEndian(size)
        archive.appendLittleEndian(size)
        archive.appendLittleEndian(UInt16(name.count))
        archive.appendLittleEndian(UInt16(0))
        archive.append(name)
        archive.append(entry.data)
        // Merkezi dizin kaydı (arşivin sonunda toplanır).
        centralDirectory.appendLittleEndian(UInt32(0x0201_4B50))
        centralDirectory.appendLittleEndian(zipVersion)
        centralDirectory.appendLittleEndian(zipVersion)
        centralDirectory.appendLittleEndian(zipUTF8NamesFlag)
        centralDirectory.appendLittleEndian(UInt16(0))
        centralDirectory.appendLittleEndian(zipDOSTime)
        centralDirectory.appendLittleEndian(zipDOSDate)
        centralDirectory.appendLittleEndian(checksum)
        centralDirectory.appendLittleEndian(size)
        centralDirectory.appendLittleEndian(size)
        centralDirectory.appendLittleEndian(UInt16(name.count))
        centralDirectory.appendLittleEndian(UInt16(0))
        centralDirectory.appendLittleEndian(UInt16(0))
        centralDirectory.appendLittleEndian(UInt16(0))
        centralDirectory.appendLittleEndian(UInt16(0))
        centralDirectory.appendLittleEndian(UInt32(0))
        centralDirectory.appendLittleEndian(localHeaderOffset)
        centralDirectory.append(name)
    }
    let centralDirectoryOffset: UInt32 = UInt32(archive.count)
    archive.append(centralDirectory)
    // Merkezi dizinin sonu.
    archive.appendLittleEndian(UInt32(0x0605_4B50))
    archive.appendLittleEndian(UInt16(0))
    archive.appendLittleEndian(UInt16(0))
    archive.appendLittleEndian(UInt16(entries.count))
    archive.appendLittleEndian(UInt16(entries.count))
    archive.appendLittleEndian(UInt32(centralDirectory.count))
    archive.appendLittleEndian(centralDirectoryOffset)
    archive.appendLittleEndian(UInt16(0))
    return archive
}

/// Arşivi açmak için gereken ZIP sürümü (2.0).
private let zipVersion: UInt16 = 20
/// Genel amaçlı bayrak: dosya adları UTF-8.
private let zipUTF8NamesFlag: UInt16 = 0x0800
/// Sabit dosya tarihi: 1980-01-01 00:00 (MS-DOS biçimi).
private let zipDOSTime: UInt16 = 0
private let zipDOSDate: UInt16 = (1 << 5) | 1

/// CRC-32 (ZIP ve PNG'deki, polinom 0xEDB88320). Saf fonksiyondur.
func crc32(data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
}

private let crc32Table: [UInt32] = (0..<256).map { (index: Int) -> UInt32 in
    (0..<8).reduce(UInt32(index)) { (value: UInt32, _: Int) -> UInt32 in
        value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }
}
