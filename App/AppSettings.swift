import AINotepadCore
import AINotepadUI
import AppKit
import Foundation
import SwiftUI
import os

private let settingsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Settings")

/// Canlı metin motoru. Seçim UserDefaults'ta `SettingsKey.liveEngine` ile saklanır.
enum LiveEngine: String, CaseIterable {
    case deepgram
    case whisperKit
    /// Apple'ın cihaz içi konuşma tanıması (SpeechAnalyzer): anahtarsız, büyük model indirmesi yok.
    case appleSpeech

    /// Bu motorla kaydedilen toplantının son geçiş türü.
    var recordingEngine: RecordingEngine {
        switch self {
        case .deepgram: .cloud
        case .whisperKit, .appleSpeech: .local
        }
    }
}

/// UserDefaults anahtarları.
enum SettingsKey {
    static let liveEngine: String = "liveEngine"
    static let displayMode: String = "displayMode"
    /// Kullanıcı adı (not görevlerinde "benim" tespiti için; `userContentDefaults` alanında: abonelikte hesabın).
    static let userName: String = userNameDefaultsKey
    /// Profilin unvanı, şirketi ve şirket açıklaması (ad gibi `userContentDefaults` alanında).
    static let jobTitle: String = userJobTitleDefaultsKey
    static let companyName: String = userCompanyNameDefaultsKey
    static let companyDescription: String = userCompanyDescriptionDefaultsKey
    static let hideFromScreenCapture: String = "hideFromScreenCapture"
    /// "Ne kaçırdım?" penceresi (dakika).
    static let missedWindowMinutes: String = "missedWindowMinutes"
    /// Ses dosyalarının saklama süresi (gün).
    static let audioRetentionDays: String = "audioRetentionDays"
    static let llmProvider: String = "llmProvider"
    static let llmBaseURL: String = "llmBaseURL"
    static let llmFastModel: String = "llmFastModel"
    static let llmSmartModel: String = "llmSmartModel"
    /// OpenAI uyumlu `reasoning_effort` (boş: gönderilmez).
    static let llmFastEffort: String = "llmFastEffort"
    static let llmSmartEffort: String = "llmSmartEffort"
    /// Claude: model sınıfı başına model ve effort.
    static let claudeFastModel: String = "claudeFastModel"
    static let claudeSmartModel: String = "claudeSmartModel"
    static let claudeFastEffort: String = "claudeFastEffort"
    static let claudeSmartEffort: String = "claudeSmartEffort"
    static let recordShortcut: String = "shortcut.record"
    static let windowsShortcut: String = "shortcut.windows"
    static let dictateShortcut: String = "shortcut.dictate"
    /// Sesle yazma (dikte) açık mı: açıkken kısayolu her uygulamada çalışır.
    static let voiceTypingEnabled: String = "voiceTyping.enabled"
    /// Sesle yazma başlarken ve metin yazılınca kısa ses çalınsın mı (varsayılan kapalı).
    static let voiceTypingSoundEffects: String = "voiceTyping.soundEffects"
    /// Sesle yazma tanıtımı (kısayolu dene, konuşup yazdır) gösterildi mi: bir kez açılır.
    static let voiceTypingIntroShown: String = "voiceTyping.introShown"
    static let onboardingCompleted: String = "onboardingCompleted"
    /// "Sen" (mikrofon) kapalı mı.
    static let micMuted: String = "micMuted"
    /// Kayıt başlarken katılımcılara haber verme hatırlatması.
    static let consentReminder: String = "consentReminder"
    /// Yeni toplantıların not şablonu (`NoteTemplateKind`) ve kendi şablonunun yönergesi.
    static let noteTemplate: String = "noteTemplate"
    static let customTemplate: String = "customTemplate"
    /// Kendi şablonunun adı (galeriden kopyalanınca "<ad> (kopya)"); boşsa "Kendi şablonum" yazılır.
    static let customTemplateName: String = "customTemplate.name"
    /// "Şablonu toplantı adına göre seç": ad türü açıkça gösteriyorsa yeni toplantı o şablonla yazılır.
    static let templateFromTitle: String = "noteTemplate.fromTitle"
    /// Takvim: yaklaşan toplantılar, 1 dk önce hatırlatma, görüşme başlayınca öneri.
    static let calendarEnabled: String = "calendar.enabled"
    static let meetingReminders: String = "calendar.reminders"
    static let micSuggestions: String = "calendar.micSuggestions"
    /// Bildirimler (Ayarlar › Genel › Bildirimler; iPhone'la aynı adlar, bkz. `EngagementSettingKey`): not hazır, görev
    /// günü, haftalık özet, kayıtsız hafta. Varsayılan açık.
    static let notifyNoteReady: String = EngagementSettingKey.noteReady
    static let notifyTaskDue: String = EngagementSettingKey.taskDue
    static let notifyWeeklySummary: String = EngagementSettingKey.weeklySummary
    static let notifyInactive: String = EngagementSettingKey.inactive
    /// Not hazır olunca webhook'a kendiliğinden gönder.
    static let webhookAutoSend: String = "integrations.webhookAutoSend"
    /// Sonucu belirsiz gönderimler ("toplantı|hedef"): sunucu yanıt vermedi, not gitmiş olabilir; kendiliğinden yeniden
    /// gönderilmez. Bu cihaza özeldir.
    static let uncertainSends: String = "integrations.uncertainSends"
    /// Hedefin kalıcı olarak reddettiği gönderimler ("toplantı|hedef"; 4xx, bkz. `isPermanentDeliveryFailure`):
    /// kendiliğinden yeniden denenmez, hata bir kez gösterilir. Elle gönderim işareti kaldırır. Bu cihaza özeldir.
    static let rejectedSends: String = "integrations.rejectedSends"
    /// Ana toplantı dili: otomatik algılama bu dille başlar (ve Mac'te bununla İngilizce arasında seçer).
    static let primaryMeetingLanguage: String = "language.primary"
    /// Not ve çeviri dili (`ShareLanguage`): not, canlı çeviri, "Ne kaçırdım?" ve Sor cevapları bu dilde yazılır.
    static let noteLanguage: String = "language.note"
    /// Not dili ayarından önceki sürümlerin kullanıcısına Türkçe bir kez yazıldı (`legacyNoteLanguage`).
    static let noteLanguageMigrated: String = "migration.noteLanguage"
    /// Takvimdeki çevrim içi görüşme sürerken mikrofon başka uygulamada açılınca kayıt kendiliğinden başlar.
    static let autoRecord: String = "calendar.autoRecord"
    /// Kayıtta görüşme uygulaması mikrofonu bırakınca (görüşme bitti) geri sayımdan sonra kayıt kendiliğinden biter.
    static let stopWhenCallEnds: String = "recording.stopWhenCallEnds"
    /// Yüz yüze toplantı: sistem sesi yerine mikrofon "Diğerleri" olarak konuşmacılara ayrılır.
    static let inPersonMode: String = "inPersonMode"
    /// Her not hazır olunca Apple Notlar'a gönder (varsayılan kapalı; `userContentDefaults` alanında).
    static let appleNotesAutoSend: String = "destinations.appleNotes"
    /// Apple Notlar'a kendiliğinden gönderimin açıldığı an (`Date`; kapalıyken yok): yalnızca bundan sonra biten notlar
    /// gider (`userContentDefaults` alanında).
    static let appleNotesAutoSendSince: String = "destinations.appleNotesSince"
    /// Notların Markdown olarak yazılacağı klasör (Obsidian, iCloud Drive…); seçilmediyse yok (`userContentDefaults`
    /// alanında).
    static let markdownFolder: String = "destinations.markdownFolder"
    /// Her not hazır olunca klasöre yaz (varsayılan kapalı; `userContentDefaults` alanında).
    static let markdownAutoExport: String = "destinations.markdownAuto"
    /// Kullanıcının tanıma sözlüğü (satır başına bir ad ya da terim; `userContentDefaults` alanında: abonelikte hesabın).
    static let customVocabulary: String = customVocabularyDefaultsKey
    /// Kullanıcının oluşturduğu klasörler (boş olanlar da listede kalsın).
    static let folders: String = savedFoldersKey
    /// Toplantı sayfasında "Ayrıntılar" (konuşma payları, sözlük) açık mı; varsayılan kapalı, tercih bütün toplantılar için.
    static let meetingDetailsExpanded: String = "meeting.detailsExpanded"
    /// Toplantı sayfasında notun gösterildiği dil (`ShareLanguage` kodu; boşsa notun yazıldığı dil): seçim bütün
    /// toplantılarda ve yeniden açılışta sürer.
    static let meetingNoteDisplayLanguage: String = "meeting.noteDisplayLanguage"
    /// Bir sonraki kaydın dil modu (`languageModeStorageValue`: "auto" ya da dil kodu).
    static let languageMode: String = "language.mode"
    /// Toplantılar sayfasındaki toplantı listesi açık (üst çubuktaki düğmeyle gizlenir).
    static let meetingsListVisible: String = "meetings.listVisible"
    /// Sor sayfasındaki sohbet geçmişi sütunu açık (üst çubuktaki düğmeyle).
    static let askHistoryVisible: String = "ask.historyVisible"
    /// Konuşmacıları sesinden tanıma (ses izleri yalnızca bu Mac'te).
    static let voiceRecognition: String = "voiceRecognition"
    /// Görünüm.
    static let theme: String = AppearanceKey.theme
    static let accent: String = AppearanceKey.accent
    static let fontDesign: String = AppearanceKey.fontDesign
    static let textSize: String = AppearanceKey.textSize
    static let uiScale: String = AppearanceKey.uiScale
    static let lineSpacing: String = AppearanceKey.lineSpacing
    static let bottomSpacing: String = AppearanceKey.bottomSpacing
    static let islandEnabled: String = "appearance.islandEnabled"
    static let surface: String = AppearanceKey.surface
    static let surfaceOpacity: String = AppearanceKey.surfaceOpacity
    /// "Anonim kullanım istatistiklerini paylaş" (yalnızca abonelik sürümünde görünür ve kullanılır; bkz.
    /// `HostedTelemetryCenter`).
    static let shareUsageStatistics: String = shareUsageStatisticsDefaultsKey
}

/// Arayüz dili; macOS'ta uygulama dili yeniden başlatınca uygulanır.
/// Arayüz dili: "Sistem" ya da string kataloglarının çevrildiği diller (`scripts/l10n.py` `TARGET_LANGUAGES` + Türkçe ve
/// İngilizce). Ham değer `AppleLanguages`'e yazılan dil kodudur.
enum InterfaceLanguage: String, CaseIterable {
    case system
    case turkish = "tr"
    case english = "en"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case italian = "it"
    case portugueseBrazil = "pt-BR"
    case dutch = "nl"
    case japanese = "ja"
    case korean = "ko"
    case chineseSimplified = "zh-Hans"
    case finnish = "fi"

    /// Dilin kendi dilindeki adı (seçicide her arayüz dilinde aynı görünür); "Sistem" için nil.
    var nativeName: String? {
        switch self {
        case .system: nil
        case .turkish: "Türkçe"
        case .english: "English"
        case .german: "Deutsch"
        case .french: "Français"
        case .spanish: "Español"
        case .italian: "Italiano"
        case .portugueseBrazil: "Português (Brasil)"
        case .dutch: "Nederlands"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .chineseSimplified: "简体中文"
        case .finnish: "Suomi"
        }
    }
}

/// `AppleLanguages`'in ilk dilinin arayüz dili: önce tam kod ("pt-BR", "zh-Hans"), sonra bölgesiz dil kodu ("de-DE" →
/// "de"); bilinmeyen dil nil. Saf fonksiyondur.
func interfaceLanguage(languageCode: String) -> InterfaceLanguage? {
    if let exact = InterfaceLanguage(rawValue: languageCode), exact != .system {
        return exact
    }
    let base: String = String(languageCode.prefix { $0 != "-" && $0 != "_" })
    return InterfaceLanguage.allCases.first { $0 != .system && $0.rawValue == base }
        ?? InterfaceLanguage.allCases.first { $0 != .system && $0.rawValue.hasPrefix(base + "-") }
}

/// Uygulamanın kendi tercihinde (`AppleLanguages`) kayıtlı arayüz dili; yoksa sistem.
func storedInterfaceLanguage() -> InterfaceLanguage {
    guard let identifier = Bundle.main.bundleIdentifier,
          let languages = UserDefaults.standard.persistentDomain(forName: identifier)?["AppleLanguages"] as? [String],
          let first = languages.first
    else {
        return .system
    }
    return interfaceLanguage(languageCode: first) ?? .system
}

/// Arayüz dilini kaydeder: yalnızca bu uygulamanın `AppleLanguages` tercihi değişir.
func storeInterfaceLanguage(language: InterfaceLanguage) {
    switch language {
    case .system:
        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
    case .turkish, .english, .german, .french, .spanish, .italian, .portugueseBrazil, .dutch, .japanese, .korean, .chineseSimplified, .finnish:
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }
}

/// Varsayılan arayüz dilinin yazıldığını gösteren işaret (bir kez yazılır; kullanıcının sonraki seçimi ezilmez).
private let defaultInterfaceLanguageAppliedKey: String = "interface.defaultLanguageApplied"

/// Uygulamanın varsayılan arayüz dilini bir kez yazar: bu uygulamada hiç dil seçilmemişse (`AppleLanguages` yoksa) ve
/// sistemin ilk dili `systemLanguage` ise `language` kaydedilir (Gistsmith: Türkçe macOS'ta İngilizce açılır; diğer
/// sistem dilleri kendi çevirisiyle açılır). Kullanıcı sonra "Sistem"i ya da başka bir dili seçerse bir daha
/// dokunulmaz. Metinler yüklenmeden (`AppEntry.main` başında) çağrılmalı: dil, paket metinleri ilk kez okunurken
/// belirlenir.
func applyDefaultInterfaceLanguageOnce(bundleIdentifier: String, systemLanguage: InterfaceLanguage, language: InterfaceLanguage) {
    guard !UserDefaults.standard.bool(forKey: defaultInterfaceLanguageAppliedKey) else {
        return
    }
    UserDefaults.standard.set(true, forKey: defaultInterfaceLanguageAppliedKey)
    guard UserDefaults.standard.persistentDomain(forName: bundleIdentifier)?["AppleLanguages"] == nil,
          Locale.preferredLanguages.first.flatMap({ interfaceLanguage(languageCode: $0) }) == systemLanguage
    else {
        return
    }
    storeInterfaceLanguage(language: language)
}

/// Açılışta geçerli olan arayüz dili (değiştirilince yeniden başlatma önerilir; Ayarlar yeniden kurulsa da kalır).
let launchInterfaceLanguage: InterfaceLanguage = storedInterfaceLanguage()

/// Kullanıcının oluşturduğu içeriğin (klasörler, Sor tarifleri) ve notu dışarı yazma ayarlarının (Markdown klasörü,
/// klasöre ve Apple Notlar'a kendiliğinden gönderim) saklandığı ayar alanı: geliştirici sürümünde standart ayarlar;
/// abonelikte yüklü hesabın kendi alanı (bkz. `hostedActiveAccountDefaults`), hesap yüklenmediyse hata.
func userContentDefaults() throws -> UserDefaults {
    #if HOSTED_EDITION
    try hostedActiveAccountDefaults()
    #else
    UserDefaults.standard
    #endif
}

/// Kullanıcının bağlantılarının (not hedefleri, görev araçları) Anahtar Zinciri servisi: geliştirici sürümünde
/// uygulamanın servisi; abonelikte yüklü hesabın kendi servisi (bkz. `hostedActiveAccountKeychainService`), hesap
/// yüklenmediyse hata.
func userContentKeychainService() throws -> String {
    #if HOSTED_EDITION
    try hostedActiveAccountKeychainService()
    #else
    appKeychainService
    #endif
}

/// Uygulamayı yeniden başlatır (arayüz dili değişince). Yeni kopya ancak bu kopya gerçekten kapandıktan sonra açılır:
/// kapanış iptal edilirse (kayıt ya da işleme sürüyor, çıkış koruması) 30 sn bekleyip vazgeçer. İki kopya aynı anda
/// çalışırsa yeni kopya kısayolları kaydedemez ve süren kaydı "yarıda kaldı" diye işaretlerdi. Başlatıcı
/// çalıştırılamazsa hata fırlar (uygulama kapanmaz).
@MainActor
func relaunchApplication() throws {
    let launcher: Process = Process()
    launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
    launcher.arguments = [
        "-c",
        "i=0; while /bin/kill -0 \"$1\" 2>/dev/null; do i=$((i+1)); [ $i -gt 150 ] && exit 0; sleep 0.2; done; /usr/bin/open -n \"$0\"",
        Bundle.main.bundleURL.path, String(ProcessInfo.processInfo.processIdentifier),
    ]
    try launcher.run()
    NSApplication.shared.terminate(nil)
}

/// Panelin açık/koyu görünümü.
/// Temanın macOS görünümü; sistem temasında nil (sistemi izler). Saf fonksiyondur.
func nsAppearance(theme: AppTheme) -> NSAppearance? {
    switch theme.isDark {
    case .none: nil
    case .some(false): NSAppearance(named: .aqua)
    case .some(true): NSAppearance(named: .darkAqua)
    }
}

/// Temayı uygulamanın tüm pencerelerine birden uygular (pencere bazında atama cam zemini ve adayı eski temada
/// bırakıyordu) ve renk takımlarını seçer.
@MainActor
func applyTheme(theme: AppTheme) {
    NSApplication.shared.appearance = nsAppearance(theme: theme)
    ThemeStore.shared.set(light: theme.colorSets.light, dark: theme.colorSets.dark)
}

/// Ayar aralıkları.
enum SettingsRange {
    static let missedWindowMinutes: ClosedRange<Int> = missedWindowMinutesRange
}

/// Görünüm ayarlarını varsayılana döndürür.
func resetAppearanceSettings(defaults: UserDefaults) {
    for key in [SettingsKey.theme, SettingsKey.accent, SettingsKey.fontDesign, SettingsKey.uiScale, SettingsKey.textSize,
                SettingsKey.lineSpacing, SettingsKey.bottomSpacing, SettingsKey.islandEnabled, SettingsKey.surface,
                SettingsKey.surfaceOpacity] {
        defaults.removeObject(forKey: key)
    }
}

/// Not, özet ve soru için sunulan effort seviyeleri. `xhigh`/`max` sunulmaz: gerçek 37 dakikalık toplantıda Haiku 5.5
/// `max` effort'ta parça başına ~4,5 dk düşünüp 64.000 token sınırında kesildi (not hiç oluşmadı); `high` 27 sn'de
/// eksiksiz not yazdı.
let smartEfforts: [LLMEffort] = [.low, .medium, .high]

/// Eski sürümde seçilmiş `xhigh`/`max` not effort'unu bir kez `high`'a taşır (artık sunulmuyor; notu kesiyordu).
/// Açılışta çağrılır; taşındıysa true.
func migrateSmartEffort(defaults: UserDefaults) -> Bool {
    guard let stored = defaults.string(forKey: SettingsKey.claudeSmartEffort),
          let effort = LLMEffort(rawValue: stored), !smartEfforts.contains(effort) else {
        return false
    }
    defaults.set(LLMEffort.high.rawValue, forKey: SettingsKey.claudeSmartEffort)
    return true
}

/// Varsayılanları bir kez kaydeder (uygulama açılışında).
func registerDefaultSettings() {
    UserDefaults.standard.register(defaults: [
        SettingsKey.liveEngine: LiveEngine.deepgram.rawValue,
        // Canlı çeviri isteğe bağlı: asıl amaç toplantı sonu not; açılınca iki dil gösterilir.
        SettingsKey.displayMode: DisplayMode.originalOnly.rawValue,
        SettingsKey.hideFromScreenCapture: true,
        SettingsKey.missedWindowMinutes: 3,
        SettingsKey.audioRetentionDays: 30,
        SettingsKey.llmProvider: LLMProviderKind.anthropic.rawValue,
        SettingsKey.llmBaseURL: "http://localhost:11434/v1",
        SettingsKey.llmFastModel: "",
        SettingsKey.llmSmartModel: "",
        SettingsKey.llmFastEffort: "",
        SettingsKey.llmSmartEffort: "",
        SettingsKey.claudeFastModel: ClaudeModel.haiku.rawValue,
        // Not ve özet için de Haiku yeterli (1–4 saatlik senaryo testlerinde büyük modellerle aynı eksiksizlik).
        SettingsKey.claudeSmartModel: ClaudeModel.haiku.rawValue,
        SettingsKey.claudeFastEffort: LLMEffort.low.rawValue,
        SettingsKey.claudeSmartEffort: LLMEffort.high.rawValue,
        SettingsKey.onboardingCompleted: false,
        SettingsKey.micMuted: false,
        // Ses izi biyometrik veridir: kullanıcı açıkça açmalı.
        SettingsKey.voiceRecognition: false,
        SettingsKey.consentReminder: true,
        SettingsKey.calendarEnabled: false,
        SettingsKey.meetingsListVisible: true,
        SettingsKey.askHistoryVisible: false,
        SettingsKey.inPersonMode: false,
        SettingsKey.meetingReminders: true,
        SettingsKey.micSuggestions: true,
        SettingsKey.notifyNoteReady: true,
        SettingsKey.notifyTaskDue: true,
        SettingsKey.notifyWeeklySummary: true,
        SettingsKey.notifyInactive: true,
        // Sesle yazma baştan açık: kısayol (⌃⌥D) yalnızca basılınca mikrofonu açar.
        SettingsKey.voiceTypingEnabled: true,
        SettingsKey.voiceTypingSoundEffects: false,
        SettingsKey.voiceTypingIntroShown: false,
        SettingsKey.webhookAutoSend: false,
        SettingsKey.primaryMeetingLanguage: MeetingLanguage.finnish.rawValue,
        // Arayüz dili: Türkçe arayüzde mevcut kullanıcıların notu eskisi gibi Türkçe sürer.
        SettingsKey.noteLanguage: defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue,
        SettingsKey.autoRecord: false,
        SettingsKey.stopWhenCallEnds: true,
        SettingsKey.noteTemplate: NoteTemplateKind.general.rawValue,
        SettingsKey.customTemplate: "",
        SettingsKey.customTemplateName: "",
        SettingsKey.templateFromTitle: true,
        SettingsKey.theme: AppTheme.light.rawValue,
        SettingsKey.accent: PanelAppearance.standard.accent.rawValue,
        SettingsKey.fontDesign: PanelAppearance.standard.fontChoice.storageValue,
        SettingsKey.uiScale: PanelAppearance.standard.uiScale,
        SettingsKey.textSize: PanelAppearance.standard.textSize,
        SettingsKey.lineSpacing: PanelAppearance.standard.lineSpacing,
        SettingsKey.bottomSpacing: PanelAppearance.standard.bottomSpacing,
        SettingsKey.islandEnabled: true,
        SettingsKey.surface: PanelAppearance.standard.surface.rawValue,
        SettingsKey.surfaceOpacity: PanelAppearance.standard.surfaceOpacity,
        // Abonelik sürümünde varsayılan açık (Ayarlar › Genel'den kapatılır); geliştirici sürümü hiçbir şey göndermez.
        SettingsKey.shareUsageStatistics: true,
    ])
}

/// Not dili ayarından önceki sürümlerden gelen kullanıcının notları Türkçe kalır (bkz. `legacyNoteLanguage`); bu sürümün
/// ilk açılışında bir kez çalışır. Varsayılanlar değil, yalnız kayıtlı değerler okunur.
func keepLegacyNoteLanguage(defaults: UserDefaults) {
    guard let bundleID = Bundle.main.bundleIdentifier else {
        settingsLogger.error("Paket kimliği yok, not dili taşınmadı")
        return
    }
    let stored: [String: Any] = defaults.persistentDomain(forName: bundleID) ?? [:]
    let language: ShareLanguage? = legacyNoteLanguage(
        storedNoteLanguage: stored[SettingsKey.noteLanguage] as? String,
        onboardingCompleted: stored[SettingsKey.onboardingCompleted] as? Bool ?? false,
        alreadyMigrated: stored[SettingsKey.noteLanguageMigrated] as? Bool ?? false
    )
    if let language {
        defaults.set(language.rawValue, forKey: SettingsKey.noteLanguage)
        settingsLogger.info("Önceki sürümün kullanıcısı: not dili korundu, dil: \(language.rawValue, privacy: .public)")
    }
    defaults.set(true, forKey: SettingsKey.noteLanguageMigrated)
    // Not dili hiç seçilmediyse ilk açılıştaki varsayılanı (arayüz dili) kaydedilir: arayüz dili sonradan değişince not
    // dili sessizce değişmesin.
    if stored[SettingsKey.noteLanguage] == nil, language == nil {
        defaults.set(defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue, forKey: SettingsKey.noteLanguage)
    }
}

/// Kayıtlı ayarın değeri, aralığa sıkıştırılmış.
func clampedSetting(key: String, range: ClosedRange<Int>) -> Int {
    min(max(UserDefaults.standard.integer(forKey: key), range.lowerBound), range.upperBound)
}

/// Not ve çeviri dili (Ayarlar › Genel); kayıtlı değer tanınmıyorsa (loglanır) arayüz dilinin varsayılanı.
func selectedNoteLanguage() -> ShareLanguage {
    storedNoteLanguage(value: UserDefaults.standard.string(forKey: SettingsKey.noteLanguage) ?? "")
}

/// Ayarın ham değerinden not dili (görünümlerdeki `@AppStorage(SettingsKey.noteLanguage)` için: dil değişince etiketler
/// de güncellenir); tanınmıyorsa (loglanır) arayüz dilinin varsayılanı.
func storedNoteLanguage(value stored: String) -> ShareLanguage {
    guard let language = ShareLanguage(rawValue: stored) else {
        settingsLogger.error("Not dili tanınmadı, varsayılan kullanılıyor, değer: \(stored, privacy: .public)")
        return defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations)
    }
    return language
}

/// Seçili LLM sağlayıcı türü.
func selectedLLMProviderKind() -> LLMProviderKind {
    LLMProviderKind(rawValue: UserDefaults.standard.string(forKey: SettingsKey.llmProvider) ?? "") ?? .anthropic
}

/// Kullanıcı bu eylem için bir kısayol seçip kaydetti mi (yoksa varsayılan kullanılır).
func hasStoredKeyBinding(key: String) -> Bool {
    UserDefaults.standard.data(forKey: key) != nil
}

/// Kayıtlı kısayol; yoksa varsayılan.
func storedKeyBinding(key: String, fallback: KeyBinding) -> KeyBinding {
    guard let data = UserDefaults.standard.data(forKey: key) else {
        return fallback
    }
    do {
        return try JSONDecoder().decode(KeyBinding.self, from: data)
    } catch {
        // Bozuk kayıt: varsayılan kullanılır, yeni seçim üzerine yazar.
        settingsLogger.error("Kısayol ayarı okunamadı, anahtar: \(key, privacy: .public), hata: \(String(describing: error), privacy: .private)")
        return fallback
    }
}

/// Kısayolu kaydeder.
func storeKeyBinding(key: String, binding: KeyBinding) throws {
    UserDefaults.standard.set(try JSONEncoder().encode(binding), forKey: key)
}

/// Seçili sağlayıcının yapılandırması: anahtar Keychain'den arka planda okunur. Anthropic anahtarı yoksa
/// `KeychainError.notFound`; OpenAI uyumlu ayar eksikse `LLMError.notConfigured`.
func resolveLLMProvider() async throws -> LLMProvider {
    #if HOSTED_EDITION
    // Abonelik sürümü: sağlayıcı seçimi yok, her istek bizim sunucumuza gider (toplantıdan bağımsız); hakkı yoksa durur.
    try await requireHostedAIAllowance()
    return try hostedAccountLLMProvider()
    #else
    switch selectedLLMProviderKind() {
    case .anthropic:
        return .anthropic(AnthropicConfig(
            apiKey: try await readSecretInBackground(service: appKeychainService, account: .anthropic),
            fastModel: try storedClaudeModel(key: SettingsKey.claudeFastModel),
            smartModel: try storedClaudeModel(key: SettingsKey.claudeSmartModel),
            fastEffort: try requiredEffort(key: SettingsKey.claudeFastEffort),
            smartEffort: try requiredEffort(key: SettingsKey.claudeSmartEffort)
        ))
    case .openAICompatible:
        return .openAICompatible(try storedOpenAIConfig(apiKey: try await optionalSecretInBackground(service: appKeychainService, account: .openai)))
    case .onDevice:
        return .onDevice(try onDeviceConfig())
    }
    #endif
}

/// Kaydı biten toplantının notu için sağlayıcı: abonelikte o kaydın sunucu oturumunun bütçesi (bu arada yeni bir kayıt
/// başlasa da onun bütçesine yazılmaz; oturumu olmayan kayıtta hesap çağrısı), kendi anahtarlı sürümde
/// `resolveLLMProvider`.
func resolveRecordedMeetingLLMProvider(recordID: String) async throws -> LLMProvider {
    #if HOSTED_EDITION
    let provider: LLMProvider = try hostedRecordedMeetingLLMProvider(recordID: recordID)
    // Kaydın sunucu oturumu yoksa çağrı hesaptan gider: hakkı yoksa durur (oturumlu kayıt kendi bütçesini kullanır).
    if case .hosted(let config) = provider, config.scope == .account {
        try await requireHostedAIAllowance()
    }
    return provider
    #else
    return try await resolveLLMProvider()
    #endif
}

/// Kayıt sırasındaki istekler (canlı çeviri, "Ne kaçırdım?", toplantı sorusu) için sağlayıcı. Kendi anahtarlı sürümde `resolveLLMProvider` ile aynıdır; abonelik sürümünde son açılan toplantının
/// bütçesinden düşer.
func resolveLiveLLMProvider() async throws -> LLMProvider {
    #if HOSTED_EDITION
    return try await hostedMeetingLLMProvider()
    #else
    return try await resolveLLMProvider()
    #endif
}

/// İlk açılışta (kurulum bitmemiş, motor ve LLM hiç seçilmemiş) hiçbir anahtar yoksa ve Apple Intelligence
/// kullanılabiliyorsa cihaz içi mod seçilir: uygulama kurulur kurulmaz anahtarsız çalışır. Ana toplantı dili kayıtlı
/// değilse cihazın dili (modelde varsa) ya da İngilizce olur (bkz. `onDeviceDefaultMeetingLanguage`). Anahtarı olan ya
/// da kurulumu bitirmiş kullanıcıya dokunulmaz. Seçim yapıldıysa true.
func chooseOnDeviceOnFirstRun(defaults: UserDefaults) async -> Bool {
    // Kayıtlı (varsayılan olmayan) değerler yalnız uygulamanın kendi alanında görünür.
    guard let bundleID = Bundle.main.bundleIdentifier else {
        settingsLogger.error("İlk açılışta paket kimliği yok, cihaz içi mod seçilmedi")
        return false
    }
    let stored: [String: Any] = defaults.persistentDomain(forName: bundleID) ?? [:]
    guard !defaults.bool(forKey: SettingsKey.onboardingCompleted), stored[SettingsKey.liveEngine] == nil, stored[SettingsKey.llmProvider] == nil else {
        return false
    }
    for account in [SecretAccount.deepgram, .elevenlabs, .anthropic, .openai] {
        do {
            if try await runBlocking(qos: .userInitiated, operation: { () throws -> Bool in try secretExists(service: appKeychainService, account: account) }) {
                return false
            }
        } catch {
            // Anahtar Zinciri okunamadıysa anahtar var sayılır: mevcut kullanıcının ayarı değişmesin.
            settingsLogger.error("İlk açılışta anahtar denetlenemedi, cihaz içi mod seçilmedi, hesap: \(account.rawValue, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            return false
        }
    }
    let config: OnDeviceConfig
    do {
        config = try onDeviceConfig()
    } catch {
        settingsLogger.info("İlk açılışta cihaz içi model kullanılamıyor, hata: \(String(describing: error), privacy: .private)")
        return false
    }
    // Kayıtlı ana toplantı dili korunur (kurulumda bu arada seçilmiş olabilir: alan şimdi yeniden okunur); yoksa
    // (varsayılan Fince modelde yok) cihazın dili ya da İngilizce.
    if defaults.persistentDomain(forName: bundleID)?[SettingsKey.primaryMeetingLanguage] == nil {
        let language: MeetingLanguage = onDeviceDefaultMeetingLanguage(preferredLanguages: Locale.preferredLanguages, languageCodes: config.languageCodes)
        defaults.set(language.rawValue, forKey: SettingsKey.primaryMeetingLanguage)
        settingsLogger.info("İlk açılışta ana toplantı dili seçildi, dil: \(language.rawValue, privacy: .public)")
    }
    defaults.set(LiveEngine.appleSpeech.rawValue, forKey: SettingsKey.liveEngine)
    defaults.set(LLMProviderKind.onDevice.rawValue, forKey: SettingsKey.llmProvider)
    return true
}

#if HOSTED_EDITION
/// Abonelik sürümünde ana toplantı dili kayıtlı değilse cihazın dili (`deviceDefaultMeetingLanguage`) yazılır: kayıtlı
/// varsayılan Fince'dir ve Deepgram canlı akışı dil algılamadığı için başka dilde konuşan aboneye Fince metin yazılırdı.
/// Kullanıcının seçtiği dile dokunulmaz.
func chooseHostedMeetingLanguageOnFirstRun(defaults: UserDefaults) {
    guard let bundleID = Bundle.main.bundleIdentifier else {
        settingsLogger.error("Paket kimliği yok, ana toplantı dili seçilmedi")
        return
    }
    guard defaults.persistentDomain(forName: bundleID)?[SettingsKey.primaryMeetingLanguage] == nil else {
        return
    }
    let language: MeetingLanguage = deviceDefaultMeetingLanguage(preferredLanguages: Locale.preferredLanguages)
    defaults.set(language.rawValue, forKey: SettingsKey.primaryMeetingLanguage)
    settingsLogger.info("Ana toplantı dili cihaz dilinden seçildi, dil: \(language.rawValue, privacy: .public)")
}
#endif

/// Kayıtlı OpenAI uyumlu ayar; adres ya da model eksikse `LLMError.notConfigured`.
func storedOpenAIConfig(apiKey: String?) throws -> OpenAICompatibleConfig {
    let defaults: UserDefaults = UserDefaults.standard
    return try openAICompatibleConfig(
        baseURLText: defaults.string(forKey: SettingsKey.llmBaseURL) ?? "",
        apiKey: apiKey,
        fastModel: defaults.string(forKey: SettingsKey.llmFastModel) ?? "",
        smartModel: defaults.string(forKey: SettingsKey.llmSmartModel) ?? "",
        fastEffort: storedEffort(key: SettingsKey.llmFastEffort),
        smartEffort: storedEffort(key: SettingsKey.llmSmartEffort)
    )
}

/// Kayıtlı Claude modeli (varsayılanı kayıtlı); tanınmayan değer `notConfigured` (Ayarlar'dan yeniden seçilir).
func storedClaudeModel(key: String) throws -> ClaudeModel {
    let value: String = UserDefaults.standard.string(forKey: key) ?? ""
    guard let model = ClaudeModel(rawValue: value) else {
        throw LLMError.notConfigured(detail: String(localized: "Claude modeli (\(value))"))
    }
    return model
}

/// Claude effort'u (varsayılanı kayıtlı); tanınmayan değer `notConfigured`.
func requiredEffort(key: String) throws -> LLMEffort {
    let value: String = UserDefaults.standard.string(forKey: key) ?? ""
    guard let effort = LLMEffort(rawValue: value) else {
        throw LLMError.notConfigured(detail: String(localized: "effort (\(value))"))
    }
    return effort
}

/// Kayıtlı effort; boş değer "gönderme" demektir (nil).
func storedEffort(key: String) -> LLMEffort? {
    LLMEffort(rawValue: UserDefaults.standard.string(forKey: key) ?? "")
}

/// Kayıtlı canlı çeviri görünümü; tanınmayan değerde iki dil.
func storedDisplayMode() -> DisplayMode {
    DisplayMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.displayMode) ?? "") ?? .bilingual
}

/// Ayarlardaki varsayılan not şablonu (yeni toplantılar bununla yazılır).
func defaultNoteTemplate() -> NoteTemplate {
    NoteTemplate(
        kind: NoteTemplateKind(rawValue: UserDefaults.standard.string(forKey: SettingsKey.noteTemplate) ?? "") ?? .general,
        customInstructions: UserDefaults.standard.string(forKey: SettingsKey.customTemplate) ?? ""
    )
}

/// Adı `title` olan yeni toplantının not şablonu: "Şablonu toplantı adına göre seç" açıksa ada göre (bkz.
/// `templateForTitle`), kapalıysa Ayarlar'daki varsayılan.
func newMeetingNoteTemplate(title: String) -> NoteTemplate {
    let base: NoteTemplate = defaultNoteTemplate()
    guard UserDefaults.standard.bool(forKey: SettingsKey.templateFromTitle) else {
        return base
    }
    return templateForTitle(title: title, defaultTemplate: base)
}

/// Ayarlardaki ana toplantı dili; kayıtlı değer tanınmıyorsa Fince (varsayılan) ve hata loglanır.
func primaryMeetingLanguage() -> MeetingLanguage {
    let stored: String = UserDefaults.standard.string(forKey: SettingsKey.primaryMeetingLanguage) ?? MeetingLanguage.finnish.rawValue
    guard let language = MeetingLanguage(rawValue: stored) else {
        settingsLogger.error("Ana toplantı dili tanınmadı, değer: \(stored, privacy: .public)")
        return .finnish
    }
    return language
}

/// Tanıtım modunda (`--tanitim`, yalnız Debug) mı açıldı. Release'de her zaman false: `isDemoMode` yalnız Debug'da
/// tanımlıdır (App/DemoData.swift), Release'de derlenen kod onu doğrudan kullanamaz.
func appIsDemoLaunch() -> Bool {
    #if DEBUG
    isDemoMode
    #else
    false
    #endif
}

/// Bu uygulamanın Anahtar Zinciri servis adı: geliştirici sürümünde `AINotepad` (iPhone ile paylaşılan), abonelik
/// sürümünde Info.plist'teki kendi servisi (Release `AINotepadHosted`, Debug `AINotepadHosted.debug`; kanal ve görev
/// aracı bağlantıları geliştirici sürümünün ya da yayındaki sürümün öğelerine yazılmasın). Abonelik sürümünde değer
/// `AppEntry.main`'de açılışta doğrulanır; yoksa uygulama açılmaz.
let appKeychainService: String = {
    #if DEBUG
    // Tanıtım modu sahibin Anahtar Zinciri öğelerini okumaz (bkz. App/DemoData.swift).
    if isDemoMode {
        return demoKeychainService
    }
    #endif
    #if HOSTED_EDITION
    do {
        return try hostedKeychainService(bundle: .main)
    } catch {
        fatalError("Anahtar Zinciri servis adı tanımlı değil (Info.plist \(hostedKeychainServiceInfoKey)): \(error)")
    }
    #else
    return keychainService
    #endif
}()
