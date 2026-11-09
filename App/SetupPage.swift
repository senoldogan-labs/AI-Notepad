import AINotepadCore
import AINotepadUI
import AppKit
import AVFoundation
import SwiftUI

/// Bu sürümün karşılama adımları: abonelikte giriş karşılamadan önce yapılır; kendi anahtarlarıyla çalışan sürümde
/// motor ve anahtar adımları da vardır.
#if HOSTED_EDITION
private let setupSteps: [OnboardingStep] = hostedOnboardingSteps
#else
private let setupSteps: [OnboardingStep] = ownKeysOnboardingSteps
#endif

/// Adımın başlığı.
private func setupTitle(step: OnboardingStep) -> LocalizedStringKey {
    switch step {
    case .welcome: "Hoş geldin"
    case .engine: "Nasıl başlamak istersin?"
    case .keys: "Anahtarlar"
    case .calendar: "Takvimini bağla"
    case .permissions: "Toplantılarını yazıya dökmesine izin ver"
    case .sampleMeeting: "Bir toplantıyı birlikte dinleyelim"
    case .ready: "Hazırsın"
    }
}

/// Adımın tek cümlelik açıklaması.
private func setupSubtitle(step: OnboardingStep) -> LocalizedStringKey {
    switch step {
    case .welcome: "Toplantılarını canlı yazıya döker; bitince notun hazır, en üstte senin görevlerin. Kurulum iki dakika sürer, her adım atlanabilir."
    case .engine: "Canlı metni ve notu nerede yazdıracağını seç; sonra Ayarlar'dan değişir."
    case .keys: "macOS Anahtar Zinciri'nde saklanır, hiçbir yere gönderilmez."
    case .calendar: "Sıradaki toplantıların burada görünür; o sırada başlattığın kayıt toplantının adını ve katılımcılarını alır."
    case .permissions: "Senin sesin, toplantıdaki diğer kişilerin sesi ve not hazır olunca haber. İzinleri sonra Sistem Ayarları'ndan değiştirebilirsin."
    case .sampleMeeting: "Bir dakikalık örnek toplantı: canlı metin akarken bir not yaz, bitince notun hazır. İnternet gerekmez, kullanımına sayılmaz."
    case .ready: "Kaydı kısayolla başlat; toplantı bitince notun ve görevlerin hazır."
    }
}

/// Kurulum (ana pencerede; ilk açılışta pencere burada açılır): üstte işaret, adım ilerlemesi ve "Kurulumu atla";
/// ortada adımın başlığı ve içeriği; altta geri, atla ve ana eylem. Şimdiki adım saklanır (yarıda kapanırsa oradan
/// sürer). Bitince `onFinish` örnek toplantının kimliğiyle (denendiyse) çağrılır.
struct SetupPage: View {
    let model: AppModel
    let shortcuts: ShortcutController
    let onFinish: @MainActor (String?) -> Void
    @State private var step: OnboardingStep = resumedOnboardingStep(steps: setupSteps, stored: UserDefaults.standard.string(forKey: onboardingStepKey))
    @State private var sampleMeetingID: String?
    /// Örnek toplantının aşaması (adımın alt düğmeleri buna göre).
    @State private var sampleStage: SampleStage = initialSampleStage()
    @State private var isConnectingCalendar: Bool = false
    @AppStorage(SettingsKey.calendarEnabled) private var calendarEnabled: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(shownTitle)
                            .appFont(size: 34, weight: .regular)
                            .tracking(-0.8)
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        // Örnek toplantı sürerken ve notu açıkken açıklama gizlenir: sahne ve not pencereye sığsın.
                        if !(step == .sampleMeeting && sampleStage.hidesSubtitle) {
                            Text(setupSubtitle(step: step))
                                .appFont(size: 15, weight: .regular)
                                .foregroundStyle(Theme.muted)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 560, alignment: .leading)
                        }
                    }
                    .id("baslik-\(step.rawValue)-\(sampleStage.titleID)")
                    .transition(.opacity)
                    stepContent
                        .id(step)
                        .transition(.opacity.combined(with: .offset(y: 10)))
                }
                .frame(maxWidth: step == .sampleMeeting ? 1000 : 600, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 40)
                .padding(.top, 28)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            bottomBar
        }
        .animation(.smooth(duration: 0.4), value: step)
        .onChange(of: step) { (_: OnboardingStep, current: OnboardingStep) in
            UserDefaults.standard.set(current.rawValue, forKey: onboardingStepKey)
        }
    }

    /// Gösterilen başlık: örnek toplantıda aşamaya göre (konuşuyorlar, not yazılıyor, notun hazır).
    private var shownTitle: LocalizedStringKey {
        guard step == .sampleMeeting else {
            return setupTitle(step: step)
        }
        switch sampleStage {
        case .intro, .failed: return setupTitle(step: step)
        case .live: return "Maya ve Leo konuşuyor"
        case .finishing: return "Not yazılıyor…"
        case .note: return "Notun hazır"
        }
    }

    /// Üst çubuk: işaret ve ad, adım ilerlemesi, kurulumu bitiren "Kurulumu atla".
    private var topBar: some View {
        let progress: (index: Int, count: Int) = onboardingProgress(steps: setupSteps, current: step)
        return ZStack {
            OnboardingProgress(index: progress.index, count: progress.count)
            HStack(spacing: 10) {
                AppMark(size: 24, barsRaised: true, lineDrawn: true)
                Text(verbatim: appName)
                    .appFont(size: 14, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                Spacer()
                if step != .ready {
                    Button("Kurulumu atla") { onFinish(sampleMeetingID) }
                        .buttonStyle(.hoverPlain)
                        .foregroundStyle(Theme.muted)
                        .appFont(size: 13, weight: .regular)
                }
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 56)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: WelcomeStep(model: model)
        case .engine: EngineStep(model: model)
        case .keys: KeysStep(model: model)
        case .calendar: CalendarStep(model: model)
        case .permissions: PermissionsStep(model: model)
        case .sampleMeeting:
            SampleMeetingStep(model: model, stage: $sampleStage) { (id: String) -> Void in sampleMeetingID = id }
        case .ready: ReadyStep(shortcuts: shortcuts, hasSampleMeeting: sampleMeetingID != nil)
        }
    }

    /// Alt çubuk: geri; adıma göre "Atla"; ana eylem.
    private var bottomBar: some View {
        HStack(spacing: 12) {
            if let previous = previousOnboardingStep(steps: setupSteps, current: step) {
                Button("Geri", systemImage: "chevron.left") { step = previous }
                    .buttonStyle(.hoverPlain)
                    .foregroundStyle(Theme.muted)
                    .disabled(step == .sampleMeeting && sampleStage.isRunning)
            }
            Spacer()
            switch step {
            case .ready:
                Button(sampleMeetingID == nil ? "Başla" : "Örnek notu aç") { onFinish(sampleMeetingID) }
                    .buttonStyle(.pillPrimary)
                    .keyboardShortcut(.defaultAction)
            case .sampleMeeting:
                sampleActions
            case .permissions:
                Button("Devam et") { moveNext() }
                    .buttonStyle(.pillPrimary)
                    .keyboardShortcut(.defaultAction)
            case .welcome:
                Button("Devam et") { moveNext() }
                    .buttonStyle(.pillPrimary)
                    .keyboardShortcut(.defaultAction)
            case .calendar where !calendarEnabled:
                // Takvim bağlı değilken tek ana eylem bağlamaktır (Ayarlar'daki "Takvimi kullan" ile aynı yol).
                Button("Atla") { moveNext() }
                    .buttonStyle(.hoverPlain)
                    .foregroundStyle(Theme.muted)
                Button {
                    isConnectingCalendar = true
                    Task {
                        await model.enableCalendar()
                        isConnectingCalendar = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isConnectingCalendar {
                            ProgressView().controlSize(.small)
                        }
                        Text("Takvimi bağla")
                    }
                }
                .buttonStyle(.pillPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(isConnectingCalendar)
            case .engine, .keys, .calendar:
                Button("Atla") { moveNext() }
                    .buttonStyle(.hoverPlain)
                    .foregroundStyle(Theme.muted)
                Button("Devam et") { moveNext() }
                    .buttonStyle(.pillPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .frame(maxWidth: step == .sampleMeeting ? 1000 : 600)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.vertical, 18)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    /// Örnek toplantı adımının düğmeleri: başlamadan "Atla" ve "Örnek toplantıyı başlat"; sürerken "Toplantıyı bitir";
    /// not hazırken "Devam et".
    @ViewBuilder
    private var sampleActions: some View {
        switch sampleStage {
        case .intro, .failed:
            Button("Atla") { moveNext() }
                .buttonStyle(.hoverPlain)
                .foregroundStyle(Theme.muted)
            Button("Örnek toplantıyı başlat", systemImage: "play.fill") { sampleStage = .live }
                .buttonStyle(.pillPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(sampleStage.isFailed)
        case .live:
            Button("Toplantıyı bitir", systemImage: "stop.fill") { sampleStage = .finishing }
                .buttonStyle(.pillPrimary)
                .keyboardShortcut(.defaultAction)
        case .finishing:
            Button("Not yazılıyor…") {}
                .buttonStyle(.pillPrimary)
                .disabled(true)
        case .note:
            Button("Devam et") { moveNext() }
                .buttonStyle(.pillPrimary)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func moveNext() {
        guard let next = nextOnboardingStep(steps: setupSteps, current: step) else {
            onFinish(sampleMeetingID)
            return
        }
        step = next
    }
}

// MARK: Hoş geldin

/// Hoş geldin: pastel kapakta tek cümlelik söz, iki kısa özellik, kullanıcının adı (pencerede kaydırmadan görünür) ve
/// gizlilik sözü.
private struct WelcomeStep: View {
    let model: AppModel

    var body: some View {
        let noteLanguageName: String = selectedNoteLanguage().interfaceName
        VStack(alignment: .leading, spacing: 22) {
            ZStack(alignment: .bottomLeading) {
                FilmGradient(seed: "gistsmith-giris", palette: .violet)
                Text("Toplantılarını dinler, notunu yazar")
                    .appFont(size: 26, weight: .regular)
                    .tracking(-0.5)
                    .foregroundStyle(Color.black.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(26)
            }
            .frame(height: 132)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityElement(children: .combine)
            OnboardingCard {
                featureRow(symbol: "captions.bubble.fill", title: "Canlı metin", text: "Fince, İngilizce ve 33 dil daha; istersen \(noteLanguageName) çevirisi altında akar.")
                OnboardingRowDivider()
                featureRow(symbol: "checklist", title: "Önce senin görevlerin", text: "Bitince not: görevler, kararlar, özet ve sözlük.")
            }
            // The name comes before the privacy note: at a larger interface text size (115%) the field fell under the
            // bottom bar; the note can sit lower.
            VStack(alignment: .leading, spacing: 8) {
                Text("Adın").appFont(size: 13, weight: .semibold).foregroundStyle(Theme.ink)
                SetupNameField(model: model)
                Text("Notta sana düşen görevler bu adla ayrılır.")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield")
                    .appFont(size: 14, weight: .medium)
                    .foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
                #if HOSTED_EDITION
                Text("Toplantıların ve notların bu Mac'te kalır; sunucumuz ses saklamaz, notlarını da yalnızca yapay zekâ asistanı erişimini açarsan saklar. İsteğe bağlı iPhone eşitlemesi yalnızca okuyamadığımız şifreli bir kopya tutar.")
                #else
                Text("Toplantıların, notların ve anahtarların bu Mac'te kalır.")
                #endif
            }
            .appFont(size: 13, weight: .regular)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func featureRow(symbol: String, title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        HStack(alignment: .center, spacing: 14) {
            AccentSymbolTile(symbol: symbol, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).appFont(size: 14, weight: .semibold).foregroundStyle(Theme.ink)
                Text(text).appFont(size: 12.5, weight: .regular).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
    }
}

/// Ad alanı: boşken soluk yer tutucu (macOS odaksız `prompt:`u yazı rengiyle çizer).
private struct SetupNameField: View {
    let model: AppModel

    var body: some View {
        let name: Binding<String> = Binding<String>(get: { model.userName }, set: { (value: String) -> Void in model.setUserName(name: value) })
        TextField(text: name) { Text("Adın") }
            .textFieldStyle(.plain)
            .appFont(size: 16, weight: .regular)
            .overlay(alignment: .leading) {
                if model.userName.isEmpty {
                    Text("ör. Doğan")
                        .appFont(size: 16, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .cardSurface(cornerRadius: 12)
            .frame(maxWidth: 360)
    }
}

// MARK: Motor ve anahtarlar (kendi anahtarlarıyla çalışan sürüm)

/// Başlama yolu (cihaz içi ya da kendi anahtarlarınla) ve canlı metin motoru.
private struct EngineStep: View {
    let model: AppModel
    @AppStorage(SettingsKey.llmProvider) private var provider: String = LLMProviderKind.anthropic.rawValue
    @AppStorage(SettingsKey.primaryMeetingLanguage) private var primaryLanguage: String = MeetingLanguage.finnish.rawValue
    @AppStorage(SettingsKey.noteLanguage) private var noteLanguage: String = defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                ChoiceCard(
                    symbol: "cpu", title: "Hemen başla (cihaz içi)",
                    text: onDeviceModeSupported
                        ? "Ücretsiz, anahtarsız: yazıya dökme ve not Apple Intelligence ile bu Mac'te. Konuşmacılar ayrılmaz, not daha kısadır."
                        : "macOS 26 gerektirir: Apple Intelligence ve cihaz içi konuşma tanıma bu macOS sürümünde yok.",
                    isSelected: isOnDevice
                ) {
                    provider = LLMProviderKind.onDevice.rawValue
                    Task { await model.selectEngine(engine: .appleSpeech) }
                }
                .disabled(!onDeviceModeSupported)
                .opacity(onDeviceModeSupported ? 1 : 0.55)
                ChoiceCard(
                    symbol: "key.fill", title: "Kendi anahtarlarımla",
                    text: "Daha yüksek kalite: Claude ile not, konuşmacılar ayrılır. Sonraki adımda anahtarları girersin.",
                    isSelected: !isOnDevice
                ) {
                    provider = LLMProviderKind.anthropic.rawValue
                    Task { await model.selectEngine(engine: .deepgram) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if isOnDevice {
                // Cihaz içi tanıma dil algılamaz ve model her dili yazamaz: toplantıların dili burada seçilir.
                HStack(spacing: 10) {
                    Text("Ana toplantı dili").appFont(size: 13, weight: .regular)
                    Spacer(minLength: 8)
                    SettingsMenu(selection: $primaryLanguage, options: MeetingLanguage.allCases.map { (language: MeetingLanguage) -> (String, Text) in
                        (language.rawValue, Text(verbatim: languageName(language: language)))
                    })
                }
                .onChange(of: primaryLanguage) { (_: String, _: String) in
                    model.primaryLanguageChanged()
                }
                if let problem = onDeviceProblem {
                    Text(verbatim: problem)
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Canlı metin").appFont(size: 13, weight: .semibold)
                    HStack(alignment: .top, spacing: 12) {
                        ChoiceCard(
                            symbol: "cloud.fill", title: "Bulut (en hızlı)",
                            text: "Deepgram ve ElevenLabs; konuşmacılar canlı ayrılır. İki anahtar gerekir.",
                            isSelected: model.liveEngine == .deepgram
                        ) {
                            Task { await model.selectEngine(engine: .deepgram) }
                        }
                        ChoiceCard(
                            symbol: "laptopcomputer", title: "Bu Mac'te",
                            text: "WhisperKit, internetsiz. İlk açılışta ~630 MB model indirilir.",
                            isSelected: model.liveEngine == .whisperKit
                        ) {
                            Task { await model.selectEngine(engine: .whisperKit) }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Cihaz içi mod bu sistemde seçilebilir mi: konuşma tanıma ve model ikisi de macOS 26 ister.
    private var onDeviceModeSupported: Bool {
        appleSpeechSupportedBySystem() && onDeviceLLMSupportedBySystem()
    }

    /// Cihaz içi mod seçili: Apple konuşma tanıma ve Apple Intelligence.
    private var isOnDevice: Bool {
        model.liveEngine == .appleSpeech && provider == LLMProviderKind.onDevice.rawValue
    }

    /// Cihaz içi model kullanılamıyorsa nedeni ve ne yapılacağı; kullanılabiliyorsa nil.
    private var onDeviceProblem: String? {
        do {
            let config: OnDeviceConfig = try onDeviceConfig()
            return onDeviceModeWarning(config: config, primaryLanguage: primaryMeetingLanguage(), outputLanguage: storedNoteLanguage(value: noteLanguage))
        } catch {
            return userFacingMessage(error: error)
        }
    }
}

/// Seçili motorun ve LLM'in anahtarları.
private struct KeysStep: View {
    let model: AppModel
    @AppStorage(SettingsKey.llmProvider) private var provider: String = LLMProviderKind.anthropic.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if provider == LLMProviderKind.onDevice.rawValue, model.liveEngine == .appleSpeech {
                Text("Cihaz içi modda anahtar gerekmez; bu adımı atlayabilirsin. Daha yüksek kalite istersen anahtarları sonra Ayarlar'dan ekleyip sağlayıcıyı değiştirirsin.")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                SettingsCard {
                    if model.liveEngine == .deepgram {
                        SecretField(icon: "waveform", title: "Deepgram", account: .deepgram, onChange: model.settingsChanged)
                        SecretField(icon: "person.2.wave.2", title: "ElevenLabs", account: .elevenlabs, onChange: model.settingsChanged)
                    }
                    SecretField(icon: "sparkles", title: "Anthropic (Claude)", account: .anthropic, onChange: model.settingsChanged)
                    LocalLLMSetup(model: model)
                }
                Text("Çeviri, özet ve not için Claude kullanılır; anahtarsız istersen Mac'teki Ollama'yı seç. OpenAI ve OpenCode Go Ayarlar › LLM'de.")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
        }
    }
}

// MARK: Takvim

/// Takvim: Ayarlar'daki "Takvimi kullan" ile aynı yol (`AppModel.enableCalendar`: takvim ve hatırlatma izni, servisler).
/// Bağlıyken sıradaki 3 toplantı kanıt olarak görünür; Google, Outlook ve iCloud takvimleri Sistem Ayarları ›
/// İnternet Hesapları'ndan eklenir.
private struct CalendarStep: View {
    let model: AppModel
    @AppStorage(SettingsKey.calendarEnabled) private var calendarEnabled: Bool = false
    @AppStorage(SettingsKey.meetingReminders) private var meetingReminders: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if calendarEnabled {
                connected
            } else {
                OnboardingCard {
                    HStack(alignment: .center, spacing: 14) {
                        AccentSymbolTile(symbol: "calendar", size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Takvim").appFont(size: 14, weight: .semibold).foregroundStyle(Theme.ink)
                            Text("Takvim yalnızca bu Mac'te okunur.")
                                .appFont(size: 12.5, weight: .regular)
                                .foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                }
                if let error = model.calendarError {
                    VStack(alignment: .leading, spacing: 8) {
                        NoticeText(error, severity: .error)
                            .appFont(size: 13, weight: .regular)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Sistem Ayarları'nı aç") { openPrivacySettings(anchor: "Privacy_Calendars") }
                            .buttonStyle(.link)
                            .appFont(size: 13, weight: .medium)
                    }
                }
            }
            accountsHint
        }
    }

    /// Bağlı takvim: sıradaki toplantılar (en çok 3) ve 1 dk önce hatırlatma.
    private var connected: some View {
        let upcoming: [CalendarMeeting] = upcomingProofMeetings(meetings: model.upcomingMeetings, now: Date(), limit: 3)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                Text("Takvim bağlandı").foregroundStyle(Theme.ink)
            }
            .appFont(size: 13, weight: .semibold)
            .accessibilityElement(children: .combine)
            OnboardingCard {
                if upcoming.isEmpty {
                    Text("Önümüzdeki gün takviminde toplantı yok; eklenince burada ve Ana sayfada görünür.")
                        .appFont(size: 13, weight: .regular)
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
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Toplantıdan 1 dk önce hatırlat").appFont(size: 14, weight: .semibold).foregroundStyle(Theme.ink)
                        Text("Bildirimdeki \"Kaydı başlat\" ile kayıt hemen başlar.")
                            .appFont(size: 12.5, weight: .regular)
                            .foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Açılınca bildirim izni istenir (Ayarlar'daki gibi); izin yoksa geri kapanır ve neden görünür.
                    Toggle("Toplantıdan 1 dk önce hatırlat", isOn: Binding<Bool>(
                        get: { meetingReminders },
                        set: { (enabled: Bool) -> Void in
                            meetingReminders = enabled
                            if enabled {
                                Task { await model.enableMeetingReminders() }
                            } else {
                                model.startCalendarServices()
                            }
                        }
                    ))
                    .settingsToggle()
                }
                .padding(14)
            }
            if let problem = model.notificationProblem {
                NoticeText(problem, severity: .attention)
                    .appFont(size: 12, weight: .regular)
            }
        }
    }

    /// Google, Outlook ve iCloud takvimlerinin nereden eklendiği.
    private var accountsHint: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .appFont(size: 13, weight: .medium)
                .foregroundStyle(Theme.muted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Google, Outlook ya da iCloud takvimin mi var? Sistem Ayarları › İnternet Hesapları'na eklediğin takvimler burada görünür.")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("İnternet Hesapları'nı aç") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .underline()
                .foregroundStyle(Theme.ink)
                .linkPointer(isEnabled: true)
                .appFont(size: 13, weight: .medium)
            }
        }
    }
}

// MARK: İzinler

/// İzinler: mikrofon, sistem sesi, bildirimler ve (isteğe bağlı) ekran kaydı; her satırda canlı durum. Kullanıcı Sistem Ayarları'ndan dönünce
/// (uygulama ya da pencere yeniden etkin olunca) durumlar yeniden okunur.
private struct PermissionsStep: View {
    let model: AppModel
    @State private var microphone: PermissionStatus = .checking
    @State private var systemAudio: PermissionStatus = .notDetermined
    @State private var systemAudioProblem: String?
    /// Ekran Kaydı (toplantıda paylaşılan ekran nota girsin): kayıtta sessizce istenmesin, burada görünsün.
    @State private var screenCapture: PermissionStatus = .checking
    @State private var notifier: EngagementNotifier = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingCard {
                OnboardingPermissionRow(
                    symbol: "mic.fill", title: "Mikrofon", detail: "Senin sesin (\"Sen\").", status: microphone,
                    onRequest: {
                        Task {
                            _ = await model.requestMicrophonePermission()
                            readMicrophone()
                        }
                    },
                    onOpenSettings: { openPrivacySettings(anchor: "Privacy_Microphone") }
                )
                OnboardingRowDivider()
                OnboardingPermissionRow(
                    symbol: "speaker.wave.2.fill", title: "Toplantı sesi",
                    detail: "Teams, Zoom ve tarayıcıdaki görüşmede diğer kişiler.",
                    status: systemAudio,
                    onRequest: { probeSystemAudio() },
                    onOpenSettings: { openPrivacySettings(anchor: "Privacy_AudioCapture") }
                )
                OnboardingRowDivider()
                OnboardingPermissionRow(
                    symbol: "bell.badge.fill", title: "Bildirimler", detail: "Not hazır olunca ve görev günü gelince haber verir.",
                    status: notificationStatus,
                    onRequest: { Task { await notifier.requestAuthorizationIfUndetermined() } },
                    onOpenSettings: { openNotificationSettings() }
                )
                OnboardingRowDivider()
                OnboardingPermissionRow(
                    symbol: "rectangle.on.rectangle", title: "Ekran Kaydı",
                    detail: "İsteğe bağlı: görüşmede paylaşılan ekranlar nota girer.",
                    status: screenCapture,
                    onRequest: { requestScreenCapture() },
                    onOpenSettings: { openPrivacySettings(anchor: "Privacy_ScreenCapture") }
                )
            }
            if let systemAudioProblem {
                NoticeText(systemAudioProblem, severity: .error)
                    .appFont(size: 12, weight: .regular)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("macOS toplantı sesi izninin durumunu göstermez: izin penceresinde \"İzin Ver\"i seçtiysen hazırsın. İzin vermesen de devam edebilirsin; kayıt başlarken eksik izin yeniden sorulur.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            readMicrophone()
            readScreenCapture()
        }
        .task { await notifier.refreshAuthorization() }
        // Kullanıcı izni Sistem Ayarları'nda değiştirip geri dönünce durum yenilenir; okumak ucuzdur.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { (_: Notification) in
            readMicrophone()
            readScreenCapture()
            Task { await notifier.refreshAuthorization() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { (_: Notification) in
            readMicrophone()
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

    private func readMicrophone() {
        microphone = switch model.microphonePermission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .notDetermined
        @unknown default: .checking
        }
    }

    /// Ekran Kaydı izni: varsa verildi; yoksa sorulmadı sayılır (macOS reddedildiğini ayırt ettirmez).
    private func readScreenCapture() {
        if hasScreenCapturePermission() {
            screenCapture = .granted
        } else if screenCapture != .requested {
            screenCapture = .notDetermined
        }
    }

    /// İzni ister: ilk istekte macOS kendi penceresini açar; verilmezse "İstendi" (izin Sistem Ayarları'ndan da verilir,
    /// uygulama yeniden açılınca geçerli olur).
    private func requestScreenCapture() {
        screenCapture = requestScreenCapturePermission() ? .granted : .requested
    }

    /// Sistem sesini 2 sn dener: macOS izin penceresini ilk denemede açar; durumu okunamadığı için "İstendi" olur.
    private func probeSystemAudio() {
        systemAudio = .checking
        systemAudioProblem = nil
        Task {
            do {
                try await model.probeSystemAudio()
                systemAudio = .requested
            } catch {
                systemAudio = .notDetermined
                systemAudioProblem = userFacingMessage(error: error)
            }
        }
    }

    /// Sistem Ayarları › Bildirimler'de bu uygulamanın sayfası.
    private func openNotificationSettings() {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

/// Gizlilik bölümünü Sistem Ayarları'nda açar.
@MainActor
func openPrivacySettings(anchor: String) {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
        return
    }
    NSWorkspace.shared.open(url)
}

// MARK: Örnek toplantı

/// Örnek toplantı adımının aşaması.
enum SampleStage: Equatable {
    /// Başlamadı (tanıtım).
    case intro
    /// Örnek toplantı açılamadı (dosya eksik ya da ses açılamadı); neden gösterilir, adım atlanabilir.
    case failed(String)
    /// Ses çalıyor, canlı metin akıyor (duraklatılmış da olabilir).
    case live
    /// "Bitir"e basıldı: not yazılıyor.
    case finishing
    /// Not hazır.
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

    /// Adımın açıklaması gizlenir mi (sürerken ve not açıkken yer sahneye ve nota kalır).
    var hidesSubtitle: Bool {
        switch self {
        case .intro, .failed: false
        case .live, .finishing, .note: true
        }
    }

    /// Başlığın geçiş kimliği (aşama değişince başlık yumuşakça değişir).
    var titleID: String {
        switch self {
        case .intro, .failed: "giris"
        case .live: "canli"
        case .finishing: "bitiyor"
        case .note: "not"
        }
    }
}

/// Açılıştaki aşama: tanıtım; Debug'da tanıtım sahnesi (`kurulum-ornek`, `kurulum-not`; görsel kontrol) canlı ya da not.
private func initialSampleStage() -> SampleStage {
    #if DEBUG
    if let stage = demoSampleStage(arguments: CommandLine.arguments) {
        return stage
    }
    #endif
    return .intro
}

/// Rehberli örnek toplantı: solda görüşme sahnesi ve kendi notun (koç işaretiyle), sağda canlı panelin gerçek
/// görünümü (`TranscriptPanel`) satır satır akan metinle. Canlı hattan (mikrofon, sunucu) bağımsızdır: zamanlı
/// metin sesle eş zamanlı gösterilir (bkz. `SampleMeetingPlayer`). Bitince not önceden yazılmıştır ve örnek toplantı
/// Toplantılar'a saklanır (eşitlenmez, işlenmez).
private struct SampleMeetingStep: View {
    let model: AppModel
    @Binding var stage: SampleStage
    let onSaved: @MainActor (String) -> Void
    @State private var player: SampleMeetingPlayer?
    @State private var audioURL: URL?
    @State private var myNotes: String = ""
    @State private var card: AssistantCard?
    @State private var saveProblem: String?
    @State private var levels: AudioLevels = AudioLevels(count: 14, interval: 0.1)

    var body: some View {
        Group {
            switch stage {
            case .intro:
                intro
            case .failed(let message):
                NoticeText(message, severity: .error)
                    .appFont(size: 13, weight: .regular)
                    .fixedSize(horizontal: false, vertical: true)
            case .live, .finishing:
                live
            case .note:
                note
            }
        }
        .task { load() }
        .onChange(of: stage) { (_: SampleStage, current: SampleStage) in
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

    /// Başlamadan: görüşme sahnesinin durgun hâli ve ne olacağı.
    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            SampleCallStage(names: sampleMeetingSpeakerNames, speaking: nil, elapsed: 0, isLive: false)
                .frame(height: 280)
                .frame(maxWidth: 640)
            HStack(spacing: 18) {
                introPoint(symbol: "waveform", text: "Canlı metin konuşmayla akar")
                introPoint(symbol: "square.and.pencil", text: "Sen bir not yazarsın")
                introPoint(symbol: "sparkles", text: "Bitince notun hazır")
            }
        }
    }

    private func introPoint(symbol: String, text: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .appFont(size: 13, weight: .semibold)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(text)
                .appFont(size: 13, weight: .medium)
                .foregroundStyle(Theme.ink)
        }
    }

    /// Sürerken: sahne ve not alanı solda, canlı panel sağda.
    private var live: some View {
        let elapsed: Double = player?.elapsed ?? 0
        let script: SampleMeetingScript? = player?.script
        return HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                SampleCallStage(
                    names: sampleMeetingSpeakerNames, speaking: script.flatMap { sampleMeetingSpeaker(script: $0, elapsed: elapsed) },
                    elapsed: elapsed, isLive: stage == .live
                )
                .frame(height: 300)
                VStack(alignment: .leading, spacing: 8) {
                    if showsNoteCoach(script: script, elapsed: elapsed) {
                        CoachMark(text: "Aklında kalmasını istediğini yaz; not bunu öncelik sayar.", symbol: "hand.point.down.fill", edge: .bottom)
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    } else if player?.phase == .ended, stage == .live {
                        CoachMark(text: "Toplantı bitti. \"Toplantıyı bitir\"e bas, notun hazırlansın.", symbol: "stop.circle.fill", edge: .bottom)
                            .transition(.opacity.combined(with: .offset(y: 6)))
                    }
                    SampleNotesField(text: $myNotes, placeholder: "Notlarım: ör. Özeti cuma gönder")
                }
                .animation(.smooth(duration: 0.3), value: showsNoteCoach(script: script, elapsed: elapsed))
            }
            .frame(maxWidth: .infinity)
            TranscriptPanel(state: viewState(elapsed: elapsed), actions: actions, levels: levels, myNotes: $myNotes)
                // Örnek toplantıda adlar baştan bilinir: canlı metin "Konuşmacı 1/2" değil Maya ve Leo der.
                .environment(\.liveSpeakerNames, sampleMeetingSpeakerNames)
                .frame(width: 380, height: 470)
                .panelSurface()
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.panelRadius, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
        }
    }

    /// Not hazırken: notun önizlemesi ve Toplantılar'da saklandığı.
    private var note: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let script = player?.script {
                SampleNotePreview(note: currentNote(script: script), myNotes: myNotes)
                    .padding(24)
                    .frame(maxWidth: 680, alignment: .leading)
                    .cardSurface(cornerRadius: 20)
            }
            if let saveProblem {
                NoticeText(saveProblem, severity: .error)
                    .appFont(size: 12, weight: .regular)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Örnek toplantı Toplantılar'da; istediğin zaman silebilirsin.", systemImage: "tray.full")
                    .appFont(size: 12.5, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    /// Kullanıcı henüz not yazmadıysa, ikinci konuşma başladıktan sonra not alanını gösteren koç işareti.
    private func showsNoteCoach(script: SampleMeetingScript?, elapsed: Double) -> Bool {
        guard stage == .live, myNotes.isEmpty, let script, script.lines.count > 1, player?.phase != .ended else {
            return false
        }
        return elapsed >= script.lines[1].startSec
    }

    private func viewState(elapsed: Double) -> LiveViewState {
        let transcript: [LiveSegment] = player.map { sampleMeetingTranscript(script: $0.script, elapsed: elapsed) } ?? []
        return makeLiveViewState(
            transcript: transcript, translations: [:], displayMode: .originalOnly, failedTranslations: [], otherLanguageSegments: [],
            assistantCard: card, phase: stage == .finishing ? .finishing : .recording, newPersonNumber: 3,
            isPaused: player?.phase == .paused, isMicMuted: true, canToggleMic: false, isInPerson: false, canStart: false,
            startedAt: Date().addingTimeInterval(-elapsed), statusText: "", languageText: languageName(language: .english),
            noteLanguageText: selectedNoteLanguage().interfaceName, isLivePreviewOnDevice: false, notices: []
        )
    }

    /// Paneldeki eylemler: duraklat/sürdür, bitir, "Ne kaçırdım?" (önceden yazılmış özet) ve soru (örnekte cevaplanmaz;
    /// nedeni kartta). Gezinme ve konuşmacı düzeltmesi örnekte bir şey yapmaz.
    private var actions: PanelActions {
        PanelActions(
            onHide: {}, onStart: {},
            onTogglePause: { togglePause() },
            onToggleMic: {},
            onStop: { stage = .finishing },
            onOpenMeetings: {}, onOpenSettings: {},
            onMissed: {
                if let script = player?.script {
                    card = .summary(sampleMissedSummary(note: currentNote(script: script)))
                }
            },
            onAsk: { (question: String) -> Void in
                card = .answer(question: question, text: String(localized: "Bu bir örnek toplantı; burada sorular cevaplanmaz. Gerçek toplantılarında o ana kadar konuşulanlardan cevap gelir."))
            },
            onCloseCard: { card = nil },
            onRetryTranslations: { (_: [SegmentID]) -> Void in },
            onSetLanguage: { (_: MeetingLanguage) -> Void in },
            onChooseLanguageMode: { (_: LanguageMode) -> Void in },
            onReassignBlock: { (_: [SegmentID], _: Int) -> Void in },
            onMergePerson: { (_: Int, _: Int) -> Void in },
            onBookmark: {}
        )
    }

    private func currentNote(script: SampleMeetingScript) -> MeetingNote {
        sampleMeetingNote(script: script, userName: model.userName, language: defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations))
    }

    /// Paketteki örnek toplantıyı açar; açılamazsa neden gösterilir.
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
            // Tanıtım sahnesi (görsel kontrol): ses kısık, toplantının ortasından.
            if isDemoMode, player.phase == .ready {
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

    /// Bitir: ses durur, panel "bitiriliyor"u kısa gösterir, örnek toplantı saklanır ve not açılır.
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
                onSaved(try model.addSampleMeeting(script: player.script, note: currentNote(script: player.script), myNotes: myNotes, audio: audioURL))
            } catch {
                saveProblem = String(localized: "Örnek toplantı Toplantılar'a saklanamadı: \(userFacingMessage(error: error))")
            }
            stage = .note
        }
    }
}

// MARK: Hazırsın

/// Kısayolun tuş başlıkları (`keyBindingDisplay` metninden): her değiştirici (⌃ ⌥ ⇧ ⌘) ayrı başlık, tuşun adı tek başlık
/// ("Boşluk", "F5" harf harf bölünmez). Değiştiriciler metnin başındadır. Saf fonksiyondur.
func keycapLabels(display: String) -> [String] {
    let modifierSymbols: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
    let modifiers: Substring = display.prefix { (character: Character) -> Bool in modifierSymbols.contains(character) }
    let key: Substring = display.dropFirst(modifiers.count)
    return modifiers.map(String.init) + (key.isEmpty ? [] : [String(key)])
}

#if HOSTED_EDITION
/// "Bizi nereden duydun?" yanıtının verildiğinin kaydı (UserDefaults, Bool): soru bir kez sorulur.
private let heardAboutAnsweredDefaultsKey: String = "onboarding.heardAboutAnswered"

/// Yanıtın düğme adı.
private func heardAboutTitle(source: AcquisitionSource) -> LocalizedStringKey {
    switch source {
    case .search: "Arama motoru"
    case .appStore: "App Store"
    case .social: "Sosyal medya"
    case .friend: "Arkadaş ya da iş arkadaşı"
    case .aiAssistant: "Yapay zekâ asistanı"
    case .video: "YouTube ya da podcast"
    case .blog: "Blog ya da yazı"
    case .ad: "Reklam"
    case .other: "Başka bir yer"
    }
}

/// Karşılamanın son adımında isteğe bağlı, tek dokunuşluk "Bizi nereden duydun?": yanıt yalnızca günlük toplam olarak
/// sayılır (`ConversionEvent.heardAbout`, hesaba bağlanmaz). Kullanım istatistikleri kapalıysa soru hiç görünmez (yanıt
/// gönderilmeyecekken sormak yanıltıcı olur); yanıt verildiyse bir daha sorulmaz.
private struct HeardAboutCard: View {
    @State private var answered: AcquisitionSource?
    @AppStorage(heardAboutAnsweredDefaultsKey) private var answeredBefore: Bool = false

    var body: some View {
        if HostedTelemetryCenter.shared.isConversionAllowed && (!answeredBefore || answered != nil) {
            OnboardingCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Bizi nereden duydun?").appFont(size: 14, weight: .semibold).foregroundStyle(Theme.ink)
                        Spacer(minLength: 8)
                        if answered != nil {
                            Label("Teşekkürler!", systemImage: "checkmark")
                                .appFont(size: 12.5, weight: .medium)
                                .foregroundStyle(.tint)
                        }
                    }
                    Text("İsteğe bağlı. Yanıtın hesabına bağlanmaz, yalnızca günlük toplamlarda sayılır.")
                        .appFont(size: 12.5, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    // Chips sized to their text, in as few rows as fit the card (two, or three in longer languages): the
                    // whole question stays in view above the bottom bar.
                    ViewThatFits(in: .horizontal) {
                        chipRows(perRow: 5)
                        chipRows(perRow: 3)
                    }
                }
                .padding(14)
            }
        }
    }

    /// Yanıtlar, satır başına `perRow` düğmeyle.
    private func chipRows(perRow: Int) -> some View {
        let sources: [AcquisitionSource] = AcquisitionSource.allCases
        let rows: [[AcquisitionSource]] = stride(from: 0, to: sources.count, by: perRow).map { (start: Int) -> [AcquisitionSource] in
            Array(sources[start..<min(start + perRow, sources.count)])
        }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(rows, id: \.self) { (row: [AcquisitionSource]) in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { (source: AcquisitionSource) in
                        chip(source: source)
                    }
                }
            }
        }
    }

    /// Bir yanıtın düğmesi: metni kadar geniş bir kapsül; seçilen vurgu rengiyle.
    private func chip(source: AcquisitionSource) -> some View {
        Button {
            choose(source: source)
        } label: {
            Text(heardAboutTitle(source: source))
                .appFont(size: 12.5, weight: answered == source ? .semibold : .regular)
                .lineLimit(1)
                .fixedSize()
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .foregroundStyle(answered == source ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.ink))
                .background(Capsule().strokeBorder(answered == source ? AnyShapeStyle(.tint) : AnyShapeStyle(Theme.line), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(answered != nil)
        .accessibilityAddTraits(answered == source ? .isSelected : [])
    }

    /// Yanıtı bir kez sayar ve teşekkür eder.
    private func choose(source: AcquisitionSource) {
        guard answered == nil else {
            return
        }
        answered = source
        answeredBefore = true
        HostedTelemetryCenter.shared.record(conversion: .heardAbout(source: source))
    }
}
#endif

/// Hazırsın: kısayollar, kaydın nereden başladığı ve Sor ile tarifler.
private struct ReadyStep: View {
    let shortcuts: ShortcutController
    let hasSampleMeeting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            OnboardingCard {
                ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { (item: (offset: Int, element: ShortcutAction)) in
                    if item.offset > 0 {
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                    shortcutRow(action: item.element)
                }
            }
            OnboardingCard {
                pointer(symbol: "record.circle", title: "Kayıt", text: "Ana sayfadaki \"Kaydı başlat\", menü çubuğu ya da kısayol; kayıt sırasında canlı panel açılır.")
                OnboardingRowDivider()
                pointer(symbol: "bubble.left.and.text.bubble.right", title: "Sor ve tarifler", text: "Toplantılarına soru sor; sık sorduğunu tarif olarak kaydet, \"/\" ile çalıştır.")
                if hasSampleMeeting {
                    OnboardingRowDivider()
                    pointer(symbol: "doc.text", title: "Örnek toplantı", text: "Toplantılar'da seni bekliyor; istediğin zaman silebilirsin.")
                }
            }
            #if HOSTED_EDITION
            HeardAboutCard()
            #endif
        }
    }

    private func shortcutRow(action: ShortcutAction) -> some View {
        let display: String = keyBindingDisplay(binding: shortcuts.currentBinding(action: action))
        return HStack(spacing: 14) {
            Text(action.title).appFont(size: 14, weight: .regular).foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            KeycapRow(labels: keycapLabels(display: display), height: 26, fontSize: 13)
            // VoiceOver kısayolu harf harf değil tek bir ad olarak okur.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: display))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func pointer(symbol: String, title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        HStack(alignment: .center, spacing: 14) {
            AccentSymbolTile(symbol: symbol, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).appFont(size: 14, weight: .semibold).foregroundStyle(Theme.ink)
                Text(text).appFont(size: 12.5, weight: .regular).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
    }
}
