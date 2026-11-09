import AINotepadCore
import os
import Foundation

// Abonelik sürümünün paylaşılan koda bağlandığı noktalar (`#if HOSTED_EDITION` ile çağrılır): LLM sağlayıcısı, son
// geçiş, kurulum eksikleri, canlı metin motoru ve rapor hedefi.

#if os(macOS)
/// Abonelik sürümünde motor seçimi gizlidir: `AppModel`'in yerel motoru WhisperKit'tir; her kaydın canlı motoru
/// (Deepgram ya da Mac) kayıt başında sunucuya göre seçilir (`hostedLiveChoice`).
let hostedLocalEngine: LiveEngine = .whisperKit
#endif

private let seamsLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "HostedSeams")

/// A recording's live routes: per-track route (diagnostics, telemetry, the record's engine), the hybrid session's start
/// for the tracks not written on the device, and the tracks written on the device from the start.
struct HostedLiveChoice {
    let routes: HostedLiveRoutes
    let start: HybridLiveStart
    let onDeviceSpeakers: Set<Speaker>
}

/// Chooses the recording's live routes (after the meeting session opened). "Diğerleri" is re-transcribed by the final
/// pass, so for a user in the on-device rollout (`liveOnDevice`) whose device has the language's Apple model installed
/// its live text is written on the device (`hostedLiveRoutes`); "Sen" (Mac) follows the server. When the device supports
/// the language but lacks the model, the model is installed in the background on an inexpensive network for the next
/// meeting. Tracks on the cloud route need a first grant (it declares how many tracks stream, for the server's budget
/// estimate; the grant itself is discarded, every connection gets a new one). If the server offers no cloud stream or
/// the grant fails (budget, network, server), those tracks run on the device's engine (`localSpeechAvailable`: always on
/// the Mac, iOS 26+ on iPhone); without one there is no live text (`hostedLiveStartPlan`: the recording continues, the
/// transcript and note come after it). Grants are not stored or logged.
@MainActor
func hostedLiveChoice(language: MeetingLanguage, keyterms: [String], liveSpeakers: Set<Speaker>, localSpeechAvailable: Bool) async -> HostedLiveChoice {
    let serverEngine: HostedLiveEngine = hostedExpectedLiveEngine(account: .shared)
    let inRollout: Bool = hostedExpectedLiveOnDevice(account: .shared)
    let support: OnDeviceLiveSupport = inRollout
        ? await currentOnDeviceLiveSupport(language: language)
        : onDeviceLiveSupport(systemSupported: appleSpeechSupportedBySystem(), choice: nil, installed: false)
    if onDeviceLiveUnavailable(inRollout: inRollout, support: support) != nil {
        seamsLogger.info("Cihaz içi canlı önizleme bu toplantıda kullanılamıyor, durum: \(String(describing: support), privacy: .public)")
        recordTelemetryCount(kind: .onDeviceLiveUnavailable)
    }
    if let model = onDeviceModelToInstall(inRollout: inRollout, support: support) {
        installOnDeviceSpeechModelInBackground(language: language, choice: model)
    }
    let routes: HostedLiveRoutes = hostedLiveRoutes(serverEngine: serverEngine, inRollout: inRollout, support: support)
    let onDevice: Set<Speaker> = onDeviceSpeakers(routes: routes, liveSpeakers: liveSpeakers)
    if !onDevice.isEmpty {
        recordTelemetryCount(kind: .onDeviceLiveStarted)
    }
    let cloud: Set<Speaker> = cloudSpeakers(routes: routes, liveSpeakers: liveSpeakers)
    guard !cloud.isEmpty else {
        return hostedLiveChoiceWithoutCloud(routes: routes, liveSpeakers: liveSpeakers, onDeviceSpeakers: onDevice, localSpeechAvailable: localSpeechAvailable)
    }
    let client: HostedClient
    let meetingID: String
    let grant: HostedDeepgramGrant
    let streams: Int = cloud.count
    do {
        client = try HostedServices.requireClient()
        guard let current = await client.currentMeetingID() else {
            throw HostedClientError.noActiveMeeting
        }
        meetingID = current
        grant = try await client.deepgramGrant(meetingID: meetingID, streams: streams)
    } catch {
        seamsLogger.warning("Deepgram jetonu alınamadı, canlı metin bulutta değil, hata: \(String(describing: error), privacy: .private)")
        return hostedLiveChoiceWithoutCloud(
            routes: routesAfterCloudFallback(routes: routes), liveSpeakers: liveSpeakers, onDeviceSpeakers: onDevice, localSpeechAvailable: localSpeechAvailable
        )
    }
    let source: DeepgramLiveSource = DeepgramLiveSource(
        language: language, keyterms: keyterms, options: hostedDeepgramListenOptions(grant: grant),
        onConnectionEvent: { (event: DeepgramConnectionEvent) -> Void in
            Task { @MainActor in
                switch event {
                case .dropped: recordTelemetryCount(kind: .deepgramSocketDrop)
                case .reconnected: recordTelemetryCount(kind: .deepgramReconnect)
                }
            }
        }
    ) { () async throws -> String in
        // Duraklatmada jeton istenmez (sunucu duraklatmayı kapatırdı): kopan bağlantı kayıt sürünce yeniden kurulur.
        await HostedAccount.shared.waitWhileMeetingPaused(meetingID: meetingID)
        return try await client.deepgramGrant(meetingID: meetingID, streams: streams).accessToken
    }
    return HostedLiveChoice(routes: routes, start: .deepgram(source), onDeviceSpeakers: onDevice)
}

/// The user is in the on-device live preview rollout (from the last entitlements read); not signed in or unknown: no.
@MainActor
func hostedExpectedLiveOnDevice(account: HostedAccount) -> Bool {
    switch account.state {
    case .signedIn(let entitlements):
        hostedLiveOnDevice(entitlements: entitlements)
    case .signedInStatusUnknown, .loading, .signedOut, .unavailable:
        false
    }
}

/// Languages whose background model install already started in this launch (one attempt per launch and language).
@MainActor private var onDeviceModelInstallsStarted: Set<MeetingLanguage> = []

/// Installs the language's Apple speech model in the background so the next meeting can use the on-device preview:
/// only on an inexpensive network (not cellular, hotspot or Low Data Mode) and outside Low Power Mode, once per launch
/// and language. A failure is logged; the meeting in progress is not affected (its live text is in the cloud).
@MainActor
private func installOnDeviceSpeechModelInBackground(language: MeetingLanguage, choice: AppleSpeechChoice) {
    guard !onDeviceModelInstallsStarted.contains(language) else {
        return
    }
    guard HostedAccount.shared.isOnInexpensiveNetwork, !ProcessInfo.processInfo.isLowPowerModeEnabled else {
        seamsLogger.info("Cihaz içi konuşma modeli şimdi indirilmiyor (ücretli ağ ya da düşük güç), yerel ayar: \(choice.localeIdentifier, privacy: .public)")
        return
    }
    onDeviceModelInstallsStarted.insert(language)
    seamsLogger.info("Cihaz içi konuşma modeli arka planda kuruluyor, yerel ayar: \(choice.localeIdentifier, privacy: .public)")
    Task.detached(priority: .background) {
        do {
            _ = try await prepareAppleSpeech(language: language) { (_: Double) -> Void in }
            seamsLogger.info("Cihaz içi konuşma modeli kuruldu, yerel ayar: \(choice.localeIdentifier, privacy: .public)")
        } catch {
            seamsLogger.error("Cihaz içi konuşma modeli kurulamadı, yerel ayar: \(choice.localeIdentifier, privacy: .public), hata: \(String(describing: error), privacy: .private)")
        }
    }
}

/// Bulut olmadan canlı metin (bulutsuz izler için): cihazdaki motor (bir iz yerel motorda yazılıyorsa kullanımı sayılır)
/// ya da yok (iPhone, iOS 18–25: kayıt sürer, metin ve not kayıttan sonra; cihaz içi kullanım sayılmaz).
@MainActor
private func hostedLiveChoiceWithoutCloud(
    routes: HostedLiveRoutes, liveSpeakers: Set<Speaker>, onDeviceSpeakers: Set<Speaker>, localSpeechAvailable: Bool
) -> HostedLiveChoice {
    switch hostedLiveStartPlan(cloudGranted: false, localSpeechAvailable: localSpeechAvailable) {
    case .local, .cloud:
        if liveSpeakers.contains(where: { (speaker: Speaker) -> Bool in trackRoute(routes: routes, speaker: speaker) == .local }) {
            recordFeatureUsage(feature: .onDeviceLive)
        }
        return HostedLiveChoice(routes: routes, start: .local, onDeviceSpeakers: onDeviceSpeakers)
    case .unavailable:
        return HostedLiveChoice(
            routes: routes, start: .unavailable(message: userFacingMessage(error: AppleSpeechError.requiresNewerSystem)), onDeviceSpeakers: onDeviceSpeakers
        )
    }
}

/// Sunucunun önerdiği canlı motor (son okunan hak durumundan): giriş yapılmış ve sunucu `deepgram` diyorsa bulut,
/// değilse (hak durumu okunamadı, okunuyor, giriş yok, hesap kullanılamıyor dahil) Mac.
@MainActor
func hostedExpectedLiveEngine(account: HostedAccount) -> HostedLiveEngine {
    switch account.state {
    case .signedIn(let entitlements):
        hostedLiveEngine(entitlements: entitlements)
    case .signedInStatusUnknown, .loading, .signedOut, .unavailable:
        .whisperKit
    }
}

/// Sor (toplantı dışı yapay zekâ) şu an neden kullanılamıyor; kullanılabiliyorsa nil. Deneme ilk toplantıyla başlar
/// (`trialEndsAt` o zaman dolar): abonelik erişimi olmayan, denemesi başlamamış hesap önce bir toplantı kaydetmeli.
/// Sunucu çağrılmaz; diğer retler (deneme bitti, sınır) sunucunun hatasıyla gösterilir.
@MainActor
func hostedAskUnavailableReason(account: HostedAccount) -> String? {
    // Hakkı yoksa (deneme bitti, bu Mac'te kullanıldı) "önce toplantı kaydet" denmez: sorunca abone olma teklifi açılır.
    guard case .signedIn(let entitlements) = account.state, case .trial(.notStarted) = hostedPlanStatus(entitlements: entitlements, now: Date()) else {
        return nil
    }
    return String(localized: "Önce bir toplantı kaydet: ücretsiz deneme ilk toplantıyla başlar, sonra toplantılarına soru sorabilirsin.")
}

/// Açılışta Mac modeli (~630 MB) yüklensin mi: yalnızca giriş yapılmış ve sunucu bulut canlı metnini önermiyorsa (ya
/// da hak durumu okunamadıysa: çevrimdışıyken bulut da kullanılamaz). Bulut kullanılabiliyorsa model ilk Mac'e geçişte
/// iner; giriş yapılmamışsa hiç inmez.
@MainActor
func hostedPreloadsLocalModel(account: HostedAccount) -> Bool {
    switch account.state {
    case .signedIn(let entitlements):
        return hostedLiveEngine(entitlements: entitlements) == .whisperKit
    case .signedInStatusUnknown:
        return true
    case .loading, .signedOut, .unavailable:
        return false
    }
}

/// Kayıt sırasındaki ve kaydın hemen ardındaki yapay zekâ çağrıları: son açılan toplantının bütçesinden düşer.
@MainActor
func hostedMeetingLLMProvider() throws -> LLMProvider {
    // Çevrimdışı kayıtta toplantı oturumu yok: canlı çağrılar yapılmaz (önceki toplantının bütçesine yazılmaz).
    guard !HostedAccount.shared.isOfflineRecording else {
        throw HostedClientError.offlineRecording
    }
    let client: HostedClient = try HostedServices.requireClient()
    return .hosted(HostedLLMConfig(baseURL: client.baseURL, credentials: client, scope: .meeting))
}

/// Kaydı biten toplantının notu: kaydın kendi sunucu oturumunun bütçesinden (bkz. `HostedMeetingLink`); kaydın oturumu
/// yoksa hesap çağrısı (kullanıcının toplantı dışı payından), başka bir toplantının bütçesi asla kullanılmaz.
func hostedRecordedMeetingLLMProvider(recordID: String) throws -> LLMProvider {
    let client: HostedClient = try HostedServices.requireClient()
    guard let serverMeetingID = hostedServerMeetingID(recordID: recordID, links: try loadHostedMeetingLinks()) else {
        return .hosted(HostedLLMConfig(baseURL: client.baseURL, credentials: client, scope: .account))
    }
    return .hosted(HostedLLMConfig(baseURL: client.baseURL, credentials: client, scope: .recordedMeeting(serverMeetingID: serverMeetingID)))
}

/// Hesap düzeyindeki yapay zekâ çağrısından önce: hakkı yoksa (deneme bitti, bu Mac'te kullanıldı, abonelik sona erdi)
/// istek sunucuya gitmez, abone olma teklifi açılır (en çok `hostedSubscriptionPromptIntervalSec`'te bir) ve
/// `subscription_required` fırlar ("deneme ilk toplantıyla başlar" gibi yanıltıcı sunucu yanıtı yerine).
@MainActor
func requireHostedAIAllowance() throws {
    guard HostedAccount.shared.requiresSubscription else {
        return
    }
    HostedAccount.shared.promptSubscriptionIfDue()
    throw HostedAPIError(code: .subscriptionRequired, rawCode: HostedErrorCode.subscriptionRequired.rawValue, status: 402, serverMessage: "", path: "/v1/llm/messages")
}

/// Her zaman kullanılabilen yapay zekâ çağrıları (Sor, notu yeniden yazma, düzenleme, paylaşım çevirisi, görev aracı):
/// toplantı kimliği gönderilmez, kullanıcının sınırlarına sayılır.
func hostedAccountLLMProvider() throws -> LLMProvider {
    let client: HostedClient = try HostedServices.requireClient()
    return .hosted(HostedLLMConfig(baseURL: client.baseURL, credentials: client, scope: .account))
}

/// Kaydın ardından (ve yarıda kalan işlemenin sürdürülmesinde) son geçiş: kayıt sunucunun `/v1/transcribe` ucuyla
/// (ElevenLabs Scribe) yazıya dökülür; ses yalnızca kaydın kendi sunucu oturumuna yazılır (bkz. `HostedMeetingLink`).
/// Oturum önceden yeniden açılmaz: düzgün biten toplantı sunucuda işleme süresi (`MEETING_PROCESSING_HOURS`) boyunca
/// açıktır; kapanmışsa parça yüklemesi `meeting_not_active` alınca bir kez açılır (bkz. `HostedFinalTranscriber`).
/// Böylece yarıda kalan son geçişin sürdürülmesi yeniden işleme hakkı harcamaz. Kaydın oturumu yoksa son geçiş yapılmaz
/// ve nedeni toplantıda görünür.
func hostedFinalPassPlan(keyterms: [String], recordID: String) async -> FinalPassPlan {
    let client: HostedClient
    let links: [HostedMeetingLink]
    do {
        client = try HostedServices.requireClient()
        links = try loadHostedMeetingLinks()
    } catch {
        return .skip(reason: userFacingMessage(error: error))
    }
    guard let meetingID = hostedServerMeetingID(recordID: recordID, links: links) else {
        return .skip(reason: String(localized: "Bu toplantı sunucuda bir kayıt oturumuna bağlı değil; konuşmacılar canlı metinden kalır."))
    }
    return .run(TelemetryFinalTranscriber(inner: HostedFinalTranscriber(client: client, meetingID: meetingID, keyterms: keyterms)))
}

/// "Tekrar işle"nin son geçişi: kayıt baştan yeniden yazıya dökülür. Oturumun ek süresi geçtiyse ya da sesi zaten
/// yazıldıysa önce yeniden işleme için açılır (`reprocessMeeting`; sınırlı sayıda, yeni deneme ya da toplantı süresi
/// açmaz, ses hakkı kaydın süresi kadar yeniden açılır). Kaydın oturumu yoksa, yeniden açılamıyorsa ya da ses hakkı
/// kapandıysa son geçiş yapılmaz ve nedeni toplantıda görünür (önceki son geçiş metni varsa korunur).
func hostedReprocessFinalPassPlan(keyterms: [String], recordID: String) async -> FinalPassPlan {
    let client: HostedClient
    let links: [HostedMeetingLink]
    do {
        client = try HostedServices.requireClient()
        links = try loadHostedMeetingLinks()
    } catch {
        return .skip(reason: userFacingMessage(error: error))
    }
    guard let meetingID = hostedServerMeetingID(recordID: recordID, links: links) else {
        return .skip(reason: String(localized: "Bu toplantı sunucuda bir kayıt oturumuna bağlı değil; konuşmacılar canlı metinden kalır."))
    }
    do {
        let reopened: HostedReprocessedMeeting = try await client.reprocessMeeting(meetingID: meetingID)
        seamsLogger.info("Kaydın sunucu oturumu işlemeye açık, kalan yeniden işleme: \(reopened.reprocessesLeft, privacy: .public)")
    } catch let error as HostedAPIError where error.code == .notFound {
        // Toplantı sunucuda varsa (kapatma isteği yanıtlanıyorsa) 404 yeniden işleme ucunun olmadığıdır: sunucu güncel
        // değil. İşleme açıkça durur; son geçiş sessizce atlanmaz.
        if await hostedMeetingExists(client: client, meetingID: meetingID) {
            seamsLogger.error("Sunucu yeniden işleme ucunu tanımıyor, işleme durdu")
            return .stop(HostedClientError.serverOutdated(path: "/v1/meetings/{id}/reprocess"))
        }
        seamsLogger.warning("Kaydın sunucu oturumu yok, son geçiş yapılmadı")
        return .skip(reason: userFacingMessage(error: error))
    } catch {
        seamsLogger.warning("Kaydın sunucu oturumu yeniden açılamadı, hata: \(String(describing: error), privacy: .private)")
        return .skip(reason: userFacingMessage(error: error))
    }
    return .run(TelemetryFinalTranscriber(inner: HostedFinalTranscriber(client: client, meetingID: meetingID, keyterms: keyterms)))
}

/// Toplantı sunucuda var mı: kapatma isteği (bitmiş toplantıda etkisiz) yanıtlanıyorsa evet, `not_found` ise hayır; diğer
/// hatalarda bilinmez sayılır (hayır).
private func hostedMeetingExists(client: HostedClient, meetingID: String) async -> Bool {
    do {
        _ = try await client.endMeeting(meetingID: meetingID)
        return true
    } catch {
        seamsLogger.warning("Toplantının varlığı doğrulanamadı, hata: \(String(describing: error), privacy: .private)")
        return false
    }
}

/// Kayıt–sunucu oturumu bağlarının UserDefaults anahtarı.
private let hostedMeetingLinksKey: String = "hosted.meetingLinks"

/// Saklanan bağlar (yoksa boş); bozuk kayıt `StorageError`.
func loadHostedMeetingLinks() throws -> [HostedMeetingLink] {
    guard let data = UserDefaults.standard.data(forKey: hostedMeetingLinksKey) else {
        return []
    }
    do {
        return try JSONDecoder().decode([HostedMeetingLink].self, from: data)
    } catch {
        throw StorageError.writeFailed(path: hostedMeetingLinksKey, reason: "bağlar okunamadı: \(error.localizedDescription)")
    }
}

/// Kaydı sunucu oturumuna bağlar (en yeni `hostedMeetingLinkCapacity` bağ tutulur).
func saveHostedMeetingLink(link: HostedMeetingLink) throws {
    let links: [HostedMeetingLink] = appendingHostedMeetingLink(links: try loadHostedMeetingLinks(), link: link, capacity: hostedMeetingLinkCapacity)
    UserDefaults.standard.set(try JSONEncoder().encode(links), forKey: hostedMeetingLinksKey)
}

/// Kaydın bağını siler (sunucu oturumu yok).
func removeHostedMeetingLink(recordID: String) throws {
    UserDefaults.standard.set(try JSONEncoder().encode(removingHostedMeetingLink(links: try loadHostedMeetingLinks(), recordID: recordID)), forKey: hostedMeetingLinksKey)
}

/// Bekleyen kayıtların sahipleri (kayıt kimliği → kullanıcı) için UserDefaults anahtarı.
private let hostedRecordOwnersKey: String = "hosted.recordOwners"

/// Bekleyen kayıtların sahipleri; yoksa boş.
func loadHostedRecordOwners() -> [String: String] {
    UserDefaults.standard.dictionary(forKey: hostedRecordOwnersKey) as? [String: String] ?? [:]
}

/// Kaydı oturumdaki kullanıcıya yazar (kuyruğa alınırken): başka hesapla giriş yapılınca o hesaba faturalanmaz.
func saveHostedRecordOwner(recordID: String, userId: String) {
    var owners: [String: String] = loadHostedRecordOwners()
    owners[recordID] = userId
    UserDefaults.standard.set(owners, forKey: hostedRecordOwnersKey)
}

/// Bağlı kayıtların kimlikleri (okunamazsa hata).
func hostedLinkedRecordIDs() throws -> Set<String> {
    Set(try loadHostedMeetingLinks().map(\.recordID))
}

/// Kurulum eksikleri (menüde ve Ana sayfada): sunucu adresi geçersizse ya da giriş yapılmamışsa.
func hostedSetupProblems() async -> [String] {
    do {
        guard try await HostedServices.requireClient().isSignedIn() else {
            return [userFacingMessage(error: HostedClientError.notSignedIn)]
        }
        return []
    } catch {
        return [userFacingMessage(error: error)]
    }
}

/// Geri bildirim ve çökme raporunun hedefi: abonelik sunucusu; rapor hesaba bağlanır (bearer). Sunucu jetonsuz
/// raporu kabul etmez: giriş yapılmamışsa `HostedClientError.notSignedIn` (kullanıcıya "giriş yap" denir).
func hostedReportDestination() async throws -> ReportDestination {
    let client: HostedClient = try HostedServices.requireClient()
    return ReportDestination(baseURL: client.baseURL, accessToken: try await client.validAccessToken())
}

#if os(macOS)
/// Abonelikte kaydı engelleyen hak durumu (deneme bitti, aylık sınır doldu); hak durumu okunmamışsa ya da kayıt
/// başlayabilirse nil (bkz. `hostedStartBlock`).
@MainActor
func hostedStartBlockNotice() -> StartBlockNotice? {
    // Hak durumu okunamıyorsa (çevrimdışı) kayıt, son bilinen hak durumu son 7 günde izin verdiyse çevrimdışı başlar;
    // vermediyse neden burada yazar (başlatıp hata göstermek yerine).
    if case .signedInStatusUnknown = HostedAccount.shared.state {
        // İzin oturumdaki kullanıcınınsa geçer (başka hesabın son izni bu hesaba kayıt açmaz).
        let permit: HostedOfflinePermit? = loadHostedOfflinePermit()
        guard hostedOfflineRecordingMinutes(permit: permit, userId: HostedAccount.shared.signedInUserIDCache, now: Date()) == nil else {
            return nil
        }
        return StartBlockNotice(reason: userFacingMessage(error: HostedClientError.offlineNotAllowed), action: .retry)
    }
    guard case .signedIn(let entitlements) = HostedAccount.shared.state, let block = hostedStartBlock(entitlements: entitlements, now: Date()) else {
        return nil
    }
    switch block {
    case .trialEnded where HostedAccount.shared.isTrialRefusedOnThisMac:
        return StartBlockNotice(reason: String(localized: "Bu Mac'te ücretsiz deneme başka bir hesapla kullanıldı. Kayda devam etmek için abone ol."), action: .subscribe)
    case .trialEnded:
        return StartBlockNotice(reason: String(localized: "Ücretsiz denemen bitti. Kayda devam etmek için abone ol."), action: .subscribe)
    case .monthlyCapReached:
        return StartBlockNotice(
            reason: String(localized: "Bu ayki kullanım sınırın doldu; \(hostedResetDayText(now: Date())) tarihinde sıfırlanır."), action: .openAccount
        )
    case .subscriptionEnded:
        return StartBlockNotice(reason: String(localized: "Aboneliğin sona erdi. Kayda devam etmek için yeniden abone ol."), action: .subscribe)
    case .paymentOverdue:
        return StartBlockNotice(reason: String(localized: "Ödeme alınamadı. Kayda devam etmek için Ayarlar › Plan ve faturalandırma'da \"Hesabı yönet\"ten kartını güncelle."), action: .openAccount)
    }
}
#endif
