import AINotepadCore
import SwiftUI

/// "Hangisi sendin?" kartının kapatıldığı toplantıların kimlikleri (virgülle; bu cihazda).
private let dismissedMeetingsKey: String = "userSpeakerPromptDismissed"

/// Yüz yüze toplantının notunda "Hangisi sendin?" kartı (bkz. `userSpeakerCandidates`): kullanıcı konuşmacılardan birini
/// seçer, o konuşmacıya kullanıcının adı verilir ve görevleri Görevlerim'e düşer. Ad henüz yoksa önce sorulur. "Hiçbiri"
/// kartı bu toplantı için kapatır. Mac ve iPhone toplantı sayfası aynı kartı gösterir.
public struct UserSpeakerPrompt: View {
    let record: MeetingRecord
    let userName: String
    let isLocked: Bool
    /// Seçilen konuşmacı ve kullanıcının adı (girilen ya da kayıtlı).
    let onChoose: @MainActor (Int, String) -> Void
    @AppStorage(dismissedMeetingsKey) private var dismissed: String = ""
    @State private var typedName: String = ""
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(record: MeetingRecord, userName: String, isLocked: Bool, onChoose: @escaping @MainActor (Int, String) -> Void) {
        self.record = record
        self.userName = userName
        self.isLocked = isLocked
        self.onChoose = onChoose
    }

    public var body: some View {
        let candidates: [UserSpeakerCandidate] = userSpeakerCandidates(record: record, userName: userName)
        if !candidates.isEmpty, !dismissedIDs.contains(record.id) {
            card(candidates: candidates)
        }
    }

    private var dismissedIDs: Set<String> {
        Set(dismissed.split(separator: ",").map(String.init))
    }

    private func card(candidates: [UserSpeakerCandidate]) -> some View {
        let savedName: String = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String = savedName.isEmpty ? typedName.trimmingCharacters(in: .whitespacesAndNewlines) : savedName
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bu toplantıda hangisi sendin?")
                    .appFont(size: 15, weight: .semibold)
                Text("Yüz yüze kayıtta sen de konuşmacılardan birisin. Seçince sana düşen görevler Görevlerim'e gelir.")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if savedName.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Adın").appFont(size: 12, weight: .medium).foregroundStyle(Theme.muted)
                    // Örnek metin alanın üstünde soluk çizilir: macOS odaksız alanın yer tutucusunu yazı rengiyle çiziyor.
                    TextField(text: $typedName) { EmptyView() }
                        .textFieldStyle(.plain)
                        .accessibilityLabel(Text("Adın"))
                        .appFont(size: 14, weight: .regular)
                        .overlay(alignment: .leading) {
                            if typedName.isEmpty {
                                Text("Örn. Aino Virtanen")
                                    .appFont(size: 14, weight: .regular)
                                    .foregroundStyle(Theme.muted)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(candidates) { (candidate: UserSpeakerCandidate) in
                    Button {
                        onChoose(candidate.person, name)
                    } label: {
                        row(candidate: candidate)
                    }
                    .buttonStyle(.hoverPlain)
                    .disabled(name.isEmpty || isLocked)
                }
            }
            Button("Hiçbiri") {
                withAnimation(.smooth(duration: 0.2)) {
                    dismissed = (dismissedIDs.union([record.id])).sorted().joined(separator: ",")
                }
            }
            .buttonStyle(.pill)
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func row(candidate: UserSpeakerCandidate) -> some View {
        let color: Color = personColor(person: candidate.person)
        return HStack(alignment: .top, spacing: 10) {
            Text(verbatim: "\(candidate.person)")
                .appFont(size: 13, weight: .semibold)
                .foregroundStyle(personTextColor(person: candidate.person))
                .frame(width: 28, height: 28)
                .background(Circle().fill(color.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(speakerLabel(speaker: .others, person: candidate.person))
                    .appFont(size: 14, weight: .medium)
                if !candidate.sample.isEmpty {
                    Text(verbatim: "“\(candidate.sample)”")
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .appFont(size: 11, weight: .semibold)
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// Görevlerim'in üstündeki kart: kullanıcının hangi konuşmacı olduğu seçilmemiş yüz yüze toplantılar (bkz.
/// `userSpeakerCandidates`; "Hiçbiri" denenler hariç). Dokununca toplantı açılır, orada "Hangisi sendin?" sorulur.
public struct PendingUserSpeakerMeetings: View {
    let meetings: [MeetingRecord]
    let userName: String
    let onOpen: @MainActor (String) -> Void
    @AppStorage(dismissedMeetingsKey) private var dismissed: String = ""

    public init(meetings: [MeetingRecord], userName: String, onOpen: @escaping @MainActor (String) -> Void) {
        self.meetings = meetings
        self.userName = userName
        self.onOpen = onOpen
    }

    public var body: some View {
        let dismissedIDs: Set<String> = Set(dismissed.split(separator: ",").map(String.init))
        let pending: [MeetingRecord] = meetings.filter { (record: MeetingRecord) -> Bool in
            !dismissedIDs.contains(record.id) && !userSpeakerCandidates(record: record, userName: userName).isEmpty
        }
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hangi konuşmacı olduğunu seç")
                        .appFont(size: 15, weight: .semibold)
                    Text("Bu yüz yüze toplantılardaki görevlerin, konuşmacını seçince buraya gelir.")
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(pending, id: \.id) { (record: MeetingRecord) in
                        Button {
                            onOpen(record.id)
                        } label: {
                            HStack(spacing: 10) {
                                CoverBackground(seed: record.id)
                                    .frame(width: 22, height: 22)
                                    .clipShape(Circle())
                                Text(record.note?.title ?? record.title)
                                    .appFont(size: 14, weight: .medium)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(record.startedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(interfaceLocale())))
                                    .appFont(size: 12, weight: .regular)
                                    .foregroundStyle(Theme.muted)
                                Image(systemName: "chevron.right")
                                    .appFont(size: 11, weight: .semibold)
                                    .foregroundStyle(Theme.muted)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.hoverPlain)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.soft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}
