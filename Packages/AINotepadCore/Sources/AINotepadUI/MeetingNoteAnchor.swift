/// Toplantı sayfasında kapaktaki çiplerin kaydırdığı not bölümleri (Mac ve iPhone `ScrollViewReader` kimlikleri).
public enum MeetingNoteAnchor: Hashable, Sendable {
    /// "Senin görevlerin".
    case myTasks
    /// "Kararlar".
    case decisions
    /// Notun sekmeli bölümleri (görevler, konu akışı, kararlar, işaretli anlar): çipler sekmeyi seçip buraya kaydırır.
    case sections
}
