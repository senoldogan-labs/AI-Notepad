import AINotepadCore
import AppKit
import Foundation
import Observation
import os

extension SettingsKey {
    /// Çevrimiçi görüşme kaydında paylaşılan ekranın görüntüleri alınsın mı (varsayılan kapalı; açıkça açılır).
    static let screenSnapshots: String = "screenSnapshots.enabled"
    /// Gistsmith: whether key screen snapshots go with the AI note (off by default; images leave the Mac only then).
    static let screenNotes: String = "screenNotes.enabled"
}

/// Ekran görüntülerinin uygulama tarafı: kayıt sırasında görüntü almayı yönetir, toplantıların görüntü listesini ve
/// küçük resimlerini tutar, silmeleri yapar. Görüntüler toplantının klasöründe (`Screens/`) durur.
@MainActor
@Observable
final class ScreenSnapshotCenter {
    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "ScreenSnapshots")

    /// Toplantı başına görüntüler (sayfası açılan toplantılar okunur; kayıt sürerken yenileri eklenir).
    private(set) var snapshots: [String: [ScreenSnapshot]] = [:]
    /// Toplantı başına son okuma ya da silme hatası (toplantı sayfasında satır içinde).
    private(set) var errors: [String: String] = [:]
    /// Per meeting: snapshots the user unticked for notes (`Screens/excluded-from-notes.json`).
    private(set) var noteExclusions: [String: Set<String>] = [:]
    @ObservationIgnored private let recorder: ScreenSnapshotRecorder = ScreenSnapshotRecorder()
    @ObservationIgnored private let thumbnails: NSCache<NSString, NSImage> = NSCache()
    /// Görüntüsü alınan kaydın toplantısı; kayıt yokken nil.
    @ObservationIgnored private var recordingMeetingID: String?
    /// Bu kayıtta görüntü saklandı mı (özellik kullanımı kayıt başına bir kez işlenir).
    @ObservationIgnored private var storedThisRecording: Bool = false

    /// Kayıt başında görüntü almayı başlatır. Başlatılamazsa (izin yok) hata atar; kayıt etkilenmez.
    func startRecording(meetingID: String, directory: URL, origin: ContinuousClock.Instant, onStopped: @escaping @MainActor (ScreenCaptureError) -> Void) throws(ScreenCaptureError) {
        recordingMeetingID = meetingID
        storedThisRecording = false
        try recorder.start(meetingDirectory: directory, origin: origin, policy: screenSnapshotPolicy) { [weak self] (event: ScreenSnapshotEvent) -> Void in
            self?.handle(event: event, meetingID: meetingID, onStopped: onStopped)
        }
    }

    /// Kayıt duraklatılınca görüntü alınmaz.
    func setPaused(_ isPaused: Bool) {
        recorder.setPaused(isPaused)
    }

    /// Kayıt bitince görüntü alma durur. İkinci kez çağrılması zararsızdır.
    func stopRecording() {
        recorder.stop()
        recordingMeetingID = nil
    }

    private func handle(event: ScreenSnapshotEvent, meetingID: String, onStopped: @MainActor (ScreenCaptureError) -> Void) {
        switch event {
        case .stored(let snapshot):
            snapshots[meetingID] = (snapshots[meetingID] ?? []).filter { $0 != snapshot } + [snapshot]
            if !storedThisRecording {
                storedThisRecording = true
                recordFeatureUsage(feature: .screenSnapshots)
            }
        case .capReached:
            Self.logger.info("Ekran görüntüsü sınırı doldu, toplantı: \(meetingID, privacy: .public)")
        case .stopped(let error):
            Self.logger.error("Ekran görüntüsü alma durdu, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .public)")
            onStopped(error)
        }
    }

    /// Toplantının görüntülerini klasöründen yeniden okur (arka planda).
    func refresh(meetingID: String, directory: URL) async {
        let result: Result<([ScreenSnapshot], Set<String>), any Error> = await Task.detached(priority: .userInitiated) { () -> Result<([ScreenSnapshot], Set<String>), any Error> in
            Result { (try listScreenSnapshots(meetingDirectory: directory), try readScreenNoteExclusions(meetingDirectory: directory)) }
        }.value
        switch result {
        case .success(let (list, excluded)):
            snapshots[meetingID] = list
            noteExclusions[meetingID] = prunedScreenNoteExclusions(excluded: excluded, snapshots: list)
            errors[meetingID] = nil
        case .failure(let error):
            Self.logger.error("Ekran görüntüleri okunamadı, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            errors[meetingID] = String(localized: "Ekran görüntüleri okunamadı: \(userFacingMessage(error: error))")
        }
    }

    /// Tek görüntüyü kalıcı siler.
    func delete(meetingID: String, directory: URL, snapshot: ScreenSnapshot) {
        do {
            try deleteScreenSnapshot(meetingDirectory: directory, snapshot: snapshot)
            snapshots[meetingID] = (snapshots[meetingID] ?? []).filter { $0 != snapshot }
            let excluded: Set<String> = noteExclusions[meetingID] ?? []
            if excluded.contains(snapshot.id) {
                let pruned: Set<String> = prunedScreenNoteExclusions(excluded: excluded, snapshots: snapshots[meetingID] ?? [])
                try writeScreenNoteExclusions(meetingDirectory: directory, excluded: pruned)
                noteExclusions[meetingID] = pruned
            }
            thumbnails.removeObject(forKey: thumbnailKey(meetingID: meetingID, snapshot: snapshot))
            errors[meetingID] = nil
        } catch {
            Self.logger.error("Ekran görüntüsü silinemedi, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            errors[meetingID] = String(localized: "Ekran görüntüsü silinemedi: \(userFacingMessage(error: error))")
        }
    }

    /// Toplantının bütün görüntülerini kalıcı siler.
    func deleteAll(meetingID: String, directory: URL) {
        do {
            try deleteAllScreenSnapshots(meetingDirectory: directory)
            snapshots[meetingID] = []
            noteExclusions[meetingID] = []
            thumbnails.removeAllObjects()
            errors[meetingID] = nil
        } catch {
            Self.logger.error("Ekran görüntüleri silinemedi, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            errors[meetingID] = String(localized: "Ekran görüntüleri silinemedi: \(userFacingMessage(error: error))")
        }
    }

    /// Ticks or unticks a snapshot for notes and saves the choice in the meeting's folder; the next note uses it.
    func toggleNoteExclusion(meetingID: String, directory: URL, snapshot: ScreenSnapshot) {
        let updated: Set<String> = toggledScreenNoteExclusion(excluded: noteExclusions[meetingID] ?? [], snapshotID: snapshot.id)
        do {
            try writeScreenNoteExclusions(meetingDirectory: directory, excluded: updated)
            noteExclusions[meetingID] = updated
            errors[meetingID] = nil
        } catch {
            Self.logger.error("Nota ekleme seçimi kaydedilemedi, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            errors[meetingID] = String(localized: "Seçim kaydedilemedi: \(userFacingMessage(error: error))")
        }
    }

    /// Görüntünün küçük resmi (arka planda okunur, önbellekte tutulur); okunamazsa hata atar.
    func thumbnail(meetingID: String, directory: URL, snapshot: ScreenSnapshot, maxPixelSize: Int) async throws -> NSImage {
        let key: NSString = thumbnailKey(meetingID: meetingID, snapshot: snapshot)
        if maxPixelSize <= screenThumbnailPixels, let cached = thumbnails.object(forKey: key) {
            return cached
        }
        let file: URL = screenSnapshotFile(meetingDirectory: directory, snapshot: snapshot)
        let image: CGImage = try await Task.detached(priority: .userInitiated) { () throws -> CGImage in
            try downscaledImage(file: file, maxPixelSize: maxPixelSize)
        }.value
        let result: NSImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        if maxPixelSize <= screenThumbnailPixels {
            thumbnails.setObject(result, forKey: key)
        }
        return result
    }

    /// Toplantının klasörü çözülemedi: hata sayfada görünür.
    func record(error: any Error, meetingID: String) {
        Self.logger.error("Toplantı klasörü çözülemedi, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
        errors[meetingID] = String(localized: "Ekran görüntüleri açılamadı: \(userFacingMessage(error: error))")
    }

    private func thumbnailKey(meetingID: String, snapshot: ScreenSnapshot) -> NSString {
        "\(meetingID)/\(snapshot.id)" as NSString
    }
}

private let screenNotesLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "ScreenNotes")

/// Listedeki küçük resimlerin uzun kenarı (piksel; Retina'da 280 noktalık genişliğe yeter).
let screenThumbnailPixels: Int = 640

/// Görüntü alma hatasının kullanıcı metni.
func screenCaptureMessage(error: ScreenCaptureError) -> String {
    switch error {
    case .permissionDenied:
        String(localized: "Ekran görüntüleri alınamıyor: Ekran Kaydı izni yok. Sistem Ayarları › Gizlilik ve Güvenlik › Ekran ve Sistem Sesi Kaydı'nda bu uygulamaya izin verip uygulamayı yeniden aç.")
    case .noDisplay:
        String(localized: "Ekran görüntüleri alınamıyor: ekran bulunamadı.")
    case .captureFailed:
        String(localized: "Ekran görüntüleri art arda alınamadı, bu kayıtta durduruldu. Kayıt sürüyor.")
    case .storeFailed:
        String(localized: "Ekran görüntüleri kaydedilemedi, bu kayıtta durduruldu. Disk alanını kontrol et; kayıt sürüyor.")
    }
}

extension AppModel {
    /// Kayıt başında: ayar açıksa ve görüşme çevrimiçiyse (yüz yüze modunda paylaşılan ekran yoktur) görüntü almayı
    /// başlatır. Başlatılamaz ya da sonradan durursa nedeni paneldeki hatalarda görünür; kayıt sürer.
    func startScreenSnapshots(meetingID: String, directory: URL, origin: ContinuousClock.Instant, isInPerson: Bool) {
        guard UserDefaults.standard.bool(forKey: SettingsKey.screenSnapshots), !isInPerson else {
            return
        }
        do {
            try screenSnapshots.startRecording(meetingID: meetingID, directory: directory, origin: origin) { [weak self] (error: ScreenCaptureError) -> Void in
                guard let self else {
                    return
                }
                self.errorMessages = appendUnique(messages: self.errorMessages, message: screenCaptureMessage(error: error))
            }
        } catch {
            errorMessages = appendUnique(messages: errorMessages, message: screenCaptureMessage(error: error))
        }
    }

    /// Toplantı sayfası açılınca görüntüleri okur; klasörü çözülemezse hata sayfada görünür.
    func refreshScreenSnapshots(meetingID: String) async {
        do {
            await screenSnapshots.refresh(meetingID: meetingID, directory: try sessionDirectory(id: meetingID))
        } catch {
            screenSnapshots.record(error: error, meetingID: meetingID)
        }
    }

    /// Tek görüntüyü kalıcı siler; hata sayfada görünür.
    func deleteScreenSnapshot(meetingID: String, snapshot: ScreenSnapshot) {
        do {
            screenSnapshots.delete(meetingID: meetingID, directory: try sessionDirectory(id: meetingID), snapshot: snapshot)
        } catch {
            screenSnapshots.record(error: error, meetingID: meetingID)
        }
    }

    /// Toplantının bütün görüntülerini kalıcı siler; hata sayfada görünür.
    func deleteAllScreenSnapshots(meetingID: String) {
        do {
            screenSnapshots.deleteAll(meetingID: meetingID, directory: try sessionDirectory(id: meetingID))
        } catch {
            screenSnapshots.record(error: error, meetingID: meetingID)
        }
    }

    /// Ticks or unticks a snapshot for notes; a failure shows on the page.
    func toggleScreenNoteExclusion(meetingID: String, snapshot: ScreenSnapshot) {
        do {
            screenSnapshots.toggleNoteExclusion(meetingID: meetingID, directory: try sessionDirectory(id: meetingID), snapshot: snapshot)
        } catch {
            screenSnapshots.record(error: error, meetingID: meetingID)
        }
    }

    /// Whether notes are written with screen snapshots: only Gistsmith (its server is the only provider that takes images)
    /// and only with the setting on.
    func screenNotesPlan() -> ScreenNotesPlan {
        #if HOSTED_EDITION
        UserDefaults.standard.bool(forKey: SettingsKey.screenNotes) ? .on : .off
        #else
        .off
        #endif
    }

    /// Counts the feature once a note was written with snapshots: the plan was on, the note succeeded and the meeting
    /// had snapshots left after the user's unticks (the selector then always sends at least one).
    func recordScreenNotesUsage(plan: ScreenNotesPlan, result: MeetingRecord, directory: URL) {
        guard plan == .on, result.note != nil, result.status == .done, result.failureMessage == nil else {
            return
        }
        do {
            let excluded: Set<String> = try readScreenNoteExclusions(meetingDirectory: directory)
            if try listScreenSnapshots(meetingDirectory: directory).contains(where: { !excluded.contains($0.id) }) {
                recordFeatureUsage(feature: .screenNotes)
            }
        } catch {
            screenNotesLogger.error("Ekran görüntüleri okunamadı (kullanım sayımı), toplantı: \(result.id, privacy: .public), hata: \(String(describing: error), privacy: .private)")
        }
    }

    /// Görüntünün küçük ya da büyük hâli (`maxPixelSize`); okunamazsa hata atar.
    func screenSnapshotImage(meetingID: String, snapshot: ScreenSnapshot, maxPixelSize: Int) async throws -> NSImage {
        try await screenSnapshots.thumbnail(meetingID: meetingID, directory: try sessionDirectory(id: meetingID), snapshot: snapshot, maxPixelSize: maxPixelSize)
    }
}
