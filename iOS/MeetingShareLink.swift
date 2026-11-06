import AINotepadCore
import AINotepadUI
import SwiftUI
import UIKit

/// Mac'teki "Bağlantıyla paylaş…" kartının iPhone sayfası: süre, isteğe bağlı transkript, uçtan uca şifreli bağlantı
/// oluşturma ve bu toplantının bu cihazdaki bağlantıları (kopyala, kaldır). Paylaşılan not sayfada seçili dildeki nottur.
struct PhoneNoteShareSheet: View {
    let record: MeetingRecord
    /// Sayfada seçili not dili (paylaşım sürümü); nil ise asıl not.
    let language: ShareLanguage?
    @State private var center: NoteShareCenter = NoteShareCenter()
    @State private var expiry: NoteShareExpiry = .month
    @State private var includeTranscript: Bool = false
    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        NavigationStack {
            ScrollView {
                NoteSharePanel(
                    expiry: $expiry, includeTranscript: $includeTranscript, hasTranscript: !transcriptParagraphs(record: record).isEmpty,
                    links: center.links(meetingID: record.id), status: center.status, copiedShareID: center.copiedShareID,
                    onCreate: create, onCopy: { (entry: NoteShareLinkEntry) in center.copy(entry: entry, copy: copyToPasteboard) },
                    onRevoke: { (entry: NoteShareLinkEntry) in Task { await center.revoke(shareID: entry.shareID) } }, onClose: nil
                )
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Bağlantıyla paylaş")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                }
            }
        }
        .task(id: record.id) { await center.refresh() }
    }

    private func create() {
        guard let payload = noteSharePayload(record: record, language: language, includeTranscript: includeTranscript) else {
            return
        }
        Task { await center.create(meetingID: record.id, payload: payload, expiry: expiry, copy: copyToPasteboard) }
    }

    private func copyToPasteboard(_ link: URL) {
        UIPasteboard.general.url = link
    }
}
