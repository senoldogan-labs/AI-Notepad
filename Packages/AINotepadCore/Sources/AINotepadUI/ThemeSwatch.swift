import SwiftUI

/// Tema kartı: takımın zemini üstünde küçük bir kart ve iki yazı çizgisi, altında adı; seçili olan vurgu rengiyle
/// çerçeveli. Sistem teması açık ve koyuyu çapraz bölünmüş gösterir.
public struct ThemeSwatch: View {
    private let theme: AppTheme
    private let isSelected: Bool
    private let accent: Color
    private let onSelect: @MainActor () -> Void

    public init(theme: AppTheme, isSelected: Bool, accent: Color, onSelect: @escaping @MainActor () -> Void) {
        self.theme = theme
        self.isSelected = isSelected
        self.accent = accent
        self.onSelect = onSelect
    }

    public var body: some View {
        let sets: (light: ThemeColorSet, dark: ThemeColorSet) = ThemeStore.shared.palette.colorSets(theme: theme)
        Button(action: onSelect) {
            VStack(spacing: 8) {
                ZStack {
                    preview(set: ThemeStore.shared.palette.swatchSet(theme: theme))
                    if theme == .system {
                        preview(set: sets.dark)
                            .clipShape(DiagonalHalf())
                    }
                }
                .frame(height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isSelected ? accent : Theme.line, lineWidth: isSelected ? 2 : 1))
                Text(verbatim: theme.displayName)
                    .appFont(size: 12, weight: isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Theme.ink : Theme.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverPlain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func preview(set: ThemeColorSet) -> some View {
        ZStack(alignment: .topLeading) {
            Color(hex: set.background)
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 3).fill(Color(hex: set.ink)).frame(width: 34, height: 5)
                RoundedRectangle(cornerRadius: 3).fill(Color(hex: set.muted)).frame(width: 22, height: 4)
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(hex: set.card))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color(hex: set.line)))
                    .frame(height: 22)
            }
            .padding(10)
        }
    }
}

/// Sol üstten sağ alta çapraz bölünmüş sağ-alt yarı.
private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        var path: Path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
