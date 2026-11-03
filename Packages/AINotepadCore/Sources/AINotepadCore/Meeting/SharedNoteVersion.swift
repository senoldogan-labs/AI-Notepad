import Foundation

// Notun başka dildeki sürümü (Mac'te özetin dil menüsü, iPhone'da toplantı sayfasındaki dil seçimi): sürüm
// `sharedNoteRequest` ile çevrilir ve toplantıda saklanır (`MeetingRecord.sharedNotes`, not değişince silinir). Sayfa,
// paylaşım ve dışa aktarma aynı sürümü buradan seçer.

/// Dil menüsündeki seçenekler: sık kullanılan Fince ve İngilizce önde, diğer diller alt menüde; asıl notun dili
/// (`original`) paylaşım dili olarak yinelenmez.
public struct ShareLanguageChoices: Sendable, Equatable {
    public let featured: [ShareLanguage]
    public let others: [ShareLanguage]
}

/// Notu `original` dilinde yazılmış toplantının dil menüsü seçenekleri. Saf fonksiyondur.
public func shareLanguageChoices(original: ShareLanguage) -> ShareLanguageChoices {
    let featured: [ShareLanguage] = [ShareLanguage.finnish, .english].filter { $0 != original }
    return ShareLanguageChoices(
        featured: featured,
        others: ShareLanguage.allCases.filter { ![.finnish, .english, original].contains($0) }
    )
}

/// Notun `language` dilindeki gösterilecek sürümü: saklı ve asıl notun tüm bölümlerini taşıyorsa (`isSharedNoteComplete`,
/// görev sayısı aynı) çeviri. Görevleri asıl görevlerin kimliğini taşır (`taskKey`): tamamlandı, Anımsatıcılar ve
/// gönderildi işaretleri çeviride de aynı göreve bağlıdır. Notu, saklı çevirisi olmayan ya da çevirisi eksik (eski)
/// toplantıda nil: sürüm yeniden hazırlanmalı. Saf fonksiyondur.
public func sharedNoteVersion(record: MeetingRecord, language: ShareLanguage) -> MeetingNote? {
    guard let original = record.note, let shared = record.sharedNotes?[language.rawValue],
          isSharedNoteComplete(shared: shared, original: original), shared.tasks.count == original.tasks.count else {
        return nil
    }
    let tasks: [NoteTask] = zip(shared.tasks, original.tasks).map { (pair: (NoteTask, NoteTask)) -> NoteTask in
        pair.0.with(storedKey: taskKey(task: pair.1))
    }
    let keyed: MeetingNote = MeetingNote(title: shared.title, summary: shared.summary, decisions: shared.decisions, tasks: tasks, glossary: shared.glossary)
    let withOutline: MeetingNote = shared.outline.map { keyed.with(outline: $0) } ?? keyed
    return shared.language.map { withOutline.with(language: $0) } ?? withOutline
}

/// Toplantının seçili dilde gösterilen, paylaşılan ve dışa aktarılan hali: dil nil ise kayıt olduğu gibi (asıl not);
/// değilse not o dildeki sürümle değişir (`sharedNoteVersion`; başlık da çeviriden). Sürüm henüz hazır değilse nil:
/// asıl not yerine sessizce başka dil çıkmasın. Saf fonksiyondur.
public func recordInLanguage(record: MeetingRecord, language: ShareLanguage?) -> MeetingRecord? {
    guard let language else {
        return record
    }
    return sharedNoteVersion(record: record, language: language).map { record.with(note: $0) }
}
