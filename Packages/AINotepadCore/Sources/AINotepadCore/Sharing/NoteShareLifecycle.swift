import Foundation
import os

private let noteShareLifecycleLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "NoteShare")

/// The share endpoints a link's creation needs (`HostedShareClient`; tests use a local fake).
public protocol HostedShareAPI: Sendable {
    func create(shareID: String, blob: Data, expiry: NoteShareExpiry) async throws -> HostedNoteShare
    func delete(shareID: String) async throws
}

extension HostedShareClient: HostedShareAPI {}

/// How creating a link ended. The local link book is the only place the key lives, so a link the server holds but
/// the book does not is either removed on the server or kept in memory with its key; it is never left unknown.
public enum NoteShareCreateOutcome: Sendable, Equatable {
    /// The link is live and saved in the book (`links` is the book as written).
    case saved(entry: NoteShareLinkEntry, links: NoteShareLinks)
    /// The book could not be saved, so the link was removed on the server again: nothing is shared.
    case revokedAfterSaveFailure(saveError: StorageError)
    /// The book could not be saved and removing the link failed too: the link stays live until it expires or is
    /// removed. `entry` (with its key) is the caller's to keep in memory, show, and save with the next book write
    /// (`noteShareLinksAddingUnsaved`).
    case unsavedLive(entry: NoteShareLinkEntry, saveError: StorageError)
}

/// Seals `payload` under `secret`, uploads it and saves the link in the book at `linksFile`, merging `unsaved` entries
/// of earlier failed saves. When the save fails, the just-created link is removed on the server (a link already gone
/// counts as removed). The create is never repeated: after its own removal the server would make the same id
/// readable again (it keeps no record of removed ids). Nothing secret is logged.
public func createNoteShareLink(
    api: any HostedShareAPI, linksFile: URL, unsaved: [NoteShareLinkEntry], meetingID: String, payload: SharedNotePayload, expiry: NoteShareExpiry,
    secret: NoteShareSecret, siteOrigin: URL
) async throws -> NoteShareCreateOutcome {
    let blob: Data = try sealNoteShare(payload: payload, secret: secret, nonce: nil)
    let stored: HostedNoteShare = try await api.create(shareID: secret.shareID, blob: blob, expiry: expiry)
    let entry: NoteShareLinkEntry = NoteShareLinkEntry(
        shareID: secret.shareID, meetingID: meetingID, link: noteShareLink(siteOrigin: siteOrigin, secret: secret),
        createdAt: Date(timeIntervalSince1970: Double(stored.createdAt) / 1000), expiresAt: Date(timeIntervalSince1970: Double(stored.expiresAt) / 1000),
        includesTranscript: payload.transcript != nil
    )
    let saveError: StorageError
    do {
        let links: NoteShareLinks = addingNoteShareLink(
            links: noteShareLinksAddingUnsaved(links: try loadNoteShareLinks(url: linksFile), unsaved: unsaved), entry: entry
        )
        try saveNoteShareLinks(links: links, url: linksFile)
        return .saved(entry: entry, links: links)
    } catch let error as StorageError {
        saveError = error
    } catch {
        // The book's own functions throw `StorageError`; anything else is a failed write all the same.
        saveError = StorageError.writeFailed(path: linksFile.path, reason: error.localizedDescription)
    }
    noteShareLifecycleLogger.error("Shared link created but not saved on this device, removing it, error: \(String(describing: saveError), privacy: .private)")
    do {
        try await api.delete(shareID: secret.shareID)
    } catch let error as HostedAPIError where error.code == .notFound {
        noteShareLifecycleLogger.info("Unsaved shared link was already gone on the server")
    } catch {
        noteShareLifecycleLogger.error("Unsaved shared link could not be removed, it stays live, error: \(String(describing: error), privacy: .private)")
        return .unsavedLive(entry: entry, saveError: saveError)
    }
    return .revokedAfterSaveFailure(saveError: saveError)
}

/// The book with `unsaved` entries (links whose save failed) added. Pure function.
public func noteShareLinksAddingUnsaved(links: NoteShareLinks, unsaved: [NoteShareLinkEntry]) -> NoteShareLinks {
    unsaved.reduce(links) { (book: NoteShareLinks, entry: NoteShareLinkEntry) -> NoteShareLinks in addingNoteShareLink(links: book, entry: entry) }
}
