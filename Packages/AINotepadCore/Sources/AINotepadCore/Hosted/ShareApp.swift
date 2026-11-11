import CoreGraphics
import CoreImage
import Foundation

/// The site link the "Share Gistsmith" page shares when the account has no invite link. `utm_source` must be one of the
/// server's allowed campaign sources (`campaignSources` in `server/src/downloads.ts`, where `qr` is listed for this link).
public let shareAppSiteURL: URL = URL(string: "https://gistsmith.com/?utm_source=qr&utm_campaign=share-app")!

/// The link the "Share Gistsmith" page encodes and shares: the account's invite link when it has one (the friend's
/// sign-up counts for the inviter), otherwise the site link. Pure function.
public func shareAppLink(inviteURL: URL?) -> URL {
    inviteURL ?? shareAppSiteURL
}

/// A QR code could not be drawn.
public enum QRCodeError: Error, Equatable {
    /// The text is empty or does not fit in a QR code at error correction level H.
    case notEncodable(characterCount: Int)
    /// Core Image produced no bitmap.
    case renderFailed
}

/// One colour of a QR code (sRGB components 0...1).
public struct QRCodeColor: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// From a 0xRRGGBB value. Pure function.
    public init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Draws `text` as a QR code at error correction level H (30% of the code may be covered, so a logo fits in the centre),
/// each module `moduleScale` pixels square with sharp edges, `ink` modules on `paper` with the standard 4-module quiet
/// zone. Deterministic: the same input gives the same bitmap.
public func qrCodeImage(text: String, moduleScale: Int, ink: QRCodeColor, paper: QRCodeColor) throws(QRCodeError) -> CGImage {
    guard !text.isEmpty, moduleScale > 0 else {
        throw QRCodeError.notEncodable(characterCount: text.count)
    }
    guard let generator = CIFilter(name: "CIQRCodeGenerator") else {
        throw QRCodeError.renderFailed
    }
    generator.setValue(Data(text.utf8), forKey: "inputMessage")
    generator.setValue("H", forKey: "inputCorrectionLevel")
    guard let code = generator.outputImage else {
        // Core Image gives no image when the message is too long for the correction level.
        throw QRCodeError.notEncodable(characterCount: text.count)
    }
    guard let colouring = CIFilter(name: "CIFalseColor") else {
        throw QRCodeError.renderFailed
    }
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw QRCodeError.renderFailed
    }
    colouring.setValue(code, forKey: kCIInputImageKey)
    colouring.setValue(CIColor(red: ink.red, green: ink.green, blue: ink.blue, alpha: 1, colorSpace: space), forKey: "inputColor0")
    colouring.setValue(CIColor(red: paper.red, green: paper.green, blue: paper.blue, alpha: 1, colorSpace: space), forKey: "inputColor1")
    guard let coloured = colouring.outputImage else {
        throw QRCodeError.renderFailed
    }
    let scale: CGFloat = CGFloat(moduleScale)
    let scaled: CIImage = coloured.samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let context: CIContext = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
    guard let image = context.createCGImage(scaled, from: scaled.extent.integral, format: .RGBA8, colorSpace: space) else {
        throw QRCodeError.renderFailed
    }
    return image
}
