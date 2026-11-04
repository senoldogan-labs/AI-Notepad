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
        "Kısayola basıp konuş; söylediğin, imlecin olduğu yere yazılır (Mail, Slack, Notlar, tarayıcı…). Ses bu Mac'te yazıya dökülür; ses de metin de hiçbir yere gönderilmez. Giriş yapmış her hesapta ücretsiz ve sınırsız; deneme toplantılarından ve aylık süreden düşmez."
        #else
        "Kısayola basıp konuş; söylediğin, imlecin olduğu yere yazılır (Mail, Slack, Notlar, tarayıcı…). Ses bu Mac'te yazıya dökülür; ses de metin de hiçbir yere gönderilmez."
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: Text("Sesle yazma")) {
                Text(summary)
            } control: {
                Toggle("Sesle yazma", isOn: $isEnabled).settingsToggle()
            }
            .onChange(of: isEnabled) { (_: Bool, _: Bool) in
                shortcuts.sync()
            }
            SettingsRow(title: Text("Kısayol")) {
                Text("Basılı tut: konuştuğun sürece dinler, bırakınca yazar. Kısa dokun: eller serbest dinler; bitirmek için yeniden dokun ya da Esc'ye bas.")
                if let error = shortcuts.errors[.dictate] {
                    NoticeText(error, severity: .error)
                } else if let reason = shortcuts.unsetDefaults[.dictate] {
                    // Varsayılan kısayol çakıştı: menü uyarmaz, kısayol burada seçilir.
                    NoticeText(String(localized: "Varsayılan kısayol atanmadı: \(reason) Sesle yazmak için bir kısayol seç."), severity: .attention)
                }
            } control: {
                ShortcutRecorder(shortcuts: shortcuts, action: .dictate, binding: shortcuts.assignedBinding(action: .dictate))
                .disabled(!isEnabled)
            }
            SettingsRow(title: Text("Erişilebilirlik izni")) {
                Text("Metni yazdığın yere yapıştırmak (⌘V) için gerekir. \(appName) yalnızca dikte ettiğin metni yapıştırır; tuş vuruşlarını, ekranı ya da diğer uygulamaların içeriğini okumaz. İzin yoksa metin panoya kopyalanır, ⌘V ile kendin yapıştırırsın.")
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
            SettingsRow(title: Text("Dil")) {
                languageDetail
            } control: {
                EmptyView()
            }
            Text("Toplantı kaydı sürerken sesle yazma kapalıdır (mikrofon toplantıda). Parola alanlarına yazmaz.")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
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

    @ViewBuilder
    private var languageDetail: some View {
        let name: String = meetingLanguageName(language: language)
        switch languageSupport {
        case .checking, .appleSpeech:
            Text("Ana toplantı dilinle (\(name)) yazar; Ayarlar › Genel'den değişir. Apple'ın cihaz içi diktesi kullanılır; dil modeli gerekirse ilk kullanımda indirilir.")
        case .unsupported:
            NoticeText(userFacingMessage(error: DictationError.unsupportedLanguage(language)), severity: .attention)
        case .whisperKit:
            Text("Ana toplantı dilinle (\(name)) yazar; Ayarlar › Genel'den değişir. Bu Mac'te WhisperKit modeliyle çalışır (~630 MB; yoksa ilk kullanımda indirilir).")
        }
    }
}
