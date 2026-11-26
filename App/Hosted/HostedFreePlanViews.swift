import AINotepadCore
import AINotepadUI
import SwiftUI

// The free plan's own views on the Mac (Gistsmith): the card in place of a meeting's missing note. The plan card, usage
// and offers are in HostedUsageViews.swift and HostedPlanViews.swift.

/// In place of a finished meeting's missing note on the free plan: why there is no note and what to do. When a free note
/// is left this month and the meeting fits one, "Write the note" spends it (the user asks; nothing is spent on its own);
/// otherwise the plans open with the limit's reason (`hostedFreeNoteAction`). Never called a trial.
struct HostedFreeNoteCard: View {
    let model: AppModel
    let record: MeetingRecord
    let allowance: HostedFreeAllowance
    let isLocked: Bool

    var body: some View {
        let action: HostedFreeNoteAction = hostedFreeNoteAction(segments: meetingSegments(record: record), allowance: allowance)
        HStack(alignment: .top, spacing: 14) {
            AccentSymbolTile(symbol: "sparkles", size: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text("Bu toplantının notu yok")
                    .appFont(size: 14, weight: .medium)
                    .foregroundStyle(Theme.ink)
                Text(verbatim: hostedFreeNoteCardText(action: action, notice: record.notice, allowance: allowance))
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    switch action {
                    case .write:
                        Button("Notu yaz") { model.regenerateNote(meetingID: record.id) }
                            .buttonStyle(.pillPrimary)
                            .disabled(isLocked)
                        Button("Planları gör") { HostedAccount.shared.showFreeUpgrade(moment: .freePlanStarted) }
                            .buttonStyle(.pill)
                    case .upgrade(let moment):
                        Button("Kişisel planla bu notu al") { HostedAccount.shared.showFreeUpgrade(moment: moment) }
                            .buttonStyle(.pillPrimary)
                    }
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 14)
    }
}
