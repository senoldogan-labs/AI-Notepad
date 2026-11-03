import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

/// Sesle yazmanın dili bu Mac'te destekleniyor mu (Ayarlar'da gösterilir).
private enum DictationLanguageSupport: Equatable {
    case checking
    /// macOS 26+: Apple'ın cihaz içi diktesi bu dili destekliyor.
    case appleSpeech
    /// macOS 26+: desteklemiyor (sesle yazma açıkça hata verir).
    case unsupported
    /// macOS 15–25: WhisperKit modeli.
    case whisperKit
}

/// Ayarlar › Sesle yazma: aç/kapa, kısayol (basılı tut ya da dokun), Erişilebilirlik izni ve dil.
struct VoiceTypingSettings: View {
    let shortcuts: ShortcutController
    @AppStorage(SettingsKey.voiceTypingEnabled) private var isEnabled: Bool = true
    @AppStorage(SettingsKey.primaryMeetingLanguage) private var primaryLanguage: String = MeetingLanguage.finnish.rawValue
    @State private var isTrusted: Bool = false
    @State private var languageSupport: DictationLanguageSupport = .checking

    private var language: MeetingLanguage {
        MeetingLanguage(rawValue: primaryLanguage) ?? primaryMeetingLanguage()
    }

    /// Özelliğin özeti: abonelikte ücretsiz ve toplantı hakkından düşmediği de yazar.
    private var summary: LocalizedStringKey {
        #if HOSTED_EDITION
        "Kısayola basıp konuş; söylediğin, imlecin olduğu yere yazılır (Mail, Slack, Notlar, tarayıcı…). Ses bu Mac'te yazıya dökülür; ses de metin de hiçbir yere gönderilmez. Giriş yapmış her hesapta ücretsiz ve sınırsız; deneme toplantılarından ve aylık süreden düşmez. Toplantı kaydı sürerken sesle yazma kapalıdır (mikrofon toplantıda). Parola alanlarına yazmaz."
        #else
        "Kısayola basıp konuş; söylediğin, imlecin olduğu yere yazılır (Mail, Slack, Notlar, tarayıcı…). Ses bu Mac'te yazıya dökülür; ses de metin de hiçbir yere gönderilmez. Toplantı kaydı sürerken sesle yazma kapalıdır (mikrofon toplantıda). Parola alanlarına yazmaz."
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: Text("Sesle yazma"), hint: Text(summary)) {
                Toggle("Sesle yazma", isOn: $isEnabled).settingsToggle()
            }
            .onChange(of: isEnabled) { (_: Bool, _: Bool) in
                shortcuts.sync()
            }
            SettingsRow(
                title: Text("Kısayol"),
                hint: Text("Basılı tut: konuştuğun sürece dinler, bırakınca yazar. Kısa dokun: eller serbest dinler; bitirmek için yeniden dokun ya da Esc'ye bas.")
            ) {
                if let error = shortcuts.errors[.dictate] {
                    NoticeText(error, severity: .error)
                }
            } control: {
                ShortcutRecorder(binding: shortcuts.currentBinding(action: .dictate)) { (binding: KeyBinding) -> Void in
                    shortcuts.change(action: .dictate, binding: binding)
                }
                .disabled(!isEnabled)
            }
            SettingsRow(
                title: Text("Erişilebilirlik izni"),
                hint: Text("Metni yazdığın yere yapıştırmak (⌘V) için gerekir. \(appName) yalnızca dikte ettiğin metni yapıştırır; tuş vuruşlarını, ekranı ya da diğer uygulamaların içeriğini okumaz. İzin yoksa metin panoya kopyalanır, ⌘V ile kendin yapıştırırsın.")
            ) {
                if !isTrusted {
                    NoticeText("İzin verilmedi: metin yalnızca panoya kopyalanır.", severity: .attention)
                }
            } control: {
                if isTrusted {
                    Label("İzin verildi", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                } else {
                    Button("İzin ver") {
                        requestAccessibilityPermission()
                    }
                }
            }
            SettingsRow(title: Text("Dil"), hint: languageHint) {
                if languageSupport == .unsupported {
                    NoticeText(userFacingMessage(error: DictationError.unsupportedLanguage(language)), severity: .attention)
                }
            } control: {
                Text(verbatim: meetingLanguageName(language: language))
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
        }
        .onAppear { isTrusted = isAccessibilityTrusted() }
        // İzin Sistem Ayarları'nda verilip uygulamaya dönülünce durum yenilenir.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { (_: Notification) in
            isTrusted = isAccessibilityTrusted()
        }
        .task(id: primaryLanguage) {
            languageSupport = .checking
            if #available(macOS 26.0, *) {
                languageSupport = await appleDictationSupports(language: language) ? .appleSpeech : .unsupported
            } else {
                languageSupport = .whisperKit
            }
        }
    }

    /// Dilin açıklaması: hangi dille ve hangi tanımayla yazıldığı (desteklenmeyen dilin uyarısı satırda kalır).
    private var languageHint: Text {
        let name: String = meetingLanguageName(language: language)
        switch languageSupport {
        case .checking, .appleSpeech, .unsupported:
            return Text("Ana toplantı dilinle (\(name)) yazar; Ayarlar › Genel'den değişir. Apple'ın cihaz içi diktesi kullanılır; dil modeli gerekirse ilk kullanımda indirilir.")
        case .whisperKit:
            return Text("Ana toplantı dilinle (\(name)) yazar; Ayarlar › Genel'den değişir. Bu Mac'te WhisperKit modeliyle çalışır (~630 MB; yoksa ilk kullanımda indirilir).")
        }
    }
}
