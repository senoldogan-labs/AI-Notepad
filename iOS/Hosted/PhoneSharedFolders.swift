import AINotepadCore
import AINotepadUI
import SwiftUI

// iPhone'da paylaşılan klasörler (Mac'teki `SharedFolderMacBindings`, `MacSharedFolderCard` ve `MacSharedWithMePage` ile
// aynı davranış; açıklamalar kısa). Durum ve işler `SharedFolderCenter`'da (App/Hosted, Mac'le ortak).

/// Paylaşılan klasörlerin iPhone uygulamasına bağları (kök görünüme eklenir): hesap yüklenince kurulur, öne gelince
/// yenilenir (sahibin iPhone'u katılanları ekler, notları yayımlar). Tanıtım modunda sunucuya gitmeden örnek gösterir.
struct PhoneSharedFolderBindings: ViewModifier {
    let account: HostedAccount
    let session: PhoneAccountSession
    @Environment(\.scenePhase) private var scenePhase: ScenePhase

    func body(content: Content) -> some View {
        let store: PhoneStore = session.store
        content
            .onChange(of: hostedSyncScopeKey(account: account), initial: true) { (_: HostedSyncScopeKey, scopeKey: HostedSyncScopeKey) in
                SharedFolderCenter.shared.attach(hooks: SharedFolderHooks(
                    records: { () -> [MeetingRecord] in store.meetings },
                    savedFolders: { () -> [String] in store.savedFolders },
                    ownerName: { () -> String in store.userName },
                    meetingsLoaded: { () -> Bool in store.isLoaded }
                ))
                #if DEBUG
                if isDemoMode {
                    showDemoSharedFolders()
                    return
                }
                #endif
                Task { await SharedFolderCenter.shared.update(scopeKey: scopeKey) }
            }
            .onChange(of: scenePhase) { (_: ScenePhase, phase: ScenePhase) in
                #if DEBUG
                if isDemoMode {
                    return
                }
                #endif
                if phase == .active {
                    SharedFolderCenter.shared.appBecameActive()
                }
            }
    }
}

/// Klasörün paylaşım sayfası (kitaplıkta klasör açıkken "Paylaş"): Mac'teki kartla aynı panel.
struct PhoneShareFolderScreen: View {
    let folderName: String
    let store: PhoneStore
    @State private var center: SharedFolderCenter = .shared
    @State private var includeTranscript: Bool = false
    @State private var inviteLabel: String = ""

    var body: some View {
        let shared: OwnedSharedFolder? = center.ownedFolder(named: folderName)
        ScrollView {
            SharedFolderPanel(
                folderName: folderName,
                noteCount: meetingsInFolder(records: store.meetings, folder: folderName).filter { $0.note != nil && !$0.isSampleMeeting }.count,
                snapshot: shared.map { (owned: OwnedSharedFolder) -> SharedFolderOwnerSnapshot in
                    SharedFolderOwnerSnapshot(includesTranscript: owned.includesTranscript, members: owned.members, publishesHere: owned.publisherDevice == center.deviceID, publishProblem: center.publishProblems[owned.id])
                },
                includeTranscript: $includeTranscript, inviteLabel: $inviteLabel, status: center.status,
                inviteLink: center.lastInvite.flatMap { $0.folderID == shared?.id ? $0.link : nil }, ownerName: store.userName,
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
                onClose: nil
            )
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Klasörü paylaş")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: folderName) {
            #if DEBUG
            if isDemoMode {
                return
            }
            #endif
            await center.refresh()
        }
    }
}

/// "Benimle paylaşılanlar": davetle katılma ve katıldığın klasörler.
struct PhoneSharedWithMeScreen: View {
    let router: PhoneRouter
    @State private var center: SharedFolderCenter = .shared
    @State private var link: String = ""
    @State private var displayName: String = ""

    var body: some View {
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
                        router.push(route: .sharedFolder(folder.id))
                    } label: {
                        SharedFolderRow(item: folder.summary)
                            .padding(12)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                if center.joined.isEmpty {
                    QuietEmptyCard(symbol: "person.2", title: "Henüz seninle paylaşılan klasör yok", message: "Davet bağlantısını yukarıya yapıştır.")
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Benimle paylaşılanlar")
        // Sayfa açıkken gelen davet ve soğuk açılışta hesap hazır olunca bekleyen davet (Mac'teki gibi).
        .onChange(of: center.pendingInviteLink) { (_: String?, _: String?) in
            Task { await openPendingInvite() }
        }
        .onChange(of: center.hasAccount) { (_: Bool, _: Bool) in
            Task { await openPendingInvite() }
        }
        .task {
            await openPendingInvite()
            #if DEBUG
            if isDemoMode {
                return
            }
            #endif
            await center.refresh()
        }
    }
}

extension PhoneSharedWithMeScreen {
    /// Bekleyen davet bağlantısını hesap hazırsa açar (değilse hesap gelince açılır).
    fileprivate func openPendingInvite() async {
        guard center.hasAccount, let pending = center.pendingInviteLink else {
            return
        }
        center.pendingInviteLink = nil
        link = pending
        await center.lookUp(link: pending)
    }
}

/// Katıldığın bir klasörün notları.
struct PhoneSharedFolderScreen: View {
    let folderID: String
    let router: PhoneRouter
    @State private var center: SharedFolderCenter = .shared
    @State private var confirmingLeave: Bool = false
    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        Group {
            if let folder = center.joined.first(where: { $0.id == folderID }) {
                if folder.isWaitingForOwner {
                    SharedFolderWaitingView(ownerName: folder.ownerName)
                } else {
                    notes(folder: folder)
                }
            } else {
                PhoneEmptyState(symbol: "folder", title: "Klasör artık paylaşılmıyor", message: "Paylaşan klasörü durdurmuş ya da seni çıkarmış olabilir.") {
                    EmptyView()
                }
            }
        }
        .background(Theme.background)
        .navigationTitle(center.joined.first(where: { $0.id == folderID })?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Klasörden ayrıl", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmingLeave = true }
                } label: {
                    Label("Diğer", systemImage: "ellipsis")
                }
            }
        }
        .confirmationDialog(Text("Klasörden ayrılınsın mı?"), isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button("Ayrıl", role: .destructive) {
                dismiss()
                Task { await center.leave(folderID: folderID) }
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Notlar bu iPhone'dan silinir; yeniden katılmak için yeni davet gerekir.")
        }
    }

    private func notes(folder: JoinedSharedFolder) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text("\(folder.ownerName) paylaştı · uçtan uca şifreli")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                if folder.notes.isEmpty {
                    QuietEmptyCard(symbol: "doc.text", title: "Henüz not yok", message: "Paylaşan klasöre not eklediğinde burada görünür.")
                }
                ForEach(folder.notes, id: \.itemID) { (note: SharedFolderCachedItem) in
                    Button {
                        router.push(route: .sharedNote(folderID: folder.id, itemID: note.itemID))
                    } label: {
                        SharedNoteRow(note: note)
                            .padding(12)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
    }
}

/// Paylaşılan bir not (salt okunur).
struct PhoneSharedNoteScreen: View {
    let folderID: String
    let itemID: String
    @State private var center: SharedFolderCenter = .shared

    var body: some View {
        let folder: JoinedSharedFolder? = center.joined.first { $0.id == folderID }
        Group {
            if let folder, let note = folder.notes.first(where: { $0.itemID == itemID }) {
                ScrollView {
                    SharedNoteView(note: note.payload.note, ownerName: folder.ownerName)
                        .padding(16)
                }
            } else {
                PhoneEmptyState(symbol: "doc.questionmark", title: "Not bulunamadı", message: "Paylaşan notu klasörden çıkarmış olabilir.") {
                    EmptyView()
                }
            }
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
/// Tanıtım modunun örnek paylaşılan klasörleri (görsel kontrol; sunucuya gidilmez).
@MainActor
private func showDemoSharedFolders() {
    let device: String = "demo-device"
    let members: [SharedFolderMemberView] = [
        SharedFolderMemberView(memberID: "m1", state: .active, label: "mehmet@example.com", displayName: "Mehmet", expiresAt: Date().addingTimeInterval(86_400 * 30)),
        SharedFolderMemberView(memberID: "m2", state: .accepted, label: "aino@example.com", displayName: "Aino", expiresAt: Date().addingTimeInterval(86_400 * 30)),
        SharedFolderMemberView(memberID: "m3", state: .invited, label: "sara@example.com", displayName: nil, expiresAt: Date().addingTimeInterval(86_400 * 7)),
    ]
    // Örnek not JSON'dan (yükün kurucuları çekirdeğe özel); bozulursa tanıtım açıkça durur.
    let json: String = """
    {"v":1,"lang":"en","rtl":false,"title":"Q4 launch plan","subtitle":"November 6, 2026 10:00 · 32 min",
     "headings":{"summary":"Summary","outline":"Topics","decisions":"Decisions","openQuestions":"Open questions","tasks":"Tasks","glossary":"Glossary","transcript":"Transcript"},
     "summary":"The team agreed to launch the iPhone app on December 1 and to put the pricing page live a week earlier.",
     "outline":[{"time":"00:00","title":"Launch date","summary":"December 1 for iPhone; the Mac app follows with 0.3."}],
     "decisions":["Launch on December 1.","Pricing page goes live on November 24."],"openQuestions":["Do we need a press kit?"],
     "tasks":[{"owner":"Mehmet","description":"Prepare App Store screenshots","due":"Nov 20"},{"owner":"Aino","description":"Draft the launch post","due":null}],
     "glossary":[]}
    """
    let note: SharedNotePayload
    do {
        note = try JSONDecoder().decode(SharedNotePayload.self, from: Data(json.utf8))
    } catch {
        preconditionFailure("Tanıtımın örnek notu okunamadı: \(error)")
    }
    SharedFolderCenter.shared.showDemo(
        owned: [OwnedSharedFolder(id: "demo-owned", name: "Product", includesTranscript: false, members: members, publisherDevice: device)],
        joined: [
            JoinedSharedFolder(
                id: "demo-joined", name: "Sales weekly", ownerName: "Ayşe", isWaitingForOwner: false,
                notes: [SharedFolderCachedItem(itemID: "demo-note", tag: "0", payload: SharedFolderItemPayload(startedAt: Date().addingTimeInterval(-86_400 * 2), note: note))]
            ),
            JoinedSharedFolder(id: "demo-waiting", name: "Design reviews", ownerName: "Jonas", isWaitingForOwner: true, notes: []),
        ],
        deviceID: device
    )
}
#endif
