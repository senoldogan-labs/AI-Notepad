import AINotepadCore
import AINotepadUI
import AuthenticationServices
import os
import SwiftUI
import UIKit

// Notun ve görevlerin başka uygulamalara gönderilmesi (Mac'teki AppModel'in "Not hedefleri" ve "Görev araçları"
// bölümleri): kanallar (Slack, Teams, Discord, Zoom, webhook), Notion, Linear ve Jira. Bağlantılar hesabın kendi Anahtar
// Zinciri servisinde Mac'teki Gistsmith'le aynı biçimde saklanır (`DestinationVault`, `TrackerVault`); gönderim kuralları
// çekirdektedir (`deliverNote`, `autoSendQueue`, `sendTasksToTracker`).

/// Sonucu belirsiz gönderimlerin ayar anahtarı (Mac'teki `SettingsKey.uncertainSends` ile aynı ad).
private let phoneUncertainSendsKey: String = "integrations.uncertainSends"

/// Hesabın not hedefleri ve görev araçları: bağlama, kaldırma, elle ve kendiliğinden gönderim. Hesap değişince oturumla
/// birlikte yenisi kurulur (bkz. `PhoneAccountSession`).
@MainActor
@Observable
final class PhoneIntegrations {
    private static let logger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneIntegrations")
    private let store: PhoneStore
    /// Bağlı not hedefleri (Ayarlar › Bağlantılar); birden çok olabilir.
    private(set) var destinations: [NoteDestination] = []
    /// Görev araçları (Linear, Jira).
    private(set) var taskTrackers: [TaskTracker] = []
    /// Toplantı başına not gönderiminin durumu (toplantı sayfasında görünür).
    private(set) var noteStates: [String: WebhookSendState] = [:]
    /// Toplantı başına görev gönderiminin durumu.
    private(set) var trackerStates: [String: WebhookSendState] = [:]
    /// Kendiliğinden gönderim, kaldırma ve okuma hataları: toplantı sayfasında ve Ayarlar › Bağlantılar'da görünür,
    /// kullanıcı kapatır.
    private(set) var problems: [String] = []

    /// Depolar yüklü hesabın Anahtar Zinciri servisine bağlıdır; servis değişirse (hesap ilk kez yüklendi) yeniden kurulur.
    @ObservationIgnored private var vaults: (service: String, destinations: DestinationVault, trackers: TrackerVault)?
    /// Gönderim sonuçlarının kalkma zamanlayıcıları (`not|toplantı`, `görev|toplantı`).
    @ObservationIgnored private var sendStateFades: [String: Task<Void, Never>] = [:]
    /// Süren not gönderimleri (`toplantı|hedef`): elle, kendiliğinden ve "Hepsine gönder" aynı notu üst üste göndermesin.
    @ObservationIgnored private var notesInFlight: Set<String> = []
    /// Toplantı kayıtta ya da işlenirken gönderildi işaretleri; işleme bitince kayda yazılır.
    @ObservationIgnored private var pendingSentMarks: [String: Set<String>] = [:]
    @ObservationIgnored private var pendingTaskMarks: [String: [(tracker: TaskTracker, tasks: [NoteTask])]] = [:]
    /// Kendiliğinden gönderim sürüyor; sürerken gelen istek tur bitince bir kez daha çalıştırır.
    @ObservationIgnored private var autoSendRunning: Bool = false
    @ObservationIgnored private var autoSendRequested: Bool = false

    init(store: PhoneStore) {
        self.store = store
    }

    // MARK: Depolar

    /// Yüklü hesabın depoları; hesap yüklenmediyse `StorageError.accountNotSelected`.
    private func currentVaults() throws -> (destinations: DestinationVault, trackers: TrackerVault) {
        guard let accountKey = AppPaths.activeAccountKey() else {
            throw StorageError.accountNotSelected
        }
        let service: String = try accountKeychainService(appService: try hostedKeychainService(bundle: .main), accountKey: accountKey)
        if let vaults, vaults.service == service {
            return (vaults.destinations, vaults.trackers)
        }
        let destinationVault: DestinationVault = DestinationVault(service: service, account: .destinations, clientName: appName) {
            (connection: ChannelConnection) async throws -> ChannelConnection in
            try await refreshConnectionTokens(connection: connection)
        }
        let trackerVault: TrackerVault = TrackerVault(service: service, clientName: appName)
        vaults = (service, destinationVault, trackerVault)
        return (destinationVault, trackerVault)
    }

    private func destinationVault() throws -> DestinationVault {
        try currentVaults().destinations
    }

    private func trackerVault() throws -> TrackerVault {
        try currentVaults().trackers
    }

    /// Hedefleri ve görev araçlarını okur; okunamazsa neden sorunlarda görünür.
    func load() async {
        do {
            destinations = try await destinationVault().all()
            taskTrackers = try await trackerVault().all()
        } catch {
            Self.logger.error("Bağlantılar okunamadı, hata: \(String(describing: error), privacy: .private)")
            report(message: String(localized: "Bağlantılar okunamadı: \(userFacingMessage(error: error))"))
        }
    }

    func dismissProblems() {
        problems = []
    }

    private func report(message: String) {
        problems = appendUnique(messages: problems, message: message)
    }

    private func refreshDestinationList() async {
        do {
            destinations = try await destinationVault().all()
        } catch {
            report(message: userFacingMessage(error: error))
        }
    }

    private func refreshTrackerList() async {
        do {
            taskTrackers = try await trackerVault().all()
        } catch {
            report(message: userFacingMessage(error: error))
        }
    }

    // MARK: Not hedefleri

    /// Yeni hedef ekler (kendiliğinden gönderim kapalı başlar; kullanıcı açar).
    @discardableResult
    func addDestination(target: DestinationTarget) async throws -> NoteDestination {
        let destination: NoteDestination = NoteDestination(id: UUID().uuidString, target: target, autoSend: false, createdAt: Date(), needsReconnect: false)
        try await destinationVault().upsert(destination)
        destinations = try await destinationVault().all()
        return destination
    }

    /// Hedefin bağlantısını değiştirir (kanalı değiştir, yeniden bağlan); kimliği ve ayarı korunur. Değişmeden önceki
    /// kayıtlı hedef döner (yerini alan eski izni geri almak için).
    @discardableResult
    func replaceDestinationTarget(id: String, target: DestinationTarget) async throws -> NoteDestination {
        let previous: NoteDestination = try await destinationVault().replaceTarget(id: id, target: target)
        destinations = try await destinationVault().all()
        return previous
    }

    /// Kendiliğinden gönderimi açar ya da kapatır; kayıtlı hedefin yalnızca bu ayarı değişir.
    func setAutoSend(destinationID: String, enabled: Bool) async {
        do {
            try await destinationVault().setAutoSend(id: destinationID, enabled: enabled)
            destinations = try await destinationVault().all()
        } catch {
            report(message: userFacingMessage(error: error))
        }
    }

    /// Hedefi kaldırır; servis tarafında da kapatılır (Slack jetonu ve Notion izni geri alınır, Discord webhook'u
    /// silinir). Servis tarafı kapatılamazsa hedef yine kaldırılır; neden ve erişimin nasıl kaldırılacağı gösterilir.
    func removeDestination(id: String) async {
        do {
            let removed: NoteDestination = try await destinationVault().remove(id: id)
            destinations = try await destinationVault().all()
            do {
                try await revokeDestination(destination: removed, clientName: appName)
            } catch {
                Self.logger.warning("Hedef servis tarafında kapatılamadı, hedef: \(destinationName(destination: removed), privacy: .public), hata: \(String(describing: error), privacy: .private)")
                report(message: remoteRevocationFailureMessage(service: destinationName(destination: removed), appName: appName, error: error))
            }
        } catch {
            report(message: userFacingMessage(error: error))
        }
    }

    /// Hesap hedefinin kanallarını yeniden listeler (yeniden giriş yapmadan kanal değiştirmek için).
    func channelOptions(destinationID: String) async throws -> (signIn: ChannelSignIn, options: [ChannelOption]) {
        let connection: ChannelConnection = try await destinationVault().connection(id: destinationID)
        // Bağlantı alınırken jetonlar yenilenip yazılmış olabilir: bellekteki liste eski jetonlarla kalmasın.
        await refreshDestinationList()
        let signIn: ChannelSignIn = ChannelSignIn(service: connection.service, tokens: connection.tokens, workspace: connection.workspace)
        return (signIn, try await listChannels(signIn: signIn))
    }

    /// Ayarlardaki "Deneme mesajı gönder": örnek notu hedefe gönderir; hata metni döner.
    func sendTestNote(destinationID: String) async -> String? {
        guard let destination = destinations.first(where: { $0.id == destinationID }) else {
            return userFacingMessage(error: DestinationError.notFound(id: destinationID))
        }
        let sample: MeetingRecord = MeetingRecord(
            id: "deneme", title: appName, startedAt: Date(), endedAt: Date(), language: nil, status: .done, failureMessage: nil,
            liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:], note: nil, audioDeleted: false, engine: .cloud,
            notice: nil, meNeedsFinalPass: nil
        )
        let note: MeetingNote = MeetingNote(
            title: String(localized: "\(appName) bağlantı denemesi"),
            summary: String(localized: "Bu bir deneme mesajıdır: toplantı notların buraya böyle gelecek."),
            decisions: [], tasks: [], glossary: []
        )
        do {
            try await deliverNote(vault: destinationVault(), destination: destination, record: sample, note: note)
            await refreshDestinationList()
            return nil
        } catch {
            Self.logger.error("Hedef denemesi başarısız, hata: \(String(describing: error), privacy: .private)")
            await refreshDestinationList()
            return userFacingMessage(error: error)
        }
    }

    /// Notion'a bağlanır (uygulama içi tarayıcıda izin) ve hedef olarak ekler; hesabın kimliği hemen okunur.
    func connectNotion(browser: PhoneMCPSignIn) async throws {
        let connection: MCPConnection = try await browser.signIn(service: .notion)
        try await addDestination(target: .notion(NotionTarget(connection: connection, pageTitle: String(localized: "Özel sayfalar"), identity: nil)))
        await resolveMissingNotionIdentities()
    }

    /// Notion hedefini yeniden bağlar: kimliği, ayarı ve bağlanma anı korunur; yerini aldığı eski izin geri alınır.
    func reconnectNotion(destinationID: String, browser: PhoneMCPSignIn) async throws {
        let connection: MCPConnection = try await browser.signIn(service: .notion)
        let previous: NoteDestination = try await replaceDestinationTarget(
            id: destinationID, target: .notion(NotionTarget(connection: connection, pageTitle: String(localized: "Özel sayfalar"), identity: nil))
        )
        if case .notion(let old) = previous.target, let replaced = replacedGrant(old: old.connection, new: connection) {
            revokeReplacedGrant(connection: replaced, service: MCPService.notion.displayName)
        }
        await resolveMissingNotionIdentities()
    }

    /// Yerini alan eski bağlantının OAuth iznini arka planda geri alır; geri alınamazsa engellemeyen bir mesaj gösterilir.
    private func revokeReplacedGrant(connection: MCPConnection, service: String) {
        Task {
            do {
                try await revokeMCPConnection(connection: connection, clientName: appName)
            } catch {
                Self.logger.warning("Eski bağlantının izni geri alınamadı, servis: \(service, privacy: .public), hata: \(String(describing: error), privacy: .private)")
                report(message: replacedGrantRevocationFailureMessage(service: service, error: error))
            }
        }
    }

    /// Kimliği bilinmeyen Notion hedeflerinin çalışma alanını ve kullanıcısını okur (Mac'teki gibi); okunamazsa uyarı
    /// loglanır ve sonraki turda yeniden denenir.
    private func resolveMissingNotionIdentities() async {
        let missing: [String] = destinations.compactMap { (destination: NoteDestination) -> String? in
            guard case .notion(let target) = destination.target, target.identity == nil, !destination.needsReconnect else {
                return nil
            }
            return destination.id
        }
        guard !missing.isEmpty else {
            return
        }
        for id in missing {
            do {
                try await destinationVault().resolveNotionIdentity(id: id)
            } catch {
                Self.logger.warning("Notion hesabının kimliği okunamadı, hedef: \(id, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            }
        }
        await refreshDestinationList()
    }

    // MARK: Not gönderimi

    /// Toplantı kayıtta ya da işleniyor: kayıt işleme bitince bütünüyle yazılır, işaretler beklemeli.
    private func isLocked(meetingID: String) -> Bool {
        guard let record = store.meetings.first(where: { $0.id == meetingID }) else {
            return false
        }
        return record.status == .recording || record.status == .processing
    }

    /// Paylaşılan toplantı: konuşmacı adları notta uygulanmış (Mac'teki `shownMeeting`).
    private func shownMeeting(id: String) -> MeetingRecord? {
        store.meetings.first { $0.id == id }.map { namedRecord(record: $0, userName: phoneUserName()) }
    }

    /// Notu bir hedefe gönderir; başarılıysa toplantıya işlenir. Hata metni döner (toplantı, not ya da hedef yoksa ve
    /// aynı gönderim zaten sürüyorsa da).
    private func sendNote(meetingID: String, destinationID: String) async -> String? {
        guard let record = shownMeeting(id: meetingID) else {
            return userFacingMessage(error: NoteSendError.meetingNotFound(id: meetingID))
        }
        guard let note = record.note else {
            return userFacingMessage(error: NoteSendError.noNote(meetingID: meetingID))
        }
        guard let destination = destinations.first(where: { $0.id == destinationID }) else {
            return userFacingMessage(error: DestinationError.notFound(id: destinationID))
        }
        let sendKey: String = meetingDestinationKey(meetingID: meetingID, destinationID: destinationID)
        guard !notesInFlight.contains(sendKey) else {
            return userFacingMessage(error: NoteSendError.alreadySending(meetingID: meetingID, destinationID: destinationID))
        }
        notesInFlight.insert(sendKey)
        defer { notesInFlight.remove(sendKey) }
        // Elle gönderim belirsiz işaretini kaldırır: kullanıcı kontrol edip yeniden göndermeyi seçti.
        storeUncertainSends(sends: uncertainSends().subtracting([sendKey]))
        do {
            try await deliverNote(vault: destinationVault(), destination: destination, record: record, note: note)
            recordFeatureUsage(feature: .integration(telemetryIntegration(target: destination.target)))
            markSent(meetingID: meetingID, destination: destination)
            Self.logger.info("Not hedefe gönderildi, toplantı: \(meetingID, privacy: .public), hedef: \(destinationName(destination: destination), privacy: .public)")
            return nil
        } catch let error as DeliveryUncertainError {
            // Not gitmiş olabilir: kendiliğinden yeniden gönderilmez (iki kez düşmesin); kullanıcıya gösterilir.
            storeUncertainSends(sends: uncertainSends().union([sendKey]))
            Self.logger.warning("Not gönderiminin sonucu belirsiz, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            return String(localized: "\(destinationName(destination: destination)): \(userFacingMessage(error: error))")
        } catch {
            Self.logger.error("Not hedefe gönderilemedi, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            return String(localized: "\(destinationName(destination: destination)): \(userFacingMessage(error: error))")
        }
    }

    /// Notu verilen hedeflere sırayla gönderir; toplantı sayfasındaki durum güncellenir.
    func sendNote(meetingID: String, destinationIDs: [String]) async {
        showSendState(state: .sending, meetingID: meetingID, states: \.noteStates)
        var failures: [String] = []
        for id in destinationIDs {
            if let failure = await sendNote(meetingID: meetingID, destinationID: id) {
                failures.append(failure)
            }
        }
        await refreshDestinationList()
        showSendState(state: failures.isEmpty ? .sent : .failed(failures.joined(separator: "\n")), meetingID: meetingID, states: \.noteStates)
    }

    /// Gönderim durumunu yazar; sonuç süresi dolunca kendiliğinden kalkar (bkz. `sendResultFadeDelay`).
    private func showSendState(state: WebhookSendState, meetingID: String, states: ReferenceWritableKeyPath<PhoneIntegrations, [String: WebhookSendState]>) {
        let key: String = "\(states)|\(meetingID)"
        sendStateFades[key]?.cancel()
        self[keyPath: states][meetingID] = state
        guard let delay = sendResultFadeDelay(state: state) else {
            sendStateFades[key] = nil
            return
        }
        sendStateFades[key] = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                // Yalnızca iptal: yeni bir durum geldi, eski sonucun zamanlayıcısı bir şey kaldırmaz.
                return
            }
            self?[keyPath: states][meetingID] = nil
            self?.sendStateFades[key] = nil
        }
    }

    /// Gönderildi işareti: hedefin kimliği ve cihazdan bağımsız anahtarı. Toplantı kilitliyse işleme bitince yazılır.
    private func markSent(meetingID: String, destination: NoteDestination) {
        let marks: [String] = [destination.id] + [destinationSendKey(destination: destination)].compactMap { $0 }
        guard !isLocked(meetingID: meetingID) else {
            pendingSentMarks[meetingID, default: []].formUnion(marks)
            return
        }
        writeMarks(meetingID: meetingID) { (record: MeetingRecord) -> MeetingRecord in
            marks.reduce(record) { (result: MeetingRecord, mark: String) -> MeetingRecord in result.markingSent(destinationID: mark) }
        }
    }

    /// İşareti diskteki en güncel kayda yazar (not yeniden yazılırken de: yeni not diskten okunan kayda uygulanır).
    private func writeMarks(meetingID: String, change: (MeetingRecord) -> MeetingRecord) {
        do {
            let directory: URL = try store.sessionDirectory(id: meetingID)
            let updated: MeetingRecord = change(try loadMeeting(directory: directory))
            try saveMeeting(record: updated, directory: directory)
            store.upsert(record: updated)
        } catch {
            Self.logger.error("Gönderim işareti yazılamadı, toplantı: \(meetingID, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            report(message: String(localized: "Toplantı kaydedilemedi: \(userFacingMessage(error: error))"))
        }
    }

    /// İşleme sürerken bekleyen işaretleri, toplantı artık kilitli değilse kayda yazar.
    private func flushPendingMarks() {
        for (meetingID, marks) in pendingSentMarks where !isLocked(meetingID: meetingID) {
            pendingSentMarks[meetingID] = nil
            writeMarks(meetingID: meetingID) { (record: MeetingRecord) -> MeetingRecord in
                marks.reduce(record) { (result: MeetingRecord, mark: String) -> MeetingRecord in result.markingSent(destinationID: mark) }
            }
        }
        for (meetingID, items) in pendingTaskMarks where !isLocked(meetingID: meetingID) {
            pendingTaskMarks[meetingID] = nil
            writeMarks(meetingID: meetingID) { (record: MeetingRecord) -> MeetingRecord in
                items.reduce(record) { (result: MeetingRecord, item: (tracker: TaskTracker, tasks: [NoteTask])) -> MeetingRecord in
                    markingTasksSent(record: result, tracker: item.tracker, tasks: item.tasks)
                }
            }
        }
    }

    /// Sonucu belirsiz gönderimler (`toplantı|hedef`): kendiliğinden gönderim bunları atlar.
    private func uncertainSends() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: phoneUncertainSendsKey) ?? [])
    }

    private func storeUncertainSends(sends: Set<String>) {
        guard sends != uncertainSends() else {
            return
        }
        UserDefaults.standard.set(sends.sorted(), forKey: phoneUncertainSendsKey)
    }

    /// Bekleyen kendiliğinden gönderimleri yapar (Mac'teki kurallarla): toplantı işlenip notu hazır olunca, hesap
    /// yüklenince ve uygulama öne gelince. Ağ yokken kaçanlar böylece sonra gider; her (toplantı, hedef) bir kez
    /// gönderilir. iPhone kilitliyken Anahtar Zinciri okunamadığı için tur kilit açılınca (öne gelince) yapılır.
    func processPendingAutoSends() async {
        #if DEBUG
        // "--otomatik-gonderim-yok": görsel kontrol ve testlerde toplantılar hedeflere gitmesin (yalnız Debug).
        if CommandLine.arguments.contains("--otomatik-gonderim-yok") {
            return
        }
        #endif
        guard AppPaths.activeAccountKey() != nil else {
            return
        }
        guard UIApplication.shared.isProtectedDataAvailable else {
            Self.logger.info("iPhone kilitli, kendiliğinden gönderim kilit açılınca yapılacak")
            return
        }
        guard !autoSendRunning else {
            autoSendRequested = true
            return
        }
        autoSendRunning = true
        defer { autoSendRunning = false }
        repeat {
            autoSendRequested = false
            await refreshDestinationList()
            flushPendingMarks()
            await resolveMissingNotionIdentities()
            let locked: Set<String> = Set(store.meetings.map(\.id).filter { isLocked(meetingID: $0) })
            let pending: [(meetingID: String, destinationID: String)] = autoSendQueue(
                records: store.meetings, destinations: destinations, now: Date(), pendingMarks: pendingSentMarks, locked: locked, uncertain: uncertainSends()
            )
            for item in pending {
                // Liste kurulduktan sonra elle gönderilmeye başlandıysa ya da gönderildiyse atlanır (not iki kez düşmesin).
                let record: MeetingRecord? = store.meetings.first { $0.id == item.meetingID }
                let destination: NoteDestination? = destinations.first { $0.id == item.destinationID }
                let sentMeanwhile: Bool = (pendingSentMarks[item.meetingID] ?? []).contains(item.destinationID)
                    || (record.flatMap { (current: MeetingRecord) -> Bool? in destination.map { wasSent(record: current, destination: $0) } } ?? false)
                guard !sentMeanwhile, !notesInFlight.contains(meetingDestinationKey(meetingID: item.meetingID, destinationID: item.destinationID)) else {
                    continue
                }
                if let failure = await sendNote(meetingID: item.meetingID, destinationID: item.destinationID) {
                    report(message: failure)
                }
            }
            if !pending.isEmpty {
                await refreshDestinationList()
            }
        } while autoSendRequested
    }

    // MARK: Görev araçları (Linear, Jira)

    /// Linear ya da Jira'ya bağlanır (uygulama içi tarayıcıda izin). Sunucuda iş açan araç yoksa bağlantı kaldırılır ve
    /// neden gösterilir. Aynı servis yeniden bağlanırsa kimlik ve hedef korunur; yerini aldığı eski izin geri alınır.
    func connectTracker(service: MCPService, browser: PhoneMCPSignIn) async throws {
        let connection: MCPConnection = try await browser.signIn(service: service)
        let connected: TrackerConnectResult = try await trackerVault().connect(service: service, connection: connection, newID: UUID().uuidString)
        let tracker: TaskTracker = connected.tracker
        if let replaced = connected.replaced {
            revokeReplacedGrant(connection: replaced, service: service.displayName)
        }
        defer { Task { await self.refreshTrackerList() } }
        do {
            try await trackerVault().withTracker(id: tracker.id) {
                (current: TaskTracker, persist: @escaping @Sendable (MCPConnection, MCPConnection) async throws -> Void) async throws -> Void in
                try await validateTracker(service: current.service, connection: current.connection, clientName: appName, persist: persist)
            }
        } catch TaskTrackerError.noCreateTool(let name) {
            await revokeTracker(tracker: try await trackerVault().remove(id: tracker.id))
            throw TaskTrackerError.noCreateTool(service: name)
        }
        await resolveTrackerIdentity(id: tracker.id)
    }

    /// Aracın hesap kimliğini okur (başka cihazdan gönderilenleri tanımak için); okunamazsa uyarı loglanır.
    private func resolveTrackerIdentity(id: String) async {
        do {
            try await trackerVault().resolveIdentity(id: id)
        } catch {
            Self.logger.warning("Görev aracının hesap kimliği okunamadı, araç: \(id, privacy: .public), hata: \(String(describing: error), privacy: .private)")
        }
        await refreshTrackerList()
    }

    /// Görev aracını kaldırır; OAuth izni sunucuda arka planda geri alınır.
    func removeTracker(id: String) async {
        let removed: TaskTracker
        do {
            removed = try await trackerVault().remove(id: id)
        } catch {
            report(message: userFacingMessage(error: error))
            await refreshTrackerList()
            return
        }
        await refreshTrackerList()
        Task { await revokeTracker(tracker: removed) }
    }

    private func revokeTracker(tracker: TaskTracker) async {
        do {
            try await revokeMCPConnection(connection: tracker.connection, clientName: appName)
        } catch {
            Self.logger.warning("Görev aracının izni geri alınamadı, servis: \(tracker.service.rawValue, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            report(message: remoteRevocationFailureMessage(service: tracker.service.displayName, appName: appName, error: error))
        }
    }

    /// Görev aracında seçilebilir hedefler (Linear takımları, Jira projeleri).
    func trackerTargets(id: String) async throws -> [String] {
        try await trackerVault().targets(id: id)
    }

    func setTrackerTarget(id: String, target: String) async {
        do {
            try await trackerVault().setTarget(id: id, target: target.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            report(message: userFacingMessage(error: error))
        }
        await refreshTrackerList()
    }

    /// Toplantının kapsamdaki görevlerini araçta iş olarak açar (Mac'teki "Görevleri gönder"); daha önce gönderilenler
    /// yinelenmez. İşleri hesabın yapay zekâsı açar (sunucumuz üzerinden). Sonuç toplantı sayfasında görünür.
    func sendTasks(meetingID: String, trackerID: String, scope: TaskSendScope) async {
        if let known = taskTrackers.first(where: { $0.id == trackerID }), known.identity == nil {
            await resolveTrackerIdentity(id: trackerID)
        }
        guard let record = shownMeeting(id: meetingID), let note = record.note, let tracker = taskTrackers.first(where: { $0.id == trackerID }) else {
            return
        }
        let tasks: [NoteTask] = tasksToSend(record: record, note: note, tracker: tracker, scope: scope)
        guard !tasks.isEmpty else {
            showSendState(state: .failed(String(localized: "Gönderilecek açık görev yok (hepsi gönderilmiş ya da tamamlanmış).")), meetingID: meetingID, states: \.trackerStates)
            return
        }
        showSendState(state: .sending, meetingID: meetingID, states: \.trackerStates)
        defer { Task { await self.refreshTrackerList() } }
        do {
            let llm: LLMProvider = try phoneAccountLLMProvider()
            let title: String = note.title
            let language: ShareLanguage = phoneNoteLanguage()
            try requireOnDeviceLanguages(provider: llm, meetingLanguages: note.writtenLanguage.meetingLanguage.map { [$0] } ?? [], outputLanguage: language)
            let result: TrackerSendResult = try await trackerVault().withTracker(id: trackerID) {
                (current: TaskTracker, persist: @escaping @Sendable (MCPConnection, MCPConnection) async throws -> Void) async throws -> TrackerSendResult in
                try await sendTasksToTracker(tracker: current, clientName: appName, persist: persist, tasks: tasks, meetingTitle: title, language: language, llm: llm)
            }
            markTasksSent(meetingID: meetingID, tracker: tracker, tasks: result.createdTaskIndices.map { tasks[$0] })
            Self.logger.info("Görevler araca gönderildi, araç: \(tracker.service.rawValue, privacy: .public), sayı: \(result.createdTaskIndices.count, privacy: .public), özet: \(result.summary, privacy: .private)")
            recordFeatureUsage(feature: .integration(telemetryIntegration(tracker: tracker.service)))
            showSendState(state: .done(String(localized: "\(tracker.service.displayName): \(result.createdTaskIndices.count) görev açıldı")), meetingID: meetingID, states: \.trackerStates)
        } catch TaskTrackerError.partial(let service, let created, let total, let reason) {
            // Açılanlar işaretlenir: yeniden gönderimde yalnızca kalanlar gider.
            markTasksSent(meetingID: meetingID, tracker: tracker, tasks: created.filter { tasks.indices.contains($0) }.map { tasks[$0] })
            Self.logger.error("Görevlerin bir kısmı açılamadı, araç: \(tracker.service.rawValue, privacy: .public), açılan: \(created.count, privacy: .public)")
            showSendState(
                state: .failed(userFacingMessage(error: TaskTrackerError.partial(service: service, created: created, total: total, reason: reason))),
                meetingID: meetingID, states: \.trackerStates
            )
        } catch TaskTrackerError.uncertain(let service, let created, let uncertainTask, let taskTitle, let total, let reason) {
            // Kesin açılanlar işaretlenir; sonucu belirsiz görev işaretlenmez, kullanıcı araçta kontrol etmeli.
            markTasksSent(meetingID: meetingID, tracker: tracker, tasks: created.filter { tasks.indices.contains($0) }.map { tasks[$0] })
            let error: TaskTrackerError = .uncertain(service: service, created: created, uncertainTask: uncertainTask, taskTitle: taskTitle, total: total, reason: reason)
            Self.logger.warning("Görev açmanın sonucu belirsiz, araç: \(tracker.service.rawValue, privacy: .public), açılan: \(created.count, privacy: .public)")
            showSendState(state: .failed(userFacingMessage(error: error)), meetingID: meetingID, states: \.trackerStates)
        } catch {
            Self.logger.error("Görevler araca gönderilemedi, araç: \(tracker.service.rawValue, privacy: .public), hata: \(String(describing: error), privacy: .private)")
            showSendState(state: .failed(String(localized: "\(tracker.service.displayName): \(userFacingMessage(error: error))")), meetingID: meetingID, states: \.trackerStates)
        }
    }

    /// Araçta açılan görevleri işaretler; toplantı kilitliyse işleme bitince yazılır.
    private func markTasksSent(meetingID: String, tracker: TaskTracker, tasks: [NoteTask]) {
        guard !tasks.isEmpty else {
            return
        }
        guard !isLocked(meetingID: meetingID) else {
            pendingTaskMarks[meetingID, default: []].append((tracker: tracker, tasks: tasks))
            return
        }
        writeMarks(meetingID: meetingID) { (record: MeetingRecord) -> MeetingRecord in
            markingTasksSent(record: record, tracker: tracker, tasks: tasks)
        }
    }
}

// MARK: MCP girişi (Notion, Linear, Jira)

/// Uzak MCP sunucusuna uygulama içi tarayıcıda giriş: izin sayfası ASWebAuthenticationSession'da açılır, dönüş Mac'teki
/// gibi yerel adreste (`http://127.0.0.1:<port>/callback`, bkz. `LoopbackRedirect`) yakalanır; uygulama öndeyken dinler.
/// Dönüş gelince ya da giriş bitince pencere kapanır; kullanıcı pencereyi kapatırsa giriş iptal edilir.
/// (AuthenticationServices sunum sağlayıcısı: dış sistem bağlantısı, NSObject gerekir.)
@MainActor
final class PhoneMCPSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    /// Açık pencerenin kimliği: kapatılmış eski pencerenin geç gelen bildirimi yeni girişi iptal etmesin.
    private var sessionToken: UUID?
    /// Süren giriş: pencere kapatılınca iptal edilir.
    private var running: Task<MCPConnection, any Error>?
    /// Pencere açılamadı: giriş bu nedenle bitti.
    private var startFailure: HostedBrowserSignInError?

    /// Servise giriş yapar; kullanıcı pencereyi kapatırsa ya da çağıran görev iptal edilirse `CancellationError`.
    func signIn(service: MCPService) async throws -> MCPConnection {
        startFailure = nil
        let task: Task<MCPConnection, any Error> = Task { @MainActor in
            try await signInToMCP(service: service, appName: appName) { (url: URL) async -> Void in
                await MainActor.run { self.present(url: url) }
            }
        }
        running = task
        defer {
            running = nil
            close()
        }
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            if let startFailure {
                throw startFailure
            }
            throw CancellationError()
        }
    }

    /// İzin sayfasını açar; yalnızca https (keşiften gelen adres `file:` ya da özel şema olamasın). Açılamazsa giriş
    /// nedeniyle biter.
    private func present(url: URL) {
        guard url.scheme?.lowercased() == "https" else {
            fail(reason: "güvenli olmayan giriş adresi, şema: \(url.scheme ?? "yok")")
            return
        }
        let token: UUID = UUID()
        // Tamamlanma bloğu `@Sendable`: sistem onu arka plandaki kuyrukta çağırır (bkz. `HostedAccount.runWebSignIn`).
        let completion: @Sendable (URL?, (any Error)?) -> Void = { [weak self] (_: URL?, error: (any Error)?) -> Void in
            // Dönüş yerel adrese gelir; pencere ancak kapatılınca (kullanıcı ya da `close`) biter.
            guard let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin else {
                return
            }
            Task { @MainActor in
                guard let self, self.sessionToken == token else {
                    return
                }
                self.running?.cancel()
            }
        }
        let session: ASWebAuthenticationSession = ASWebAuthenticationSession(url: url, callback: .customScheme(oauthCallbackScheme), completionHandler: completion)
        session.presentationContextProvider = self
        // Tarayıcıdaki Notion, Linear ya da Atlassian oturumu kullanılabilsin (her bağlanışta parola sorulmasın).
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        sessionToken = token
        guard session.start() else {
            fail(reason: "start() false döndü")
            return
        }
    }

    private func fail(reason: String) {
        startFailure = .sessionNotStarted(reason: reason)
        running?.cancel()
    }

    /// Pencereyi kapatır (giriş bitti ya da vazgeçildi).
    private func close() {
        sessionToken = nil
        session?.cancel()
        session = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // İzin sayfası öndeki sahnenin penceresinde açılır.
        let scenes: [UIWindowScene] = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active: UIWindowScene? = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let scene = active else {
            preconditionFailure("Giriş penceresi istendi ama uygulamanın sahnesi yok")
        }
        return scene.keyWindow ?? scene.windows.first ?? UIWindow(windowScene: scene)
    }
}

// MARK: Tetikleyiciler

/// Uygulama öne gelince bekleyen kendiliğinden gönderimler yapılır (Mac'teki saatlik denetimin karşılığı; iPhone
/// kilitliyken kaçanlar da böyle gider). Açılıştaki tur hesap verisi okununca, işleme sonundaki
/// `PhoneRecorder.onMeetingProcessed` ile başlar.
struct PhoneIntegrationTriggers: ViewModifier {
    let integrations: PhoneIntegrations
    /// Hesabın verisi yüklü.
    let isLoaded: Bool
    @Environment(\.scenePhase) private var scenePhase: ScenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { (_: ScenePhase, phase: ScenePhase) in
                guard phase == .active, isLoaded else {
                    return
                }
                Task { await integrations.processPendingAutoSends() }
            }
    }
}

// MARK: Toplantı sayfası

/// Toplantının ⋯ menüsünde "Kanala gönder" (her bağlı hedefe ayrı ya da hepsine; gönderilmiş hedef işaretli) ve
/// "Görevleri gönder" (Linear ya da Jira'da iş olarak; yalnız sana düşenler ya da hepsi). Hedef yoksa nereden
/// ekleneceği söylenir.
struct PhoneSendMenuItems: View {
    let record: MeetingRecord
    @Environment(PhoneIntegrations.self) private var integrations: PhoneIntegrations

    /// Kayıttaki ya da işlenen toplantı gönderilmez (not yazılırken eski not gitmesin).
    private var isSendable: Bool {
        record.note != nil && record.status != .recording && record.status != .processing
    }

    var body: some View {
        Menu("Kanala gönder", systemImage: "paperplane") {
            if integrations.destinations.isEmpty {
                Text("Ayarlar › Bağlantılar'dan kanal ekle")
            } else {
                ForEach(integrations.destinations) { (destination: NoteDestination) in
                    Button {
                        Task { await integrations.sendNote(meetingID: record.id, destinationIDs: [destination.id]) }
                    } label: {
                        Label(
                            "\(destinationName(destination: destination)) · \(destinationDetail(destination: destination))",
                            systemImage: wasSent(record: record, destination: destination) ? "checkmark" : "paperplane"
                        )
                    }
                }
                if integrations.destinations.count > 1 {
                    Divider()
                    Button("Hepsine gönder") {
                        Task { await integrations.sendNote(meetingID: record.id, destinationIDs: integrations.destinations.map(\.id)) }
                    }
                }
            }
        }
        .disabled(!isSendable || integrations.noteStates[record.id] == .sending)
        // Araç adı iki noktadan sonra: Türkçe ek ada göre değişir ("Jira'ya").
        Menu("Görevleri gönder", systemImage: "checklist") {
            if integrations.taskTrackers.isEmpty {
                Text("Ayarlar › Bağlantılar › Görev araçları'ndan Linear ya da Jira bağla")
            } else {
                ForEach(integrations.taskTrackers) { (tracker: TaskTracker) in
                    Button("Bana düşenleri gönder: \(tracker.service.displayName)") {
                        Task { await integrations.sendTasks(meetingID: record.id, trackerID: tracker.id, scope: .mine) }
                    }
                    Button("Tüm görevleri gönder: \(tracker.service.displayName)") {
                        Task { await integrations.sendTasks(meetingID: record.id, trackerID: tracker.id, scope: .all) }
                    }
                }
            }
        }
        .disabled(!isSendable || (record.note?.tasks ?? []).isEmpty || integrations.trackerStates[record.id] == .sending)
    }
}

/// Toplantı sayfasında gönderimin durumu (kanala not, görev aracına görevler) ve kendiliğinden gönderim hataları.
/// Gönderilirken kâğıt uçak sakince nabız atar; sonuç süresi dolunca yumuşakça kaybolur.
struct PhoneSendStatus: View {
    let meetingID: String
    @Environment(PhoneIntegrations.self) private var integrations: PhoneIntegrations

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PhoneDismissibleErrorList(messages: integrations.problems) { integrations.dismissProblems() }
            line(state: integrations.noteStates[meetingID], sending: "Kanala gönderiliyor…", sent: "Not kanala gönderildi")
            line(state: integrations.trackerStates[meetingID], sending: "Görevler açılıyor…", sent: "Görevler gönderildi")
        }
        .animation(.easeOut(duration: 0.4), value: integrations.noteStates[meetingID])
        .animation(.easeOut(duration: 0.4), value: integrations.trackerStates[meetingID])
    }

    @ViewBuilder
    private func line(state: WebhookSendState?, sending: LocalizedStringKey, sent: LocalizedStringKey) -> some View {
        switch state {
        case nil:
            EmptyView()
        case .sending:
            Label {
                Text(sending)
            } icon: {
                Image(systemName: "paperplane").symbolEffect(.pulse)
            }
            .appFont(size: 13, weight: .regular)
            .foregroundStyle(Theme.muted)
            .transition(.opacity)
        case .sent:
            Label(sent, systemImage: "checkmark.circle")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .transition(.opacity)
        case .done(let summary):
            Label(summary, systemImage: "checkmark.circle")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .textSelection(.enabled)
                .transition(.opacity)
        case .failed(let message):
            NoticeText(message, severity: .attention)
                .appFont(size: 13, weight: .regular)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
    }
}
