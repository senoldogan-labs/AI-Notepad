import Foundation

/// Canlı olayın kayıt ekranına (gözlenen transkripte) gidişi: şimdi uygulanacak mı ve ekran görünmezken bekletilen
/// geçici bölümler.
public struct BackgroundLiveRouting: Sendable, Equatable {
    /// Olay şimdi transkripte uygulanmalı.
    public let appliesNow: Bool
    /// Uygulama arka plandayken bekletilen geçici bölümler (bölüm başına en yenisi); öne dönünce uygulanır.
    public let deferredPartials: [SegmentID: LiveSegment]

    public init(appliesNow: Bool, deferredPartials: [SegmentID: LiveSegment]) {
        self.appliesNow = appliesNow
        self.deferredPartials = deferredPartials
    }
}

/// Canlı olayın transkripte ne zaman gideceği. Arka planda ekran görünmez: geçici (kesinleşmemiş) bölümler saniyede
/// birkaç kez gelir ve her biri kayıt ekranını yeniden kurdururdu (işlemci, arka plan sınırı); bunlar bölüm başına
/// en yenisi olarak bekletilir. Kesin bölümler ve diğer olaylar her zaman hemen uygulanır (kontrol noktası, çeviri, canlı
/// etkinlik ve çökmede kurtarma onları kullanır); kesinleşen bölümün bekleyen geçici hâli atılır. Saf fonksiyondur.
public func routingLiveEvent(event: LiveSessionEvent, deferredPartials: [SegmentID: LiveSegment], isInBackground: Bool) -> BackgroundLiveRouting {
    guard case .segment(let segment) = event else {
        return BackgroundLiveRouting(appliesNow: true, deferredPartials: deferredPartials)
    }
    var pending: [SegmentID: LiveSegment] = deferredPartials
    guard isInBackground, !segment.isFinal else {
        pending[segment.id] = nil
        return BackgroundLiveRouting(appliesNow: true, deferredPartials: pending)
    }
    pending[segment.id] = segment
    return BackgroundLiveRouting(appliesNow: false, deferredPartials: pending)
}

/// Öne dönünce bekletilen geçici bölümler transkripte uygulanır: ekran uzaktayken gelen her şeyi hemen gösterir. Saf
/// fonksiyondur.
public func applyingDeferredPartials(transcript: [LiveSegment], deferredPartials: [SegmentID: LiveSegment]) -> [LiveSegment] {
    deferredPartials.values
        .sorted { (left: LiveSegment, right: LiveSegment) -> Bool in
            left.startSec == right.startSec ? left.id.index < right.id.index : left.startSec < right.startSec
        }
        .reduce(transcript) { (current: [LiveSegment], partial: LiveSegment) -> [LiveSegment] in
            applyEvent(transcript: current, event: .segment(partial))
        }
}
