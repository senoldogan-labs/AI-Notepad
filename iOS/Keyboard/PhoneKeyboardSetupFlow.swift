import AINotepadUI
import KeyboardCore
import SwiftUI
import UIKit

/// Our keyboard extension's bundle id (`project.yml`: app id + ".Keyboard").
private let ourKeyboardBundleIdentifier: String = keyboardExtensionBundleIdentifier(appBundleIdentifier: Bundle.main.bundleIdentifier ?? "")

/// The identifier of a system input mode. `UITextInputMode` has no public identifier; third-party keyboards are listed
/// under their extension's bundle id in its `identifier` property. Read only when the object answers it, so a future
/// iOS without it gives nil ("unknown") instead of an exception.
private func inputModeIdentifier(_ mode: UITextInputMode) -> String? {
    guard mode.responds(to: NSSelectorFromString("identifier")) else {
        return nil
    }
    return mode.value(forKey: "identifier") as? String
}

/// Whether Gistsmith Keyboard is in the user's active keyboards; nil when the system does not tell.
@MainActor
func phoneKeyboardIsEnabled() -> Bool? {
    let identifiers: [String?] = UITextInputMode.activeInputModes.map(inputModeIdentifier)
    guard !identifiers.isEmpty, !identifiers.contains(where: { $0 == nil }) else {
        return nil
    }
    return keyboardInputModesContainOurs(identifiers: identifiers.compactMap { $0 }, extensionBundleIdentifier: ourKeyboardBundleIdentifier)
}

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
/// text field → try voice typing → ready. The page is never chosen by a button alone: it comes from what the app
/// observes (`keyboardSetupStep`): the system's keyboard list, the keyboard's report (written only with Full Access), the
/// field's current keyboard and the last dictation the keyboard inserted. Coming back from Settings, a report from the
/// keyboard and a keyboard switch re-read the facts at once; a one-second tick covers the Full Access wait.
struct PhoneKeyboardSetupFlow: View {
    let host: PhoneKeyboardHost
    @Environment(\.dismiss) private var dismiss: DismissAction
    @Environment(\.openURL) private var openURL: OpenURLAction
    @Environment(\.scenePhase) private var scenePhase: ScenePhase
    @State private var flowStartedAt: Date = Date()
    @State private var now: Date = Date()
    @State private var introDone: Bool = false
    @State private var isEnabled: Bool? = phoneKeyboardIsEnabled()
    @State private var activeSince: Date?
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
            if phase == .active {
                refreshFacts()
            }
        }
        .onChange(of: host.reportRevision) { refreshFacts() }
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
            introDone: introDone, isEnabled: isEnabled, lastKeyboardSeenAt: host.report?.lastSeenAt,
            lastDictationSucceededAt: host.lastDictationSucceededAt, keyboardActiveInFieldSince: activeSince,
            voiceTypingAvailable: phoneVoiceTypingAvailable(), tryVoiceSkipped: skipped, flowStartedAt: flowStartedAt, now: now
        ))
    }

    private func refreshFacts() {
        isEnabled = phoneKeyboardIsEnabled()
        host.refreshReport()
        now = Date()
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
                primaryTitle: Text("Ayarları aç"), primaryAction: openSettings, secondaryTitle: nil, secondaryAction: {}
            ) {
                EmptyView()
            } content: {
                KeyboardStepList(
                    steps: [
                        Text("**Klavyeler**'e dokun"), Text("**Gistsmith**'i aç"), Text("**Tam Erişime İzin Ver**'i aç"),
                        Text("Çıkan soruda **İzin Ver**'e dokun"),
                    ],
                    footnote: Text("Bitince Gistsmith'e geri dön; kurulum kendiliğinden ilerler. Yazdıkların hiçbir yere gönderilmez; klavyenin ağ bağlantısı yoktur.")
                )
            }
        case .fullAccess:
            KeyboardSetupPage(
                title: Text("Tam Erişim'i aç"), subtitle: Text("Klavye açık ama Gistsmith'le konuşamıyor. Sesle yazma için Tam Erişim gerekir."),
                primaryTitle: Text("Ayarları aç"), primaryAction: openSettings, secondaryTitle: nil, secondaryAction: {}
            ) {
                EmptyView()
            } content: {
                VStack(spacing: 16) {
                    KeyboardStepList(
                        steps: [Text("**Klavyeler**'e dokun"), Text("**Tam Erişime İzin Ver**'i aç"), Text("Çıkan soruda **İzin Ver**'e dokun")],
                        footnote: Text("Tam Erişim klavyeye yalnız Gistsmith'le paylaşılan klasörü açar. Klavyenin ağ bağlantısı yoktur; yazdıkların hiçbir yere gönderilmez.")
                    )
                    tryField
                }
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
                Button("Ayarları aç") { openSettings() }
                Button("Tamam", role: .cancel) {}
            } message: {
                Text("Ayarlar › Gistsmith › Klavyeler'de Gistsmith'in açık olduğuna bak. Şifre ve telefon numarası alanlarında iOS yalnız kendi klavyesini gösterir.")
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

    /// The real text field the user switches keyboards in and dictates into. It reports which keyboard is up.
    private var tryField: some View {
        KeyboardProbeField(text: $tryText, placeholder: String(localized: "Sesle yazmayı burada dene")) { (isOurs: Bool) in
            if isOurs {
                if activeSince == nil {
                    activeSince = Date()
                }
            } else {
                activeSince = nil
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
        openURL(settings)
    }
}

/// A multi-line text field (UIKit) that reports whether Gistsmith Keyboard is the keyboard it shows: SwiftUI's
/// `TextField` does not expose its input mode. Focused when it appears.
private struct KeyboardProbeField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onKeyboardChange: @MainActor (Bool) -> Void

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
        context.coordinator.observe(view: view)
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
        var parent: KeyboardProbeField
        let placeholder: UILabel = UILabel()
        private weak var view: UITextView?
        /// Removed in `deinit` (nonisolated); written once on the main actor.
        nonisolated(unsafe) private var observer: (any NSObjectProtocol)?

        init(parent: KeyboardProbeField) {
            self.parent = parent
        }

        func observe(view: UITextView) {
            self.view = view
            observer = NotificationCenter.default.addObserver(
                forName: UITextInputMode.currentInputModeDidChangeNotification, object: nil, queue: .main
            ) { [weak self] (_: Notification) in
                MainActor.assumeIsolated {
                    self?.report()
                }
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            report()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onKeyboardChange(false)
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            placeholder.isHidden = !textView.text.isEmpty
        }

        private func report() {
            guard let view, view.isFirstResponder, let mode = view.textInputMode else {
                parent.onKeyboardChange(false)
                return
            }
            parent.onKeyboardChange(inputModeIdentifier(mode) == ourKeyboardBundleIdentifier)
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
}
