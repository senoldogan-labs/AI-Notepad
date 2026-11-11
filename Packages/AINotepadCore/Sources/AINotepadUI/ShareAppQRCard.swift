import AINotepadCore
import SwiftUI

/// QR modules in Ember ink on a cream card (both themes: a QR code scans best dark on light).
public let shareQRInk: UInt32 = 0x2A1A12
public let shareQRPaper: UInt32 = 0xFBF6EE

/// The "Share Gistsmith" QR code: dark Ember-ink modules on a cream rounded card with the app icon in the centre (error
/// correction level H keeps the code readable under it). The bitmap is drawn by `qrCodeImage`; when it cannot be drawn
/// the card says why. VoiceOver reads it as one image that opens the link.
public struct ShareAppQRCard: View {
    let link: URL
    let icon: Image?

    public init(link: URL, icon: Image?) {
        self.link = link
        self.icon = icon
    }

    public var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 28, style: .continuous)
        Group {
            switch Result(catching: { try qrCodeImage(text: link.absoluteString, moduleScale: 12, ink: QRCodeColor(hex: shareQRInk), paper: QRCodeColor(hex: shareQRPaper)) }) {
            case .success(let image):
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        GeometryReader { (proxy: GeometryProxy) in
                            let side: CGFloat = proxy.size.width * 0.2
                            if let icon {
                                icon
                                    .resizable()
                                    .aspectRatio(1, contentMode: .fit)
                                    .frame(width: side, height: side)
                                    .clipShape(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous))
                                    .padding(side * 0.08)
                                    .background(Color(hex: shareQRPaper), in: RoundedRectangle(cornerRadius: side * 0.3, style: .continuous))
                                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                            }
                        }
                    }
            case .failure(let error):
                Text("QR kodu çizilemedi: \(String(describing: error))")
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(Color(hex: shareQRInk))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .padding(14)
        .background(Color(hex: shareQRPaper), in: shape)
        .overlay(shape.strokeBorder(Color.black.opacity(0.06), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.12), radius: 18, y: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Gistsmith bağlantısının QR kodu"))
        .accessibilityAddTraits(.isImage)
    }
}
