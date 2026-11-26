import AINotepadCore
import AINotepadUI
import SwiftUI

// The free plan's own views on the iPhone (Mac: App/Hosted/HostedFreePlanViews.swift).

/// In place of a finished meeting's missing note on the free plan (Mac's `HostedFreeNoteCard`): why there is no note and
/// what to do — write it with one of the month's free notes, or get it with a paid plan. Never called a trial.
struct PhoneFreeNoteCard: View {
    let store: PhoneStore
    let record: MeetingRecord
    let allowance: HostedFreeAllowance
    let isEditable: Bool

    var body: some View {
        let action: HostedFreeNoteAction = hostedFreeNoteAction(segments: meetingSegments(record: record), allowance: allowance)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                AccentSymbolTile(symbol: "sparkles", size: 40)
                Text("Bu toplantının notu yok")
                    .appFont(size: 15, weight: .medium)
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
            }
            Text(verbatim: hostedFreeNoteCardText(action: action, notice: record.notice, allowance: allowance))
                .appFont(size: 14, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            switch action {
            case .write:
                Button {
                    Task { await store.regenerateNote(meetingID: record.id) }
                } label: {
                    PhonePrimaryButtonLabel(title: "Notu yaz")
                }
                .buttonStyle(.plain)
                .disabled(!isEditable || store.regeneratingIDs.contains(record.id))
                Button("Planları gör") { HostedAccount.shared.showFreeUpgrade(moment: .freePlanStarted) }
                    .appFont(size: 14, weight: .semibold)
            case .upgrade(let moment):
                Button {
                    HostedAccount.shared.showFreeUpgrade(moment: moment)
                } label: {
                    PhonePrimaryButtonLabel(title: "Kişisel planla bu notu al")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 14)
    }
}
