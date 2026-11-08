import Foundation

/// Kayıt sırasında açılan mikrofonun transkriptteki işaretinin bölüm numarası: Deepgram (0'dan), boşluk doldurma
/// (1.000.000'dan) ve Mac'e geçiş (`localSegmentIndexBase`) bölümleriyle çakışmaz.
public let microphoneJoinedMarkerIndex: Int = 3_000_000

/// Mikrofon kapalı başlayan kayıtta mikrofonun açıldığı anın transkript işareti: o anda kesinleşmiş, metni `text` olan
/// bir "Sen" bölümü. Transkriptte, kayıtta saklanan metinde ve notun okuduğu satırlarda "Sen"in bu andan önce
/// kaydedilmediğini söyler (öncesindeki sessizliği konuşmadığı sanılmasın). Saf fonksiyondur.
public func microphoneJoinedMarker(atSec: Double, text: String) -> LiveSegment {
    LiveSegment(
        id: SegmentID(speaker: .me, index: microphoneJoinedMarkerIndex), startSec: atSec, endSec: atSec, text: text, isFinal: true,
        failureMessage: nil, person: nil
    )
}
