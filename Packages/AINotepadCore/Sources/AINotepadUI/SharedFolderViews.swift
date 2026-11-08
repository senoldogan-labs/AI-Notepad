import AINotepadCore
import SwiftUI

// Paylaşılan klasörlerin ortak görünümleri (Mac ve iPhone; tasarım docs/superpowers/specs/2026-11-08-shared-folders.md):
// sahibin paneli (davet, üyeler, durdurma), "Benimle paylaşılanlar" listesi, klasörün notları, salt okunur not ve davetle
// katılma. Durumu ve işleri çağıran verir; görünümler yalnızca çizer. Mac'te açıklamalar tam, iPhone'da kısa.

/// Sahibin gördüğü paylaşım: transkript seçeneği, üyeler ve yayıncı cihaz.
public struct SharedFolderOwnerSnapshot: Equatable, Sendable {
    public let includesTranscript: Bool
    public let members: [SharedFolderMemberView]
    /// Notları bu cihaz yayımlıyor (değilse "Buradan yayımla").
    public let publishesHere: Bool
    /// Son yayımlamanın sorunu (ör. abonelik yok, not fazla uzun); yoksa nil.
    public let publishProblem: String?

    public init(includesTranscript: Bool, members: [SharedFolderMemberView], publishesHere: Bool, publishProblem: String?) {
        self.includesTranscript = includesTranscript
        self.members = members
        self.publishesHere = publishesHere
        self.publishProblem = publishProblem
    }
}

/// Sahibin paneli: paylaşılmamış klasörde "Paylaş", paylaşılmışta davet, üyeler ve "Paylaşımı durdur" (satır içi onayla).
public struct SharedFolderPanel: View {
    let folderName: String
    /// Klasördeki notlu toplantı sayısı (paylaşılacak not sayısı).
    let noteCount: Int
    /// Nil: klasör henüz paylaşılmadı.
    let snapshot: SharedFolderOwnerSnapshot?
    @Binding var includeTranscript: Bool
    @Binding var inviteLabel: String
    let status: NoteSharePanelStatus
    /// Az önce oluşturulan davet bağlantısı (paylaşım düğmesi görünür).
    let inviteLink: URL?
    let ownerName: String
    let onShare: @MainActor () -> Void
    let onInvite: @MainActor () -> Void
    let onRemove: @MainActor (SharedFolderMemberView) -> Void
    let onStop: @MainActor () -> Void
    let onPublishHere: @MainActor () -> Void
    let onClose: (@MainActor () -> Void)?
    @State private var confirmingStop: Bool = false
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(
        folderName: String, noteCount: Int, snapshot: SharedFolderOwnerSnapshot?, includeTranscript: Binding<Bool>, inviteLabel: Binding<String>,
        status: NoteSharePanelStatus, inviteLink: URL?, ownerName: String, onShare: @escaping @MainActor () -> Void, onInvite: @escaping @MainActor () -> Void,
        onRemove: @escaping @MainActor (SharedFolderMemberView) -> Void, onStop: @escaping @MainActor () -> Void, onPublishHere: @escaping @MainActor () -> Void,
        onClose: (@MainActor () -> Void)?
    ) {
        self.folderName = folderName
        self.noteCount = noteCount
        self.snapshot = snapshot
        _includeTranscript = includeTranscript
        _inviteLabel = inviteLabel
        self.status = status
        self.inviteLink = inviteLink
        self.ownerName = ownerName
        self.onShare = onShare
        self.onInvite = onInvite
        self.onRemove = onRemove
        self.onStop = onStop
        self.onPublishHere = onPublishHere
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Label {
                Text("Uçtan uca şifreli: Gistsmith bile bu notları okuyamaz.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock")
            }
            .appFont(size: 12, weight: .regular)
            .foregroundStyle(Theme.muted)
            if let snapshot {
                sharedBody(snapshot: snapshot)
            } else {
                notSharedBody
            }
            statusRow
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label {
                Text("KLASÖRÜ PAYLAŞ").tracking(DesignTokens.labelTracking)
            } icon: {
                Image(systemName: "person.2")
            }
            .appFont(size: 11, weight: .semibold)
            .foregroundStyle(appearance.accent.color)
            Text(verbatim: folderName)
                .appFont(size: 13, weight: .medium)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let onClose {
                Button("Kapat", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.hoverPlain)
                    .foregroundStyle(Theme.muted)
                    .accessibilityLabel("Klasör paylaşımını kapat")
            }
        }
    }

    private var notSharedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            #if os(macOS)
            Text("Ekip arkadaşların bu klasördeki notları Mac'te ve iPhone'da okur: özet, kararlar, görevler ve konu akışı. Klasöre sonra eklediğin notlar da paylaşılır. Ses, ekran görüntüleri, kendi notların ve Sor sohbetlerin paylaşılmaz.")
                .appFont(size: 13, weight: .regular)
                .fixedSize(horizontal: false, vertical: true)
            #else
            Text("Ekip arkadaşların bu klasördeki notları okur; ses ve kendi notların paylaşılmaz.")
                .appFont(size: 13, weight: .regular)
                .fixedSize(horizontal: false, vertical: true)
            #endif
            transcriptToggle
            Text("\(noteCount) not paylaşılacak.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
            Button("Klasörü paylaş", systemImage: "person.2.badge.plus", action: onShare)
                .buttonStyle(.pillPrimary)
                .disabled(status == .working)
        }
    }

    private var transcriptToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Transkriptleri de paylaş", isOn: $includeTranscript)
                .appFont(size: 13, weight: .regular)
                .fixedSize()
            #if os(macOS)
            Text("Transkript, toplantıdaki herkesin söylediklerini olduğu gibi içerir; katılımcıların buna razı olduğundan emin ol.")
                .appFont(size: 11, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            #else
            Text("Herkesin söyledikleri olduğu gibi paylaşılır.")
                .appFont(size: 11, weight: .regular)
                .foregroundStyle(Theme.muted)
            #endif
        }
    }

    @ViewBuilder
    private func sharedBody(snapshot: SharedFolderOwnerSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(snapshot.includesTranscript ? "\(noteCount) not paylaşılıyor · transkriptlerle" : "\(noteCount) not paylaşılıyor")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
            if let problem = snapshot.publishProblem {
                NoticeText(problem, severity: .attention)
                    .appFont(size: 12, weight: .regular)
                    .textSelection(.enabled)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    inviteField
                    inviteButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    inviteField
                    inviteButton
                }
            }
            if let inviteLink {
                inviteShareRow(link: inviteLink)
            }
            if !snapshot.members.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(snapshot.members) { (member: SharedFolderMemberView) in
                        memberRow(member: member)
                        if member.id != snapshot.members.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .background(Theme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
            }
            if !snapshot.publishesHere {
                HStack(spacing: 8) {
                    Text("Notları diğer cihazın yayımlıyor.")
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                    Button("Buradan yayımla", action: onPublishHere)
                        .buttonStyle(.pill)
                        .disabled(status == .working)
                }
            }
            stopRow(memberCount: snapshot.members.filter { $0.state == .active }.count)
        }
    }

    private var inviteField: some View {
        SharedFolderTextField(placeholder: "Ad ya da e-posta", text: $inviteLabel)
            .frame(minWidth: 200, maxWidth: 320)
            .onSubmit(onInvite)
    }

    private var inviteButton: some View {
        Button("Davet bağlantısı oluştur", systemImage: "link.badge.plus", action: onInvite)
            .buttonStyle(.pillPrimary)
            .disabled(status == .working || inviteLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func inviteShareRow(link: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ShareLink(
                    item: link,
                    subject: Text("\(ownerName) “\(folderName)” notlarını seninle paylaştı"),
                    message: Text("Gistsmith'te paylaşılan klasöre katılmak için bağlantıyı aç (7 gün geçerli, tek kişilik).")
                ) {
                    Label("Bağlantıyı gönder", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.pill)
                Text("Kopyalandı")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
            Text("Bağlantı tek kişilik ve 7 gün geçerli. Katılan kişiyi tanımıyorsan listeden kaldır.")
                .appFont(size: 11, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func memberRow(member: SharedFolderMemberView) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: member.displayName.map { member.label.isEmpty ? $0 : "\($0) · \(member.label)" } ?? member.label)
                    .appFont(size: 13, weight: .medium)
                    .lineLimit(1)
                memberStateText(member: member)
                    .appFont(size: 11, weight: .regular)
                    .foregroundStyle(member.state == .unverified ? NoticeSeverity.attention.tint : Theme.muted)
            }
            Spacer(minLength: 8)
            Button(member.state == .invited ? "Daveti geri al" : "Kaldır", systemImage: "person.badge.minus") { onRemove(member) }
                .buttonStyle(.pill)
                .disabled(status == .working)
        }
        .padding(.vertical, 8)
    }

    private func memberStateText(member: SharedFolderMemberView) -> Text {
        switch member.state {
        case .invited:
            Text("Davet edildi · \(member.expiresAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(interfaceLocale()))) tarihine kadar")
        case .accepted:
            Text("Katıldı · birazdan notları görür")
        case .unverified:
            Text("Bu katılım doğrulanamadı; tanımıyorsan kaldır.")
        case .active:
            Text("Üye · notları okuyabilir")
        }
    }

    @ViewBuilder
    private func stopRow(memberCount: Int) -> some View {
        if confirmingStop {
            VStack(alignment: .leading, spacing: 8) {
                NoticeText("\(memberCount) kişi bu klasöre erişimi kaybeder. Daha önce okudukları notlar cihazlarında kalabilir.", severity: .attention)
                    .appFont(size: 12, weight: .regular)
                HStack(spacing: 8) {
                    Button("Paylaşımı durdur", role: .destructive) {
                        confirmingStop = false
                        onStop()
                    }
                    .buttonStyle(.pill)
                    Button("Vazgeç") { confirmingStop = false }
                        .buttonStyle(.pill)
                }
            }
        } else {
            Button("Paylaşımı durdur…", systemImage: "person.2.slash") { confirmingStop = true }
                .buttonStyle(.hoverPlain)
                .foregroundStyle(Theme.muted)
                .appFont(size: 12, weight: .regular)
                .disabled(status == .working)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch status {
        case .idle:
            EmptyView()
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Bekle…").appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted)
            }
        case .failed(let message):
            NoticeText(message, severity: .error)
                .appFont(size: 12, weight: .regular)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Benimle paylaşılanlar

/// Üyenin gördüğü bir klasör.
public struct SharedFolderSummaryItem: Identifiable, Equatable, Sendable {
    public let folderID: String
    public let name: String
    public let ownerName: String
    /// Nil: sahibin cihazının üyeyi eklemesi bekleniyor.
    public let noteCount: Int?

    public init(folderID: String, name: String, ownerName: String, noteCount: Int?) {
        self.folderID = folderID
        self.name = name
        self.ownerName = ownerName
        self.noteCount = noteCount
    }

    public var id: String { folderID }
}

/// "Benimle paylaşılanlar" satırı: klasör adı, paylaşan ve not sayısı (ya da bekleme).
public struct SharedFolderRow: View {
    let item: SharedFolderSummaryItem

    public init(item: SharedFolderSummaryItem) {
        self.item = item
    }

    public var body: some View {
        HStack(spacing: 12) {
            AccentSymbolTile(symbol: "folder.badge.person.crop", size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.name).appFont(size: 14, weight: .medium).lineLimit(1)
                Group {
                    if let count = item.noteCount {
                        Text("\(item.ownerName) paylaştı") + Text(verbatim: " · ") + Text("\(count) not")
                    } else {
                        Text("\(item.ownerName) onaylayınca açılır")
                    }
                }
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// Paylaşılan bir notun listedeki satırı.
public struct SharedNoteRow: View {
    let note: SharedFolderCachedItem

    public init(note: SharedFolderCachedItem) {
        self.note = note
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: note.payload.note.title).appFont(size: 14, weight: .medium).lineLimit(2)
            Text(verbatim: note.payload.note.subtitle).appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Bekleme durumu: sahibin cihazı üyeyi henüz eklemedi.
public struct SharedFolderWaitingView: View {
    let ownerName: String

    public init(ownerName: String) {
        self.ownerName = ownerName
    }

    public var body: some View {
        QuietEmptyState(
            symbol: "hourglass", title: "Onay bekleniyor",
            message: "Notlar, \(ownerName) Gistsmith'i bir sonraki açışında burada görünür."
        ) { EmptyView() }
    }
}

// MARK: - Salt okunur not

/// Paylaşılan not (salt okunur): başlık, tarih, özet, konu akışı, kararlar, açık konular, görevler, sözlük ve (varsa)
/// transkript. Bölüm başlıkları notun dilindedir (paylaşanın yazdığı gibi).
public struct SharedNoteView: View {
    let note: SharedNotePayload
    let ownerName: String

    public init(note: SharedNotePayload, ownerName: String) {
        self.note = note
        self.ownerName = ownerName
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: note.title).appFont(size: 22, weight: .semibold).textSelection(.enabled)
                Text(verbatim: note.subtitle).appFont(size: 13, weight: .regular).foregroundStyle(Theme.muted)
                Label {
                    Text("\(ownerName) paylaştı · salt okunur")
                } icon: {
                    Image(systemName: "person.2")
                }
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
            }
            if !note.summary.isEmpty {
                section(title: note.headings.summary) {
                    Text(verbatim: note.summary).appFont(size: 14, weight: .regular).textSelection(.enabled)
                }
            }
            if !note.outline.isEmpty {
                section(title: note.headings.outline) {
                    ForEach(Array(note.outline.enumerated()), id: \.offset) { (_: Int, item: SharedOutlineItem) in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(item.time)  \(item.title)").appFont(size: 14, weight: .medium)
                            Text(verbatim: item.summary).appFont(size: 13, weight: .regular).foregroundStyle(Theme.ink.opacity(0.85))
                        }
                    }
                }
            }
            bullets(title: note.headings.decisions, items: note.decisions)
            bullets(title: note.headings.openQuestions, items: note.openQuestions)
            if !note.tasks.isEmpty {
                section(title: note.headings.tasks) {
                    ForEach(Array(note.tasks.enumerated()), id: \.offset) { (_: Int, task: SharedTask) in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "circle").imageScale(.small).foregroundStyle(Theme.muted)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: task.description).appFont(size: 14, weight: .regular)
                                Text(verbatim: [task.owner, task.due].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .appFont(size: 12, weight: .regular)
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                    }
                }
            }
            if !note.glossary.isEmpty {
                section(title: note.headings.glossary) {
                    ForEach(Array(note.glossary.enumerated()), id: \.offset) { (_: Int, entry: SharedGlossaryEntry) in
                        Text(verbatim: "\(entry.term): \(entry.meaning)").appFont(size: 13, weight: .regular)
                    }
                }
            }
            if let transcript = note.transcript, !transcript.isEmpty {
                section(title: note.headings.transcript) {
                    ForEach(Array(transcript.enumerated()), id: \.offset) { (_: Int, paragraph: SharedTranscriptParagraph) in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(paragraph.time) · \(paragraph.speaker)").appFont(size: 11, weight: .medium).foregroundStyle(Theme.muted)
                            Text(verbatim: paragraph.text).appFont(size: 13, weight: .regular).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .environment(\.layoutDirection, note.rtl ? .rightToLeft : .leftToRight)
    }

    @ViewBuilder
    private func bullets(title: String, items: [String]) -> some View {
        if !items.isEmpty {
            section(title: title) {
                ForEach(Array(items.enumerated()), id: \.offset) { (_: Int, item: String) in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: "•").foregroundStyle(Theme.muted)
                        Text(verbatim: item).appFont(size: 14, weight: .regular).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title.uppercased()).tracking(DesignTokens.labelTracking).appFont(size: 11, weight: .semibold).foregroundStyle(Theme.muted)
            content()
        }
    }
}

// MARK: - Davetle katılma

/// Katılma ekranının durumu.
public enum SharedFolderJoinState: Equatable, Sendable {
    /// Bağlantı bekleniyor.
    case enterLink
    /// Davet bulundu: klasör ve paylaşan; `open` değilse neden katılınamayacağı.
    case preview(folderName: String, ownerName: String, state: String)
    /// Katıldı; sahibin cihazı ekleyince notlar görünür.
    case joined(folderName: String, ownerName: String)
}

/// Davet bağlantısıyla katılma: bağlantıyı yapıştır, klasörü ve paylaşanı gör, görünen adını yaz, katıl.
public struct SharedFolderJoinPanel: View {
    @Binding var link: String
    @Binding var displayName: String
    let state: SharedFolderJoinState
    let status: NoteSharePanelStatus
    let onLookUp: @MainActor () -> Void
    let onJoin: @MainActor () -> Void
    let onPaste: (@MainActor () -> Void)?

    public init(
        link: Binding<String>, displayName: Binding<String>, state: SharedFolderJoinState, status: NoteSharePanelStatus, onLookUp: @escaping @MainActor () -> Void,
        onJoin: @escaping @MainActor () -> Void, onPaste: (@MainActor () -> Void)?
    ) {
        _link = link
        _displayName = displayName
        self.state = state
        self.status = status
        self.onLookUp = onLookUp
        self.onJoin = onJoin
        self.onPaste = onPaste
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if os(macOS)
            Text("Biri seninle bir Gistsmith klasörü paylaştıysa sana bir davet bağlantısı gönderdi. Bağlantıyı buraya yapıştır; notlar uçtan uca şifrelidir, Gistsmith bile okuyamaz.")
                .appFont(size: 13, weight: .regular)
                .fixedSize(horizontal: false, vertical: true)
            #else
            Text("Sana gönderilen davet bağlantısını yapıştır.")
                .appFont(size: 13, weight: .regular)
            #endif
            HStack(spacing: 8) {
                SharedFolderTextField(placeholder: "Davet bağlantısı", text: $link)
                    .onSubmit(onLookUp)
                if let onPaste {
                    Button("Yapıştır", systemImage: "doc.on.clipboard", action: onPaste)
                        .buttonStyle(.pill)
                }
                Button("Daveti aç", action: onLookUp)
                    .buttonStyle(.pillPrimary)
                    .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || status == .working)
            }
            switch state {
            case .enterLink:
                EmptyView()
            case .preview(let folderName, let ownerName, let inviteState):
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(ownerName) “\(folderName)” klasörünü seninle paylaşıyor.")
                        .appFont(size: 14, weight: .medium)
                    switch inviteState {
                    case "open":
                        SharedFolderTextField(placeholder: "Görünen adın", text: $displayName)
                            .frame(maxWidth: 320)
                        Text("\(ownerName) bu adı görür.")
                            .appFont(size: 11, weight: .regular)
                            .foregroundStyle(Theme.muted)
                        Button("Katıl", systemImage: "person.badge.plus", action: onJoin)
                            .buttonStyle(.pillPrimary)
                            .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || status == .working)
                    case "accepted":
                        NoticeText("Bu davete zaten katıldın.", severity: .info)
                    case "own":
                        NoticeText("Bu senin klasörünün daveti.", severity: .info)
                    case "expired":
                        NoticeText("Bu davetin süresi dolmuş; klasörü paylaşandan yeni bir davet iste.", severity: .attention)
                    default:
                        NoticeText("Bu davet başka biri tarafından kullanılmış; klasörü paylaşandan yeni bir davet iste.", severity: .attention)
                    }
                }
                .padding(12)
                .background(Theme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
            case .joined(let folderName, let ownerName):
                NoticeText("“\(folderName)” klasörüne katıldın. Notlar, \(ownerName) Gistsmith'i bir sonraki açışında görünür.", severity: .info)
                    .appFont(size: 13, weight: .regular)
            }
            switch status {
            case .idle:
                EmptyView()
            case .working:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Bekle…").appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted)
                }
            case .failed(let message):
                NoticeText(message, severity: .error)
                    .appFont(size: 12, weight: .regular)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Metin alanı: boşken soluk renkli yer tutucu (macOS odaksız `prompt:`'u metin renginde çizer, yazılmış sanılır).
struct SharedFolderTextField: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        TextField(text: $text) {
            EmptyView()
        }
        .textFieldStyle(.roundedBorder)
        .appFont(size: 13, weight: .regular)
        .overlay(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder)
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .padding(.leading, 8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(Text(placeholder))
    }
}
