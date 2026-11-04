import Foundation

/// Bir çevirinin sıradaki yolu.
public enum TranslationLane: Sendable, Equatable {
    /// Yeni konuşma (ve kullanıcının "Tekrar dene"si): önce ve geliş sırasıyla çevrilir.
    case live
    /// Canlı çeviri toplantının ortasında açılınca biriken eski cümleler: canlı yol boşken, en yeniden eskiye çevrilir.
    case backlog
}

/// Sıradan alınan çeviri.
public struct DequeuedTranslation<Job: Sendable>: Sendable {
    public let job: Job
    public let lane: TranslationLane
    /// İş alındıktan sonraki sıra.
    public let queue: LiveTranslationQueue<Job>
}

/// Canlı çevirinin sırası. Çeviri toplantının ortasında açılınca o ana dek çevrilmemiş cümleler (birikmiş) yeni konuşmanın
/// önüne girseydi canlı görünüm dakikalarca geride kalırdı: yeni konuşma her zaman önce çevrilir; birikmiş cümleler canlı
/// yol boşken ve en yeniden eskiye doğru (ekranda görünen son cümleler önce) çevrilir. Birikmiş işler aynı anda en çok
/// `backlogSlots` çeviri yeri kullanır: kalan yer yeni konuşmaya hep açık kalır. Saf değer tipidir.
public struct LiveTranslationQueue<Job: Sendable>: Sendable {
    /// Yeni konuşma, geliş sırasıyla.
    public let live: [Job]
    /// Birikmiş cümleler, eskiden yeniye (en yenisi sondan alınır).
    public let backlog: [Job]

    public init(live: [Job], backlog: [Job]) {
        self.live = live
        self.backlog = backlog
    }

    /// Boş sıra.
    public static var empty: LiveTranslationQueue<Job> {
        LiveTranslationQueue(live: [], backlog: [])
    }

    public var isEmpty: Bool {
        live.isEmpty && backlog.isEmpty
    }

    /// İşi verilen yola ekler (birikmiş işler eskiden yeniye eklenir).
    public func adding(job: Job, lane: TranslationLane) -> LiveTranslationQueue<Job> {
        switch lane {
        case .live:
            LiveTranslationQueue(live: live + [job], backlog: backlog)
        case .backlog:
            LiveTranslationQueue(live: live, backlog: backlog + [job])
        }
    }

    /// Sıradaki iş: önce yeni konuşma (geliş sırasıyla); canlı yol boşsa ve birikmiş işlerin kullandığı yer
    /// (`backlogInFlight`) `backlogSlots`'tan azsa en yeni birikmiş iş. Alınacak iş yoksa nil.
    public func next(backlogInFlight: Int, backlogSlots: Int) -> DequeuedTranslation<Job>? {
        if let first = live.first {
            return DequeuedTranslation(job: first, lane: .live, queue: LiveTranslationQueue(live: Array(live.dropFirst()), backlog: backlog))
        }
        guard backlogInFlight < backlogSlots, let newest = backlog.last else {
            return nil
        }
        return DequeuedTranslation(job: newest, lane: .backlog, queue: LiveTranslationQueue(live: live, backlog: Array(backlog.dropLast())))
    }
}

/// Birikmiş çevirilerin aynı anda kullanabileceği çeviri yeri: en az bir yer yeni konuşmaya kalır. Saf fonksiyondur.
public func backlogTranslationSlots(maxParallel: Int) -> Int {
    max(maxParallel - 1, 1)
}
