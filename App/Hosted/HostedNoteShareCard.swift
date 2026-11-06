import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

/// Mac'te toplantı sayfasının üstündeki "Bağlantıyla paylaş" kartı (açılır pencere yok): süre, isteğe bağlı transkript,
/// bağlantı oluşturma ve bu toplantının bağlantıları. Paylaşılan not sayfada seçili dildeki nottur.
struct NoteShareCard: View {
    let record: MeetingRecord
    /// Sayfada seçili not dili (paylaşım sürümü); nil ise asıl not.
    let language: ShareLanguage?
    let onClose: @MainActor () -> Void
    @State private var center: NoteShareCenter = NoteShareCenter()
    @State private var expiry: NoteShareExpiry = .month
    @State private var includeTranscript: Bool = false

    var body: some View {
        NoteSharePanel(
            expiry: $expiry, includeTranscript: $includeTranscript, hasTranscript: !transcriptParagraphs(record: record).isEmpty,
            links: center.links(meetingID: record.id), status: center.status, copiedShareID: center.copiedShareID,
            onCreate: create, onCopy: { (entry: NoteShareLinkEntry) in center.copy(entry: entry, copy: copyToPasteboard) },
            onRevoke: { (entry: NoteShareLinkEntry) in Task { await center.revoke(shareID: entry.shareID) } }, onClose: onClose
        )
        .padding(14)
        .frame(maxWidth: 820, alignment: .leading)
        .cardSurface(cornerRadius: 16)
        .task(id: record.id) { await center.refresh() }
    }

    private func create() {
        guard let payload = noteSharePayload(record: record, language: language, includeTranscript: includeTranscript) else {
            return
        }
        Task { await center.create(meetingID: record.id, payload: payload, expiry: expiry, copy: copyToPasteboard) }
    }

    private func copyToPasteboard(_ link: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.absoluteString, forType: .string)
    }
}
