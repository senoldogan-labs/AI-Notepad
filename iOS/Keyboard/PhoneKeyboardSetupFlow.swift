import AINotepadUI
import KeyboardCore
import SwiftUI
import UIKit

/// Voice typing works on this iPhone (on-device dictation, iOS 26+).
func phoneVoiceTypingAvailable() -> Bool {
    if #available(iOS 26, *) {
        return true
    }
    return false
}

/// Debug: a setup page forced by `--klavye-kurulum <adim>` (screenshots); nil in normal use.
@MainActor
enum PhoneKeyboardSetupDebug {
    static var forcedStep: KeyboardSetupStep?
}

/// The `--klavye-kurulum` value of each page.
func keyboardSetupStep(launchValue: String) -> KeyboardSetupStep? {
    switch launchValue {
    case "tanitim": .intro
    case "ac": .turnOn
    case "tam-erisim": .fullAccess
    case "degistir": .switchKeyboard
    case "dene": .tryVoice
    case "hazir": .ready
    default: nil
    }
}

/// The guided setup of Gistsmith Keyboard: intro → numbered steps and iOS Settings → switch to the keyboard in a real
/// text field → try voice typing → ready. The page comes from what the app observes (`keyboardSetupStep`), using only
/// documented facts: the keyboard's own report in the App Group (written when it appears, with Full Access), whether
/// the setup's field is focused, whether the user went to Settings and came back, and the last dictation the keyboard
/// inserted. Coming back from Settings and a report from the keyboard (Darwin signal) re-read the facts at once; a
/// one-second tick covers the Full Access hint.
struct PhoneKeyboardSetupFlow: View {
    let host: PhoneKeyboardHost
    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.openURL) private var openURL: OpenURLAction
    @Environment(\.scenePhase) private var scenePhase: ScenePhase
    @State private var flowStartedAt: Date = Date()
    @State private var now: Date = Date()
    @State private var introDone: Bool = false
    /// The setup opened iOS Settings; the next return to the app counts as "back from Settings".
    @State private var openedSettings: Bool = false
    @State private var returnedFromSettings: Bool = false
    @State private var fieldFocusedSince: Date?
    @State private var fullAccessHintShown: Bool = false
    @State private var skipped: Bool = false
    @State private var showsHelp: Bool = false
    @State private var tryText: String = ""
    @AppStorage(PhoneKeyboardKey.meetingNotes) private var meetingNotes: Bool = false

    var body: some View {
        NavigationStack {
            page
                .animation(.easeInOut(duration: 0.25), value: step)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel(Text("Kapat"))
                    }
                }
                .navigationTitle(Text("Sesle yazma"))
                .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: scenePhase) { (_: ScenePhase, phase: ScenePhase) in
            guard phase == .active else {
                return
            }
            if openedSettings {
                returnedFromSettings = true
            }
            host.refreshReport()
            now = Date()
        }
        .onChange(of: host.reportRevision) { now = Date() }
        .onChange(of: step) { (_: KeyboardSetupStep, next: KeyboardSetupStep) in
            if next == .fullAccess {
                fullAccessHintShown = true
            }
        }
        .task {
            host.refreshReport()
            while !Task.isCancelled {
                now = Date()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private var step: KeyboardSetupStep {
        if let forced = PhoneKeyboardSetupDebug.forcedStep {
            return forced
        }
        return keyboardSetupStep(facts: KeyboardSetupFacts(
            introDone: introDone, returnedFromSettings: returnedFromSettings, lastFullAccessReportAt: keyboardFullAccessSeenAt(report: host.report),
            lastDictationSucceededAt: host.lastDictationSucceededAt, fieldFocusedSince: fieldFocusedSince, fullAccessHintShown: fullAccessHintShown,
            voiceTypingAvailable: phoneVoiceTypingAvailable(), tryVoiceSkipped: skipped, flowStartedAt: flowStartedAt, now: now
        ))
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case .intro:
            KeyboardSetupPage(
                title: Text("Her uygulamada sesle yaz"), subtitle: Text("Konuş, Gistsmith Klavye söylediğini bu iPhone'da yazıya döker; adlarını ve terimlerini bilir."),
                primaryTitle: Text("iOS Ayarları'nda aç"), primaryAction: { introDone = true }, secondaryTitle: nil, secondaryAction: {}
            ) {
                KeyboardIntroArt()
            } content: {
                EmptyView()
            }
        case .turnOn:
            KeyboardSetupPage(
                title: Text("Klavyeyi aç"), subtitle: Text("Ayarlar'da Gistsmith sayfası açılacak. Şunları yap:"),
                primaryTitle: Text("Ayarları aç"), primaryAction: openSettings,
                secondaryTitle: Text("Klavyeyi zaten ekledim"), secondaryAction: { returnedFromSettings = true }
            ) {
                EmptyView()
            } content: {
                KeyboardStepList(
                    steps: [
                        AttributedString(localized: "**Klavyeler**'e dokun"), AttributedString(localized: "**Gistsmith**'i aç"),
                        AttributedString(localized: "**Tam Erişime İzin Ver**'i aç"), AttributedString(localized: "Çıkan soruda **İzin Ver**'e dokun"),
                    ],
                    footnote: Text("Bitince Gistsmith'e geri dön; kurulum kendiliğinden ilerler. Yazdıkların hiçbir yere gönderilmez; klavyenin ağ bağlantısı yoktur.")
                )
            }
        case .fullAccess:
            KeyboardSetupPage(
                title: Text("Tam Erişim'i aç"),
                subtitle: Text("Gistsmith'i seçtiysen ve kurulum ilerlemiyorsa Tam Erişim kapalıdır: klavye Gistsmith'e ancak onunla haber verebilir."),
                primaryTitle: Text("Ayarları aç"), primaryAction: openSettings, secondaryTitle: Text("Gistsmith listede yok mu?"), secondaryAction: { showsHelp = true }
            ) {
                EmptyView()
            } content: {
                VStack(spacing: 16) {
                    KeyboardStepList(
                        steps: [
                            AttributedString(localized: "**Klavyeler**'e dokun"), AttributedString(localized: "**Tam Erişime İzin Ver**'i aç"),
                            AttributedString(localized: "Çıkan soruda **İzin Ver**'e dokun"),
                        ],
                        footnote: Text("Tam Erişim klavyeye yalnız Gistsmith'le paylaşılan klasörü açar. Klavyenin ağ bağlantısı yoktur; yazdıkların hiçbir yere gönderilmez.")
                    )
                    tryField
                }
            }
            .alert(Text("Gistsmith listede yok mu?"), isPresented: $showsHelp) {
                helpButtons
            } message: {
                helpMessage
            }
        case .switchKeyboard:
            KeyboardSetupPage(
                title: Text("🌐 tuşuna basılı tut, Gistsmith'i seç"), subtitle: Text("Aşağıdaki alana dokun; açılan klavyede dünya tuşuna basılı tut ve listeden Gistsmith'i seç."),
                primaryTitle: nil, primaryAction: {}, secondaryTitle: Text("Gistsmith listede yok mu?"), secondaryAction: { showsHelp = true }
            ) {
                KeyboardSwitchArt(otherKeyboardName: Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en") ?? "English")
            } content: {
                tryField
            }
            .alert(Text("Gistsmith listede yok mu?"), isPresented: $showsHelp) {
                helpButtons
            } message: {
                helpMessage
            }
        case .tryVoice:
            KeyboardSetupPage(
                title: Text("Şimdi konuşarak yaz"), subtitle: host.isSessionActive
                    ? Text("Klavyedeki mikrofona dokun ve bir şey söyle; metin alana yazılır.")
                    : Text("Önce mikrofonu hazırla; sonra klavyedeki mikrofona dokun ve bir şey söyle."),
                primaryTitle: host.isSessionActive ? nil : Text("Mikrofonu hazırla"), primaryAction: { host.startSessionManually() },
                secondaryTitle: Text("Şimdilik geç"), secondaryAction: { skipped = true }
            ) {
                EmptyView()
            } content: {
                VStack(spacing: 12) {
                    if #available(iOS 26, *) {
                        preparationLine
                    }
                    tryField
                }
            }
            .task {
                // The dictation model downloads now (no microphone), so the first dictation does not wait for it.
                if #available(iOS 26, *), host.preparation == .idle {
                    await host.prepareDictation()
                }
            }
        case .ready:
            KeyboardSetupPage(
                title: Text("Hazırsın"), subtitle: nil, primaryTitle: Text("Bitti"), primaryAction: { dismiss() }, secondaryTitle: nil, secondaryAction: {}
            ) {
                EmptyView()
            } content: {
                VStack(spacing: 16) {
                    KeyboardReadyCard(title: Text("Gistsmith Klavye hazır"), subtitle: phoneKeyboardReadySubtitle())
                    meetingNotesChoice
                }
            }
        }
    }

    @ViewBuilder
    private var helpButtons: some View {
        Button("Ayarları aç") { openSettings() }
        Button("Tamam", role: .cancel) {}
    }

    private var helpMessage: Text {
        Text("Ayarlar › Gistsmith › Klavyeler'de Gistsmith'in açık olduğuna bak. Şifre ve telefon numarası alanlarında iOS yalnız kendi klavyesini gösterir.")
    }

    /// The on-device dictation model's download for the keyboard's languages.
    @available(iOS 26, *)
    private var preparationLine: some View {
        HStack(spacing: 8) {
            switch host.preparation {
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Hazır.")
            case .preparing(let progress?):
                ProgressView()
                Text("İndiriliyor… \(Int(progress * 100))%")
            case .preparing(nil), .idle:
                ProgressView()
                Text("Hazırlanıyor…")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.attention)
                    .accessibilityHidden(true)
                Text(verbatim: message)
            }
            Spacer(minLength: 0)
        }
        .appFont(size: 14, weight: .regular)
        .foregroundStyle(Theme.muted)
        .accessibilityElement(children: .combine)
    }

    /// The explicit yes/no for meeting notes in the keyboard (off by default; spec "Review").
    private var meetingNotesChoice: some View {
        Toggle(isOn: $meetingNotes) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Klavyede toplantı notları")
                    .appFont(size: 16, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                Text("Son toplantılarının özetini ve görevlerini her uygulamaya ekle. Liste yalnız bu iPhone'da kalır.")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(16)
        .cardSurface(cornerRadius: 18)
        .onChange(of: meetingNotes) { host.syncShared() }
    }

    /// The real text field the user switches keyboards in and dictates into. It reports only whether it is focused (a
    /// documented fact); which keyboard it shows is learned from the keyboard's own report.
    private var tryField: some View {
        SetupTextField(text: $tryText, placeholder: String(localized: "Sesle yazmayı burada dene")) { (isFocused: Bool) in
            if isFocused {
                if fieldFocusedSince == nil {
                    fieldFocusedSince = Date()
                }
            } else {
                fieldFocusedSince = nil
            }
            now = Date()
        }
        .frame(height: 120)
        .cardSurface(cornerRadius: 20)
    }

    private func openSettings() {
        guard let settings = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        openedSettings = true
        openURL(settings)
    }
}

/// A multi-line text field (UIKit) focused when it appears, reporting when it gains and loses focus.
private struct SetupTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onFocusChange: @MainActor (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let view: UITextView = UITextView()
        view.delegate = context.coordinator
        view.font = UIFont.preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        view.accessibilityLabel = placeholder
        context.coordinator.placeholder.text = placeholder
        context.coordinator.placeholder.font = view.font
        context.coordinator.placeholder.textColor = .placeholderText
        context.coordinator.placeholder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(context.coordinator.placeholder)
        NSLayoutConstraint.activate([
            context.coordinator.placeholder.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 17),
            context.coordinator.placeholder.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
        ])
        DispatchQueue.main.async {
            view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            view.text = text
        }
        context.coordinator.placeholder.isHidden = !text.isEmpty
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SetupTextField
        let placeholder: UILabel = UILabel()

        init(parent: SetupTextField) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocusChange(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onFocusChange(false)
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            placeholder.isHidden = !textView.text.isEmpty
        }
    }
}
