import AINotepadCore
import AINotepadUI
import Foundation
import Observation
import os

private let noteShareLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "NoteShare")

// Notu bağlantıyla paylaşmanın uygulama tarafı (Mac'teki Gistsmith ve iPhone ortak). Not cihazda şifrelenir
// (`sealNoteShare`), sunucuya yalnızca şifreli blok gider (`HostedShareClient`); anahtar yalnızca bağlantıdadır.
// Hangi bağlantının hangi toplantıya ait olduğu ve bağlantının kendisi yalnızca bu cihazdaki defterdedir
// (`NoteShareLinks.json`); sunucunun listesi hangi bağlantıların hâlâ açık olduğunu söyler.

/// Toplantı sayfasındaki "Bağlantıyla paylaş" panelinin durumu ve işleri.
@MainActor
@Observable
final class NoteShareCenter {
    /// Bu cihazın bildiği açık bağlantılar.
    private(set) var book: NoteShareLinks = .empty
    private(set) var status: NoteSharePanelStatus = .idle
    /// Az önce kopyalanan bağlantı (düğmede "Kopyalandı").
    private(set) var copiedShareID: String?
    /// Links live on the server whose book save failed and whose removal failed too (`NoteShareCreateOutcome.unsavedLive`):
    /// held here with their keys, shown in the list, and saved with the next book write.
    @ObservationIgnored private var unsaved: [NoteShareLinkEntry] = []

    /// Toplantının bu cihazdaki açık bağlantıları, yeniden eskiye.
    func links(meetingID: String) -> [NoteShareLinkEntry] {
        noteShareLinks(links: book, meetingID: meetingID)
    }

    /// Defteri okur ve sunucunun listesiyle kaldırılmış ya da süresi dolmuş bağlantıları düşürür. Çevrimdışıyken defter
    /// olduğu gibi gösterilir ve hata panelde yazılır.
    func refresh() async {
        status = .working
        do {
            let url: URL = try noteShareLinksFileURL()
            let saved: NoteShareLinks = try loadNoteShareLinks(url: url)
            book = noteShareLinksAddingUnsaved(links: saved, unsaved: unsaved)
            let live: [HostedNoteShare] = try await shareClient().list()
            let pruned: NoteShareLinks = keepingLiveNoteShareLinks(links: book, liveShareIDs: Set(live.map(\.shareId)))
            // Saving here also retries the links whose save failed when they were created.
            if pruned != saved {
                try saveNoteShareLinks(links: pruned, url: url)
            }
            unsaved = []
            book = pruned
            status = .idle
        } catch {
            fail(error: error, action: "list")
        }
    }

    /// Notu şifreleyip yükler, bağlantıyı deftere yazar ve panoya kopyalar. If the book cannot be saved, the link is
    /// removed on the server again; if that fails too, it is kept in memory with its key (listed, saved with the next
    /// book write) and not copied (`createNoteShareLink`).
    func create(meetingID: String, payload: SharedNotePayload, expiry: NoteShareExpiry, copy: @MainActor (URL) -> Void) async {
        status = .working
        do {
            let outcome: NoteShareCreateOutcome = try await createNoteShareLink(
                api: try shareClient(), linksFile: try noteShareLinksFileURL(), unsaved: unsaved, meetingID: meetingID, payload: payload, expiry: expiry,
                secret: newNoteShareSecret(), siteOrigin: try HostedServices.siteBase()
            )
            switch outcome {
            case .saved(let entry, let links):
                unsaved = []
                book = links
                copy(entry.link)
                copiedShareID = entry.shareID
                status = .idle
            case .revokedAfterSaveFailure(let saveError):
                fail(error: saveError, action: "create")
            case .unsavedLive(let entry, let saveError):
                unsaved.append(entry)
                book = noteShareLinksAddingUnsaved(links: book, unsaved: [entry])
                fail(error: saveError, action: "create")
            }
        } catch {
            fail(error: error, action: "create")
        }
    }

    /// Bağlantıyı panoya kopyalar.
    func copy(entry: NoteShareLinkEntry, copy: @MainActor (URL) -> Void) {
        copy(entry.link)
        copiedShareID = entry.shareID
    }

    /// Bağlantıyı sunucuda kaldırır (okuyanlar hemen "kaldırıldı" görür) ve defterden siler. Sunucuda zaten yoksa da
    /// defterden silinir.
    func revoke(shareID: String) async {
        status = .working
        do {
            do {
                try await shareClient().delete(shareID: shareID)
            } catch let error as HostedAPIError where error.code == .notFound {
                noteShareLogger.info("Shared link was already gone on the server")
            }
            unsaved.removeAll { $0.shareID == shareID }
            book = removingNoteShareLink(links: book, shareID: shareID)
            let url: URL = try noteShareLinksFileURL()
            let updated: NoteShareLinks = removingNoteShareLink(
                links: noteShareLinksAddingUnsaved(links: try loadNoteShareLinks(url: url), unsaved: unsaved), shareID: shareID
            )
            try saveNoteShareLinks(links: updated, url: url)
            unsaved = []
            book = updated
            status = .idle
        } catch {
            fail(error: error, action: "revoke")
        }
    }

    private func shareClient() throws -> HostedShareClient {
        let client: HostedClient = try HostedServices.requireClient()
        return HostedShareClient(baseURL: client.baseURL, credentials: client)
    }

    private func fail(error: any Error, action: String) {
        noteShareLogger.error("Note share failed, action: \(action, privacy: .public), error: \(String(describing: error), privacy: .private)")
        status = .failed(userFacingMessage(error: error))
    }
}

/// Paylaşılacak yük: sayfada seçili dildeki not (paylaşım sürümü yoksa asıl not) ve istenirse transkript. Not yoksa nil.
/// Saf fonksiyondur.
func noteSharePayload(record: MeetingRecord, language: ShareLanguage?, includeTranscript: Bool) -> SharedNotePayload? {
    guard let note = record.note else {
        return nil
    }
    let shown: (note: MeetingNote, language: ShareLanguage?) = language.flatMap { (choice: ShareLanguage) -> (note: MeetingNote, language: ShareLanguage?)? in
        record.sharedNotes?[choice.rawValue].map { (note: $0, language: choice) }
    } ?? (note: note, language: nil)
    return sharedNotePayload(record: record, note: shown.note, language: shown.language, transcript: includeTranscript ? transcriptParagraphs(record: record) : nil)
}

/// Silinen toplantıların bu cihazdaki bağlantılarını sunucuda kaldırır ve defterden siler (arka planda; toplantı Çöp
/// Sepeti'nden geri alınsa da bağlantılar geri gelmez). Kaldırılamayan bağlantı (çevrimdışı) defterde kalır, süresi
/// dolunca sunucuda kendiliğinden kapanır; hata loglanır.
@MainActor
func revokeNoteShareLinks(meetingIDs: Set<String>) {
    let entries: [NoteShareLinkEntry]
    do {
        entries = try loadNoteShareLinks(url: try noteShareLinksFileURL()).entries.filter { meetingIDs.contains($0.meetingID) }
    } catch {
        noteShareLogger.error("Shared links of deleted meetings could not be read, error: \(String(describing: error), privacy: .private)")
        return
    }
    guard !entries.isEmpty else {
        return
    }
    Task { @MainActor in
        let center: NoteShareCenter = NoteShareCenter()
        for entry in entries {
            await center.revoke(shareID: entry.shareID)
        }
        if case .failed(let message) = center.status {
            noteShareLogger.error("Shared links of a deleted meeting were not all removed, message: \(message, privacy: .private)")
        }
    }
}
