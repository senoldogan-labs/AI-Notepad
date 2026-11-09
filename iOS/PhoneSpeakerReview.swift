import AINotepadCore
import AINotepadUI
import SwiftUI

// Transkriptin başında konuşmacı incelemesi (Mac'teki "Gözden geçir"): akıllı model transkripti okuyup ad ve
// birleştirme önerir; öneriler tek tek uygulanır ya da reddedilir. Uygulanan ad ve birleştirme toplantıya hemen yazılır
// (`PhoneStore.renameSpeakers`, `mergeSpeakers`): transkript, not, görevler ve liste adı aynı anda gösterir.

/// "Gözden geçir" düğmesi, tek cümlelik açıklama ve (inceleme açıksa) öneri kartı.
struct PhoneSpeakerReviewSection: View {
    let store: PhoneStore
    let record: MeetingRecord
    /// Adlar değiştirilebilir (kayıtta, işlenen ya da notu yazılan toplantıda değil).
    let isEditable: Bool
    let canPlay: Bool
    let onPlay: @MainActor (Double) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let state: SpeakerReviewState? = store.speakerReviews[record.id]
        VStack(alignment: .leading, spacing: 10) {
            if state == nil {
                HStack(spacing: 12) {
                    Text("Transkripti okuyup ad ve birleştirme önerir")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        store.reviewSpeakers(meetingID: record.id)
                    } label: {
                        Label("Gözden geçir", systemImage: "sparkles")
                            .appFont(size: 14, weight: .semibold)
                            .foregroundStyle(appearance.accent.color)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(appearance.accent.softFill(tintOpacity: 0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEditable)
                    .opacity(isEditable ? 1 : 0.5)
                }
            }
            if let state {
                PhoneSpeakerReviewCard(store: store, record: record, state: state, isEditable: isEditable, canPlay: canPlay, onPlay: onPlay)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.smooth(duration: 0.3), value: state)
    }
}

/// İncelemenin önerileri: her biri tek dokunuşla uygulanır ya da reddedilir; şüpheli anlara dokununca oradan çalar.
/// Öneri uygulanınca not eski adlarla kaldığı için "Notu yenile" sunulur.
private struct PhoneSpeakerReviewCard: View {
    let store: PhoneStore
    let record: MeetingRecord
    let state: SpeakerReviewState
    let isEditable: Bool
    let canPlay: Bool
    let onPlay: @MainActor (Double) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("Konuşmacı önerileri", systemImage: "sparkles")
                    .appFont(size: 12, weight: .semibold)
                    .tracking(DesignTokens.labelTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(appearance.accent.color)
                Spacer(minLength: 0)
                Button {
                    store.closeSpeakerReview(meetingID: record.id)
                } label: {
                    Image(systemName: "xmark")
                        .appFont(size: 12, weight: .semibold)
                        .foregroundStyle(Theme.muted)
                        .frame(width: 30, height: 30)
                        // Dokunma alanı en az 44 pt (Apple HIG); simge küçük kalır.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Önerileri kapat")
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(appearance.accent.color.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(appearance.accent.color.opacity(0.15)))
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Transkript okunuyor…")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                PhoneErrorList(messages: [message])
                Button("Yeniden dene", systemImage: "arrow.clockwise") { store.reviewSpeakers(meetingID: record.id) }
                    .appFont(size: 14, weight: .medium)
                    .disabled(!isEditable)
            }
        case .ready(let review, let applied):
            ForEach(review.names) { (suggestion: SpeakerNameSuggestion) in
                suggestionRow(
                    title: Text("\(label(person: suggestion.person)) → \(suggestion.name)"),
                    reason: suggestion.reason,
                    onAccept: { store.acceptNameSuggestion(meetingID: record.id, suggestion: suggestion) },
                    onDismiss: { store.dismissNameSuggestion(meetingID: record.id, suggestion: suggestion) }
                )
            }
            ForEach(review.merges) { (suggestion: SpeakerMergeSuggestion) in
                suggestionRow(
                    title: Text("\(label(person: suggestion.from)) ile \(label(person: suggestion.into)) aynı kişi"),
                    reason: suggestion.reason,
                    onAccept: { store.acceptMergeSuggestion(meetingID: record.id, suggestion: suggestion) },
                    onDismiss: { store.dismissMergeSuggestion(meetingID: record.id, suggestion: suggestion) }
                )
            }
            if !review.suspicious.isEmpty {
                Text("KONTROL ET")
                    .appFont(size: 11, weight: .semibold)
                    .tracking(DesignTokens.labelTracking)
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 2)
                ForEach(review.suspicious) { (passage: SuspiciousPassage) in
                    suspiciousRow(passage: passage)
                }
            }
            if !review.hasPendingSuggestions && review.suspicious.isEmpty && applied == 0 {
                Label("Öneri yok: transkriptte ad ya da birleştirme için yeterli ipucu bulunamadı.", systemImage: "lightbulb")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if applied > 0 {
                HStack(spacing: 10) {
                    Text("Not eski adlarla yazıldı.")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 0)
                    Button("Notu yenile", systemImage: "arrow.clockwise") {
                        Task { await store.regenerateNote(meetingID: record.id) }
                    }
                    .appFont(size: 14, weight: .semibold)
                    .foregroundStyle(appearance.accent.color)
                    .disabled(!isEditable)
                }
                .padding(.top, 2)
            }
        }
    }

    /// Konuşmacının şu anki adı ve numarası: "Aino (Konuşmacı 2)" ya da "Konuşmacı 2".
    private func label(person: Int) -> String {
        let number: String = speakerLabel(speaker: .others, person: person)
        return record.speakerNames[person].map { "\($0) (\(number))" } ?? number
    }

    private func suggestionRow(
        title: Text, reason: String, onAccept: @escaping @MainActor () -> Void, onDismiss: @escaping @MainActor () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                title
                    .appFont(size: 15, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                Text(reason)
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onAccept) {
                Image(systemName: "checkmark")
                    .appFont(size: 13, weight: .bold)
                    .foregroundStyle(appearance.accent.onColor)
                    .frame(width: 34, height: 34)
                    .background(appearance.accent.color, in: Circle())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEditable)
            .opacity(isEditable ? 1 : 0.5)
            .accessibilityLabel("Öneriyi uygula")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .appFont(size: 13, weight: .bold)
                    .foregroundStyle(Theme.muted)
                    .frame(width: 34, height: 34)
                    .background(Theme.soft, in: Circle())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Öneriyi reddet")
        }
    }

    @ViewBuilder
    private func suspiciousRow(passage: SuspiciousPassage) -> some View {
        let seconds: Double? = timestampSeconds(text: passage.time)
        Button {
            if let seconds {
                onPlay(seconds)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: passage.time)
                    .appFont(size: 12, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(canPlay && seconds != nil ? appearance.accent.color : Theme.muted)
                Text(passage.note)
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canPlay || seconds == nil)
        .accessibilityHint(Text("Bu andan dinle"))
    }
}
