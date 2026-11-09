import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

/// Sesle yazma tanıtımının adımları.
enum VoiceTypingIntroStep: Int, CaseIterable {
    /// Kısayola bas: tuş kapakları basılıyken yanar (mikrofon açılmaz).
    case shortcut
    /// Alana konuşup yazdır: gerçek sesle yazma.
    case tryIt
    /// Hazırsın: iki kullanımın özeti.
    case done
}

/// Sesle yazmanın kısa tanıtımı (sayfa): üstte ilerleme çubuğu ve "Atla"; kısayolu dene, konuşup yazdır, hazırsın.
/// Sesle yazma ilk açılınca ya da Ayarlar'daki "Dene"ye basılınca açılır; atlanabilir, bitince ya da atlanınca bir daha
/// kendiliğinden açılmaz (`SettingsKey.voiceTypingIntroShown`, çağıran işaretler).
struct VoiceTypingIntroSheet: View {
    let dictation: DictationController
    let shortcuts: ShortcutController
    let onFinish: @MainActor () -> Void
    @State private var step: VoiceTypingIntroStep

    init(dictation: DictationController, shortcuts: ShortcutController, initialStep: VoiceTypingIntroStep, onFinish: @escaping @MainActor () -> Void) {
        self.dictation = dictation
        self.shortcuts = shortcuts
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                IntroProgressBar(step: step)
                Button("Atla") { onFinish() }
                    .buttonStyle(.hoverPlain)
                    .foregroundStyle(Theme.muted)
                    .opacity(step == .done ? 0 : 1)
                    .disabled(step == .done)
            }
            Group {
                switch step {
                case .shortcut:
                    IntroShortcutStep(dictation: dictation, shortcuts: shortcuts) { step = .tryIt }
                case .tryIt:
                    IntroTryStep(keyCaps: shortcuts.assignedBinding(action: .dictate).map { keyBindingKeyCaps(binding: $0) }) { step = .done }
                case .done:
                    IntroDoneStep(keyCaps: shortcuts.assignedBinding(action: .dictate).map { keyBindingKeyCaps(binding: $0) }, onFinish: onFinish)
                }
            }
            .id(step)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 16)), removal: .opacity))
            .padding(.top, 26)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .animation(.smooth(duration: 0.25), value: step)
        .padding(28)
        .frame(width: 540, height: 420)
    }
}

/// Üç parçalı ilerleme çubuğu: geçilen ve geçerli adım vurgu renginde.
private struct IntroProgressBar: View {
    let step: VoiceTypingIntroStep
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        HStack(spacing: 6) {
            ForEach(VoiceTypingIntroStep.allCases, id: \.self) { (item: VoiceTypingIntroStep) in
                Capsule()
                    .fill(item.rawValue <= step.rawValue ? appearance.accent.color : Theme.line)
                    .frame(height: 4)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Adım \(step.rawValue + 1) / \(VoiceTypingIntroStep.allCases.count)"))
    }
}

/// Adımın başlığı ve açıklaması.
private struct IntroHeading: View {
    let title: Text
    let detail: Text

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            title
                .appFont(size: 22, weight: .semibold)
                .tracking(-0.4)
                .foregroundStyle(Theme.ink)
            detail
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 1. adım: kısayolun tuş kapakları; kullanıcı kısayola basınca yanar ("çalışıyor"). Adım açıkken kısayol yalnız
/// sayılır, mikrofon açılmaz (`DictationController.startKeyTest`).
private struct IntroShortcutStep: View {
    let dictation: DictationController
    let shortcuts: ShortcutController
    let onNext: @MainActor () -> Void

    var body: some View {
        let binding: KeyBinding? = shortcuts.assignedBinding(action: .dictate)
        let isTested: Bool = dictation.keyTestPresses > 0
        VStack(alignment: .leading, spacing: 0) {
            IntroHeading(
                title: Text("Kısayolunu dene"),
                detail: Text("Klavyede kısayola basılı tut; tuşlar burada yanar. Bu adımda mikrofon açılmaz.")
            )
            VStack(spacing: 18) {
                if let binding {
                    KeyCaps(caps: keyBindingKeyCaps(binding: binding), size: .large, isLit: dictation.isShortcutHeld)
                } else {
                    NoticeText(String(localized: "Sesle yazmanın kısayolu yok. Aşağıdan bir kısayol seç."), severity: .attention)
                }
                Group {
                    if isTested {
                        Label("Kısayol çalışıyor", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    } else {
                        Text("Kısayola basmanı bekliyorum…")
                            .foregroundStyle(Theme.muted)
                    }
                }
                .appFont(size: 13, weight: .medium)
                if let error = shortcuts.errors[.dictate] {
                    NoticeText(error, severity: .error)
                }
                HStack(spacing: 8) {
                    Text("Başka bir kısayol mu?")
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                    ShortcutRecorder(shortcuts: shortcuts, action: .dictate, binding: binding)
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.soft.opacity(0.6)))
            .padding(.top, 22)
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                Button("İleri", action: onNext)
                    .buttonStyle(.pillPrimary)
                    .disabled(!isTested)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { dictation.startKeyTest() }
        .onDisappear { dictation.endKeyTest() }
    }
}

/// 2. adım: alana tıklayıp kısayolla konuş; sesle yazma metni gerçekten buraya yapıştırır. İzin yoksa metin panoya
/// kopyalanır; adım bunu söyler ve izin düğmesini gösterir.
private struct IntroTryStep: View {
    let keyCaps: [String]?
    let onNext: @MainActor () -> Void
    @State private var text: String = ""
    @State private var isTrusted: Bool = isAccessibilityTrusted()
    @FocusState private var isFocused: Bool

    var body: some View {
        let hasText: Bool = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            IntroHeading(
                title: Text("Konuş, yazsın"),
                detail: Text("Kısayola basılı tut, bir cümle söyle ve bırak. Ör. “Yarın onda kısa bir toplantı yapalım.”")
            )
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .appFont(size: 15, weight: .regular)
                .lineLimit(4...6)
                .focused($isFocused)
                .padding(14)
                .overlay(alignment: .topLeading) {
                    // macOS odaksız alanın yer tutucusunu yazı renginde çizer: soluk metin elle.
                    if text.isEmpty {
                        HStack(spacing: 6) {
                            if let keyCaps {
                                KeyCaps(caps: keyCaps, size: .small, isLit: false)
                            }
                            Text("basılı tut ve konuş…")
                        }
                        .appFont(size: 15, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .padding(14)
                        .allowsHitTesting(false)
                    }
                }
                .background(shape.fill(Theme.card))
                .overlay(shape.strokeBorder(isFocused ? Color.accentColor.opacity(0.6) : Theme.line))
                .padding(.top, 22)
            Group {
                if hasText {
                    Label("Oldu! Her uygulamada böyle çalışır.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                } else if !isTrusted {
                    HStack(spacing: 10) {
                        NoticeText("Erişilebilirlik izni yok: metin panoya kopyalanır, buraya ⌘V ile yapıştırırsın.", severity: .attention)
                        AccessibilityPermissionControl(isTrusted: isTrusted)
                    }
                } else {
                    Text("Ekranın altında beliren hap dinlediğini gösterir.")
                        .foregroundStyle(Theme.muted)
                }
            }
            .appFont(size: 12, weight: .medium)
            .padding(.top, 12)
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                if hasText {
                    Button("İleri", action: onNext)
                        .buttonStyle(.pillPrimary)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Şimdilik geç", action: onNext)
                        .buttonStyle(.pill)
                }
            }
        }
        .onAppear { isFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { (_: Notification) in
            isTrusted = isAccessibilityTrusted()
        }
    }
}

/// 3. adım: hazırsın; basılı tut ve eller serbest kullanımının özeti.
private struct IntroDoneStep: View {
    let keyCaps: [String]?
    let onFinish: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "checkmark")
                .appFont(size: 22, weight: .bold)
                .foregroundStyle(appearance.accent.onColor)
                .frame(width: 52, height: 52)
                .background(Circle().fill(appearance.accent.color))
            IntroHeading(
                title: Text("Hazırsın"),
                detail: Text("Sesle yazma her uygulamada çalışır. Ayarlar › Sesle yazma'dan kısayolu, sesleri ve dili değiştirebilirsin.")
            )
            .padding(.top, 18)
            VStack(alignment: .leading, spacing: 12) {
                tip(title: Text("Basılı tut"), detail: Text("Konuştuğun sürece dinler, bırakınca yazar."))
                tip(title: Text("Kısa dokun"), detail: Text("Eller serbest dinler; bitirmek için yeniden dokun ya da Esc'ye bas."))
            }
            .padding(.top, 20)
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                Button("Bitti", action: onFinish)
                    .buttonStyle(.pillPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func tip(title: Text, detail: Text) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let keyCaps {
                KeyCaps(caps: keyCaps, size: .small, isLit: false)
            }
            VStack(alignment: .leading, spacing: 1) {
                title.appFont(size: 13, weight: .medium)
                detail
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
