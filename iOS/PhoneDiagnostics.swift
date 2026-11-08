import AINotepadCore
import AINotepadUI
import AVFAudio
import EventKit
import SwiftUI
import UIKit
import UserNotifications
import os

// iPhone tanılaması (Ayarlar › Destek › Tanılama; Mac'teki Ayarlar › Tanılama): sürüm, sistem, hesap, bağlantı,
// izinler, canlı metin, sesinden tanıma, depolama ve son hatalar. Toplantı içeriği (ses, metin, not, başlık, ad), anahtar,
// jeton ve e-posta girmez; altyapı ayrıntısı Mac'teki Gistsmith'teki gibi yazılmaz (bkz. HostedDiagnostics.swift).
// Kullanıcı kopyalamadıkça hiçbir yere gitmez.

/// Uygulamanın log alt sistemi (son hatalar buradan okunur).
private let phoneLogSubsystem: String = "com.senoldogan.AINotepad"

private let phoneDiagnosticsLogger: Logger = Logger(subsystem: phoneLogSubsystem, category: "PhoneDiagnostics")

/// Sunucu erişim denetiminin zaman aşımı.
private let phoneHealthTimeoutSec: Double = 10

/// Hata mesajlarından silinecek kullanıcı adları: yüklü hesabın Ayarlar'daki adı (hesabın ayar alanında, bkz.
/// `PhoneStore.userName`; iPhone'da sistem kullanıcı adı anlamsız). Hesap yüklenmediyse ad da yoktur. Hesabın ayar alanı
/// açılamazsa neden loglanır; tanılama yine gösterilir (kullanıcı kopyalamadıkça hiçbir yere gitmez).
func diagnosticsUserNames() -> [String] {
    guard let key = AppPaths.activeAccountKey() else {
        return []
    }
    do {
        return [try hostedAccountDefaults(accountKey: key).string(forKey: PhoneSettingsKey.userName) ?? ""]
    } catch {
        phoneDiagnosticsLogger.error("Tanılamada gizlenecek ad okunamadı, hata: \(String(describing: error), privacy: .private)")
        return []
    }
}

/// Tanılamanın ağ ve disk okumaları (ekranda ve kopyalanan metinde aynı); okunurken nil.
private struct PhoneDiagnosticsReadings {
    let health: APIHealth?
    let errors: Result<[DiagnosticErrorEntry], any Error>
    let notifications: UNAuthorizationStatus
    let sessionsSize: Result<Int64, any Error>
    let modelsSize: Result<Int64, any Error>
    let freeSpace: Result<Int64, any Error>
}

/// Uygulama bölümü: ad, sürüm, tür, sistem ve iPhone modeli (seri numarası ya da donanım kimliği yok).
@MainActor
private func phoneAppDiagnostics(bundle: Bundle) -> DiagnosticsSection {
    let version: String = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    let build: String = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    let modelLabel: String = String(localized: "iPhone modeli")
    let model: DiagnosticsItem
    do {
        model = DiagnosticsItem(label: modelLabel, value: try deviceMachineIdentifier(), status: .plain)
    } catch {
        model = DiagnosticsItem(label: modelLabel, value: String(localized: "okunamadı"), status: .error)
    }
    return DiagnosticsSection(title: String(localized: "Uygulama"), items: [
        DiagnosticsItem(label: String(localized: "Ad"), value: appName, status: .plain),
        DiagnosticsItem(label: String(localized: "Sürüm"), value: appVersionText(version: version, build: build), status: .plain),
        DiagnosticsItem(label: String(localized: "Tür"), value: String(localized: "Abonelik sürümü"), status: .plain),
        DiagnosticsItem(label: String(localized: "Sistem"), value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)", status: .plain),
        model,
    ])
}

/// Bildirim izninin satırı (toplantı hatırlatmaları için); okunurken nil. Reddedildiyse dikkat. Saf fonksiyondur.
private func notificationDiagnostics(status: UNAuthorizationStatus?) -> DiagnosticsItem {
    let label: String = String(localized: "Bildirimler")
    guard let status else {
        return DiagnosticsItem(label: label, value: String(localized: "Okunuyor…"), status: .plain)
    }
    switch status {
    case .authorized, .provisional, .ephemeral: return DiagnosticsItem(label: label, value: String(localized: "İzin verildi"), status: .plain)
    case .denied: return DiagnosticsItem(label: label, value: String(localized: "Reddedildi"), status: .attention)
    case .notDetermined: return DiagnosticsItem(label: label, value: String(localized: "Henüz sorulmadı"), status: .plain)
    @unknown default: return DiagnosticsItem(label: label, value: String(localized: "Bilinmiyor"), status: .plain)
    }
}

/// İzinler bölümü: mikrofon, takvim, anımsatıcılar ve bildirimler.
private func phonePermissionDiagnostics(notifications: UNAuthorizationStatus?) -> DiagnosticsSection {
    DiagnosticsSection(title: String(localized: "İzinler"), items: [
        microphonePermissionDiagnostics(permission: AVAudioApplication.shared.recordPermission),
        eventKitPermissionDiagnostics(label: String(localized: "Takvim"), status: EKEventStore.authorizationStatus(for: .event)),
        eventKitPermissionDiagnostics(label: String(localized: "Anımsatıcılar"), status: EKEventStore.authorizationStatus(for: .reminder)),
        notificationDiagnostics(status: notifications),
    ])
}

/// Canlı metin bölümü: yalnızca nerede çalıştığı (sunucunun önerisi), bulut ya da bu iPhone. Sağlayıcı ve model adları
/// yazılmaz.
@MainActor
private func phoneLiveDiagnostics(account: HostedAccount) -> DiagnosticsSection {
    let place: String
    switch hostedExpectedLiveEngine(account: account) {
    case .deepgram:
        place = String(localized: "Bulut")
    case .whisperKit:
        place = String(localized: "Bu iPhone'da")
    }
    return DiagnosticsSection(title: String(localized: "Canlı metin"), items: [DiagnosticsItem(label: String(localized: "Çalıştığı yer"), value: place, status: .plain)])
}

/// Sesinden tanıma bölümü: ayar, modelin durumu ve kayıtlı ses sayısı (adlar yazılmaz).
@MainActor
private func phoneVoiceDiagnostics(voices: PhoneVoices) -> DiagnosticsSection {
    let title: String = String(localized: "Sesinden tanıma")
    guard phoneVoiceRecognitionEnabled() else {
        return DiagnosticsSection(title: title, items: [
            DiagnosticsItem(label: String(localized: "Durum"), value: String(localized: "Kapalı"), status: .plain),
            DiagnosticsItem(label: String(localized: "Tanınan sesler"), value: "\(voices.registered.count)", status: .plain),
        ])
    }
    let modelLabel: String = String(localized: "Ses modeli")
    let model: DiagnosticsItem
    switch voices.modelState {
    case .checking:
        model = DiagnosticsItem(label: modelLabel, value: String(localized: "Denetleniyor…"), status: .plain)
    case .missing:
        model = DiagnosticsItem(label: modelLabel, value: String(localized: "İndirilmedi"), status: .attention)
    case .downloading(let fraction):
        model = DiagnosticsItem(
            label: modelLabel, value: String(localized: "İndiriliyor, \(fraction.formatted(.percent.precision(.fractionLength(0)).locale(interfaceLocale())))"),
            status: .plain
        )
    case .ready:
        model = DiagnosticsItem(label: modelLabel, value: String(localized: "Hazır"), status: .plain)
    case .failed(let message):
        model = DiagnosticsItem(label: modelLabel, value: redactedDiagnosticText(text: message, userNames: diagnosticsUserNames()), status: .error)
    }
    var items: [DiagnosticsItem] = [DiagnosticsItem(label: String(localized: "Durum"), value: String(localized: "Açık"), status: .plain), model]
    items.append(DiagnosticsItem(label: String(localized: "Tanınan sesler"), value: "\(voices.registered.count)", status: .plain))
    if let error = voices.registryError {
        items.append(DiagnosticsItem(label: String(localized: "Kayıtlı sesler"), value: redactedDiagnosticText(text: error, userNames: diagnosticsUserNames()), status: .error))
    }
    return DiagnosticsSection(title: title, items: items)
}

/// Depolama bölümü: toplantı sayısı, toplantıların ve modellerin kapladığı alan, boş alan.
private func phoneStorageDiagnostics(meetingCount: Int, readings: PhoneDiagnosticsReadings?) -> DiagnosticsSection {
    let title: String = String(localized: "Depolama")
    let count: DiagnosticsItem = DiagnosticsItem(label: String(localized: "Toplantılar"), value: "\(meetingCount)", status: .plain)
    guard let readings else {
        return DiagnosticsSection(title: title, items: [count, DiagnosticsItem(label: String(localized: "Boyut"), value: String(localized: "Okunuyor…"), status: .plain)])
    }
    return DiagnosticsSection(title: title, items: [
        count,
        storageSizeDiagnostics(label: String(localized: "Toplantıların boyutu"), size: readings.sessionsSize),
        storageSizeDiagnostics(label: String(localized: "Modeller"), size: readings.modelsSize),
        freeSpaceDiagnostics(capacity: readings.freeSpace),
    ])
}

/// Tüm bölümler; ekran ve kopyalanan metin bunlardan üretilir (tarihler `dateText` biçiminde: ekranda yerel, kopyalanan
/// metinde ISO 8601). Okumalar sürerken sunucu ve son hatalar "denetleniyor/okunuyor" görünür.
@MainActor
private func collectPhoneDiagnostics(
    account: HostedAccount, store: PhoneStore, readings: PhoneDiagnosticsReadings?, dateText: (Date) -> String
) -> [DiagnosticsSection] {
    let base: Result<URL, any Error> = Result { try hostedDiagnosticsAPIBase() }
    return [
        phoneAppDiagnostics(bundle: .main),
        hostedAccountDiagnostics(account: account, dateText: dateText),
        hostedConnectionDiagnostics(base: base, health: readings?.health),
        phonePermissionDiagnostics(notifications: readings?.notifications),
        phoneLiveDiagnostics(account: account),
        phoneVoiceDiagnostics(voices: store.voices),
        phoneStorageDiagnostics(meetingCount: store.meetings.count, readings: readings),
        readings.map { recentErrorsDiagnostics(errors: $0.errors) } ?? pendingRecentErrorsDiagnostics(),
    ]
}

/// Sunucuyu denetler, son hataları, bildirim iznini ve disk kullanımını okur (birbirini beklemez; disk okuması ana iş
/// parçacığı dışında).
@MainActor
private func readPhoneDiagnostics() async -> PhoneDiagnosticsReadings {
    let base: Result<URL, any Error> = Result { try hostedDiagnosticsAPIBase() }
    let userNames: [String] = diagnosticsUserNames()
    async let health: APIHealth? = probeAPIHealth(base: base, timeoutSec: phoneHealthTimeoutSec)
    async let errors: Result<[DiagnosticErrorEntry], any Error> = loadRecentAppErrorsInBackground(subsystem: phoneLogSubsystem, userNames: userNames)
    async let notifications: UNAuthorizationStatus = UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    let sessions: Result<URL, any Error> = Result { try AppPaths.sessionsDirectory() }
    let models: Result<URL, any Error> = Result { try AppPaths.modelsDirectory() }
    let sizes: (sessions: Result<Int64, any Error>, models: Result<Int64, any Error>, free: Result<Int64, any Error>) = await runBlocking(qos: .utility) { () -> (sessions: Result<Int64, any Error>, models: Result<Int64, any Error>, free: Result<Int64, any Error>) in
        (
            sessions: sessions.flatMap { (url: URL) -> Result<Int64, any Error> in Result { try directorySize(url: url) } },
            models: models.flatMap { (url: URL) -> Result<Int64, any Error> in Result { try directorySize(url: url) } },
            free: models.flatMap { (url: URL) -> Result<Int64, any Error> in Result { try availableCapacity(url: url) } }
        )
    }
    return PhoneDiagnosticsReadings(
        health: await health, errors: await errors, notifications: await notifications,
        sessionsSize: sizes.sessions, modelsSize: sizes.models, freeSpace: sizes.free
    )
}

/// Ekrandaki tarih: arayüz dilinde gün ve saat. Saf fonksiyondur.
private func phoneDiagnosticsScreenDate(date: Date) -> String {
    date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(interfaceLocale()))
}

/// Kopyalanan tanılamadaki tarih: ISO 8601 (destekte saat dilimi karışmasın). Saf fonksiyondur.
private func phoneDiagnosticsCopyDate(date: Date) -> String {
    date.formatted(.iso8601)
}

/// Geri bildirime eklenen tanılama metni (Mac'teki `makeDiagnostics`): okumalar beklenir, metin kopyalanan tanılamayla
/// aynıdır (tarihler ISO 8601; ses, metin, not, anahtar ve jeton yok).
@MainActor
func makePhoneDiagnosticsText(account: HostedAccount, store: PhoneStore) async -> String {
    let readings: PhoneDiagnosticsReadings = await readPhoneDiagnostics()
    let sections: [DiagnosticsSection] = collectPhoneDiagnostics(account: account, store: store, readings: readings, dateText: phoneDiagnosticsCopyDate)
    return diagnosticsText(sections: sections, generatedAt: Date())
}

/// Tanılama ekranı: bölümler (solda soluk etiket, sağda değer; kötü değer uyarı renginde simgeyle), "Yenile" ve
/// "Tanılama bilgisini kopyala". Kopyalama, okumalar bitmeden kapalıdır (sunucu denetimi ve son hatalar eksik kalmasın).
struct PhoneDiagnosticsScreen: View {
    let account: HostedAccount
    let store: PhoneStore
    @State private var readings: PhoneDiagnosticsReadings?
    @State private var isRefreshing: Bool = false
    @State private var copied: Bool = false

    var body: some View {
        let sections: [DiagnosticsSection] = collectPhoneDiagnostics(account: account, store: store, readings: readings, dateText: phoneDiagnosticsScreenDate)
        List {
            Section {
                Button {
                    guard let readings else {
                        return
                    }
                    let support: [DiagnosticsSection] = collectPhoneDiagnostics(account: account, store: store, readings: readings, dateText: phoneDiagnosticsCopyDate)
                    UIPasteboard.general.string = diagnosticsText(sections: support, generatedAt: Date())
                    copied = true
                } label: {
                    Label(copied ? "Kopyalandı" : "Tanılama bilgisini kopyala", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(isRefreshing || readings == nil)
            } footer: {
                Text("Sorun bildirirken işe yarar; ses, metin, not ve anahtar yok, kopyalamadıkça hiçbir yere gitmez.")
            }
            ForEach(Array(sections.enumerated()), id: \.offset) { (entry: (offset: Int, element: DiagnosticsSection)) in
                Section {
                    ForEach(Array(entry.element.items.enumerated()), id: \.offset) { (item: (offset: Int, element: DiagnosticsItem)) in
                        PhoneDiagnosticsRow(item: item.element)
                    }
                } header: {
                    Text(verbatim: entry.element.title)
                }
            }
        }
        .navigationTitle("Tanılama")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isRefreshing {
                    ProgressView()
                } else {
                    Button("Yenile", systemImage: "arrow.clockwise") { Task { await refresh() } }
                }
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        isRefreshing = true
        copied = false
        defer { isRefreshing = false }
        readings = nil
        if phoneVoiceRecognitionEnabled() {
            await store.voices.refreshModelState()
        }
        readings = await readPhoneDiagnostics()
    }
}

/// Tanılama satırı: solda soluk etiket, sağda değer (seçilebilir); kötü değer uyarı renginde simgeyle.
private struct PhoneDiagnosticsRow: View {
    let item: DiagnosticsItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: item.label)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let severity = phoneNoticeSeverity(status: item.status) {
                    Image(systemName: severity.symbol)
                        .imageScale(.small)
                        .foregroundStyle(severity.tint)
                        .accessibilityHidden(true)
                }
                Text(verbatim: item.value)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .appFont(size: 14, weight: .regular)
    }
}

/// Değerin durumuna karşılık gelen uyarı önemi; olağan değerde nil (simge yok). Saf fonksiyondur.
private func phoneNoticeSeverity(status: DiagnosticsStatus) -> NoticeSeverity? {
    switch status {
    case .plain: nil
    case .attention: .attention
    case .error: .error
    }
}
