import AINotepadCore
import AINotepadUI
import AppKit
import CoreAudio
import SwiftUI
import os

private let voiceTypingSettingsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "VoiceTypingSettings")

/// Sesle yazmanın dili bu Mac'te destekleniyor mu (Ayarlar'da gösterilir).
private enum DictationLanguageSupport: Equatable {
    case checking
    /// macOS 26+: Apple'ın cihaz içi diktesi bu dili destekliyor.
    case appleSpeech
    /// macOS 26+: desteklemiyor (sesle yazma açıkça hata verir).
    case unsupported
    /// macOS 14.2–25: WhisperKit modeli.
    case whisperKit
}

/// Ayarlar › Sesle yazma: üstte tanıtım kartı ("Dene" tanıtımı açar), sonra kartlar halinde aç/kapa ve izin, kısayollar
/// (basılı tut, eller serbest, değiştir), dil ve mikrofon, ses efektleri, gizlilik. Sesle yazma ilk kez açılınca ya da
/// "Dene"ye basılınca kısa tanıtım (`VoiceTypingIntroSheet`) açılır; tanıtım bir kez kendiliğinden gösterilir.
struct VoiceTypingSettings: View {
    let shortcuts: ShortcutController
    @Environment(DictationController.self) private var dictation: DictationController
    @AppStorage(SettingsKey.voiceTypingEnabled) private var isEnabled: Bool = true
    @AppStorage(SettingsKey.voiceTypingSoundEffects) private var soundEffects: Bool = false
    @AppStorage(SettingsKey.voiceTypingIntroShown) private var introShown: Bool = false
    @AppStorage(SettingsKey.primaryMeetingLanguage) private var primaryLanguage: String = MeetingLanguage.finnish.rawValue
    @State private var isTrusted: Bool = false
    @State private var languageSupport: DictationLanguageSupport = .checking
    @State private var microphoneName: String?
    @State private var isIntroPresented: Bool = false

    private var language: MeetingLanguage {
        MeetingLanguage(rawValue: primaryLanguage) ?? primaryMeetingLanguage()
    }

    /// Çalışan (ya da kayıtlı) kısayolun tuş kapakları; varsayılanı çakışıp atanmadıysa nil.
    private var keyCaps: [String]? {
        shortcuts.assignedBinding(action: .dictate).map { keyBindingKeyCaps(binding: $0) }
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
            VoiceTypingHero(keyCaps: keyCaps, isEnabled: isEnabled) {
                if !isEnabled {
                    // Açılış tanıtımı ayrıca tetiklenmesin: tanıtım zaten açılıyor.
                    introShown = true
                    isEnabled = true
                }
                isIntroPresented = true
            }
            .padding(.top, 18)
            SettingsGroup(title: Text("Sesle yazma")) {
                SettingsRow(icon: "waveform.and.mic", title: Text("Sesle yazma")) {
                    SettingsMoreText(summary: Text("Kısayola basıp konuş; söylediğin, imlecin olduğu yere yazılır."), details: Text(summary))
                } control: {
                    Toggle("Sesle yazma", isOn: $isEnabled).settingsToggle()
                }
                .onChange(of: isEnabled) { (_: Bool, enabled: Bool) in
                    shortcuts.sync()
                    // İlk açılışta kısa tanıtım (bir kez).
                    if enabled, !introShown {
                        isIntroPresented = true
                    }
                }
                SettingsRow(icon: "accessibility", title: Text("Erişilebilirlik izni")) {
                    SettingsMoreText(
                        summary: Text("Metni yazdığın yere yapıştırmak (⌘V) için gerekir."),
                        details: Text("Metni yazdığın yere yapıştırmak (⌘V) için gerekir. \(appName) yalnızca dikte ettiğin metni yapıştırır; tuş vuruşlarını, ekranı ya da diğer uygulamaların içeriğini okumaz. İzin yoksa metin panoya kopyalanır, ⌘V ile kendin yapıştırırsın.")
                    )
                    if !isTrusted {
                        NoticeText("İzin verilmedi: metin yalnızca panoya kopyalanır.", severity: .attention)
                    }
                } control: {
                    AccessibilityPermissionControl(isTrusted: isTrusted)
                }
            }
            shortcutGroup
            SettingsGroup(title: Text("Dil ve mikrofon")) {
                SettingsRow(icon: "globe", title: Text("Dil")) {
                    languageDetail
                } control: {
                    EmptyView()
                }
                SettingsRow(icon: "mic", title: Text("Mikrofon")) {
                    if let microphoneName {
                        Text("macOS'ta seçili giriş aygıtı kullanılır: \(microphoneName).")
                    } else {
                        Text("macOS'ta seçili giriş aygıtı kullanılır.")
                    }
                } control: {
                    Button("Ses ayarları") { openSoundInputSettings() }
                }
            }
            SettingsGroup(title: Text("Sesler")) {
                SettingsRow(icon: "speaker.wave.2", title: Text("Ses efektleri")) {
                    Text("Dinleme başlarken ve biterken kısa bir ses çalar.")
                } control: {
                    Toggle("Ses efektleri", isOn: $soundEffects).settingsToggle()
                }
            }
            privacyGroup
        }
        .onAppear {
            isTrusted = isAccessibilityTrusted()
            microphoneName = defaultInputDeviceName()
        }
        // İzin ve giriş aygıtı Sistem Ayarları'nda değişip uygulamaya dönülünce yenilenir.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { (_: Notification) in
            isTrusted = isAccessibilityTrusted()
            microphoneName = defaultInputDeviceName()
        }
        .task(id: primaryLanguage) {
            languageSupport = .checking
            if #available(macOS 26.0, *) {
                languageSupport = await appleDictationSupports(language: language) ? .appleSpeech : .unsupported
            } else {
                languageSupport = .whisperKit
            }
        }
        .sheet(isPresented: $isIntroPresented) {
            VoiceTypingIntroSheet(dictation: dictation, shortcuts: shortcuts, initialStep: .shortcut) {
                introShown = true
                isIntroPresented = false
            }
            .modifier(AppSheetChrome())
        }
        .onChange(of: isIntroPresented) { (_: Bool, presented: Bool) in
            // Sayfa dışına tıklanıp kapatılsa da tanıtım bir daha kendiliğinden açılmaz.
            if !presented {
                introShown = true
            }
        }
    }

    /// Kısayollar: aynı kısayol iki türlü kullanılır (basılı tut ya da kısa dokun); değiştirme kaydediciyle.
    private var shortcutGroup: some View {
        SettingsGroup(title: Text("Kısayollar")) {
            SettingsRow(icon: "hand.point.up.left", title: Text("Basılı tut ve konuş")) {
                Text("Konuştuğun sürece dinler, bırakınca yazar.")
            } control: {
                shortcutChips(gesture: Text("basılı tut"))
            }
            SettingsRow(icon: "infinity", title: Text("Eller serbest")) {
                Text("Kısa dokun, konuş; bitirmek için yeniden dokun ya da Esc'ye bas.")
            } control: {
                shortcutChips(gesture: Text("dokun"))
            }
            SettingsRow(icon: "keyboard", title: Text("Kısayol")) {
                Text("İki kullanım da aynı kısayolu kullanır.")
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
        } footer: {
            Text("Toplantı kaydı sürerken sesle yazma kapalıdır (mikrofon toplantıda). Parola alanlarına yazmaz.")
        }
    }

    @ViewBuilder
    private func shortcutChips(gesture: Text) -> some View {
        if let keyCaps {
            HStack(spacing: 8) {
                KeyCaps(caps: keyCaps, size: .regular, isLit: false)
                gesture
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
            .opacity(isEnabled ? 1 : 0.45)
        } else {
            Text("Kısayol yok")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
        }
    }

    /// Gizlilik: ses ve metnin nereye gittiği (yalnızca bu Mac), pano ve kullanım istatistiği.
    private var privacyGroup: some View {
        SettingsGroup(title: Text("Gizlilik")) {
            SettingsRow(icon: "lock.laptopcomputer", title: Text("Ses bu Mac'te kalır")) {
                privacyEngineText
            } control: {
                EmptyView()
            }
            // Pano yalnızca yapıştırmada (Erişilebilirlik izni var) geri döner; izin yoksa metin panoda kalır.
            if isTrusted {
                SettingsRow(icon: "doc.on.clipboard", title: Text("Pano eski haline döner")) {
                    Text("Metin kısa süre panoya yazılıp ⌘V ile yapıştırılır; pano hemen önceki içeriğine döner. Pano geçmişi uygulamaları (Maccy, Raycast…) bu metni geçmişe almaz.")
                } control: {
                    EmptyView()
                }
            } else {
                SettingsRow(icon: "doc.on.clipboard", title: Text("Metin panoda kalır")) {
                    Text("Erişilebilirlik izni olmadan metin panoya kopyalanır ve orada kalır; pano geçmişi uygulamaları onu da kaydedebilir.")
                } control: {
                    EmptyView()
                }
            }
            #if HOSTED_EDITION
            SettingsRow(icon: "chart.bar", title: Text("Kullanım istatistiği")) {
                Text("Kullanım istatistikleri açıksa yalnızca sesle yazmanın o gün kullanıldığı sayılır; ses ya da metin asla gönderilmez.")
            } control: {
                EmptyView()
            }
            #endif
        }
    }

    @ViewBuilder
    private var privacyEngineText: some View {
        if #available(macOS 26.0, *) {
            Text("Ses Apple'ın cihaz içi diktesiyle bu Mac'te yazıya dökülür. Ses kaydedilmez, saklanmaz; ses de metin de hiçbir sunucuya gönderilmez.")
        } else {
            Text("Ses WhisperKit modeliyle bu Mac'te yazıya dökülür. Ses kaydedilmez, saklanmaz; ses de metin de hiçbir sunucuya gönderilmez.")
        }
    }

    @ViewBuilder
    private var languageDetail: some View {
        let name: String = meetingLanguageName(language: language)
        switch languageSupport {
        case .checking, .appleSpeech:
            Text("Ana toplantı dilinle (\(name)) yazar; Ayarlar › Kayıt ve diller'den değişir. Apple'ın cihaz içi diktesi kullanılır; dil modeli gerekirse ilk kullanımda indirilir.")
        case .unsupported:
            NoticeText(userFacingMessage(error: DictationError.unsupportedLanguage(language)), severity: .attention)
        case .whisperKit:
            Text("Ana toplantı dilinle (\(name)) yazar; Ayarlar › Kayıt ve diller'den değişir. Bu Mac'te WhisperKit modeliyle çalışır (~630 MB; yoksa ilk kullanımda indirilir).")
        }
    }
}

/// Erişilebilirlik izninin durumu ya da "İzin ver" düğmesi (Ayarlar ve tanıtım).
struct AccessibilityPermissionControl: View {
    let isTrusted: Bool

    var body: some View {
        if isTrusted {
            Label("İzin verildi", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.tint)
        } else {
            Button("İzin ver") {
                requestAccessibilityPermission()
            }
        }
    }
}

/// Sesle yazma sayfasının tanıtım kartı: solda başlık, kısa açıklama, "Dene" ve kısayolun tuşları; sağda durgun pastel
/// zeminde küçük bir pencere örneği (yazılan cümle) ve altında sesle yazma hapı. Animasyon yok.
private struct VoiceTypingHero: View {
    let keyCaps: [String]?
    let isEnabled: Bool
    let onTry: @MainActor () -> Void

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                copy
                illustration.frame(width: 290)
            }
            VStack(alignment: .leading, spacing: 18) {
                copy
                illustration
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Theme.card))
        .overlay(shape.strokeBorder(Theme.line))
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Klavyeden hızlı: konuş, yazsın")
                .appFont(size: 22, weight: .semibold)
                .tracking(-0.4)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Her uygulamada kısayola basılı tut, konuş ve bırak: söylediğin imlecin olduğu yere yazılır. Mail, Slack, Notlar, tarayıcı; hepsi bu Mac'te.")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(isEnabled ? LocalizedStringKey("Hemen dene") : LocalizedStringKey("Aç ve dene"), action: onTry)
                    .buttonStyle(.accentPill)
                if let keyCaps {
                    KeyCaps(caps: keyCaps, size: .regular, isLit: false)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var illustration: some View {
        ZStack(alignment: .bottom) {
            FilmGradient(seed: "sesle-yazma", palette: .ocean)
            VStack(spacing: 12) {
                VoiceTypingMockWindow()
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                DictationPillView(
                    state: .listening(handsFree: false, canEscape: false, shortcut: ""), partialText: "", levels: heroWaveLevels, onTap: {}
                )
                .scaleEffect(0.82)
                .padding(.bottom, 8)
                .allowsHitTesting(false)
            }
        }
        .frame(height: 196)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Tanıtım görselindeki dalganın durgun seviyeleri (konuşma gibi inip çıkan).
private let heroWaveLevels: [Float] = [0.02, 0.05, 0.12, 0.3, 0.18, 0.42, 0.6, 0.35, 0.22, 0.5, 0.72, 0.4, 0.26, 0.55, 0.3, 0.14, 0.08, 0.03]

/// Tanıtım görselinde küçük bir mesaj penceresi: başlık noktaları, yazılmış cümle ve imleç.
private struct VoiceTypingMockWindow: View {
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 10, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { (_: Int) in
                    Circle().fill(Theme.line).frame(width: 6, height: 6)
                }
            }
            HStack(alignment: .lastTextBaseline, spacing: 1) {
                Text("Yarın onda kısa bir toplantı yapalım, sunumu ben getiririm.")
                    .appFont(size: 11, weight: .regular)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Rectangle()
                    .fill(appearance.accent.color)
                    .frame(width: 1.5, height: 12)
            }
            RoundedRectangle(cornerRadius: 2).fill(Theme.soft).frame(width: 120, height: 5)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Theme.card))
        .overlay(shape.strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
    }
}

/// Sistem Ayarları › Ses › Giriş'i açar (giriş aygıtı orada seçilir).
@MainActor
private func openSoundInputSettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input") else {
        return
    }
    NSWorkspace.shared.open(url)
}

/// macOS'un varsayılan giriş aygıtının adı (ör. "MacBook Pro Mikrofonu"); aygıt yoksa ya da okunamazsa nil (satır
/// adsız açıklamayı gösterir).
@MainActor
func defaultInputDeviceName() -> String? {
    var device: AudioDeviceID = 0
    var size: UInt32 = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address: AudioObjectPropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    let deviceStatus: OSStatus = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    guard deviceStatus == noErr, device != 0 else {
        voiceTypingSettingsLogger.info("Varsayılan giriş aygıtı yok, durum: \(deviceStatus, privacy: .public)")
        return nil
    }
    var name: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    address.mSelector = kAudioObjectPropertyName
    let nameStatus: OSStatus = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name)
    guard nameStatus == noErr, let name else {
        voiceTypingSettingsLogger.error("Giriş aygıtının adı okunamadı, durum: \(nameStatus, privacy: .public)")
        return nil
    }
    return name.takeRetainedValue() as String
}
