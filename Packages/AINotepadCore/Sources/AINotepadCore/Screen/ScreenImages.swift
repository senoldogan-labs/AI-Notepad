import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Ekran görüntüsü işleme (parmak izi, JPEG) hataları.
public enum ScreenImageError: Error, Equatable {
    /// Küçültülmüş gri çizim bağlamı kurulamadı.
    case fingerprintFailed(width: Int, height: Int)
    /// JPEG yazılamadı.
    case encodingFailed(reason: String)
    /// Görüntü dosyası okunamadı ya da çözülemedi.
    case decodingFailed(path: String)
}

/// Görüntünün küçültülmüş gri parmak izi (`screenFingerprintWidth`×`screenFingerprintHeight`). Çizim yumuşatmalı
/// küçültür: her hücre kendi bölgesinin ortalama parlaklığıdır (imleç ya da tek karakter değişimi hücreyi oynatmaz).
public func screenFingerprint(image: CGImage) throws -> ScreenFingerprint {
    let width: Int = screenFingerprintWidth
    let height: Int = screenFingerprintHeight
    var luma: [UInt8] = Array(repeating: 0, count: width * height)
    let drawn: Bool = luma.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return false
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else {
        throw ScreenImageError.fingerprintFailed(width: width, height: height)
    }
    return ScreenFingerprint(width: width, height: height, luma: luma)
}

/// Görüntüyü JPEG'e çevirir (`quality` 0–1).
public func jpegData(image: CGImage, quality: Double) throws -> Data {
    let data: NSMutableData = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw ScreenImageError.encodingFailed(reason: "CGImageDestinationCreateWithData")
    }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw ScreenImageError.encodingFailed(reason: "CGImageDestinationFinalize")
    }
    return data as Data
}

/// Dosyadaki görüntünün uzun kenarı en fazla `maxPixelSize` olan kopyası (küçük resim ve MCP için).
public func downscaledImage(file: URL, maxPixelSize: Int) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
          ] as CFDictionary) else {
        throw ScreenImageError.decodingFailed(path: file.path)
    }
    return image
}

/// MCP'nin döndürdüğü görüntünün en büyük boyutu (bayt; base64'ten önce). İstemcilerin ileti sınırlarının altında kalır.
public let mcpScreenMaxBytes: Int = 900_000

/// Görüntü dosyasının MCP'ye gidecek JPEG'i: dosya `maxBytes`'ı aşmıyorsa olduğu gibi, aşıyorsa sığana dek küçültülerek
/// (her adımda uzun kenar ¾). Hiçbir boyutta sığmazsa `encodingFailed`.
public func screenImageForMCP(file: URL, maxBytes: Int) throws -> Data {
    let original: Data
    do {
        original = try Data(contentsOf: file)
    } catch {
        throw ScreenImageError.decodingFailed(path: file.path)
    }
    guard original.count > maxBytes else {
        return original
    }
    var maxPixelSize: Int = screenSnapshotPolicy.maxPixelSize
    while maxPixelSize >= 200 {
        maxPixelSize = maxPixelSize * 3 / 4
        let data: Data = try jpegData(image: try downscaledImage(file: file, maxPixelSize: maxPixelSize), quality: screenSnapshotPolicy.jpegQuality)
        if data.count <= maxBytes {
            return data
        }
    }
    throw ScreenImageError.encodingFailed(reason: "image does not fit in \(maxBytes) bytes")
}
