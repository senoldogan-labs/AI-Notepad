import Foundation

// "Öbür uygulamayı al" sayfaları: iPhone'daki Gistsmith Ayarlar'da Mac uygulamasını, Mac'teki Gistsmith iPhone
// uygulamasını tanıtır (paylaşılan bağlantı, ertesi sabah hatırlatma, QR kod). Bağlantılar sitenin
// (`web/src/config.ts`) adresleriyle aynıdır.

/// Mac uygulamasının indirme sayfası: iPhone'daki "Bağlantıyı paylaş" bunu paylaşır (kişi Mac'inde açar). Geliştirme
/// derlemesinde de yayındaki sitedir: paylaşılan bağlantı yerel sunucuyu göstermemeli.
public let gistsmithMacDownloadURL: URL = URL(string: "https://gistsmith.com/download")!

/// iPhone uygulamasının App Store sayfası (App Store kimliği 6829577553): Mac'teki QR kod ve "Bağlantıyı kopyala".
public let gistsmithAppStoreURL: URL = URL(string: "https://apps.apple.com/app/gistsmith/id6829577553")!

/// Tanıtım satırının "göründü" sayımı bu açılışta yapıldı mı: satır kaydırmayla ya da Ayarlar'a her dönüşte yeniden
/// görünür, sayım uygulama açılışı başına birdir. Ana aktörde okunur ve yazılır.
@MainActor public var otherAppPromoShownCounted: Bool = false

/// "Sonra hatırlat" bildiriminin saati (yerel saatle ertesi sabah).
public let otherAppReminderHour: Int = 9

/// Hatırlatmanın anı hesaplanamadı (takvimde o gün ya da saat yok).
public enum OtherAppReminderError: Error, Equatable {
    case dateUnavailable(now: Date, hour: Int, calendarIdentifier: String)
}

/// "Sonra hatırlat"ın anı: ertesi gün `hour`:00, verilen takvim ve saat diliminde. Saf fonksiyondur.
public func otherAppReminderDate(now: Date, calendar: Calendar, hour: Int) throws -> Date {
    let today: Date = calendar.startOfDay(for: now)
    guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
          let reminder = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: tomorrow) else {
        throw OtherAppReminderError.dateUnavailable(now: now, hour: hour, calendarIdentifier: "\(calendar.identifier)")
    }
    return reminder
}
