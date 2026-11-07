/// Toplantı sayfasında kapaktaki bağlantının kaydırdığı not bölümleri (Mac ve iPhone `ScrollViewReader` kimlikleri).
public enum MeetingNoteAnchor: Hashable, Sendable {
    /// "Senin görevlerin".
    case myTasks
    /// "Kararlar".
    case decisions
    /// "Açık konular".
    case openQuestions
    /// Notun başı (Özet bölümü).
    case sections
}
