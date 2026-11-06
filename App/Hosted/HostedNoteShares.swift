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
            book = try loadNoteShareLinks(url: url)
            let live: [HostedNoteShare] = try await shareClient().list()
            let pruned: NoteShareLinks = keepingLiveNoteShareLinks(links: book, liveShareIDs: Set(live.map(\.shareId)))
            if pruned != book {
                try saveNoteShareLinks(links: pruned, url: url)
                book = pruned
            }
            status = .idle
        } catch {
            fail(error: error, action: "list")
        }
    }

    /// Notu şifreleyip yükler, bağlantıyı deftere yazar ve panoya kopyalar. Başarılıysa bağlantı.
    func create(meetingID: String, payload: SharedNotePayload, expiry: NoteShareExpiry, copy: @MainActor (URL) -> Void) async {
        status = .working
        do {
            let secret: NoteShareSecret = newNoteShareSecret()
            let blob: Data = try sealNoteShare(payload: payload, secret: secret, nonce: nil)
            let stored: HostedNoteShare = try await shareClient().create(shareID: secret.shareID, blob: blob, expiry: expiry)
            let link: URL = noteShareLink(siteOrigin: try HostedServices.siteBase(), secret: secret)
            let entry: NoteShareLinkEntry = NoteShareLinkEntry(
                shareID: secret.shareID, meetingID: meetingID, link: link, createdAt: Date(timeIntervalSince1970: Double(stored.createdAt) / 1000),
                expiresAt: Date(timeIntervalSince1970: Double(stored.expiresAt) / 1000), includesTranscript: payload.transcript != nil
            )
            let url: URL = try noteShareLinksFileURL()
            let updated: NoteShareLinks = addingNoteShareLink(links: try loadNoteShareLinks(url: url), entry: entry)
            try saveNoteShareLinks(links: updated, url: url)
            book = updated
            copy(link)
            copiedShareID = entry.shareID
            status = .idle
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
            let url: URL = try noteShareLinksFileURL()
            let updated: NoteShareLinks = removingNoteShareLink(links: try loadNoteShareLinks(url: url), shareID: shareID)
            try saveNoteShareLinks(links: updated, url: url)
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
