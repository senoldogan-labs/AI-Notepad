import AINotepadCore
import AINotepadUI
import Foundation
import Observation
import os
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private let sharedFoldersLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "SharedFolders")

// Paylaşılan klasörlerin uygulama tarafı (Mac'teki Gistsmith ve iPhone ortak; tasarım
// docs/superpowers/specs/2026-11-08-shared-folders.md). Sunucunun `SHARED_FOLDERS_POLICY` anahtarının arkasındadır:
// sunucu kapalı derse hiçbir giriş görünmez (ve önbellekler silinmez). Bütün şifreleme ve kararlar çekirdekte
// (`SharedFolderService`); burada hesap kapsamı, cihazdaki defter, yenileme zamanlaması ve ekranların durumu var.

/// Uygulamanın paylaşılan klasörlere verdiği bağlantılar.
struct SharedFolderHooks {
    /// Bu cihazdaki toplantılar (yayımlanacak notlar; örnek toplantı çekirdekte dışarıda kalır).
    let records: @MainActor () -> [MeetingRecord]
    /// Kayıtlı klasörler (toplantısız klasörler dahil).
    let savedFolders: @MainActor () -> [String]
    /// Paylaşanın görünen adı (Profil'deki ad).
    let ownerName: @MainActor () -> String
    /// Toplantılar diskten okundu: okunmadan yayımlanırsa boş liste yayımlanmış notları sildirirdi.
    let meetingsLoaded: @MainActor () -> Bool
}

/// Sahibin bir klasörü (ekranların gördüğü hâli).
struct OwnedSharedFolder: Identifiable, Equatable {
    let id: String
    let name: String
    let includesTranscript: Bool
    let members: [SharedFolderMemberView]
    /// Notları yayımlayan cihazın kimliği.
    let publisherDevice: String?

    init(folder: OpenedSharedFolder, members: [SharedFolderMemberView]) {
        id = folder.folderID
        name = folder.folderName
        includesTranscript = folder.meta?.includeTranscript ?? false
        self.members = members
        publisherDevice = folder.remote.publisherDevice
    }

    init(id: String, name: String, includesTranscript: Bool, members: [SharedFolderMemberView], publisherDevice: String?) {
        self.id = id
        self.name = name
        self.includesTranscript = includesTranscript
        self.members = members
        self.publisherDevice = publisherDevice
    }
}

/// Üyenin bir klasörü (ekranların gördüğü hâli) ve önbellekteki notları.
struct JoinedSharedFolder: Identifiable, Equatable {
    let id: String
    let name: String
    let ownerName: String
    /// Sahibin cihazının üyeyi eklemesi bekleniyor.
    let isWaitingForOwner: Bool
    let notes: [SharedFolderCachedItem]

    init(folder: OpenedSharedFolder, notes: [SharedFolderCachedItem]) {
        id = folder.folderID
        name = folder.folderName
        ownerName = folder.ownerName
        isWaitingForOwner = folder.isWaitingForOwner
        self.notes = notes
    }

    init(id: String, name: String, ownerName: String, isWaitingForOwner: Bool, notes: [SharedFolderCachedItem]) {
        self.id = id
        self.name = name
        self.ownerName = ownerName
        self.isWaitingForOwner = isWaitingForOwner
        self.notes = notes
    }

    var summary: SharedFolderSummaryItem {
        SharedFolderSummaryItem(folderID: id, name: name, ownerName: ownerName, noteCount: isWaitingForOwner ? nil : notes.count)
    }
}

/// Sunucunun paylaşılan klasörleri sunup sunmadığı (`SHARED_FOLDERS_POLICY`).
enum SharedFoldersAvailability: Equatable {
    case unknown
    case available
    case unavailable
}

/// Mac'te ön planda kendiliğinden yenileme aralığı (sahibin cihazı katılanları bu sürede ekler).
private let sharedFoldersPeriodSeconds: Double = 300

/// Yüklü hesabın paylaşılan klasörleri. Tek örnek; hesap değişince ya da çıkışta sıfırlanır.
@MainActor
@Observable
final class SharedFolderCenter {
    static let shared: SharedFolderCenter = SharedFolderCenter()

    private(set) var availability: SharedFoldersAvailability = .unknown
    private(set) var owned: [OwnedSharedFolder] = []
    private(set) var joined: [JoinedSharedFolder] = []
    /// Sahibin panelindeki ve listelerdeki son işin durumu.
    private(set) var status: NoteSharePanelStatus = .idle
    /// Az önce oluşturulan davet (klasör kimliği ve bağlantı).
    private(set) var lastInvite: (folderID: String, link: URL)?
    private(set) var joinState: SharedFolderJoinState = .enterLink
    private(set) var joinStatus: NoteSharePanelStatus = .idle
    /// Bu cihazın yayıncı kimliği (panel "Buradan yayımla"yı buna göre gösterir).
    private(set) var deviceID: String?

    @ObservationIgnored private var hooks: SharedFolderHooks?
    @ObservationIgnored private var scope: (accountKey: String, userID: String)?
    @ObservationIgnored private var identity: SharingIdentity?
    /// Tohumun en son mühürlendiği eşitleme anahtarının kimliği (nil: eşitleme kapalıyken kuruldu).
    @ObservationIgnored private var identitySealedKeyID: String?
    /// Hesap kapsamı hazır (davet bağlantısı ancak o zaman açılır).
    private(set) var hasAccount: Bool = false
    @ObservationIgnored private var lookup: SharedFolderInviteLookup?
    /// Süren yenileme ve hesap kuşağı (`generation`); başka hesabın süren yenilemesi yenisini bekletmez.
    @ObservationIgnored private var refreshTask: (generation: Int, task: Task<Void, Never>)?
    /// Yenileme sürerken yeni bir yenileme istendi (ör. bir işlemden sonra): süren bitince bir tur daha yapılır.
    @ObservationIgnored private var refreshAgain: Bool = false
    /// Klasör kimliği → son yayımlamanın sorunu (abonelik yok, not fazla uzun, sınır doldu…); panel gösterir. Klasör
    /// yine listede ve yönetilebilir kalır.
    private(set) var publishProblems: [String: String] = [:]
    @ObservationIgnored private var lastRefreshAt: Date?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    /// Her hesap değişiminde artar: eski hesabın geç gelen sonucu yenisinin durumunu yazmaz.
    @ObservationIgnored private var generation: Int = 0

    private init() {}

    var isAvailable: Bool { availability == .available }

    func attach(hooks newHooks: SharedFolderHooks) {
        hooks = newHooks
    }

    /// Hesap durumu değişti: yüklü hesap için yenilenir, değilse her şey sıfırlanır (eşitlemedeki kapsamla aynı kural).
    func update(scopeKey: HostedSyncScopeKey) async {
        let next: (accountKey: String, userID: String)?
        if let loaded = scopeKey.loadedAccountKey, let userID = scopeKey.signedInUserID, accountDataKey(userId: userID) == loaded {
            next = (loaded, userID)
        } else {
            next = nil
        }
        guard next?.accountKey != scope?.accountKey || next?.userID != scope?.userID else {
            return
        }
        // Başka bir hesaba geçişte önceki hesaba gelen davet de düşer; soğuk açılışta (önce hesap yok) bağlantı kalır.
        if scope != nil {
            pendingInviteLink = nil
        }
        generation += 1
        scope = next
        hasAccount = next != nil
        identity = nil
        identitySealedKeyID = nil
        publishProblems = [:]
        deviceID = nil
        lookup = nil
        owned = []
        joined = []
        lastInvite = nil
        joinState = .enterLink
        status = .idle
        availability = .unknown
        periodicTask?.cancel()
        periodicTask = nil
        guard next != nil else {
            return
        }
        await refresh()
        #if os(macOS)
        startPeriodicRefresh()
        #endif
    }

    #if os(macOS)
    private func startPeriodicRefresh() {
        periodicTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(sharedFoldersPeriodSeconds))
                guard !Task.isCancelled else {
                    return
                }
                await self?.refresh()
            }
        }
    }
    #endif

    /// Uygulama öne geldi: son yenilemeden bir dakika geçtiyse yenilenir (sahibin cihazı katılanları ekler).
    func appBecameActive() {
        if let lastRefreshAt, Date().timeIntervalSince(lastRefreshAt) < 60 {
            return
        }
        Task { await refresh() }
    }

    /// Bir klasör paylaşımda mı (sahibi bu hesap).
    func ownedFolder(named name: String) -> OwnedSharedFolder? {
        owned.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Paylaşılan klasörlerin adları (kenar çubuğundaki işaret ve "Klasöre taşı" menüsündeki uyarı için).
    var sharedFolderNames: Set<String> {
        Set(owned.map { $0.name.lowercased() })
    }

    /// Dışarıdan gelen davet bağlantısı (iPhone: `gistsmith://join#…` ya da evrensel bağlantı): katılma ekranı açılınca
    /// alınır.
    var pendingInviteLink: String?

    #if DEBUG
    /// Tanıtım modunda (`--tanitim`) ekran görüntüleri için örnek paylaşılan klasörler; sunucuya gidilmez.
    func showDemo(owned demoOwned: [OwnedSharedFolder], joined demoJoined: [JoinedSharedFolder], deviceID demoDevice: String) {
        generation += 1
        availability = .available
        owned = demoOwned
        joined = demoJoined
        deviceID = demoDevice
    }
    #endif

    // MARK: Yenileme

    /// Listeyi okur; sahibin klasörlerinde katılanları ekler, ayrılanları anahtar yenileyerek çıkarır ve bu cihaz
    /// yayıncıysa notları yayımlar; üyenin klasörlerinde değişen notları indirir. Bir klasörün hatası diğerlerini
    /// durdurmaz (loglanır, panelde gösterilir).
    ///
    /// Yenileme sürerken çağrılırsa süren yenilemenin bitmesini ve ardından bir tur daha yapılmasını bekler: bir işlemin
    /// (paylaş, davet, ayrıl…) sonucu, ondan önce başlamış bir yenilemenin eski listesiyle kaybolmaz.
    func refresh() async {
        let started: Int = generation
        if let running = refreshTask, running.generation == started {
            refreshAgain = true
            await running.task.value
            return
        }
        let task: Task<Void, Never> = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            repeat {
                refreshAgain = false
                await refreshOnce(started: started)
            } while refreshAgain && started == generation
        }
        refreshTask = (started, task)
        await task.value
        if refreshTask?.generation == started {
            refreshTask = nil
        }
    }

    private func refreshOnce(started: Int) async {
        guard let scope, started == generation else {
            return
        }
        do {
            let service: SharedFolderService = try makeService(userID: scope.userID)
            let list: HostedSharedFolderList = try await service.client.folders()
            guard started == generation else {
                return
            }
            availability = list.available ? .available : .unavailable
            lastRefreshAt = Date()
            guard list.available else {
                return
            }
            let directory: URL = try foldersDirectory(accountKey: scope.accountKey)
            var state: SharedFolderDeviceState = try loadSharedFolderDeviceState(directory: directory)
            deviceID = state.deviceID
            guard !list.folders.isEmpty else {
                try pruneSharedFolderNotes(directory: directory, keep: [])
                try saveSharedFolderDeviceState(state: state.keeping(folderIDs: []), directory: directory)
                owned = []
                joined = []
                return
            }
            let identity: SharingIdentity = try await currentIdentity(service: service, accountKey: scope.accountKey)
            var hadFolderError: Bool = false
            var nextOwned: [OwnedSharedFolder] = []
            var nextJoined: [JoinedSharedFolder] = []
            for remote in list.folders {
                do {
                    let result: (folder: OpenedSharedFolder, state: SharedFolderDeviceState) = try await process(
                        remote: remote, service: service, identity: identity, state: state, directory: directory
                    )
                    state = result.state
                    if result.folder.isOwner {
                        let members: [SharedFolderMemberView]
                        do {
                            members = try sharedFolderMemberViews(
                                members: try await service.client.members(folderID: remote.folderId), identity: identity, folderID: remote.folderId
                            )
                        } catch {
                            // Üyeler okunamadı (ağ): klasör yine listede, son bilinen üyelerle; hata gösterilir.
                            sharedFoldersLogger.error("Shared folder members could not be read, error: \(String(describing: error), privacy: .public)")
                            status = .failed(userFacingMessage(error: error))
                            hadFolderError = true
                            members = owned.first { $0.id == remote.folderId }?.members ?? []
                        }
                        nextOwned.append(OwnedSharedFolder(folder: result.folder, members: members))
                    } else {
                        nextJoined.append(JoinedSharedFolder(folder: result.folder, notes: try loadSharedFolderNotes(directory: directory, folderID: remote.folderId)))
                    }
                } catch {
                    sharedFoldersLogger.error("Shared folder could not be refreshed, error: \(String(describing: error), privacy: .public)")
                    status = .failed(userFacingMessage(error: error))
                    hadFolderError = true
                    // Geçici bir hata klasörü listeden düşürmesin (paylaşılan klasör silinebilir görünür, üye notlarını
                    // kaybeder): son bilinen hâli kalır.
                    nextOwned += owned.filter { $0.id == remote.folderId }
                    nextJoined += joined.filter { $0.id == remote.folderId }
                }
            }
            let listed: Set<String> = Set(list.folders.map(\.folderId))
            // Başarılı bir listede olmayan klasörlerin notları silinir (sunucu kapalıyken buraya gelinmez).
            try pruneSharedFolderNotes(directory: directory, keep: listed)
            try saveSharedFolderDeviceState(state: state.keeping(folderIDs: listed), directory: directory)
            guard started == generation else {
                return
            }
            owned = nextOwned
            joined = nextJoined
            // Bir önceki yenilemenin hatası, bu yenileme hatasız bittiyse ekranda kalmasın.
            if !hadFolderError, case .failed = status {
                status = .idle
            }
        } catch {
            sharedFoldersLogger.error("Shared folders could not be refreshed, error: \(String(describing: error), privacy: .public)")
            if started == generation {
                status = .failed(userFacingMessage(error: error))
            }
        }
    }

    /// Bir klasörün yenilemesi: aç (sürüm sabiti denetlenir), sahibinse üyelikleri düzelt ve yayımla, üyeyse notları
    /// indir. Üyelik değiştiyse klasör yeniden okunur.
    private func process(
        remote: HostedSharedFolder, service: SharedFolderService, identity: SharingIdentity, state: SharedFolderDeviceState, directory: URL
    ) async throws -> (folder: OpenedSharedFolder, state: SharedFolderDeviceState) {
        var folder: OpenedSharedFolder = try openSharedFolder(remote: remote, identity: identity, storedPin: state.pins[remote.folderId])
        var next: SharedFolderDeviceState = state.with(pin: folder.pin, folderID: folder.folderID)
        if folder.isOwner {
            if try await service.reconcileRoster(folder: folder, identity: identity, removing: []) {
                folder = try await reopened(folderID: folder.folderID, service: service, identity: identity, state: next)
                next = next.with(pin: folder.pin, folderID: folder.folderID)
            }
            if let hooks, hooks.meetingsLoaded() {
                let ledger: Set<String> = Set(next.ledgers[folder.folderID] ?? [])
                do {
                    let published: Set<String> = try await service.publish(
                        folder: folder, identity: identity, deviceID: next.deviceID, records: hooks.records(), savedFolders: hooks.savedFolders(), ledger: ledger
                    )
                    next = next.with(ledger: published, folderID: folder.folderID)
                    publishProblems[folder.folderID] = nil
                } catch let error as HostedAPIError where error.code == .subscriptionRequired {
                    // Yayımlama abonelik ya da deneme ister; üyeleri yönetmek ve paylaşımı durdurmak istemez.
                    sharedFoldersLogger.notice("Shared folder publishing paused, subscription required")
                    publishProblems[folder.folderID] = String(
                        localized: "Yeni notlar paylaşılmıyor: abonelik ya da deneme gerekiyor. Üyeler paylaşılmış notları okumaya devam eder."
                    )
                } catch {
                    // Yayımlama hatası (not fazla uzun, sınır doldu, ağ) klasörü listeden düşürmez: klasör yönetilebilir
                    // kalır, sorun panelde yazılır, sonraki yenilemede yeniden denenir.
                    sharedFoldersLogger.error("Shared folder publishing failed, error: \(String(describing: error), privacy: .public)")
                    publishProblems[folder.folderID] = userFacingMessage(error: error)
                }
            }
            return (folder, next)
        }
        if !folder.isWaitingForOwner {
            let cached: [SharedFolderCachedItem] = try loadSharedFolderNotes(directory: directory, folderID: folder.folderID)
            let notes: [SharedFolderCachedItem] = try await service.readNotes(folder: folder, cached: cached)
            if notes != cached {
                try saveSharedFolderNotes(notes: notes, directory: directory, folderID: folder.folderID)
            }
        }
        return (folder, next)
    }

    /// Klasörün sunucudaki son hâli (yenilemede ve işlemden hemen önce; roster ve sürümler güncel olsun).
    private func reopened(folderID: String, service: SharedFolderService, identity: SharingIdentity, state: SharedFolderDeviceState) async throws -> OpenedSharedFolder {
        guard let remote = try await service.client.folders().folders.first(where: { $0.folderId == folderID }) else {
            throw SharedFolderSetupError.folderNotFound
        }
        return try openSharedFolder(remote: remote, identity: identity, storedPin: state.pins[folderID])
    }

    // MARK: Sahibin işleri

    /// Klasörü paylaşır (ilk kez kullanılıyorsa bu cihazda paylaşım kimliği kurulur) ve hemen yayımlar.
    func share(folderName: String, includeTranscript: Bool) async {
        await perform(action: "share") { (service: SharedFolderService, identity: SharingIdentity, state: SharedFolderDeviceState) in
            let ownerName: String = self.currentOwnerName()
            _ = try await service.createFolder(
                identity: identity, meta: SharedFolderMeta(name: folderName, ownerName: ownerName, includeTranscript: includeTranscript), deviceID: state.deviceID
            )
        }
    }

    /// Davet bağlantısı oluşturur ve panoya kopyalar.
    func invite(folderID: String, label: String) async {
        let trimmed: String = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        await perform(action: "invite") { (service: SharedFolderService, identity: SharingIdentity, state: SharedFolderDeviceState) in
            let folder: OpenedSharedFolder = try await self.reopened(folderID: folderID, service: service, identity: identity, state: state)
            let link: URL = try await service.invite(folder: folder, identity: identity, label: trimmed, siteOrigin: try HostedServices.siteBase())
            copyToPasteboard(link: link)
            self.lastInvite = (folderID, link)
        }
    }

    /// Üyeyi çıkarır (anahtar yenilenir: sonraki notları göremez) ya da daveti geri alır.
    func remove(folderID: String, member: SharedFolderMemberView) async {
        await perform(action: "remove") { (service: SharedFolderService, identity: SharingIdentity, state: SharedFolderDeviceState) in
            let folder: OpenedSharedFolder = try await self.reopened(folderID: folderID, service: service, identity: identity, state: state)
            if member.state == .active {
                try await service.reconcileRoster(folder: folder, identity: identity, removing: [member.memberID])
            } else {
                try await service.client.revokeInvite(folderID: folderID, memberID: member.memberID)
            }
        }
    }

    func stopSharing(folderID: String) async {
        await perform(action: "stop") { (service: SharedFolderService, _: SharingIdentity, _: SharedFolderDeviceState) in
            try await service.client.stopSharing(folderID: folderID)
        }
    }

    /// Notları bundan sonra bu cihaz yayımlar.
    func publishHere(folderID: String) async {
        await perform(action: "publish-here") { (service: SharedFolderService, _: SharingIdentity, state: SharedFolderDeviceState) in
            _ = try await service.client.takeOverPublisher(folderID: folderID, deviceID: state.deviceID)
        }
    }

    // MARK: Üyenin işleri

    func leave(folderID: String) async {
        await perform(action: "leave") { (service: SharedFolderService, _: SharingIdentity, _: SharedFolderDeviceState) in
            try await service.client.leave(folderID: folderID)
        }
    }

    /// Davet bağlantısını açar: sahibin anahtarları bağlantıdaki kanıtla denetlenir, klasör ve paylaşan gösterilir.
    func lookUp(link: String) async {
        guard let scope else {
            joinStatus = .failed(String(localized: "Hesabın henüz hazır değil; birazdan yeniden dene."))
            return
        }
        joinStatus = .working
        do {
            let found: SharedFolderInviteLookup = try await makeService(userID: scope.userID).lookUpInvite(link: link)
            lookup = found
            joinState = .preview(folderName: found.preview.folderName, ownerName: found.preview.ownerName, state: found.state)
            joinStatus = .idle
        } catch {
            sharedFoldersLogger.error("Invite could not be opened, error: \(String(describing: error), privacy: .public)")
            joinStatus = .failed(userFacingMessage(error: error))
        }
    }

    /// Açılan davete katılır.
    func join(displayName: String) async {
        guard let scope, let lookup else {
            joinStatus = .failed(String(localized: "Hesabın henüz hazır değil; birazdan yeniden dene."))
            return
        }
        joinStatus = .working
        do {
            let service: SharedFolderService = try makeService(userID: scope.userID)
            let identity: SharingIdentity = try await currentIdentity(service: service, accountKey: scope.accountKey)
            try await service.accept(lookup: lookup, identity: identity, displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines))
            joinState = .joined(folderName: lookup.preview.folderName, ownerName: lookup.preview.ownerName)
            joinStatus = .idle
            self.lookup = nil
            await refresh()
        } catch {
            sharedFoldersLogger.error("Invite could not be accepted, error: \(String(describing: error), privacy: .public)")
            joinStatus = .failed(userFacingMessage(error: error))
        }
    }

    /// Katılma ekranını baştan başlatır.
    func resetJoin() {
        lookup = nil
        joinState = .enterLink
        joinStatus = .idle
    }

    // MARK: Yardımcılar

    private func perform(action: String, work: @MainActor (SharedFolderService, SharingIdentity, SharedFolderDeviceState) async throws -> Void) async {
        guard let scope else {
            return
        }
        status = .working
        do {
            let service: SharedFolderService = try makeService(userID: scope.userID)
            let identity: SharingIdentity = try await currentIdentity(service: service, accountKey: scope.accountKey)
            let state: SharedFolderDeviceState = try loadSharedFolderDeviceState(directory: try foldersDirectory(accountKey: scope.accountKey))
            try await work(service, identity, state)
            // Düğmeler yenileme bitene dek kilitli kalır: "Paylaş"a ikinci kez basılıp aynı klasör iki kez paylaşılmasın.
            // Yenilemenin yazdığı hata ezilmez.
            await refresh()
            if status == .working {
                status = .idle
            }
        } catch {
            sharedFoldersLogger.error("Shared folder action failed, action: \(action, privacy: .public), error: \(String(describing: error), privacy: .public)")
            status = .failed(userFacingMessage(error: error))
        }
    }

    /// Bu cihazın paylaşım kimliği (yoksa kurulur; eşitleme açıksa diğer cihazlar için eşitleme anahtarıyla mühürlenir).
    /// Eşitleme sonradan açılırsa tohum yeni eşitleme anahtarıyla bir kez daha mühürlenir (hesabın diğer cihazları için).
    private func currentIdentity(service: SharedFolderService, accountKey: String) async throws -> SharingIdentity {
        let syncKey: SyncAccountKey? = try HostedSyncCenter.shared.deviceAccountKey()
        if let identity, syncKey == nil || identitySealedKeyID == syncKey?.keyID {
            return identity
        }
        let created: SharingIdentity = try await service.setUpIdentity(
            store: SharingIdentityKeychainStore(service: try identityKeychainService(accountKey: accountKey)), syncKey: syncKey
        )
        identity = created
        identitySealedKeyID = syncKey?.keyID
        return created
    }

    private func currentOwnerName() -> String {
        let name: String = hooks?.ownerName().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? String(localized: "Bir Gistsmith kullanıcısı") : name
    }

    private func makeService(userID: String) throws -> SharedFolderService {
        let client: HostedClient = try HostedServices.requireClient()
        return SharedFolderService(client: HostedSharedFolderClient(baseURL: client.baseURL, credentials: client), userID: userID)
    }

    private func foldersDirectory(accountKey: String) throws -> URL {
        AppPaths.accountSharedFoldersDirectory(dataRoot: try AppPaths.applicationSupport(), accountKey: accountKey)
    }

    /// Kimlik, hesabın kendi Anahtar Zinciri servisinde (eşitleme anahtarıyla aynı servis).
    private func identityKeychainService(accountKey: String) throws -> String {
        #if os(macOS)
        try hostedAccountKeychainService(accountKey: accountKey)
        #else
        try accountKeychainService(appService: try hostedKeychainService(bundle: .main), accountKey: accountKey)
        #endif
    }
}

/// Davet bağlantısını panoya kopyalar.
@MainActor
private func copyToPasteboard(link: URL) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(link.absoluteString, forType: .string)
    #else
    UIPasteboard.general.url = link
    #endif
}

/// Panodaki metin bir davet bağlantısıysa o metin (katılma ekranındaki "Yapıştır"). Pano okunduğunda iPhone sistem
/// uyarısı gösterir; bu yüzden yalnızca kullanıcı düğmeye basınca çağrılır.
@MainActor
func pastedSharedFolderInvite() -> String? {
    #if os(macOS)
    let text: String? = NSPasteboard.general.string(forType: .string)
    #else
    let text: String? = UIPasteboard.general.url?.absoluteString ?? UIPasteboard.general.string
    #endif
    guard let text else {
        return nil
    }
    do {
        _ = try sharedFolderInvite(text: text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        return nil
    }
}
