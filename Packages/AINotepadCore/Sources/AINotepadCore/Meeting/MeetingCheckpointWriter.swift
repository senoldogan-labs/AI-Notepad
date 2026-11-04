import Foundation

/// Kayıt sürerken her ~30 sn'de alınan kontrol noktasını (`meeting.json`) ana iş parçacığı dışında kodlayıp yazar. Uzun
/// toplantıda kayıt büyüdükçe kodlama pahalanır (4 saatte onlarca ms): ana iş parçacığında yapılınca arayüz takılıyordu.
/// Anlık görüntü ana aktörde alınır ve yazım sırası (`claimMeetingWrite`) o anda belirlenir; kodlama ve atomik yazım
/// arka planda, sırayla yapılır. Daha yeni bir anlık görüntü (sonraki kontrol noktası ya da kaydın bitişinde ana aktörde
/// yapılan `saveMeeting`) önce yazıldıysa eskisi onun üstüne yazılmaz.
@MainActor
public final class MeetingCheckpointWriter {
    /// Sıradaki son yazım: yeni yazım onun bitmesini bekler (yazımlar birikmez, sırayla yapılır).
    private var pending: Task<Void, Never>?

    public init() {}

    /// Anlık görüntüyü arka planda yazar; ana aktörü yalnızca sıra almak ve görev kurmak kadar tutar. Yazılamazsa
    /// `onFailure` ana aktörde çağrılır.
    public func write(record: MeetingRecord, directory: URL, onFailure: @escaping @MainActor @Sendable (any Error) -> Void) {
        let ticket: MeetingWriteTicket = claimMeetingWrite(directory: directory)
        let previous: Task<Void, Never>? = pending
        pending = Task.detached(priority: .utility) { () async -> Void in
            await previous?.value
            do {
                try saveMeeting(record: record, directory: directory, ticket: ticket)
            } catch {
                await onFailure(error)
            }
        }
    }

    /// Bekleyen yazımların hepsi bitene dek bekler.
    public func drain() async {
        await pending?.value
    }
}
