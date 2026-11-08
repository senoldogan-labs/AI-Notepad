import SwiftUI

/// Ayar satırının solundaki küçük simge kutusu: vurgu renginin (Görünüm › Vurgu rengi) soluk zemini üstünde vurgu
/// renginde SF Symbol. Mac'teki gruplu ayar kartlarında ve iPhone'daki ayar listesinde (Label simgesi olarak) aynı
/// görünür; yalnızca süsleme (VoiceOver atlar).
public struct SettingsIconTile: View {
    private let systemImage: String
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(systemImage: String) {
        self.systemImage = systemImage
    }

    public var body: some View {
        Image(systemName: systemImage)
            .shapeSymbol(size: 13, weight: .medium)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(appearance.accent.color)
            .frame(width: 28, height: 28)
            .background(appearance.accent.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}
