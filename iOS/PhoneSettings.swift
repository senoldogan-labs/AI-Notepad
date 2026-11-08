import AINotepadCore
import AINotepadUI
import Foundation
import os

/// iPhone ayar anahtarları; adlar Mac'tekilerle aynıdır. Ayarlar cihazda kalır.
enum PhoneSettingsKey {
    /// Kitaplık sıkı listede mi (kartlar yerine satırlar; ekrana daha çok toplantı sığar).
    static let libraryCompact: String = "library.compact"
    static let primaryMeetingLanguage: String = "language.primary"
    /// Not ve çeviri dili (`ShareLanguage`): not, canlı çeviri ve Sor cevapları bu dilde yazılır.
    static let noteLanguage: String = "language.note"
    /// Toplantı sayfasında notun gösterildiği dil (`ShareLanguage` kodu; boşsa notun yazıldığı dil): seçim bütün
    /// toplantılarda ve yeniden açılışta sürer.
    static let meetingNoteDisplayLanguage: String = "meeting.noteDisplayLanguage"
    /// Bir sonraki kaydın dil modu (`languageModeStorageValue`: "auto" ya da dil kodu).
    static let languageMode: String = "language.mode"
    /// Not dili ayarından önceki sürümlerin kullanıcısına Türkçe bir kez yazıldı (`legacyNoteLanguage`).
    static let noteLanguageMigrated: String = "migration.noteLanguage"
    /// Kullanıcı adı (notta "Sen" ve sana düşen görevler); hesabın ayar alanında (bkz. `PhoneStore.userName`).
    static let userName: String = userNameDefaultsKey
    /// Profilin unvanı, şirketi ve şirket açıklaması; ad gibi hesabın ayar alanında (bkz. `PhoneStore.userProfile`).
    static let jobTitle: String = userJobTitleDefaultsKey
    static let companyName: String = userCompanyNameDefaultsKey
    static let companyDescription: String = userCompanyDescriptionDefaultsKey
    /// Kayıt başında "katılımcılara haber ver" kartı.
    static let consentReminder: String = "consentReminder"
    /// Ses dosyalarının saklama süresi (gün).
    static let audioRetentionDays: String = "audioRetentionDays"
    /// İlk açılış karşılaması bitti ya da atlandı.
    static let onboardingCompleted: String = "onboardingCompleted"
    /// Tema takımı (Mac'teki ayarla aynı ad; bkz. `AppTheme`).
    static let theme: String = AppearanceKey.theme
    /// Vurgu rengi (`PanelAccent`; Mac'teki ayarla aynı ad): düğmeler, ölçerler, seçili sekme.
    static let accent: String = AppearanceKey.accent
    /// Yazı tipi (`AppFontChoice`), arayüz yazı ölçeği, okuma metni boyutu ve satır aralığı (Mac'teki ayarlarla aynı ad).
    static let fontDesign: String = AppearanceKey.fontDesign
    static let uiScale: String = AppearanceKey.uiScale
    static let textSize: String = AppearanceKey.textSize
    static let lineSpacing: String = AppearanceKey.lineSpacing
    /// Canlı metnin son satırının altındaki boşluk (Mac'teki "Alt boşluk" ile aynı ad).
    static let bottomSpacing: String = AppearanceKey.bottomSpacing
    /// Konuşma tanımanın doğru yazması gereken adlar ve terimler (satır ya da virgülle; Mac'teki "Tanıma sözlüğü");
    /// hesabın ayar alanında (bkz. `PhoneStore.vocabulary`).
    static let customVocabulary: String = customVocabularyDefaultsKey
    /// Yeni toplantıların not şablonu (`NoteTemplateKind`) ve "Kendi şablonum"un yönergesi (Mac'teki ayarlarla aynı ad).
    static let noteTemplate: String = "noteTemplate"
    static let customTemplate: String = "customTemplate"
    /// Kendi şablonunun adı (galeriden kopyalanınca "<ad> (kopya)"); boşsa "Kendi şablonum" yazılır.
    static let customTemplateName: String = "customTemplate.name"
    /// "Şablonu toplantı adına göre seç" (Mac'teki ayarla aynı ad).
    static let templateFromTitle: String = "noteTemplate.fromTitle"
    /// Canlı çeviri görünümü (`DisplayMode`, Mac'teki ayarla aynı ad): `originalOnly` kayıt sırasında çevirmez,
    /// `turkishOnly` canlı metinde yalnız çeviriyi gösterir.
    static let displayMode: String = "displayMode"
    /// "Ne kaçırdım?" özetinin kapsadığı son dakika sayısı (Mac'teki ayarla aynı ad).
    static let missedWindowMinutes: String = "missedWindowMinutes"
    /// Takvim (sıradaki toplantılar, kaydı süren etkinliğe bağlama); varsayılan kapalı, açılınca izin istenir.
    static let calendarEnabled: String = "calendar.enabled"
    /// Toplantıdan 1 dk önce "Kaydı başlat" bildirimi (Mac'teki ayarla aynı ad); iPhone'da varsayılan kapalı, açılınca
    /// bildirim izni istenir.
    static let meetingReminders: String = "calendar.reminders"
    /// Bildirimler (Ayarlar › Bildirimler; Mac'le aynı adlar, bkz. `EngagementSettingKey`): not hazır, görev günü,
    /// haftalık özet, kayıtsız hafta. Varsayılan açık.
    static let notifyNoteReady: String = EngagementSettingKey.noteReady
    static let notifyTaskDue: String = EngagementSettingKey.taskDue
    static let notifyWeeklySummary: String = EngagementSettingKey.weeklySummary
    static let notifyInactive: String = EngagementSettingKey.inactive
    /// Önceki sürümlerin cihaz başına yapay zekâ onayı (girişten sonra ilk hesaba taşınır; bkz. `PhoneAIConsent`) ve
    /// tanıtım modunun onayı. Onay artık hesap başınadır (`hostedAIDisclosureAcceptedKey`).
    static let aiDisclosureAccepted: String = "hosted.aiDisclosureAccepted"
    /// Toplantı sayfasında sözlük açık mı (Mac'teki ayarla aynı ad); varsayılan kapalı, tercih tüm toplantılar için.
    static let glossaryExpanded: String = "meeting.glossaryExpanded"
    /// Toplantı sayfasında "Ayrıntılar" (konuşma payları, sözlük) açık mı; varsayılan kapalı, tercih tüm toplantılar için.
    static let meetingDetailsExpanded: String = "phone.meetingDetailsExpanded"
    /// Konuşmacıları sesinden tanı (Mac'teki ayarla aynı ad; bkz. `PhoneVoices`); varsayılan kapalı.
    static let voiceRecognition: String = "voiceRecognition"
}

/// iPhone ayarlarının varsayılanları (Mac'tekilerle aynı).
func registerPhoneDefaults() {
    UserDefaults.standard.register(defaults: [
        PhoneSettingsKey.consentReminder: true,
        PhoneSettingsKey.audioRetentionDays: 30,
        PhoneSettingsKey.primaryMeetingLanguage: MeetingLanguage.finnish.rawValue,
        PhoneSettingsKey.noteTemplate: NoteTemplateKind.general.rawValue,
        PhoneSettingsKey.customTemplate: "",
        PhoneSettingsKey.customTemplateName: "",
        PhoneSettingsKey.templateFromTitle: true,
        // iPhone'da canlı çeviri baştan açık (kayıt kartı onu anlatır); Ayarlar › Toplantı'dan kapatılır.
        PhoneSettingsKey.displayMode: DisplayMode.bilingual.rawValue,
        PhoneSettingsKey.missedWindowMinutes: 3,
        PhoneSettingsKey.meetingReminders: false,
        PhoneSettingsKey.notifyNoteReady: true,
        PhoneSettingsKey.notifyTaskDue: true,
        PhoneSettingsKey.notifyWeeklySummary: true,
        PhoneSettingsKey.notifyInactive: true,
        PhoneSettingsKey.voiceRecognition: false,
        // Mac'teki Gistsmith gibi açık; Ayarlar › Veri ve paylaşım'dan kapatılır (bkz. `HostedTelemetryCenter`).
        shareUsageStatisticsDefaultsKey: true,
        // Arayüz dili: Türkçe arayüzde mevcut kullanıcıların notu eskisi gibi Türkçe sürer.
        PhoneSettingsKey.noteLanguage: defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue,
    ])
}

/// Not dili ayarından önceki sürümlerden gelen kullanıcının notları Türkçe kalır (bkz. `legacyNoteLanguage`); bu sürümün
/// ilk açılışında bir kez çalışır. Varsayılanlar değil, yalnız kayıtlı değerler okunur.
func keepPhoneLegacyNoteLanguage(defaults: UserDefaults) {
    guard let bundleID = Bundle.main.bundleIdentifier else {
        phoneSettingsLogger.error("Paket kimliği yok, not dili taşınmadı")
        return
    }
    let stored: [String: Any] = defaults.persistentDomain(forName: bundleID) ?? [:]
    let language: ShareLanguage? = legacyNoteLanguage(
        storedNoteLanguage: stored[PhoneSettingsKey.noteLanguage] as? String,
        onboardingCompleted: stored[PhoneSettingsKey.onboardingCompleted] as? Bool ?? false,
        alreadyMigrated: stored[PhoneSettingsKey.noteLanguageMigrated] as? Bool ?? false
    )
    if let language {
        defaults.set(language.rawValue, forKey: PhoneSettingsKey.noteLanguage)
        phoneSettingsLogger.info("Önceki sürümün kullanıcısı: not dili korundu, dil: \(language.rawValue, privacy: .public)")
    }
    defaults.set(true, forKey: PhoneSettingsKey.noteLanguageMigrated)
    // Not dili hiç seçilmediyse ilk açılıştaki varsayılanı (arayüz dili) kaydedilir: arayüz dili sonradan değişince not
    // dili sessizce değişmesin.
    if stored[PhoneSettingsKey.noteLanguage] == nil, language == nil {
        defaults.set(defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue, forKey: PhoneSettingsKey.noteLanguage)
    }
}

/// Yeni kurulumda ana toplantı dili cihazın dili olur (Mac'teki Gistsmith'in `chooseHostedMeetingLanguageOnFirstRun`
/// gibi; bkz. `firstRunMeetingLanguage`): karşılamayı atlayan kullanıcıya Fince metin yazılmasın. Kullanıcının seçtiği
/// dile dokunulmaz.
func choosePhoneMeetingLanguageOnFirstRun(defaults: UserDefaults) {
    guard let bundleID = Bundle.main.bundleIdentifier else {
        phoneSettingsLogger.error("Paket kimliği yok, ana toplantı dili seçilmedi")
        return
    }
    let stored: [String: Any] = defaults.persistentDomain(forName: bundleID) ?? [:]
    guard let language = firstRunMeetingLanguage(
        storedLanguage: stored[PhoneSettingsKey.primaryMeetingLanguage] as? String,
        onboardingCompleted: stored[PhoneSettingsKey.onboardingCompleted] as? Bool ?? false,
        preferredLanguages: Locale.preferredLanguages
    ) else {
        return
    }
    defaults.set(language.rawValue, forKey: PhoneSettingsKey.primaryMeetingLanguage)
    phoneSettingsLogger.info("Ana toplantı dili cihaz dilinden seçildi, dil: \(language.rawValue, privacy: .public)")
}

private let phoneSettingsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneSettings")

/// Ana toplantı dili (otomatik modda Deepgram bununla başlar); kayıtlı değer yoksa Fince, tanınmıyorsa Fince ve hata loglanır.
func phonePrimaryMeetingLanguage() -> MeetingLanguage {
    let stored: String = UserDefaults.standard.string(forKey: PhoneSettingsKey.primaryMeetingLanguage) ?? MeetingLanguage.finnish.rawValue
    guard let language = MeetingLanguage(rawValue: stored) else {
        phoneSettingsLogger.error("Ana toplantı dili tanınmadı, değer: \(stored, privacy: .public)")
        return .finnish
    }
    return language
}

/// Not ve çeviri dili (Ayarlar); kayıtlı değer tanınmıyorsa (loglanır) arayüz dilinin varsayılanı.
func phoneNoteLanguage() -> ShareLanguage {
    phoneStoredNoteLanguage(value: UserDefaults.standard.string(forKey: PhoneSettingsKey.noteLanguage) ?? "")
}

/// Ayarın ham değerinden not dili (görünümlerdeki `@AppStorage(PhoneSettingsKey.noteLanguage)` için: dil değişince
/// etiketler de güncellenir); tanınmıyorsa (loglanır) arayüz dilinin varsayılanı.
func phoneStoredNoteLanguage(value stored: String) -> ShareLanguage {
    guard let language = ShareLanguage(rawValue: stored) else {
        phoneSettingsLogger.error("Not dili tanınmadı, varsayılan kullanılıyor, değer: \(stored, privacy: .public)")
        return defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations)
    }
    return language
}

/// Yeni toplantının not şablonu (Ayarlar); kayıtlı tür tanınmıyorsa (loglanır) genel şablon.
func phoneNoteTemplate() -> NoteTemplate {
    let stored: String = UserDefaults.standard.string(forKey: PhoneSettingsKey.noteTemplate) ?? NoteTemplateKind.general.rawValue
    guard let kind = NoteTemplateKind(rawValue: stored) else {
        phoneSettingsLogger.error("Not şablonu tanınmadı, genel şablon kullanılıyor, değer: \(stored, privacy: .public)")
        return .general
    }
    return NoteTemplate(kind: kind, customInstructions: UserDefaults.standard.string(forKey: PhoneSettingsKey.customTemplate) ?? "")
}

/// Adı `title` olan yeni toplantının not şablonu: "Şablonu toplantı adına göre seç" açıksa ada göre (bkz.
/// `templateForTitle`), kapalıysa Ayarlar'daki varsayılan (Mac'teki `newMeetingNoteTemplate`).
func phoneNewMeetingNoteTemplate(title: String) -> NoteTemplate {
    let base: NoteTemplate = phoneNoteTemplate()
    guard UserDefaults.standard.bool(forKey: PhoneSettingsKey.templateFromTitle) else {
        return base
    }
    return templateForTitle(title: title, defaultTemplate: base)
}

/// "Ne kaçırdım?" özetinin kapsadığı son dakika sayısı (Ayarlar), izin verilen aralıkta.
func phoneMissedWindowMinutes() -> Int {
    min(max(UserDefaults.standard.integer(forKey: PhoneSettingsKey.missedWindowMinutes), missedWindowMinutesRange.lowerBound), missedWindowMinutesRange.upperBound)
}

/// Canlı metnin gösterimi (Ayarlar › Toplantı; kayıt kartındaki "Canlı çeviri").
func phoneDisplayMode() -> DisplayMode {
    DisplayMode(rawValue: UserDefaults.standard.string(forKey: PhoneSettingsKey.displayMode) ?? "") ?? .bilingual
}

/// Kayıt sırasında not diline canlı çeviri açık mı (Ayarlar › Toplantı).
func phoneLiveTranslationEnabled() -> Bool {
    phoneDisplayMode().needsLiveTranslation
}

/// Kayda verilen tanıma terimleri (Mac'teki gibi): yüklü hesabın adı ve tanıma sözlüğü öne, sonra Kişiler'e elle
/// eklenenler, sonra son 20 toplantının konuşmacı adları ve sözlük terimleri; en fazla 30.
@MainActor
func phoneRecognitionKeyterms(store: PhoneStore) -> [String] {
    recognitionKeyterms(
        userName: store.userName, vocabulary: store.vocabulary,
        savedPeople: store.peopleBook.saved.map(\.name), records: Array(store.meetings.prefix(20)), limit: 30
    )
}

/// iPhone'un görünüm ayarları (yüzey ve cam opaklığı Mac penceresine özgü; iPhone'da kullanılmaz).
let phoneAppearanceKeys: [String] = [
    PhoneSettingsKey.theme, PhoneSettingsKey.accent, PhoneSettingsKey.fontDesign, PhoneSettingsKey.uiScale, PhoneSettingsKey.textSize,
    PhoneSettingsKey.lineSpacing, PhoneSettingsKey.bottomSpacing,
]

/// Görünüm ayarlarını varsayılana döndürür.
func resetPhoneAppearance(defaults: UserDefaults) {
    for key in phoneAppearanceKeys {
        defaults.removeObject(forKey: key)
    }
}
