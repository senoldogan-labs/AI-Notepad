import SwiftUI

/// Addan sabit renkli harf rozeti (Kişiler; Mac ve iPhone).
public struct PersonAvatar: View {
    let name: String
    let size: CGFloat

    public init(name: String, size: CGFloat) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        let hash: Int = name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
        let color: Color = personColor(person: hash % DesignTokens.personPalette.count + 1)
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .appFont(size: size * 0.42, weight: .semibold)
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(Circle().fill(color.opacity(0.15)).background(Circle().fill(Theme.card)))
            .accessibilityHidden(true)
    }
}
