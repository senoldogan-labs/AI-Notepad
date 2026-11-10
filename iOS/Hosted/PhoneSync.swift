import AINotepadCore
import AINotepadUI
import SwiftUI
import UIKit

// iPhone'da eşitlemenin uygulamaya bağlandığı yer ve Ayarlar'daki satırı (Mac'teki `HostedSyncMacBindings` ve
// `HostedSyncSettingsRow` ile aynı davranış; açıklama kısa, bkz. `HostedSyncCenter`).

/// Eşitlemenin iPhone uygulamasına bağları (kök görünüme eklenir): hesap yüklenince kurulur, değişiklikler kuyruğa girer,
/// öne gelince eşitlenir, geçişin yazdıkları yeniden okunur.
struct PhoneSyncBindings: ViewModifier {
    let account: HostedAccount
    let session: PhoneAccountSession
    @Environment(\.scenePhase) private var scenePhase: ScenePhase

    func body(content: Content) -> some View {
        let store: PhoneStore = session.store
        let ask: PhoneAsk = session.ask
        let recorder: PhoneRecorder = session.recorder
        content
            .onChange(of: hostedSyncScopeKey(account: account), initial: true) { (_: HostedSyncScopeKey, scopeKey: HostedSyncScopeKey) in
                HostedSyncCenter.shared.attach(hooks: HostedSyncHooks(
                    busyMeetingIDs: { () -> Set<String> in Set(store.meetingJobs.keys) },
                    recordingInProgress: { () -> Bool in recorder.phase != .idle },
                    applyReport: { (report: SyncPassReport) -> Void in applyPhoneSyncReport(report: report, store: store, ask: ask) }
                ))
                Task {
                    await HostedSyncCenter.shared.update(scopeKey: scopeKey)
                    // Kurulduğu andaki hâller taban olur (sonraki değişiklikler bunlarla karşılaştırılır).
                    if store.isLoaded {
                        HostedSyncCenter.shared.observe(meetings: store.meetings)
                    }
                    HostedSyncCenter.shared.observe(chats: ask.conversations)
                    HostedSyncCenter.shared.observe(people: store.peopleBook)
                    HostedSyncCenter.shared.observePrefs()
                }
            }
            .onChange(of: store.meetings) { (_: [MeetingRecord], meetings: [MeetingRecord]) in
                // Diskten ilk okuma bitmeden boş liste taban olmasın (yoksa her açılışta her toplantı yeniden denetlenirdi).
                if store.isLoaded {
                    HostedSyncCenter.shared.observe(meetings: meetings)
                }
            }
            .onChange(of: ask.conversations) { (_: [AskConversation], chats: [AskConversation]) in
                HostedSyncCenter.shared.observe(chats: chats)
            }
            .onChange(of: store.peopleBook) { (_: PeopleBook, book: PeopleBook) in
                HostedSyncCenter.shared.observe(people: book)
            }
            .onChange(of: store.savedFolders) { (_: [String], _: [String]) in
                HostedSyncCenter.shared.observePrefs()
            }
            .onChange(of: ask.userRecipes) { (_: [Recipe], _: [Recipe]) in
                HostedSyncCenter.shared.observePrefs()
            }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)) { (_: Notification) in
                HostedSyncCenter.shared.observePrefs()
            }
            .onChange(of: scenePhase) { (_: ScenePhase, phase: ScenePhase) in
                if phase == .active {
                    HostedSyncCenter.shared.appBecameActive()
                }
            }
            .onChange(of: HostedSyncCenter.shared.meetingsRecordedElsewhere, initial: true) { (_: Set<String>, ids: Set<String>) in
                store.meetingsRecordedElsewhere = ids
            }
    }
}

/// Eşitleme bu iPhone'da bir şey yazdı ya da sildi: değişenler diskten yeniden okunur; iki cihazda aynı satırları
/// düzenlenen kendi notların söylenir (iki sürüm de notta kalır).
@MainActor
private func applyPhoneSyncReport(report: SyncPassReport, store: PhoneStore, ask: PhoneAsk) {
    if !report.changedMeetingIDs.isEmpty {
        store.reload()
    }
    if !report.changedChatIDs.isEmpty {
        ask.loadHistory()
    }
    if report.peopleChanged {
        store.loadPeople()
    }
    if report.prefsChanged {
        store.loadFolders()
        ask.loadRecipes()
    }
    if !report.myNotesConflictMeetingIDs.isEmpty {
        store.reportSyncNotice(message: String(localized: "Kendi notların iki cihazda düzenlendi; iki sürüm de notta duruyor."))
    }
}

/// Ayarlar'daki "Mac ile iPhone arasında eşitle" bölümü: aç/kapat, durum, hata ve yeniden dene, bağlantı kodu ve başka
/// cihaz açtıysa kod girişi. Sunucu eşitlemeyi sunmuyorsa (ve bu iPhone'da açık değilse) görünmez. Kapatma satır içinde
/// onaylanır.
struct PhoneSyncSection: View {
    @State private var center: HostedSyncCenter = .shared
    @State private var confirmingOff: Bool = false
    @State private var showsCode: Bool = false
    /// Bağlantı kodu az önce kopyalandı: düğme kısa süre "Kopyalandı" der.
    @State private var codeCopied: Bool = false
    @State private var codeText: String = ""

    var body: some View {
        Group {
            if center.availability == .available || center.isOn {
                section
            }
        }
        .task {
            if center.availability != .available {
                await center.refreshAvailability()
            }
        }
    }

    private var section: some View {
        Section {
            Toggle(isOn: Binding<Bool>(
                get: { center.isOn },
                set: { (enabled: Bool) -> Void in
                    if enabled {
                        Task { await center.turnOn() }
                    } else if center.status == .needsLinkCode {
                        center.cancelJoin()
                    } else {
                        confirmingOff = true
                    }
                }
            )) {
                PhoneSettingLabel(icon: "arrow.triangle.2.circlepath", title: Text("Mac ile iPhone arasında eşitle"))
            }
            .disabled(center.isChangingSetup || confirmingOff)
            status
            if confirmingOff {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sunucudaki şifreli kopya silinir, diğer cihazlarda da eşitleme durur. Toplantıların cihazlarda kalır.")
                        .appFont(size: 13, weight: .regular)
                    HStack {
                        Button("Vazgeç") { confirmingOff = false }
                            .buttonStyle(.borderless)
                        Spacer()
                        Button("Eşitlemeyi kapat", role: .destructive) {
                            confirmingOff = false
                            Task { await center.turnOff() }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            if center.status == .needsLinkCode {
                TextField("Bağlantı kodu", text: $codeText, prompt: Text("XXXX-XXXX-…"))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .appMonoFont(size: 15, weight: .regular)
                Button("Katıl") {
                    Task {
                        if await center.join(codeText: codeText) {
                            codeText = ""
                        }
                    }
                }
                .disabled(center.isChangingSetup || codeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else if center.isOn, let code = center.linkCode {
                if showsCode {
                    Text(verbatim: code)
                        .appMonoFont(size: 15, weight: .regular)
                        .textSelection(.enabled)
                    Button(codeCopied ? LocalizedStringKey("Kopyalandı") : LocalizedStringKey("Kopyala")) {
                        UIPasteboard.general.string = code
                        codeCopied = true
                    }
                    .sensoryFeedback(.success, trigger: codeCopied) { (_: Bool, new: Bool) -> Bool in new }
                    .task(id: codeCopied) {
                        guard codeCopied else {
                            return
                        }
                        do {
                            try await Task.sleep(for: .seconds(2))
                        } catch {
                            return
                        }
                        codeCopied = false
                    }
                    Button("Kodu gizle") { showsCode = false }
                } else {
                    Button("Bağlantı kodunu göster") { showsCode = true }
                }
            }
            if let notice = center.notice {
                NoticeText(notice, severity: .attention)
            }
            if let error = center.setupError {
                NoticeText(error, severity: .error)
            }
        } header: {
            PhoneSecondaryText {
                Text("Eşitleme")
            }
        } footer: {
            PhoneSecondaryText {
                Text("Notlar, metinler, görevler, kişiler ve Sor sohbetleri şifreli olarak Mac'inle eşitlenir; ses bu iPhone'da kalır. Diğer cihaz bu kodla katılır; kodu sakla.")
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch center.status {
        case .off:
            EmptyView()
        case .working:
            Text("Eşitleniyor…").foregroundStyle(Theme.muted)
        case .synced:
            HStack {
                if let lastSyncedAt = center.lastSyncedAt {
                    Text("Son eşitleme: \(lastSyncedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale())))").foregroundStyle(Theme.muted)
                }
                Spacer()
                Button("Şimdi eşitle") { center.syncNow() }
                    .buttonStyle(.borderless)
            }
        case .needsLinkCode:
            Text("Eşitlemeyi başka bir cihaz açtı. O cihazın Ayarlar'ındaki bağlantı kodunu yaz.")
                .foregroundStyle(Theme.muted)
        case .failed(let message, _):
            NoticeText(message, severity: .attention)
            Button("Yeniden dene") { center.syncNow() }
        }
    }
}
