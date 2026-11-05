import ActivityKit
import AINotepadCore
import AINotepadUI
import AVFoundation
import SwiftUI
import UIKit

/// Adımın başlığı.
private func phoneOnboardingTitle(step: OnboardingStep) -> LocalizedStringKey {
    switch step {
    case .welcome, .engine, .keys: "Hoş geldin"
    case .calendar: "Takvimini bağla"
    case .permissions: "Toplantılarını yazıya dökmesine izin ver"
    case .sampleMeeting: "Bir toplantıyı birlikte dinleyelim"
    case .ready: "Cebinde hazır"
    }
}

/// Adımın tek cümlelik açıklaması.
private func phoneOnboardingSubtitle(step: OnboardingStep) -> LocalizedStringKey {
    switch step {
    case .welcome, .engine, .keys: "Toplantılarını canlı yazıya döker; bitince notun hazır, en üstte senin görevlerin. Kurulum iki dakika sürer, her adım atlanabilir."
    case .calendar: "Sıradaki toplantıların burada görünür; o sırada başlattığın kayıt toplantının adını ve katılımcılarını alır."
    case .permissions: "Senin sesin, kilit ekranında kayıt ve not hazır olunca haber. İzinleri sonra iPhone Ayarları'ndan değiştirebilirsin."
    case .sampleMeeting: "Bir dakikalık örnek toplantı: canlı metin akarken bir not yaz, bitince notun hazır. İnternet gerekmez, kullanımına sayılmaz."
    case .ready: "Kilit ekranında süre ve son cümle; Denetim Merkezi ya da Eylem düğmesiyle tek dokunuşla kayıt."
    }
}

/// İlk açılış (girişten ve yapay zekâ açıklamasından sonra): üstte adım ilerlemesi, ortada adımın başlığı ve içeriği,
/// altta sabit ana eylem. Adımlar Mac'le aynı (`hostedOnboardingSteps`): hoş geldin, takvim, izinler, örnek toplantı,
/// hazırsın; her adım atlanabilir, şimdiki adım saklanır (yarıda kapanırsa oradan sürer). Bitince `onFinish` örnek
/// toplantının kimliğiyle (denendiyse) çağrılır.
struct PhoneOnboarding: View {
    /// Yüklü hesabın arşivi: ad hesabın ayar alanına yazılır (bkz. `PhoneStore.userName`), örnek toplantı saklanır.
    let store: PhoneStore
    let calendar: PhoneCalendar
    let onFinish: @MainActor (String?) -> Void
    @State private var step: OnboardingStep = resumedOnboardingStep(steps: hostedOnboardingSteps, stored: UserDefaults.standard.string(forKey: onboardingStepKey))
    @State private var sampleMeetingID: String?
    @State private var sampleStage: PhoneSampleStage = phoneInitialSampleStage(arguments: CommandLine.arguments)
    @State private var isConnectingCalendar: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(shownTitle)
                            .appFont(size: 30, weight: .regular)
                            .tracking(-0.6)
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        // Örnek toplantı sürerken ve notu açıkken açıklama gizlenir: sahne ve not öne çıksın.
                        if !(step == .sampleMeeting && sampleStage.hidesSubtitle) {
                            Text(phoneOnboardingSubtitle(step: step))
                                .appFont(size: 15, weight: .regular)
                                .foregroundStyle(Theme.muted)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .id("baslik-\(step.rawValue)-\(sampleStage.titleID)")
                    stepContent
                        .id(step)
                        .transition(.opacity.combined(with: .offset(y: 10)))
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomBar
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .animation(.smooth(duration: 0.35), value: step)
        .onChange(of: step) { (_: OnboardingStep, current: OnboardingStep) in
            UserDefaults.standard.set(current.rawValue, forKey: onboardingStepKey)
        }
    }

    /// Gösterilen başlık: örnek toplantıda aşamaya göre (konuşuyorlar, not yazılıyor, notun hazır).
    private var shownTitle: LocalizedStringKey {
        guard step == .sampleMeeting else {
            return phoneOnboardingTitle(step: step)
        }
        switch sampleStage {
        case .intro, .failed: return phoneOnboardingTitle(step: step)
        case .live: return "Maya ve Leo konuşuyor"
        case .finishing: return "Not yazılıyor…"
        case .note: return "Notun hazır"
        }
    }

    /// Üst çubuk: geri, adım ilerlemesi, kurulumu bitiren "Atla".
    private var topBar: some View {
        let progress: (index: Int, count: Int) = onboardingProgress(steps: hostedOnboardingSteps, current: step)
        return ZStack {
            OnboardingProgress(index: progress.index, count: progress.count)
            HStack {
                if let previous = previousOnboardingStep(steps: hostedOnboardingSteps, current: step) {
                    Button {
                        step = previous
                    } label: {
                        Image(systemName: "chevron.left")
                            .appFont(size: 17, weight: .semibold)
                            .frame(width: 44, height: 44)
                    }
                    .foregroundStyle(Theme.ink)
                    .accessibilityLabel(Text("Geri"))
                    .disabled(step == .sampleMeeting && sampleStage.isRunning)
                }
                Spacer()
                if step != .ready {
                    Button("Kurulumu atla") { onFinish(sampleMeetingID) }
                        .appFont(size: 15, weight: .medium)
                        .foregroundStyle(Theme.muted)
                        .frame(minHeight: 44)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome, .engine, .keys:
            PhoneWelcomeStep(store: store)
        case .calendar:
            PhoneCalendarStep(calendar: calendar)
        case .permissions:
            PhonePermissionsStep()
        case .sampleMeeting:
            PhoneSampleMeetingStep(store: store, stage: $sampleStage) { (id: String) -> Void in sampleMeetingID = id }
        case .ready:
            PhoneReadyStep(hasSampleMeeting: sampleMeetingID != nil)
        }
    }

    /// Alt çubuk: adımın ana eylemi (örnek toplantıda aşamaya göre) ve gerekirse "Atla".
    private var bottomBar: some View {
        VStack(spacing: 6) {
            switch step {
            case .sampleMeeting:
                switch sampleStage {
                case .intro, .failed:
                    primary(title: "Örnek toplantıyı başlat") { sampleStage = .live }
                        .disabled(sampleStage.isFailed)
                    skip
                case .live:
                    primary(title: "Toplantıyı bitir") { sampleStage = .finishing }
                case .finishing:
                    primary(title: "Not yazılıyor…") {}
                        .disabled(true)
                case .note:
                    primary(title: "Devam et") { moveNext() }
                }
            case .ready:
                primary(title: sampleMeetingID == nil ? "Başla" : "Örnek notu aç") { onFinish(sampleMeetingID) }
            case .calendar:
                // Takvim bağlı değilken tek ana eylem bağlamaktır (Ayarlar'daki "Takvim" ile aynı yol).
                switch calendar.state {
                case .off, .failed:
                    primary(title: isConnectingCalendar ? "Bağlanıyor…" : "Takvimi bağla") {
                        isConnectingCalendar = true
                        Task {
                            await calendar.enable()
                            isConnectingCalendar = false
                        }
                    }
                    .disabled(isConnectingCalendar)
                    skip
                case .on, .denied:
                    primary(title: "Devam et") { moveNext() }
                }
            case .welcome, .engine, .keys, .permissions:
                primary(title: "Devam et") { moveNext() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Theme.background)
    }

    private var skip: some View {
        Button("Atla") { moveNext() }
            .appFont(size: 15, weight: .medium)
            .foregroundStyle(Theme.muted)
            .frame(minHeight: 36)
    }

    private func primary(title: LocalizedStringKey, action: @escaping @MainActor () -> Void) -> some View {
        Button(action: action) {
            PhonePrimaryButtonLabel(title: title)
        }
        .buttonStyle(PressableCardStyle())
    }

    private func moveNext() {
        guard let next = nextOnboardingStep(steps: hostedOnboardingSteps, current: step) else {
            onFinish(sampleMeetingID)
            return
        }
        step = next
    }
}

// MARK: Hoş geldin

/// Hoş geldin: pastel kapakta tek cümlelik söz, üç kısa özellik, gizlilik sözü, ad ve ana toplantı dili.
private struct PhoneWelcomeStep: View {
    let store: PhoneStore
    @AppStorage(PhoneSettingsKey.primaryMeetingLanguage) private var primaryLanguage: String = MeetingLanguage.finnish.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .bottomLeading) {
                FilmGradient(seed: "gistsmith-giris", palette: .violet)
                Text("Toplantılarını dinler, notunu yazar")
                    .appFont(size: 22, weight: .regular)
                    .tracking(-0.4)
                    .foregroundStyle(Color.black.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(20)
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .accessibilityElement(children: .combine)
            OnboardingCard {
                featureRow(symbol: "captions.bubble.fill", title: "Canlı metin ve çeviri", text: "Konuşma yazıya dökülür, \(phoneNoteLanguage().interfaceName) çevirisi altında akar; 35 dil ve konuşmacı ayrımı.")
                OnboardingRowDivider()
                featureRow(symbol: "checklist", title: "Önce senin görevlerin", text: "Bitince not: görevler, kararlar ve özet.")
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield")
                    .appFont(size: 14, weight: .medium)
                    .accessibilityHidden(true)
                Text("Finlandiya'dan, AB veri koruma yasasıyla. Toplantıların ve notların bu iPhone'da kalır; sunucumuz ses ve not saklamaz.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .appFont(size: 13, weight: .regular)
            .foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 10) {
                TextField("Adın", text: Binding<String>(get: { store.userName }, set: { (name: String) -> Void in store.setUserName(name: name) }), prompt: Text("Adın (ör. Doğan)"))
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .appFont(size: 17, weight: .regular)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .cardSurface(cornerRadius: 14)
                HStack {
                    Text("Ana toplantı dili").appFont(size: 15, weight: .regular)
                        .accessibilityHidden(true)
                    Spacer()
                    MenuPicker(title: "Ana toplantı dili", selection: $primaryLanguage, options: MeetingLanguage.allCases.map { (language: MeetingLanguage) -> MenuPickerOption<String> in
                        MenuPickerOption(value: language.rawValue, label: Text(languageName(language: language)))
                    }, size: 15)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .cardSurface(cornerRadius: 14)
                Text("Adın notta sana düşen görevleri ayırır; ana dil canlı metnin hangi dille başlayacağını belirler.")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func featureRow(symbol: String, title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        HStack(alignment: .center, spacing: 14) {
            AccentSymbolTile(symbol: symbol, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).appFont(size: 15, weight: .semibold).foregroundStyle(Theme.ink)
                Text(text).appFont(size: 13, weight: .regular).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Takvim

/// Takvim: Ayarlar'daki "Takvim" ile aynı yol (`PhoneCalendar.enable`); bağlıyken sıradaki 3 toplantı ve hatırlatma.
/// Google, Outlook ve iCloud takvimleri iPhone Ayarları › Takvim › Hesaplar'dan eklenir (iOS oraya doğrudan açılan
/// bir bağlantı sunmaz).
private struct PhoneCalendarStep: View {
    let calendar: PhoneCalendar
    @AppStorage(PhoneSettingsKey.meetingReminders) private var remindersEnabled: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch calendar.state {
            case .on:
                connected
            case .off, .denied, .failed:
                OnboardingCard {
                    HStack(alignment: .center, spacing: 14) {
                        AccentSymbolTile(symbol: "calendar", size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Takvim").appFont(size: 15, weight: .semibold).foregroundStyle(Theme.ink)
                            Text("Takvim yalnızca bu iPhone'da okunur.")
                                .appFont(size: 13, weight: .regular)
                                .foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if calendar.state == .denied {
                            Button("Ayarları aç") { openPhoneSettings(urlString: UIApplication.openSettingsURLString) }
                                .buttonStyle(.pill)
                                .controlSize(.small)
                                .fixedSize()
                        }
                    }
                    .padding(14)
                }
                if calendar.state == .denied {
                    NoticeText(String(localized: "Takvim izni yok: iPhone Ayarları'nda Gistsmith › Takvimler'i aç.") as String, severity: .attention)
                        .appFont(size: 13, weight: .regular)
                }
                if case .failed(let message) = calendar.state {
                    NoticeText(message as String, severity: .error)
                        .appFont(size: 13, weight: .regular)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .appFont(size: 13, weight: .medium)
                    .accessibilityHidden(true)
                Text("Google, Outlook ya da iCloud takvimin mi var? iPhone Ayarları › Takvim › Hesaplar'dan eklediğin takvimler burada görünür.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .appFont(size: 13, weight: .regular)
            .foregroundStyle(Theme.muted)
        }
    }

    /// Bağlı takvim: sıradaki toplantılar (en çok 3) ve 1 dk önce hatırlatma.
    private var connected: some View {
        let upcoming: [CalendarMeeting] = upcomingProofMeetings(meetings: calendar.meetings, now: Date(), limit: 3)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                Text("Takvim bağlandı").foregroundStyle(Theme.ink)
            }
            .appFont(size: 14, weight: .semibold)
            .accessibilityElement(children: .combine)
            OnboardingCard {
                if upcoming.isEmpty {
                    Text("Önümüzdeki gün takviminde toplantı yok; eklenince burada ve Kayıt'ta görünür.")
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(14)
                } else {
                    ForEach(Array(upcoming.enumerated()), id: \.element.id) { (item: (offset: Int, element: CalendarMeeting)) in
                        if item.offset > 0 {
                            Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 94)
                        }
                        OnboardingMeetingRow(meeting: item.element, now: Date())
                    }
                }
            }
            OnboardingCard {
                Toggle(isOn: Binding<Bool>(
                    get: { remindersEnabled },
                    set: { (enabled: Bool) -> Void in
                        if enabled {
                            Task { await calendar.enableReminders() }
                        } else {
                            calendar.disableReminders()
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Toplantıdan 1 dk önce hatırlat").appFont(size: 15, weight: .semibold).foregroundStyle(Theme.ink)
                        Text("Bildirimdeki \"Dinlemeye başla\" ile kayıt hemen başlar.")
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
            }
            if let problem = calendar.reminderProblem {
                NoticeText(problem as String, severity: .attention)
                    .appFont(size: 13, weight: .regular)
            }
        }
    }
}

// MARK: İzinler

/// İzinler: mikrofon, kilit ekranındaki kayıt (Canlı Etkinlikler) ve bildirimler; her satırda canlı durum. Uygulama öne
/// gelince (Ayarlar'dan dönüş) durumlar yeniden okunur.
private struct PhonePermissionsStep: View {
    @State private var microphone: PermissionStatus = .checking
    @State private var liveActivities: PermissionStatus = .checking
    @State private var notifier: EngagementNotifier = .shared
    @Environment(\.scenePhase) private var scenePhase: ScenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingCard {
                OnboardingPermissionRow(
                    symbol: "mic.fill", title: "Mikrofon", detail: "Toplantıdaki konuşmalar.", status: microphone,
                    onRequest: {
                        Task {
                            _ = await AVAudioApplication.requestRecordPermission()
                            readStatuses()
                        }
                    },
                    onOpenSettings: { openPhoneSettings(urlString: UIApplication.openSettingsURLString) }
                )
                OnboardingRowDivider()
                OnboardingPermissionRow(
                    symbol: "lock.iphone", title: "Kilit ekranında kayıt", detail: "Süre ve son cümle kilit ekranında ve Dynamic Island'da.",
                    status: liveActivities,
                    onRequest: {},
                    onOpenSettings: { openPhoneSettings(urlString: UIApplication.openSettingsURLString) }
                )
                OnboardingRowDivider()
                OnboardingPermissionRow(
                    symbol: "bell.badge.fill", title: "Bildirimler", detail: "Not hazır olunca ve görev günü gelince haber verir.",
                    status: notificationStatus,
                    onRequest: { Task { await notifier.requestAuthorizationIfUndetermined() } },
                    onOpenSettings: { openPhoneSettings(urlString: UIApplication.openNotificationSettingsURLString) }
                )
            }
            Text("İzin vermesen de devam edebilirsin; kayıt başlarken eksik izin yeniden sorulur.")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { readStatuses() }
        .task { await notifier.refreshAuthorization() }
        .onChange(of: scenePhase) { (_: ScenePhase, phase: ScenePhase) in
            if phase == .active {
                readStatuses()
                Task { await notifier.refreshAuthorization() }
            }
        }
    }

    private var notificationStatus: PermissionStatus {
        switch notifier.authorization {
        case .unknown: .checking
        case .notDetermined: .notDetermined
        case .allowed: .granted
        case .denied: .denied
        }
    }

    private func readStatuses() {
        microphone = switch AVAudioApplication.shared.recordPermission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .notDetermined
        @unknown default: .checking
        }
        // Canlı Etkinlikler varsayılan açıktır; sorulmaz, yalnız Ayarlar'dan kapatılır.
        liveActivities = ActivityAuthorizationInfo().areActivitiesEnabled ? .granted : .denied
    }
}

/// iPhone Ayarları'nda verilen sayfayı açar.
@MainActor
private func openPhoneSettings(urlString: String) {
    guard let url = URL(string: urlString) else {
        return
    }
    UIApplication.shared.open(url)
}

// MARK: Örnek toplantı

/// Örnek toplantı adımının aşaması (Mac'teki `SampleStage` ile aynı).
enum PhoneSampleStage: Equatable {
    case intro
    case failed(String)
    case live
    case finishing
    case note

    var isRunning: Bool {
        self == .live || self == .finishing
    }

    var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }

    /// Adımın açıklaması gizlenir mi (sürerken ve not açıkken).
    var hidesSubtitle: Bool {
        switch self {
        case .intro, .failed: false
        case .live, .finishing, .note: true
        }
    }

    /// Başlığın geçiş kimliği.
    var titleID: String {
        switch self {
        case .intro, .failed: "giris"
        case .live: "canli"
        case .finishing: "bitiyor"
        case .note: "not"
        }
    }
}

/// Açılıştaki aşama: tanıtım; Debug'da `--karsilama-ornek <canli|not>` (görsel kontrol) canlı ya da not. Saf fonksiyondur.
func phoneInitialSampleStage(arguments: [String]) -> PhoneSampleStage {
    #if DEBUG
    if let index = arguments.firstIndex(of: "--karsilama-ornek"), arguments.indices.contains(index + 1) {
        return arguments[index + 1] == "not" ? .note : .live
    }
    #endif
    return .intro
}

/// Rehberli örnek toplantı: üstte görüşme sahnesi, altında kayıt ekranındaki gerçek konuşmacı blokları (`LiveBlockView`)
/// sesle eş zamanlı akan metinle, en altta kendi notun (koç işaretiyle). Canlı hattan (mikrofon, sunucu) bağımsızdır;
/// bitince not önceden yazılmıştır ve örnek toplantı Toplantılar'a saklanır (eşitlenmez, işlenmez).
private struct PhoneSampleMeetingStep: View {
    let store: PhoneStore
    @Binding var stage: PhoneSampleStage
    let onSaved: @MainActor (String) -> Void
    @State private var player: SampleMeetingPlayer?
    @State private var audioURL: URL?
    @State private var myNotes: String = ""
    @State private var saveProblem: String?

    var body: some View {
        Group {
            switch stage {
            case .intro:
                VStack(alignment: .leading, spacing: 14) {
                    SampleCallStage(names: sampleMeetingSpeakerNames, speaking: nil, elapsed: 0, isLive: false)
                        .frame(height: 200)
                    introPoint(symbol: "waveform", text: "Canlı metin konuşmayla akar")
                    introPoint(symbol: "square.and.pencil", text: "Sen bir not yazarsın")
                    introPoint(symbol: "sparkles", text: "Bitince notun hazır")
                }
            case .failed(let message):
                NoticeText(message as String, severity: .error)
                    .appFont(size: 14, weight: .regular)
            case .live, .finishing:
                live
            case .note:
                note
            }
        }
        .task { load() }
        .onChange(of: stage) { (_: PhoneSampleStage, current: PhoneSampleStage) in
            switch current {
            case .live:
                start()
            case .finishing:
                finish()
            case .intro, .failed, .note:
                break
            }
        }
        .onDisappear { player?.stop() }
    }

    private func introPoint(symbol: String, text: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .appFont(size: 14, weight: .semibold)
                .foregroundStyle(.tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(text)
                .appFont(size: 15, weight: .medium)
                .foregroundStyle(Theme.ink)
        }
    }

    private var live: some View {
        let elapsed: Double = player?.elapsed ?? 0
        let script: SampleMeetingScript? = player?.script
        let transcript: [LiveSegment] = script.map { sampleMeetingTranscript(script: $0, elapsed: elapsed) } ?? []
        let blocks: [SpeakerBlock] = groupBySpeaker(transcript: transcript)
        let showsCoach: Bool = stage == .live && myNotes.isEmpty && player?.phase != .ended
            && (script.map { $0.lines.count > 1 && elapsed >= $0.lines[1].startSec } ?? false)
        return VStack(alignment: .leading, spacing: 14) {
            SampleCallStage(
                names: sampleMeetingSpeakerNames, speaking: script.flatMap { sampleMeetingSpeaker(script: $0, elapsed: elapsed) },
                elapsed: elapsed, isLive: stage == .live
            )
            .frame(height: 170)
            HStack(spacing: 8) {
                if stage == .finishing {
                    ProgressView().controlSize(.small)
                    Text("Not yazılıyor…")
                } else {
                    Image(systemName: "waveform").foregroundStyle(.tint).accessibilityHidden(true)
                    Text("Canlı metin")
                    Spacer()
                    Button(player?.phase == .paused ? "Sürdür" : "Duraklat", systemImage: player?.phase == .paused ? "play.fill" : "pause.fill") {
                        togglePause()
                    }
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 32)
                    .disabled(player?.phase == .ended)
                }
            }
            .appFont(size: 13, weight: .semibold)
            .foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 16) {
                ForEach(blocks) { (block: SpeakerBlock) in
                    LiveBlockView(
                        block: block, translations: [:], otherLanguage: [], failedTranslations: [], canRetry: false,
                        persons: [1, 2], newPersonNumber: 3,
                        onRetry: { (_: [SegmentID]) -> Void in },
                        onReassign: { (_: [SegmentID], _: Int) -> Void in },
                        onMerge: { (_: Int, _: Int) -> Void in }
                    )
                    .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
            .animation(.smooth(duration: 0.25), value: blocks.count)
            VStack(alignment: .leading, spacing: 8) {
                if showsCoach {
                    CoachMark(text: "Aklında kalmasını istediğini yaz; not bunu öncelik sayar.", symbol: "hand.point.down.fill", edge: .bottom)
                        .transition(.opacity)
                } else if player?.phase == .ended, stage == .live {
                    CoachMark(text: "Toplantı bitti. \"Toplantıyı bitir\"e bas, notun hazırlansın.", symbol: "stop.circle.fill", edge: .bottom)
                        .transition(.opacity)
                }
                SampleNotesField(text: $myNotes, placeholder: "Notlarım: ör. Özeti cuma gönder")
            }
            .animation(.smooth(duration: 0.3), value: showsCoach)
        }
    }

    private var note: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let script = player?.script {
                SampleNotePreview(note: currentNote(script: script), myNotes: myNotes)
                    .padding(18)
                    .cardSurface(cornerRadius: 20)
            }
            if let saveProblem {
                NoticeText(saveProblem as String, severity: .error)
                    .appFont(size: 13, weight: .regular)
            } else {
                Label("Örnek toplantı Toplantılar'da; istediğin zaman silebilirsin.", systemImage: "tray.full")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private func currentNote(script: SampleMeetingScript) -> MeetingNote {
        sampleMeetingNote(script: script, userName: store.userName, language: defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations))
    }

    private func load() {
        guard player == nil else {
            return
        }
        do {
            let bundled: (script: SampleMeetingScript, audioURL: URL) = try loadBundledSampleMeeting(bundle: .main)
            player = try SampleMeetingPlayer(script: bundled.script, audioURL: bundled.audioURL)
            audioURL = bundled.audioURL
            if stage == .live {
                start()
            }
        } catch {
            stage = .failed(String(localized: "Örnek toplantı açılamadı: \(userFacingMessage(error: error))"))
        }
    }

    private func start() {
        guard let player else {
            return
        }
        do {
            #if DEBUG
            // Görsel kontrol (`--karsilama-ornek`): ses kısık, toplantının ortasından.
            if CommandLine.arguments.contains("--karsilama-ornek"), player.phase == .ready {
                player.volume = 0
                player.seek(to: 31)
            }
            #endif
            try player.play()
        } catch {
            stage = .failed(String(localized: "Örnek toplantı açılamadı: \(userFacingMessage(error: error))"))
        }
    }

    private func togglePause() {
        guard let player else {
            return
        }
        if player.phase == .playing {
            player.pause()
        } else {
            start()
        }
    }

    private func finish() {
        player?.stop()
        Task {
            do {
                try await Task.sleep(for: .milliseconds(1400))
            } catch {
                return
            }
            guard let player, let audioURL else {
                return
            }
            do {
                onSaved(try store.addSampleMeeting(script: player.script, note: currentNote(script: player.script), myNotes: myNotes, audio: audioURL))
            } catch {
                saveProblem = String(localized: "Örnek toplantı Toplantılar'a saklanamadı: \(userFacingMessage(error: error))")
            }
            stage = .note
        }
    }
}

// MARK: Hazırsın

/// Hazırsın: kaydın nereden başladığı, rıza hatırlatması, Sor ve tarifler.
private struct PhoneReadyStep: View {
    let hasSampleMeeting: Bool

    var body: some View {
        OnboardingCard {
            pointer(symbol: "record.circle", title: "Kayıt", text: "Kayıt sekmesindeki büyük düğme, Denetim Merkezi ya da Eylem düğmesi.")
            OnboardingRowDivider()
            pointer(symbol: "hand.raised.fill", title: "Önce haber ver", text: "Kayıt başlarken katılımcılara söylemeyi hatırlatır.")
            OnboardingRowDivider()
            pointer(symbol: "bubble.left.and.text.bubble.right", title: "Sor ve tarifler", text: "Toplantılarına soru sor; sık sorduğunu tarif olarak kaydet, \"/\" ile çalıştır.")
            if hasSampleMeeting {
                OnboardingRowDivider()
                pointer(symbol: "doc.text", title: "Örnek toplantı", text: "Toplantılar'da seni bekliyor; istediğin zaman silebilirsin.")
            }
        }
    }

    private func pointer(symbol: String, title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        HStack(alignment: .center, spacing: 14) {
            AccentSymbolTile(symbol: symbol, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).appFont(size: 15, weight: .semibold).foregroundStyle(Theme.ink)
                Text(text).appFont(size: 13, weight: .regular).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
    }
}
