import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

// Mac'te paylaşılan klasörlerin uygulamaya bağlandığı yer (bkz. `SharedFolderCenter`): hesap yüklenince kurulur, uygulama
// öne gelince ve beş dakikada bir yenilenir (sahibin Mac'i katılanları ekler, notları yayımlar), toplantılar değişince
// kısa bir beklemeden sonra yeniden yayımlanır. Ekranlar: toplantılar sayfasında klasörün paylaşım kartı ve kenar
// çubuğundaki "Benimle paylaşılanlar" sayfası (açılır pencere yok).

/// Toplantılar değişince yayımlamadan önceki bekleme (düzenleme sürerken her tuşta yüklenmesin).
private let sharedFolderPublishDelaySeconds: Double = 20

/// Paylaşılan klasörlerin Mac uygulamasına bağları (menü çubuğu simgesine eklenir: ana pencere kapalıyken de çalışır).
struct SharedFolderMacBindings: ViewModifier {
    let model: AppModel
    @State private var publishTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onAppear {
                SharedFolderCenter.shared.attach(hooks: SharedFolderHooks(
                    records: { () -> [MeetingRecord] in model.meetings },
                    savedFolders: { () -> [String] in model.savedFolders },
                    ownerName: { () -> String in model.userName },
                    meetingsLoaded: { () -> Bool in model.meetingsLoaded }
                ))
            }
            .onChange(of: hostedSyncScopeKey(account: HostedAccount.shared), initial: true) { (_: HostedSyncScopeKey, scopeKey: HostedSyncScopeKey) in
                Task { await SharedFolderCenter.shared.update(scopeKey: scopeKey) }
            }
            .onChange(of: model.meetings) { (_: [MeetingRecord], _: [MeetingRecord]) in
                guard model.meetingsLoaded, !SharedFolderCenter.shared.owned.isEmpty else {
                    return
                }
                publishTask?.cancel()
                publishTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(sharedFolderPublishDelaySeconds))
                    guard !Task.isCancelled else {
                        return
                    }
                    await SharedFolderCenter.shared.refresh()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { (_: Notification) in
                SharedFolderCenter.shared.appBecameActive()
            }
    }
}

/// Toplantılar sayfasının sağında klasörün paylaşım kartı (klasör başlığındaki "Paylaş" ya da kenar çubuğundaki menü).
struct MacSharedFolderCard: View {
    let model: AppModel
    let folderName: String
    let onClose: @MainActor () -> Void
    @State private var center: SharedFolderCenter = .shared
    @State private var includeTranscript: Bool = false
    @State private var inviteLabel: String = ""

    var body: some View {
        let shared: OwnedSharedFolder? = center.ownedFolder(named: folderName)
        ScrollView {
            SharedFolderPanel(
                folderName: folderName,
                noteCount: meetingsInFolder(records: model.meetings, folder: folderName).filter { $0.note != nil && !$0.isSampleMeeting }.count,
                snapshot: shared.map { (owned: OwnedSharedFolder) -> SharedFolderOwnerSnapshot in
                    SharedFolderOwnerSnapshot(
                        includesTranscript: owned.includesTranscript, members: owned.members,
                        publishesHere: owned.publisherDevice == center.deviceID, publishProblem: center.publishProblems[owned.id]
                    )
                },
                includeTranscript: $includeTranscript, inviteLabel: $inviteLabel, status: center.status,
                inviteLink: center.lastInvite.flatMap { $0.folderID == shared?.id ? $0.link : nil }, ownerName: model.userName,
                onShare: { Task { await center.share(folderName: folderName, includeTranscript: includeTranscript) } },
                onInvite: {
                    guard let shared else {
                        return
                    }
                    let label: String = inviteLabel
                    inviteLabel = ""
                    Task { await center.invite(folderID: shared.id, label: label) }
                },
                onRemove: { (member: SharedFolderMemberView) in
                    guard let shared else {
                        return
                    }
                    Task { await center.remove(folderID: shared.id, member: member) }
                },
                onStop: {
                    guard let shared else {
                        return
                    }
                    Task { await center.stopSharing(folderID: shared.id) }
                },
                onPublishHere: {
                    guard let shared else {
                        return
                    }
                    Task { await center.publishHere(folderID: shared.id) }
                },
                onClose: onClose
            )
            .padding(18)
            .frame(maxWidth: 720, alignment: .leading)
            .cardSurface(cornerRadius: 16)
            .padding(DesignTokens.Spacing.l)
        }
        .task(id: folderName) { await center.refresh() }
    }
}

/// "Benimle paylaşılanlar" sayfası: davetle katılma, katıldığın klasörler, seçili klasörün notları ve salt okunur not.
struct MacSharedWithMePage: View {
    let router: MainWindowRouter
    @State private var center: SharedFolderCenter = .shared
    @State private var link: String = ""
    @State private var displayName: String = ""
    @State private var selectedNoteID: String?
    @State private var confirmingLeave: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SharedFolderJoinPanel(
                        link: $link, displayName: $displayName, state: center.joinState, status: center.joinStatus,
                        onLookUp: { Task { await center.lookUp(link: link) } },
                        onJoin: { Task { await center.join(displayName: displayName) } },
                        onPaste: {
                            if let pasted = pastedSharedFolderInvite() {
                                link = pasted
                                Task { await center.lookUp(link: pasted) }
                            }
                        }
                    )
                    .padding(14)
                    .cardSurface(cornerRadius: 14)
                    if case .failed(let message) = center.status {
                        NoticeText(message, severity: .error).appFont(size: 12, weight: .regular)
                    }
                    ForEach(center.joined) { (folder: JoinedSharedFolder) in
                        Button {
                            router.sharedFolderID = folder.id
                            selectedNoteID = nil
                        } label: {
                            SharedFolderRow(item: folder.summary)
                                .padding(10)
                                .background(router.sharedFolderID == folder.id ? Theme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.hoverPlain)
                    }
                    if center.joined.isEmpty {
                        QuietEmptyCard(symbol: "person.2", title: "Henüz seninle paylaşılan klasör yok", message: "Bir davet bağlantısı aldığında yukarıya yapıştır.")
                    }
                }
                .padding(DesignTokens.Spacing.l)
            }
            .frame(width: 360)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await openPendingInvite()
            await center.refresh()
        }
        // Sayfa açıkken gelen davet ve soğuk açılışta hesap hazır olunca bekleyen davet.
        .onChange(of: router.pendingInviteLink) { (_: String?, _: String?) in
            Task { await openPendingInvite() }
        }
        .onChange(of: center.hasAccount) { (_: Bool, _: Bool) in
            Task { await openPendingInvite() }
        }
    }

    /// Bekleyen davet bağlantısını hesap hazırsa açar (değilse hesap gelince açılır).
    private func openPendingInvite() async {
        guard center.hasAccount, let pending = router.pendingInviteLink else {
            return
        }
        router.pendingInviteLink = nil
        link = pending
        await center.lookUp(link: pending)
    }

    @ViewBuilder
    private var detail: some View {
        if let folder = center.joined.first(where: { $0.id == router.sharedFolderID }) {
            if folder.isWaitingForOwner {
                SharedFolderWaitingView(ownerName: folder.ownerName)
            } else if let note = folder.notes.first(where: { $0.itemID == selectedNoteID }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Button("Notlar", systemImage: "chevron.left") { selectedNoteID = nil }
                            .buttonStyle(.pill)
                        SharedNoteView(note: note.payload.note, ownerName: folder.ownerName)
                    }
                    .padding(DesignTokens.Spacing.l)
                }
            } else {
                notesList(folder: folder)
            }
        } else {
            QuietEmptyState(symbol: "folder.badge.person.crop", title: "Bir klasör seç", message: "Paylaşılan notlar burada salt okunur görünür.") { EmptyView() }
        }
    }

    private func notesList(folder: JoinedSharedFolder) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: folder.name).appFont(size: 20, weight: .semibold)
                        Text("\(folder.ownerName) paylaştı · uçtan uca şifreli").appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 8)
                    if confirmingLeave {
                        Button("Ayrıl", role: .destructive) {
                            confirmingLeave = false
                            router.sharedFolderID = nil
                            Task { await center.leave(folderID: folder.id) }
                        }
                        .buttonStyle(.pill)
                        Button("Vazgeç") { confirmingLeave = false }.buttonStyle(.pill)
                    } else {
                        Button("Klasörden ayrıl…", systemImage: "rectangle.portrait.and.arrow.right") { confirmingLeave = true }
                            .buttonStyle(.pill)
                    }
                }
                if folder.notes.isEmpty {
                    QuietEmptyCard(symbol: "doc.text", title: "Henüz not yok", message: "Paylaşan klasöre not eklediğinde burada görünür.")
                }
                ForEach(folder.notes, id: \.itemID) { (note: SharedFolderCachedItem) in
                    Button {
                        selectedNoteID = note.itemID
                    } label: {
                        SharedNoteRow(note: note)
                            .padding(12)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
                    }
                    .buttonStyle(.hoverPlain)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(DesignTokens.Spacing.l)
        }
    }
}
