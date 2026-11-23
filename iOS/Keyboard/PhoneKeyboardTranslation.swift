import AINotepadUI
import KeyboardCore
import OSLog
import SwiftUI
// `TranslationSession` is not Sendable, yet `.translationTask` hands it to a main-actor closure whose download call is
// nonisolated (Apple's documented use); the session never leaves that closure.
@preconcurrency import Translation

private let keyboardTranslationLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "KeyboardTranslation")

/// Settings › Keyboard, "Söylediğimi çevir": the switch, the language dictations are written in, and for each language
/// dictations are spoken in whether its pair is downloaded on this iPhone, with Apple's download sheet behind "İndir".
/// The keyboard translates with the same on-device models (`KeyboardTranslator`); it cannot download them itself.
@available(iOS 26, *)
struct PhoneKeyboardTranslationSection: View {
    @Binding var isOn: Bool
    /// The target's BCP 47 code ("" until one is chosen).
    @Binding var target: String
    /// The languages dictations are spoken in: the chosen voice language, or every keyboard language when it is automatic.
    let sourceLanguageCodes: [String]
    @State private var targets: [String] = []
    @State private var statuses: [KeyboardTranslationPair: LanguageAvailability.Status] = [:]
    @State private var download: TranslationSession.Configuration?
    @Environment(\.scenePhase) private var scenePhase: ScenePhase

    var body: some View {
        Section {
            Toggle(isOn: $isOn) {
                Text("Söylediğimi çevir")
                Text("Bir dilde konuş, başka bir dilde yazılsın")
            }
            if isOn {
                Picker("Yazılacak dil", selection: $target) {
                    Text("Dil seç").tag("")
                    ForEach(pickerTargets, id: \.self) { (code: String) in
                        Text(verbatim: languageName(code: code)).tag(code)
                    }
                }
                ForEach(pairs, id: \.self) { (pair: KeyboardTranslationPair) in
                    pairRow(pair: pair)
                }
            }
        } footer: {
            PhoneSecondaryText {
                Text("Çeviri bu iPhone'da, Apple'ın cihaz içi çevirisiyle yapılır; metin hiçbir yere gönderilmez. Dil çifti indirilmiş olmalı (ya da Ayarlar › Uygulamalar › Çeviri'den indir). Çevrilemezse klavye metni kendiliğinden eklemez, nedenini söyler.")
            }
        }
        .task {
            targets = await translationTargets()
        }
        .task(id: pairs) {
            await refreshStatuses()
        }
        .onChange(of: scenePhase) { (_: ScenePhase, phase: ScenePhase) in
            // The user may have downloaded a language in iOS Settings meanwhile.
            if phase == .active {
                Task { await refreshStatuses() }
            }
        }
        .translationTask(download) { (session: TranslationSession) in
            do {
                try await session.prepareTranslation()
            } catch {
                keyboardTranslationLogger.error("Translation download failed: \(String(describing: error), privacy: .public)")
            }
            await refreshStatuses()
            download = nil
        }
    }

    /// The pairs the keyboard may translate: each spoken language that is not already the target.
    private var pairs: [KeyboardTranslationPair] {
        guard isOn else {
            return []
        }
        var seen: Set<KeyboardTranslationPair> = []
        return sourceLanguageCodes.compactMap { (source: String) -> KeyboardTranslationPair? in
            guard let pair = keyboardTranslationPair(sourceLanguageCode: source, targetLanguageCode: target.isEmpty ? nil : target),
                  seen.insert(pair).inserted
            else {
                return nil
            }
            return pair
        }
    }

    /// The supported targets, with a stored target the list does not hold (so the picker can show it).
    private var pickerTargets: [String] {
        target.isEmpty || targets.contains(target) ? targets : [target] + targets
    }

    private func pairRow(pair: KeyboardTranslationPair) -> some View {
        HStack(spacing: 12) {
            Text(verbatim: "\(languageName(code: pair.sourceLanguageCode)) → \(languageName(code: pair.targetLanguageCode))")
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            switch statuses[pair] {
            case .installed:
                Label("İndirildi", systemImage: "checkmark")
                    .foregroundStyle(Theme.muted)
            case .supported:
                Button("İndir") {
                    download = TranslationSession.Configuration(
                        source: Locale.Language(identifier: pair.sourceLanguageCode), target: Locale.Language(identifier: pair.targetLanguageCode)
                    )
                }
                .disabled(download != nil)
            case .unsupported, .some:
                Text("Çevrilemiyor")
                    .foregroundStyle(Theme.muted)
            case nil:
                ProgressView()
            }
        }
    }

    private func refreshStatuses() async {
        let availability: LanguageAvailability = LanguageAvailability()
        var updated: [KeyboardTranslationPair: LanguageAvailability.Status] = [:]
        for pair in pairs {
            updated[pair] = await availability.status(
                from: Locale.Language(identifier: pair.sourceLanguageCode), to: Locale.Language(identifier: pair.targetLanguageCode)
            )
        }
        statuses = updated
    }
}

/// The languages Apple's on-device translation writes, as BCP 47 codes ("en", "en-GB", "zh-TW"), by name.
@available(iOS 26, *)
private func translationTargets() async -> [String] {
    let codes: [String] = await LanguageAvailability().supportedLanguages.map(\.minimalIdentifier)
    return Array(Set(codes)).sorted { (lhs: String, rhs: String) -> Bool in
        languageName(code: lhs).localizedStandardCompare(languageName(code: rhs)) == .orderedAscending
    }
}

/// The language's name in the app's language ("İngilizce (Birleşik Krallık)").
private func languageName(code: String) -> String {
    Locale.current.localizedString(forIdentifier: code) ?? code
}
