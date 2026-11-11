import AINotepadCore
import AINotepadUI
import os
import SwiftUI
import UIKit

private let quickActionLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "QuickActions")

/// The Home Screen quick actions (long press on the app icon; `UIApplicationShortcutItems` in project.yml, titles in
/// `iOS/InfoPlist.xcstrings`). Raw values are the items' `UIApplicationShortcutItemType`.
enum PhoneQuickAction: String, Equatable {
    /// Opens the record screen like `gistsmith://record` (recording starts only when the user taps).
    case record = "com.senoldogan.AINotepad.hosted.record"
    /// A support email with app version, iOS version and device model only.
    case contactSupport = "com.senoldogan.AINotepad.hosted.support"
    /// A confirmation sheet for deleting failed local recordings (`clearableFailedMeetings`, failed Watch imports).
    case clearStorage = "com.senoldogan.AINotepad.hosted.clearStorage"
}

/// The quick action a shortcut item names; nil for an unknown type (logged). Pure apart from the log.
func phoneQuickAction(type: String) -> PhoneQuickAction? {
    guard let action = PhoneQuickAction(rawValue: type) else {
        quickActionLogger.error("Unknown quick action, type: \(type, privacy: .public)")
        return nil
    }
    return action
}

/// The quick action waiting to be handled: set by the scene delegate (cold launch or running app), taken by
/// `PhoneQuickActionHandler` once the app's window is up.
@MainActor
@Observable
final class PhoneQuickActionCenter {
    static let shared: PhoneQuickActionCenter = PhoneQuickActionCenter()
    var pending: PhoneQuickAction?

    private init() {}
}

/// Hands every window scene the quick-action delegate (SwiftUI keeps managing the window).
final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        // Cold launch from a quick action: the item arrives here, not in `windowScene(_:performActionFor:)`.
        if let item = options.shortcutItem, let action = phoneQuickAction(type: item.type) {
            PhoneQuickActionCenter.shared.pending = action
        }
        let configuration: UISceneConfiguration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = PhoneSceneDelegate.self
        return configuration
    }
}

/// Receives a quick action while the app is running.
final class PhoneSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        guard let action = phoneQuickAction(type: shortcutItem.type) else {
            completionHandler(false)
            return
        }
        PhoneQuickActionCenter.shared.pending = action
        completionHandler(true)
    }
}

/// Handles the pending quick action: record opens the home screen through the `gistsmith://record` path, support opens
/// a mail draft (or says where to write when no mail app can take it), clear storage opens its confirmation sheet.
struct PhoneQuickActionHandler: ViewModifier {
    let sessions: PhoneSessionHost
    let router: PhoneRouter
    let account: HostedAccount
    @Environment(PhoneWatchLink.self) private var watchLink: PhoneWatchLink
    @Environment(\.openURL) private var openURL: OpenURLAction
    @State private var isClearingStorage: Bool = false
    @State private var isShowingSupportAddress: Bool = false

    func body(content: Content) -> some View {
        content
            .onChange(of: PhoneQuickActionCenter.shared.pending, initial: true) { (_: PhoneQuickAction?, action: PhoneQuickAction?) in
                guard let action else {
                    return
                }
                PhoneQuickActionCenter.shared.pending = nil
                handle(action: action)
            }
            .sheet(isPresented: $isClearingStorage) {
                PhoneClearStorageSheet(session: sessions.session, router: router, account: account, watchLink: watchLink)
                    .modifier(PhoneAppearanceModifier())
            }
            .alert("Destek", isPresented: $isShowingSupportAddress) {
                Button("Adresi kopyala") { UIPasteboard.general.string = supportEmailAddress }
                Button("Kapat", role: .cancel) {}
            } message: {
                Text("Bu iPhone'da e-posta uygulaması yok. Bize \(supportEmailAddress) adresinden yaz.")
            }
    }

    private func handle(action: PhoneQuickAction) {
        quickActionLogger.info("Quick action, type: \(action.rawValue, privacy: .public)")
        switch action {
        case .record:
            let store: PhoneStore = sessions.session.store
            openPhoneAppLink(route: .record, router: router, account: account, meetingIDs: store.meetings.map(\.id) + store.deletedMeetings.map(\.id))
        case .contactSupport:
            guard let url = supportMailURL(address: supportEmailAddress, subject: String(localized: "Gistsmith desteği"), facts: phoneSupportMailFacts()) else {
                quickActionLogger.error("Support mail link could not be built")
                isShowingSupportAddress = true
                return
            }
            openURL(url) { (accepted: Bool) in
                if !accepted {
                    quickActionLogger.warning("No app took the support mail link")
                    isShowingSupportAddress = true
                }
            }
        case .clearStorage:
            isClearingStorage = true
        }
    }
}

/// The support email's device facts: app version and build, iOS version and the hardware model identifier.
@MainActor
func phoneSupportMailFacts() -> SupportMailFacts {
    var system: utsname = utsname()
    uname(&system)
    let model: String = withUnsafeBytes(of: &system.machine) { (raw: UnsafeRawBufferPointer) -> String in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
    return SupportMailFacts(
        appVersion: currentReportDiagnostics(bundle: Bundle.main, platformName: "iOS").appVersion,
        systemVersion: "iOS \(UIDevice.current.systemVersion)", deviceModel: model
    )
}

/// One clearable recording with its size on disk (nil with the reason when the size could not be read).
private struct ClearableRow: Identifiable {
    let item: ClearableRecording
    let size: Result<Int64, StorageSizeError>
    var id: String { "\(item.kind)-\(item.id)" }
}

/// A recording's size could not be read.
private struct StorageSizeError: Error {
    let reason: String
}

/// "Clear storage": lists the failed local recordings (count, total size, each title and size), deletes only those after
/// the user confirms. Meetings go through the library's delete path and are then removed for good (`trashMeetings`,
/// `purgeDeleted`); failed Watch imports through `PhoneWatchLink.deleteImport`. Saved notes are never listed.
private struct PhoneClearStorageSheet: View {
    let session: PhoneAccountSession
    let router: PhoneRouter
    let account: HostedAccount
    let watchLink: PhoneWatchLink
    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var errors: [String] = []
    @State private var isConfirming: Bool = false
    /// Read when the sheet opens and after a delete (sizes come from disk, so not on every redraw).
    @State private var rows: [ClearableRow] = []

    /// The clearable recordings now, each with its size: failed meetings with nothing written whose audio was deleted or
    /// whose recordings on this iPhone cannot be read (a meeting whose folder cannot be found is left out and its reason
    /// shown), then failed Watch imports.
    private func currentRows() -> [ClearableRow] {
        let candidates: [MeetingRecord] = clearableCandidateMeetings(
            records: session.store.meetings, locked: phoneLockedMeetingIDs(store: session.store, recorder: session.recorder)
        )
        var unreadable: Set<String> = []
        for record in candidates where !record.audioDeleted {
            do {
                // A folder without recordings is not enough: a meeting synced from the Mac has its audio there.
                if meetingAudioOnDisk(directory: try session.store.sessionDirectory(id: record.id)) == .unreadable {
                    unreadable.insert(record.id)
                }
            } catch {
                quickActionLogger.error("Meeting folder not found, meeting: \(record.id, privacy: .public), error: \(String(describing: error), privacy: .public)")
                errors = appendUnique(messages: errors, message: userFacingMessage(error: error))
            }
        }
        let meetings: [MeetingRecord] = clearableFailedMeetings(candidates: candidates, unreadableAudioIDs: unreadable)
        return clearableRecordings(meetings: meetings, failedWatchImports: watchLink.failedImports).map { (item: ClearableRecording) -> ClearableRow in
            ClearableRow(item: item, size: size(item: item))
        }
    }

    var body: some View {
        NavigationStack {
            PhoneGroupedList {
                if account.requiresSignIn {
                    Section {
                        Text("Kayıtlar hesabına göre saklanır. Önce giriş yap, sonra yeniden dene.")
                            .appFont(size: 15, weight: .regular)
                            .foregroundStyle(Theme.ink)
                    }
                } else if rows.isEmpty {
                    Section {
                        Text("Silinecek başarısız kayıt yok. Notların ve transkriptlerin burada hiç listelenmez.")
                            .appFont(size: 15, weight: .regular)
                            .foregroundStyle(Theme.ink)
                    }
                } else {
                    Section {
                        LabeledContent {
                            Text(verbatim: totalSizeText(rows: rows))
                                .monospacedDigit()
                        } label: {
                            Text("\(rows.count) başarısız kayıt")
                        }
                        .appFont(size: 16, weight: .semibold)
                    } footer: {
                        PhoneSecondaryText {
                            Text("İşlenemeyen, notu ve transkripti olmayan kayıtlar ile içe aktarılamayan Apple Watch kayıtları. Notların, transkriptlerin ve kendi yazdıkların silinmez.")
                        }
                    }
                    Section {
                        ForEach(rows) { (row: ClearableRow) in
                            LabeledContent {
                                switch row.size {
                                case .success(let bytes):
                                    Text(verbatim: bytes.formatted(.byteCount(style: .file).locale(interfaceLocale())))
                                        .monospacedDigit()
                                case .failure(let error):
                                    Text("Boyut okunamadı: \(error.reason)")
                                }
                            } label: {
                                Label {
                                    Text(verbatim: row.item.title.isEmpty ? String(localized: "Adsız kayıt") : row.item.title)
                                } icon: {
                                    Image(systemName: row.item.kind == .watchRecording ? "applewatch" : "waveform")
                                }
                            }
                            .appFont(size: 15, weight: .regular)
                        }
                    }
                    Section {
                        Button(role: .destructive) {
                            isConfirming = true
                        } label: {
                            Text("\(rows.count) kaydı sil")
                                .frame(maxWidth: .infinity)
                                .foregroundStyle(NoticeSeverity.error.tint)
                        }
                    }
                }
                if !errors.isEmpty {
                    Section {
                        PhoneErrorList(messages: errors)
                    }
                }
            }
            .navigationTitle("Depolamayı temizle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                }
            }
            .confirmationDialog("Başarısız kayıtlar silinsin mi?", isPresented: $isConfirming, titleVisibility: .visible) {
                Button("Kalıcı olarak sil", role: .destructive) { delete(targets: rows) }
                Button("Vazgeç", role: .cancel) {}
            } message: {
                Text("Kayıtlar bütün cihazlarından silinir; geri alınamaz.")
            }
        }
        .onAppear { rows = currentRows() }
    }

    /// Deletes the listed recordings: meetings through the library's delete path then for good, Watch imports through the
    /// link. Errors stay on the sheet; with none it closes.
    private func delete(targets: [ClearableRow]) {
        let meetingIDs: Set<String> = Set(targets.filter { $0.item.kind == .meeting }.map(\.item.id))
        var problems: [String] = []
        if !meetingIDs.isEmpty {
            problems += phoneTrashMeetings(ids: meetingIDs, store: session.store, recorder: session.recorder, player: session.player, router: router)
            let trashed: Set<String> = meetingIDs.subtracting(session.store.meetings.map(\.id))
            problems += session.store.purgeDeleted(ids: trashed)
        }
        for row in targets where row.item.kind == .watchRecording {
            watchLink.deleteImport(recordingID: row.item.id)
        }
        quickActionLogger.info("Storage cleared, meetings: \(meetingIDs.count, privacy: .public), problems: \(problems.count, privacy: .public)")
        errors = problems
        rows = currentRows()
        if problems.isEmpty {
            dismiss()
        }
    }

    private func size(item: ClearableRecording) -> Result<Int64, StorageSizeError> {
        do {
            switch item.kind {
            case .meeting:
                return .success(try directorySize(url: try session.store.sessionDirectory(id: item.id)))
            case .watchRecording:
                return .success(try watchLink.inboxAudioBytes(recordingID: item.id))
            }
        } catch {
            quickActionLogger.error("Recording size could not be read, item: \(item.id, privacy: .public), error: \(String(describing: error), privacy: .public)")
            return .failure(StorageSizeError(reason: userFacingMessage(error: error)))
        }
    }

    /// The sizes that could be read, summed; with unreadable ones the total says it is at least that much.
    private func totalSizeText(rows: [ClearableRow]) -> String {
        let known: [Int64] = rows.compactMap { (row: ClearableRow) -> Int64? in try? row.size.get() }
        let total: String = known.reduce(0, +).formatted(.byteCount(style: .file).locale(interfaceLocale()))
        return known.count == rows.count ? total : String(localized: "en az \(total)")
    }
}

/// The allocated size of every file under `url`.
private func directorySize(url: URL) throws -> Int64 {
    let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
    var enumerationError: (any Error)?
    let enumerator: FileManager.DirectoryEnumerator? = FileManager.default.enumerator(
        at: url, includingPropertiesForKeys: Array(keys), options: []
    ) { (_: URL, error: any Error) -> Bool in
        enumerationError = error
        return false
    }
    guard let enumerator else {
        throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
    }
    var total: Int64 = 0
    for case let file as URL in enumerator {
        let values: URLResourceValues = try file.resourceValues(forKeys: keys)
        guard values.isRegularFile == true else {
            continue
        }
        guard let size = values.totalFileAllocatedSize else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        total += Int64(size)
    }
    if let enumerationError {
        throw enumerationError
    }
    return total
}
