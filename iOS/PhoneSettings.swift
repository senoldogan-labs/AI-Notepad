import AINotepadCore
import Foundation
import os

/// iPhone ayar anahtarları; adlar Mac'tekilerle aynıdır. Ayarlar cihazda kalır.
enum PhoneSettingsKey {
    static let primaryMeetingLanguage: String = "language.primary"
    /// Not ve çeviri dili (`ShareLanguage`): not, canlı çeviri ve Sor cevapları bu dilde yazılır.
    static let noteLanguage: String = "language.note"
    /// Not dili ayarından önceki sürümlerin kullanıcısına Türkçe bir kez yazıldı (`legacyNoteLanguage`).
    static let noteLanguageMigrated: String = "migration.noteLanguage"
    static let userName: String = "userName"
    /// Kayıt başında "katılımcılara haber ver" kartı.
    static let consentReminder: String = "consentReminder"
    /// Ses dosyalarının saklama süresi (gün).
    static let audioRetentionDays: String = "audioRetentionDays"
    /// İlk açılış karşılaması bitti ya da atlandı.
    static let onboardingCompleted: String = "onboardingCompleted"
    /// Tema takımı (Mac'teki ayarla aynı ad; bkz. `AppTheme`).
    static let theme: String = "appearance.theme"
    /// Takvim (sıradaki toplantılar, kaydı süren etkinliğe bağlama); varsayılan kapalı, açılınca izin istenir.
    static let calendarEnabled: String = "calendar.enabled"
    /// Ses ve metnin hizmetimize ve üçüncü taraf yapay zekâ sağlayıcılarına gönderileceği açıklaması kabul edildi (ilk
    /// yapay zekâ işleminden önce bir kez; bkz. `PhoneAIDisclosure`).
    static let aiDisclosureAccepted: String = "hosted.aiDisclosureAccepted"
}

/// iPhone ayarlarının varsayılanları (Mac'tekilerle aynı).
func registerPhoneDefaults() {
    UserDefaults.standard.register(defaults: [
        PhoneSettingsKey.consentReminder: true,
        PhoneSettingsKey.audioRetentionDays: 30,
        PhoneSettingsKey.primaryMeetingLanguage: MeetingLanguage.finnish.rawValue,
        // Mac'teki Gistsmith gibi açık; Ayarlar › Gizlilik'ten kapatılır (bkz. `HostedTelemetryCenter`).
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

/// Kullanıcının adı (notta "senin görevlerin" ayrımı için); yoksa boş.
func phoneUserName() -> String {
    UserDefaults.standard.string(forKey: PhoneSettingsKey.userName) ?? ""
}
