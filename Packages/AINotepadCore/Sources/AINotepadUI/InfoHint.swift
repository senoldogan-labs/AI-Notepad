import SwiftUI

/// Açıklama ipucu: vurgu renginde küçük soru işareti; dokununca (tıklayınca) açıklama küçük bir baloncukta açılır.
/// Ayar bölümlerinin altındaki uzun açıklama paragraflarının yerine bölüm başlığının ya da açıkladığı satırın yanında
/// durur. iPhone'da baloncuk tam ekran sayfaya dönüşmez ve dokunma alanı en az 44 pt'dir; VoiceOver açıklamayı ipucu
/// olarak okur.
public struct InfoHint: View {
    private let text: Text
    @State private var isPresented: Bool = false
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(_ text: Text) {
        self.text = text
    }

    public var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .appFont(size: InfoHintMetrics.symbolSize, weight: .regular)
                .foregroundStyle(appearance.accent.color)
                .frame(width: InfoHintMetrics.hitSize, height: InfoHintMetrics.hitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        // Dokunma alanı satırı ya da başlığı yükseltmesin: görünen boyut simge kadar kalır.
        .padding(.vertical, -InfoHintMetrics.verticalOverhang)
        .linkPointer(isEnabled: true)
        .accessibilityLabel(Text("Açıklama"))
        .accessibilityHint(text)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            InfoHintBubble(text: text)
        }
    }
}

/// Baloncuğun içi: uygulamanın yazı tipi ve renkleriyle okunur genişlikte açıklama.
private struct InfoHintBubble: View {
    let text: Text

    var body: some View {
        text
            .appFont(size: 14, weight: .regular)
            .foregroundStyle(Theme.ink)
            // Bölüm başlığından açılınca başlığın büyük harf biçimi açıklamaya geçmesin.
            .textCase(nil)
            .multilineTextAlignment(.leading)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: InfoHintMetrics.bubbleWidth, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            #if os(iOS)
            .presentationCompactAdaptation(.popover)
            #endif
    }
}

/// İpucunun ölçüleri: Mac'te imleçle tıklanan küçük düğme, iPhone'da parmakla dokunulan en az 44 pt alan.
private enum InfoHintMetrics {
    #if os(macOS)
    static let symbolSize: CGFloat = 13
    static let hitSize: CGFloat = 20
    static let verticalOverhang: CGFloat = 0
    #else
    static let symbolSize: CGFloat = 16
    static let hitSize: CGFloat = 44
    static let verticalOverhang: CGFloat = 12
    #endif
    static let bubbleWidth: CGFloat = 300
}
