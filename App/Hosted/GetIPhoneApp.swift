import AINotepadCore
import AINotepadUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import os
import SwiftUI

private let iPhoneAppLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "GetIPhoneApp")

/// Ayarlar'ın sol sütunundaki "Gistsmith'i iPhone'a indir" kartı (iPhone'daki "Mac için Gistsmith" satırının
/// karşılığı): tıklayınca iPhone uygulamasının tanıtım sayfası açılır, ✕ kartı bu Mac'te kalıcı olarak gizler. Sunucu
/// hesabın hangi cihazlarda kullanıldığını söylemez: iPhone'u zaten kullanan da görür, gizleyebilir. Görünüşü (açılış
/// başına bir kez) ve tıklanışı (kullanım istatistikleri açıksa) sayılır.
struct HostedIPhoneAppCard: View {
    @AppStorage(SettingsKey.iPhoneAppCardDismissed) private var isDismissed: Bool = false
    /// Görsel kontrol: `--iphone-uygulamasi` ile Ayarlar açılınca tanıtım sayfası da açık başlar.
    @State private var isSheetOpen: Bool = CommandLine.arguments.contains("--iphone-uygulamasi")
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        if !isDismissed {
            HStack(alignment: .center, spacing: 6) {
                Button {
                    recordTelemetryCount(kind: .iPhonePromoOpened)
                    isSheetOpen = true
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "iphone")
                            .appFont(size: 13, weight: .medium)
                            .foregroundStyle(appearance.accent.color)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        Text("Gistsmith'i iPhone'a indir")
                            .appFont(size: 13, weight: .medium)
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .padding(.leading, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
                .accessibilityHint(Text("iPhone uygulamasını tanıtan sayfayı açar"))
                Button {
                    withAnimation(.smooth(duration: 0.2)) { isDismissed = true }
                } label: {
                    Image(systemName: "xmark")
                        .appFont(size: 10, weight: .semibold)
                        .foregroundStyle(Theme.muted)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
                .help(Text("Gizle"))
                .accessibilityLabel(Text("iPhone uygulaması önerisini gizle"))
                .padding(.trailing, 6)
            }
            .background(appearance.accent.softFill(tintOpacity: 0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .onAppear {
                guard !otherAppPromoShownCounted else {
                    return
                }
                otherAppPromoShownCounted = true
                recordTelemetryCount(kind: .iPhonePromoShown)
            }
            .sheet(isPresented: $isSheetOpen) {
                HostedIPhoneAppSheet()
            }
        }
    }
}

/// iPhone uygulamasının tanıtım sayfası: pastel zeminde iPhone'daki ana ekranın gerçek görüntüsü, başlık ve tek cümle,
/// App Store bağlantısının QR kodu (iPhone kamerasıyla okutulur; bu Mac'te üretilir) ve "Bağlantıyı kopyala".
struct HostedIPhoneAppSheet: View {
    @State private var isCopied: Bool = false
    /// App Store bağlantısının QR kodu (sayfa açılınca bir kez üretilir).
    @State private var qrCode: Result<CGImage, QRCodeError> = appStoreQRCode()
    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        HeroSheet(
            palette: .ocean,
            seed: "iphone-uygulamasi",
            heroHeight: 270,
            title: Text("iPhone'unda toplantı notları"),
            subtitle: Text("Yüz yüze toplantıları iPhone'unla kaydet; aynı hesapla, aynı abonelikle."),
            doneTitle: Text("Bitti"),
            onDone: { dismiss() }
        ) { (size: CGSize) in
            // Telefon ortada, alttan taşar (kırpılır): ekranın üst kısmı görünür.
            Image("hero-iphone-home")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 210)
                .shadow(color: Color.black.opacity(0.18), radius: 24, y: 12)
                .frame(width: size.width, alignment: .center)
                .offset(y: 40)
        } actions: {
            HeroTileRow {
                qrTile
                Button {
                    copyLink()
                } label: {
                    HeroTileLabel(
                        systemImage: isCopied ? "checkmark" : "link",
                        title: isCopied ? Text("Kopyalandı") : Text("Bağlantıyı kopyala"),
                        detail: Text("App Store")
                    )
                }
                .buttonStyle(HeroTileButtonStyle())
            }
        }
        .frame(width: 520, height: 710)
    }

    /// QR kod kutusu: koyu temada da beyaz zeminde siyah kod (kameralar açık zeminde okur).
    @ViewBuilder
    private var qrTile: some View {
        VStack(spacing: 10) {
            switch qrCode {
            case .success(let image):
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 104, height: 104)
                    .padding(8)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel(Text("App Store bağlantısının QR kodu"))
            case .failure(let error):
                Label(userFacingMessage(error: error), systemImage: "exclamationmark.triangle")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(NoticeSeverity.attention.tint)
            }
            Text("iPhone kamerasıyla tara")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardSurface(cornerRadius: 22)
        .accessibilityElement(children: .combine)
    }

    private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(gistsmithAppStoreURL.absoluteString, forType: .string)
        recordTelemetryCount(kind: .iPhonePromoCopied)
        withAnimation(.smooth(duration: 0.2)) { isCopied = true }
    }
}

/// App Store bağlantısının QR kodu; üretilemezse hata loglanır ve sayfada yazar.
private func appStoreQRCode() -> Result<CGImage, QRCodeError> {
    do {
        return .success(try qrCodeImage(text: gistsmithAppStoreURL.absoluteString, scale: 8))
    } catch {
        iPhoneAppLogger.error("QR kod üretilemedi, hata: \(error.description, privacy: .public)")
        return .failure(error)
    }
}

/// QR kod üretilemedi.
enum QRCodeError: Error, CustomStringConvertible {
    case generatorFailed(text: String)
    case renderFailed(width: Double, height: Double)

    var description: String {
        switch self {
        case .generatorFailed(let text): "QR generator returned no image for \(text)"
        case .renderFailed(let width, let height): "QR image could not be rendered (\(width)×\(height))"
        }
    }
}

/// Metnin QR kodu (CoreImage, cihazda; orta düzey hata düzeltme), modül başına `scale` piksel, keskin kenarlı.
func qrCodeImage(text: String, scale: CGFloat) throws(QRCodeError) -> CGImage {
    let filter: CIFilter & CIQRCodeGenerator = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else {
        throw QRCodeError.generatorFailed(text: text)
    }
    let scaled: CIImage = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    guard let image = CIContext().createCGImage(scaled, from: scaled.extent) else {
        throw QRCodeError.renderFailed(width: scaled.extent.width, height: scaled.extent.height)
    }
    return image
}
