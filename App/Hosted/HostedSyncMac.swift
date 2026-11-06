import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI

// Mac'te eşitlemenin uygulamaya bağlandığı yer (bkz. `HostedSyncCenter`): hesap yüklenince kurulur, toplantı, Sor, kişi
// ve tercih değişiklikleri kuyruğa girer, uygulama öne gelince eşitlenir, geçişin yazdıkları yeniden okunur.

extension AppModel {
    /// Uzun not işi süren ya da kayıttaki toplantılar (eşitleme gelen değişiklikleri iş bitene dek bekletir).
    var syncBusyMeetingIDs: Set<String> {
        processingMeetingIDs.union([activeMeetingID, handingOffMeetingID].compactMap { $0 })
    }

    /// Eşitleme bu Mac'te bir şey yazdı ya da sildi: değişenler diskten yeniden okunur; iki cihazda aynı satırları
    /// düzenlenen kendi notların söylenir (iki sürüm de notta kalır).
    func applySyncReport(report: SyncPassReport) {
        if !report.changedMeetingIDs.isEmpty {
            reloadMeetings()
        }
        if !report.changedChatIDs.isEmpty {
            loadAskHistory()
        }
        if report.peopleChanged {
            loadPeople()
        }
        if report.prefsChanged {
            loadFolders()
            loadRecipes()
        }
        if !report.myNotesConflictMeetingIDs.isEmpty {
            ToastCenter.shared.show(
                kind: .info, title: String(localized: "Kendi notların iki cihazda düzenlendi; iki sürüm de notta duruyor."), detail: nil, action: nil
            )
        }
    }
}

/// Eşitlemenin Mac uygulamasına bağları (menü çubuğu simgesine eklenir: ana pencere kapalıyken de çalışır).
struct HostedSyncMacBindings: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content
            .onAppear {
                HostedSyncCenter.shared.attach(hooks: HostedSyncHooks(
                    busyMeetingIDs: { () -> Set<String> in model.syncBusyMeetingIDs },
                    recordingInProgress: { () -> Bool in model.isRecording },
                    applyReport: { (report: SyncPassReport) -> Void in model.applySyncReport(report: report) }
                ))
            }
            .onChange(of: hostedSyncScopeKey(account: HostedAccount.shared), initial: true) { (_: HostedSyncScopeKey, scopeKey: HostedSyncScopeKey) in
                Task {
                    await HostedSyncCenter.shared.update(scopeKey: scopeKey)
                    // Kurulduğu andaki hâller taban olur (sonraki değişiklikler bunlarla karşılaştırılır).
                    if model.meetingsLoaded {
                        HostedSyncCenter.shared.observe(meetings: model.meetings)
                    }
                    HostedSyncCenter.shared.observe(chats: model.askConversations)
                    HostedSyncCenter.shared.observe(people: model.peopleBook)
                    HostedSyncCenter.shared.observePrefs()
                }
            }
            .onChange(of: model.meetings) { (_: [MeetingRecord], meetings: [MeetingRecord]) in
                // Diskten ilk okuma bitmeden boş liste taban olmasın (yoksa her açılışta her toplantı yeniden denetlenirdi).
                if model.meetingsLoaded {
                    HostedSyncCenter.shared.observe(meetings: meetings)
                }
            }
            .onChange(of: model.askConversations) { (_: [AskConversation], chats: [AskConversation]) in
                HostedSyncCenter.shared.observe(chats: chats)
            }
            .onChange(of: model.peopleBook) { (_: PeopleBook, book: PeopleBook) in
                HostedSyncCenter.shared.observe(people: book)
            }
            .onChange(of: model.savedFolders) { (_: [String], _: [String]) in
                HostedSyncCenter.shared.observePrefs()
            }
            .onChange(of: model.userRecipes) { (_: [Recipe], _: [Recipe]) in
                HostedSyncCenter.shared.observePrefs()
            }
            // Hesapla eşitlenen ayarlar değişti (değişiklik anları `recordHostedSyncedSettingChanges` ile yazılır).
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)) { (_: Notification) in
                HostedSyncCenter.shared.observePrefs()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { (_: Notification) in
                HostedSyncCenter.shared.appBecameActive()
            }
            .onChange(of: HostedSyncCenter.shared.meetingsRecordedElsewhere, initial: true) { (_: Set<String>, ids: Set<String>) in
                model.meetingsRecordedElsewhere = ids
            }
    }
}

/// Ayarlar › Hesap'taki "Mac ile iPhone arasında eşitle" satırı: aç/kapat, durum (son eşitleme, hata ve yeniden dene),
/// iPhone'un katılacağı bağlantı kodu ve başka cihaz açtıysa kod girişi. Sunucu eşitlemeyi sunmuyorsa (ve bu Mac'te
/// açık değilse) görünmez. Kapatma satır içinde onaylanır (açılır pencere yok).
struct HostedSyncSettingsRow: View {
    @State private var center: HostedSyncCenter = .shared
    @State private var confirmingOff: Bool = false
    @State private var showsCode: Bool = false
    @State private var codeText: String = ""

    var body: some View {
        Group {
            if center.availability == .available || center.isOn {
                rows
            }
        }
        // Ayarlar açılınca sunucunun eşitlemeyi sunup sunmadığı yeniden sorulur (açılışta çevrimdışı olabilir).
        .task {
            if center.availability != .available {
                await center.refreshAvailability()
            }
        }
    }

    @ViewBuilder
    private var rows: some View {
            SettingsRow(title: Text("Mac ile iPhone arasında eşitle")) {
                Text("Toplantı metinleri, notlar, görevler, kişiler ve Sor sohbetleri aynı hesapla giriş yaptığın Mac ve iPhone'da görünür. Her şey bu Mac'te şifrelenir; sunucumuz (AB'de) yalnızca okuyamadığı şifreli kopyayı saklar. Ses ve ekran görüntüleri kaydedildiği cihazda kalır.")
                status
                if let notice = center.notice {
                    NoticeText(notice, severity: .attention)
                }
                if let error = center.setupError {
                    NoticeText(error, severity: .error)
                }
                if confirmingOff {
                    NoticeText("Kapatınca sunucudaki şifreli kopya silinir ve diğer cihazlarında da eşitleme durur. Toplantıların her cihazda yerinde kalır.", severity: .attention)
                }
            } control: {
                control
            }
            if center.status == .needsLinkCode {
                linkCodeEntry
            } else if center.isOn, let code = center.linkCode {
                linkCodeRow(code: code)
            }
    }

    @ViewBuilder
    private var status: some View {
        switch center.status {
        case .off:
            EmptyView()
        case .working:
            Text("Eşitleniyor…").foregroundStyle(Theme.ink)
        case .synced:
            if let lastSyncedAt = center.lastSyncedAt {
                Text("Son eşitleme: \(lastSyncedAt.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(Theme.ink)
            }
        case .needsLinkCode:
            Text("Bu hesapta eşitlemeyi başka bir cihaz açtı. Katılmak için o cihazda Ayarlar'da gösterilen bağlantı kodunu aşağıya yaz.")
                .foregroundStyle(Theme.ink)
        case .failed(let message, let retryAt):
            NoticeText(message, severity: .attention)
            if let retryAt {
                Text("Kendiliğinden yeniden denenecek: \(retryAt.formatted(date: .omitted, time: .shortened))")
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        HStack(spacing: 8) {
            if case .failed = center.status {
                Button("Yeniden dene") { center.syncNow() }
                    .disabled(center.isChangingSetup)
            } else if center.status == .synced {
                Button("Şimdi eşitle") { center.syncNow() }
                    .disabled(center.isChangingSetup)
            }
            if confirmingOff {
                Button("Vazgeç") { confirmingOff = false }
                Button("Eşitlemeyi kapat", role: .destructive) {
                    confirmingOff = false
                    Task { await center.turnOff() }
                }
                .disabled(center.isChangingSetup)
            } else {
                Toggle("Mac ile iPhone arasında eşitle", isOn: Binding<Bool>(
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
                ))
                .settingsToggle()
                .disabled(center.isChangingSetup)
            }
        }
    }

    private var linkCodeEntry: some View {
        SettingsRow(title: Text("Bağlantı kodu")) {
            Text("Diğer cihazda Ayarlar › Mac ile iPhone arasında eşitle altında gösterilen 32 karakterlik kod.")
        } control: {
            HStack(spacing: 8) {
                TextField("XXXX-XXXX-…", text: $codeText)
                    .settingsField(width: 260)
                    .autocorrectionDisabled()
                Button("Katıl") {
                    Task {
                        if await center.join(codeText: codeText) {
                            codeText = ""
                        }
                    }
                }
                .disabled(center.isChangingSetup || codeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func linkCodeRow(code: String) -> some View {
        SettingsRow(title: Text("Diğer cihazın için bağlantı kodu")) {
            Text("iPhone'da eşitlemeyi açınca bu kodu yaz. Kodu güvenli bir yerde sakla: bütün cihazlarını kaybedersen eşitlenen kopyayı yalnızca bu kod açar; biz göremeyiz ve sıfırlayamayız.")
            if showsCode {
                Text(verbatim: code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
            }
        } control: {
            HStack(spacing: 8) {
                if showsCode {
                    Button("Kopyala") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                    Button("Gizle") { showsCode = false }
                } else {
                    Button("Kodu göster") { showsCode = true }
                }
            }
        }
    }
}
