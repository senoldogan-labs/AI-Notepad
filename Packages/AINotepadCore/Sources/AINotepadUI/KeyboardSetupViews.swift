import SwiftUI

// The guided Gistsmith Keyboard setup's pieces (iPhone; here so they render offscreen in package tests). They only draw:
// the app passes every text and action. Ember: a static copper band with grain behind a light keyboard drawing, accent
// details, no animation.

/// One page of the setup: artwork on top (optional), a centred title and one sentence, the page's own content, and a
/// primary action pinned at the bottom with an optional quiet secondary action under it.
public struct KeyboardSetupPage<Artwork: View, Content: View>: View {
    let title: Text
    let subtitle: Text?
    let primaryTitle: Text?
    let primaryAction: () -> Void
    let secondaryTitle: Text?
    let secondaryAction: () -> Void
    let artwork: Artwork
    let content: Content

    /// - Parameters:
    ///   - primaryTitle: The bottom button; nil hides it (the page moves on by itself).
    ///   - secondaryTitle: A quiet text button under it; nil hides it.
    public init(
        title: Text, subtitle: Text?, primaryTitle: Text?, primaryAction: @escaping () -> Void, secondaryTitle: Text?,
        secondaryAction: @escaping () -> Void, @ViewBuilder artwork: () -> Artwork, @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.primaryTitle = primaryTitle
        self.primaryAction = primaryAction
        self.secondaryTitle = secondaryTitle
        self.secondaryAction = secondaryAction
        self.artwork = artwork()
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                artwork
                VStack(spacing: 10) {
                    title
                        .appTitleFont(size: 28, weight: .semibold)
                        .tracking(-0.5)
                        .foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        subtitle
                            .appFont(size: 16, weight: .regular)
                            .foregroundStyle(Theme.muted)
                    }
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
                .padding(.horizontal, 8)
                content
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if primaryTitle != nil || secondaryTitle != nil {
                VStack(spacing: 6) {
                    if let primaryTitle {
                        Button(action: primaryAction) {
                            primaryTitle
                                .appFont(size: 16, weight: .semibold)
                                .foregroundStyle(Theme.onPrimary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(Theme.primary, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(HeroTileButtonStyle())
                    }
                    if let secondaryTitle {
                        Button(action: secondaryAction) {
                            secondaryTitle
                                .appFont(size: 15, weight: .medium)
                                .foregroundStyle(Theme.muted)
                                .underline()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(HeroTileButtonStyle())
                    }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
                .background(Theme.background)
            }
        }
        .background(Theme.background)
    }
}

/// The intro artwork: an Ember band card with a light drawing of Gistsmith Keyboard in front of it, its voice bar
/// listening (accent waveform and microphone) above two rows of keys. Decorative.
public struct KeyboardIntroArt: View {
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init() {}

    public var body: some View {
        EmberBand(contourSeed: "keyboard-setup", contourCount: 4)
            .overlay(alignment: .bottom) {
                keyboardDrawing
                    .padding(.horizontal, 22)
                    .offset(y: 16)
            }
            .frame(height: 230)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .environment(\.colorScheme, .light)
            .accessibilityHidden(true)
    }

    private var keyboardDrawing: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "xmark")
                    .appFont(size: 12, weight: .semibold)
                    .foregroundStyle(Color.black.opacity(0.55))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.white))
                StaticWaveform(color: appearance.accent.color, barCount: 11, height: 18)
                    .frame(maxWidth: .infinity)
                Image(systemName: "checkmark")
                    .appFont(size: 12, weight: .bold)
                    .foregroundStyle(appearance.accent.onFillColor)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(appearance.accent.fillColor))
            }
            .padding(.horizontal, 4)
            ForEach([["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"], ["A", "S", "D", "F", "G", "H", "J", "K", "L"]], id: \.self) { (row: [String]) in
                HStack(spacing: 5) {
                    ForEach(row, id: \.self) { (key: String) in
                        Text(verbatim: key)
                            .appFont(size: 14, weight: .regular)
                            .foregroundStyle(Color.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white))
                    }
                }
                .padding(.horizontal, row.count < 10 ? 14 : 0)
            }
        }
        .padding(10)
        .padding(.bottom, 18)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(hex: 0xE4DED6)))
        .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
        .dynamicTypeSize(.large)
    }
}

/// Fixed accent bars shaped like a voice (decoration; the keyboard's own waveform moves).
struct StaticWaveform: View {
    let color: Color
    let barCount: Int
    let height: CGFloat

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { (index: Int) in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: height * staticWaveformHeight(index: index, count: barCount))
            }
        }
    }
}

/// A bar's height (0.3…1): a voice-like envelope, high in the middle. Pure function.
func staticWaveformHeight(index: Int, count: Int) -> CGFloat {
    let position: Double = count > 1 ? Double(index) / Double(count - 1) : 0.5
    let envelope: Double = sin(position * .pi)
    let ripple: Double = (sin(Double(index) * 2.3) + 1) / 2
    return CGFloat(0.3 + 0.7 * envelope * (0.55 + 0.45 * ripple))
}

/// The step's text with its Markdown-bold runs (`**Keyboards**`) in the semibold of the app's font family: the
/// environment font's fixed weight otherwise wins over the Markdown emphasis and the bold never shows. Pure function.
func keyboardStepText(markdown: AttributedString, regular: Font, emphasized: Font) -> AttributedString {
    var result: AttributedString = markdown
    for run in result.runs {
        let isStrong: Bool = run.inlinePresentationIntent?.contains(.stronglyEmphasized) ?? false
        result[run.range].font = isStrong ? emphasized : regular
    }
    return result
}

/// Numbered steps on a card: accent number discs, each step one line of text (Markdown bold from the localized string
/// shows as semibold), and an optional footnote under a divider.
public struct KeyboardStepList: View {
    let steps: [AttributedString]
    let footnote: Text?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    /// `steps`: localized Markdown, e.g. `AttributedString(localized: "Tap **Keyboards**")`.
    public init(steps: [AttributedString], footnote: Text?) {
        self.steps = steps
        self.footnote = footnote
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(steps.enumerated()), id: \.offset) { (index: Int, step: AttributedString) in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(verbatim: "\(index + 1)")
                            .appFont(size: 13, weight: .bold)
                            .foregroundStyle(appearance.accent.onFillColor)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(appearance.accent.fillColor))
                            .accessibilityHidden(true)
                        Text(keyboardStepText(
                            markdown: step, regular: appearance.font(size: 16, weight: .regular), emphasized: appearance.font(size: 16, weight: .semibold)
                        ))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(18)
            if let footnote {
                Divider().overlay(Theme.line)
                footnote
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 22)
    }
}

/// "Hold the globe, pick Gistsmith": the corner of a keyboard with the globe key held and the system's keyboard list
/// above it, Gistsmith highlighted in the accent. Decorative.
public struct KeyboardSwitchArt: View {
    let otherKeyboardName: String
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    /// `otherKeyboardName`: the system keyboard's name shown above ours (e.g. "English").
    public init(otherKeyboardName: String) {
        self.otherKeyboardName = otherKeyboardName
    }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color(hex: 0xD9D4CD))
                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Color.black.opacity(0.18), lineWidth: 6))
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: otherKeyboardName)
                    .appFont(size: 17, weight: .regular)
                    .foregroundStyle(Color.black.opacity(0.4))
                    .frame(width: 170, height: 44)
                    .background(Color(hex: 0xF4F1EC))
                Text(verbatim: "Gistsmith")
                    .appFont(size: 17, weight: .semibold)
                    .foregroundStyle(appearance.accent.onFillColor)
                    .frame(width: 170, height: 44)
                    .background(appearance.accent.fillColor)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
            .padding(.leading, 26)
            .padding(.bottom, 74)
            Image(systemName: "globe")
                .appFont(size: 24, weight: .regular)
                .foregroundStyle(Color.black.opacity(0.8))
                .frame(width: 48, height: 44)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.9)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(appearance.accent.color, lineWidth: 2))
                .padding(.leading, 26)
                .padding(.bottom, 22)
        }
        .frame(height: 200)
        .frame(maxWidth: 340)
        .environment(\.colorScheme, .light)
        .dynamicTypeSize(.large)
        .accessibilityHidden(true)
    }
}

/// The "keyboard is ready" card: an Ember band with the keyboard glyph joined to the kinds of apps it types in
/// (messages, mail, notes, browser; generic symbols, no brands), a title and one sentence.
public struct KeyboardReadyCard: View {
    let title: Text
    let subtitle: Text
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(title: Text, subtitle: Text) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "keyboard.fill")
                    .appFont(size: 18, weight: .semibold)
                    .foregroundStyle(appearance.accent.onFillColor)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(appearance.accent.fillColor))
                    // On a flat band the band and the circle share the fill colour; the ring keeps the glyph's disc visible.
                    .overlay(Circle().strokeBorder(appearance.accent.onFillColor.opacity(0.35), lineWidth: 1.5))
                Rectangle()
                    .fill(Color.black.opacity(0.25))
                    .frame(width: 14, height: 1.5)
                ForEach(["message.fill", "envelope.fill", "note.text", "globe", "bubble.left.and.text.bubble.right.fill"], id: \.self) { (symbol: String) in
                    Image(systemName: symbol)
                        .appFont(size: 15, weight: .medium)
                        .foregroundStyle(Color.black.opacity(0.7))
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.92)))
                }
            }
            .environment(\.colorScheme, .light)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                title
                    .appTitleFont(size: 22, weight: .semibold)
                    .tracking(-0.3)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                subtitle
                    .appFont(size: 15, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            EmberBand(contourSeed: "keyboard-ready", contourCount: 3)
                .frame(height: 88)
                .mask(LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom))
        }
        .cardSurface(cornerRadius: 24)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
