import SwiftUI

/// Ayar satırının solundaki küçük simge kutusu: yumuşak zemin üstünde soluk SF Symbol. Mac'teki gruplu ayar
/// kartlarında ve iPhone'daki ayar listesinde (Label simgesi olarak) aynı görünür; yalnızca süsleme (VoiceOver atlar).
public struct SettingsIconTile: View {
    private let systemImage: String

    public init(systemImage: String) {
        self.systemImage = systemImage
    }

    public var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(Theme.muted)
            .frame(width: 28, height: 28)
            .background(Theme.soft, in: shape)
            .overlay(shape.strokeBorder(Theme.line))
            .accessibilityHidden(true)
    }
}
