import AINotepadCore
import AINotepadUI
import SwiftUI

/// Uygulamanın kökü: boştayken ana ekran (bkz. `PhoneHome`); kayıtta odaklı tam ekran (gezinme çubuğu gizli): süre, ses
/// dalgası, konuşmacılı canlı metin ve not dilindeki çevirisi, "İşaretle" ve "Bitir"; bitince hazırlanma adımları.
struct PhoneHomeRoot: View {
    let recorder: PhoneRecorder
    let store: PhoneStore
    let router: PhoneRouter
    let calendar: PhoneCalendar
    let player: MeetingAudioPlayer
    let account: HostedAccount
    /// Sıradaki toplantının brifingini Sor'da açar.
    let onBriefing: @MainActor (CalendarMeeting) -> Void
    /// Kayıt ekranından açılan fotoğraf kaynağı (tarayıcı, Fotoğraflar). Kökte tutulur: kayıt ekranı kayıt bitince
    /// kalkar, açık tarayıcı ya da seçici onunla kapanıp fotoğraf kaybolmasın.
    @State private var photoSource: PhotoCaptureSource?
    /// Fotoğrafın gideceği toplantı ve an: kaynak açılırken alınır; kaynak açıkken kayıt bitse de fotoğraf biten
    /// toplantıya, çekilmek istendiği ana eklenir.
    @State private var photoTarget: LivePhotoTarget?
    /// Bu kayıtta eklenen fotoğraflar ve son ekleme hatası.
    @State private var photosAdded: Int = 0
    @State private var photoError: String?

    var body: some View {
        Group {
            switch recorder.phase {
            case .idle, .starting:
                PhoneHome(recorder: recorder, store: store, router: router, calendar: calendar, player: player, account: account, onBriefing: onBriefing)
            case .recording, .finishing:
                LiveRecordingView(recorder: recorder, onBriefing: onBriefing, photosAdded: photosAdded, photoError: photoError) { (source: PhotoCaptureSource) -> Void in
                    openPhotoSource(source: source)
                }
            }
        }
        .photoCapture(source: $photoSource) { (images: [Data]) -> Void in
            addPhotos(images: images)
        } onError: { (message: String) -> Void in
            photoError = message
        }
        // Kayıt bittikten sonra eklenemeyen fotoğrafın nedeni (kayıt ekranı artık yok).
        .alert(
            "Fotoğraf eklenemedi",
            isPresented: Binding<Bool>(
                get: { photoError != nil && (recorder.phase == .idle || recorder.phase == .starting) },
                set: { if !$0 { photoError = nil } }
            )
        ) {
            Button("Kapat", role: .cancel) { photoError = nil }
        } message: {
            Text(verbatim: photoError ?? "")
        }
        .onChange(of: recorder.startedAt) { (_: Date?, started: Date?) in
            // Yeni kayıt: sayaç ve eski hata sıfırlanır.
            if started != nil {
                photosAdded = 0
                photoError = nil
            }
        }
        .background(Theme.background)
        .animation(.smooth(duration: 0.35), value: recorder.phase == .recording || recorder.phase == .finishing)
        // Bitirilirken ve biten toplantı işlenirken ekran durağan bulanıklaşır, ortada hazırlık kartı (Mac'teki gibi).
        .modifier(PhoneProcessingOverlayHost(recorder: recorder, store: store, router: router))
    }
}

extension PhoneHomeRoot {
    /// Kaynağı açar; fotoğrafın yeri (toplantı ve kayıttaki an) şimdi alınır. Kayıt yoksa açılmaz.
    private func openPhotoSource(source: PhotoCaptureSource) {
        guard let target = recorder.livePhotoTarget() else {
            return
        }
        photoTarget = target
        photoSource = source
    }

    /// Çekilen ya da seçilen fotoğrafları kaynak açılırken alınan yere ekler (kayıt bu arada bittiyse biten toplantıya).
    private func addPhotos(images: [Data]) {
        guard !images.isEmpty, let target = photoTarget else {
            return
        }
        Task {
            let result: (added: [ScreenSnapshot], error: String?) = await AINotepadiOS.addPhotos(
                meetingID: target.meetingID, directory: target.directory, offsetSec: target.offsetSec, images: images
            )
            photosAdded += result.added.count
            photoError = result.error
        }
    }
}

/// "Salı, 27 Ekim": dilin kendi gün ve ay adlarıyla (bölge biçimi ayı sayıya çevirmesin). Saf fonksiyondur.
func longDayTitle(date: Date, locale: Locale) -> String {
    let formatter: DateFormatter = DateFormatter()
    // Yalnız dil: bölge (ör. Finlandiya) biçimi ayı sayıya çeviriyordu ("Salı 27.10.").
    formatter.locale = Locale(identifier: locale.language.languageCode?.identifier ?? "en")
    formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
    return formatter.string(from: date)
}

/// Kayıt engelinin çözüm düğmesi (Mac'teki `StartBlockAction`).
private enum PhonePlanAction {
    /// Abonelik ekranı (deneme bitti, plan sona erdi).
    case subscribe
    /// Ayarlar › Hesap (aylık sınır doldu, ödeme alınamadı).
    case openAccount
    /// Hak durumu yeniden okunur (sunucuya ulaşılamadı, çevrimdışı kayda izin yok).
    case retry
}

/// Engelin çözümü: hak durumu okunamadıysa yeniden dene, okunduysa engelin çözümü (`hostedStartBlockRemedy`); engel yoksa
/// nil.
@MainActor
private func phonePlanAction(account: HostedAccount) -> PhonePlanAction? {
    if case .signedInStatusUnknown = account.state {
        return .retry
    }
    guard case .signedIn(let entitlements) = account.state, let block = hostedStartBlock(entitlements: entitlements) else {
        return nil
    }
    switch hostedStartBlockRemedy(block: block) {
    case .subscribe: return .subscribe
    case .openAccount: return .openAccount
    }
}

/// Ana ekranda, başlığın altında hesabın durumu: kaydı engelleyen hak durumu varsa nedeni (deneme bitti, aylık sınır…) ve
/// çözümü (Mac'teki gibi tek düğme: "Abone ol" abonelik ekranını, "Kullanımı gör" Ayarlar › Hesap'ı açar, "Yeniden
/// dene" hak durumunu yeniden okur); yoksa denemede kalan toplantılar. Abonelikte ve hak durumu okunmamışken görünmez.
struct PhonePlanNotice: View {
    let account: HostedAccount
    let router: PhoneRouter

    var body: some View {
        if let blocked = phoneStartBlockMessage(account: account, now: Date()) {
            VStack(alignment: .leading, spacing: 10) {
                NoticeText(blocked as String, severity: .attention)
                    .appFont(size: 13, weight: .regular)
                if let action = phonePlanAction(account: account) {
                    Button {
                        resolve(action: action)
                    } label: {
                        Text(title(action: action))
                            .appFont(size: 15, weight: .semibold)
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(.tint, in: Capsule())
                    }
                    .buttonStyle(PressableCardStyle())
                    .disabled(account.isWorking)
                }
            }
        } else if case .signedIn(let entitlements) = account.state, case .trial(let left, _) = hostedPlanStatus(entitlements: entitlements) {
            Label(String(localized: "Ücretsiz deneme: \(hostedTrialLeftText(left: left))."), systemImage: "sparkles")
                .appFont(size: 13, weight: .medium)
                .foregroundStyle(Theme.muted)
        }
    }

    private func title(action: PhonePlanAction) -> LocalizedStringKey {
        switch action {
        case .subscribe: "Abone ol"
        case .openAccount: "Kullanımı gör"
        case .retry: "Yeniden dene"
        }
    }

    private func resolve(action: PhonePlanAction) {
        switch action {
        case .subscribe:
            account.showPlans()
        case .openAccount:
            router.openAccount()
        case .retry:
            Task { await account.refresh() }
        }
    }
}

/// Mac'teki kullanım bildiriminin iPhone karşılığı: aylık sınırın %80'i ve son deneme toplantısı (dönem başına bir kez,
/// kapatılır; bkz. `HostedAccount.visibleNotice`). Sınır dolduysa ya da deneme bittiyse neden zaten `PhonePlanNotice`'te
/// yazar.
struct PhoneUsageNotice: View {
    let account: HostedAccount

    var body: some View {
        if let notice = account.visibleNotice, let texts = texts(notice: notice) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: texts.title).appFont(size: 14, weight: .semibold)
                    Text(verbatim: texts.detail)
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if notice == .trialOneLeft {
                        Button("Abone ol") {
                            account.dismissNotice()
                            account.showPlans()
                        }
                        .appFont(size: 14, weight: .semibold)
                        .padding(.top, 2)
                        .disabled(account.isWorking)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    account.dismissNotice()
                } label: {
                    Image(systemName: "xmark")
                        .appFont(size: 11, weight: .semibold)
                        .foregroundStyle(Theme.muted)
                        .frame(width: 28, height: 28)
                        // Dokunma alanı en az 44 pt (Apple HIG); simge küçük kalır.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Kapat")
            }
            .padding(14)
            .background(NoticeSeverity.attention.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func texts(notice: HostedUsageNotice) -> (title: String, detail: String)? {
        guard case .signedIn(let entitlements) = account.state else {
            return nil
        }
        switch notice {
        case .monthlyWarning:
            let fraction: Double = hostedUsageFraction(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap)
            let percent: String = fraction.formatted(.percent.precision(.fractionLength(0)).locale(interfaceLocale()))
            return (
                title: String(localized: "Bu ayki kullanım sınırına yaklaştın: \(percent)"),
                detail: String(localized: "\(hostedMonthlyUsageText(used: entitlements.monthlyHoursUsed, cap: entitlements.monthlyHoursCap)); sınır \(hostedResetDayText(now: Date())) tarihinde sıfırlanır.")
            )
        case .trialOneLeft:
            return (
                title: String(localized: "Ücretsiz denemende 1 toplantı kaldı"),
                detail: String(localized: "Deneme \(hostedTrialTermsText(entitlements: entitlements)) sürer. Kesintisiz devam etmek için şimdi abone olabilirsin.")
            )
        case .monthlyFull, .trialEnded:
            return nil
        }
    }
}

/// Basınca hafifçe küçülen kart/düğme.
struct PressableCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Kayıt sırasında odaklı tam ekran (gezinme çubuğu gizli): üstte sabit başlık (kayıt durumu, dil, büyük süre ve ses
/// dalgası), ortada konuşmacılı canlı metin (en alta kayar), altta yüzen çubukta "Ne kaçırdım?", "İşaretle", "Bitir",
/// "Duraklat" ve "Notlarım". "Ne kaçırdım?" çubuğun üstünde asistan kartını açar; kartın altındaki alanla toplantıya
/// soru sorulur (Mac panelindeki gibi); soru alanı ⋯ › "Toplantıya sor…" ile kartsız da açılır. Rıza hatırlatması kayıt
/// başında üstte 3 saniye görünen bir bildirimdir. Çevrimdışı kayıtta ve aylık sınırla kısaltılan toplantıda üstte
/// bildirim (Mac'teki şeritler).
private struct LiveRecordingView: View {
    let recorder: PhoneRecorder
    /// "Açık görevler"in "Tümünü gör"ü kaydın takvim toplantısının brifingini Sor'da açar (Mac'teki gibi; kayıt sürer).
    let onBriefing: @MainActor (CalendarMeeting) -> Void
    /// Bu kayıtta eklenen fotoğraflar ve son ekleme hatası (kökte tutulur, bkz. `PhoneHomeRoot`).
    let photosAdded: Int
    let photoError: String?
    /// Fotoğraf kaynağını açar (tahta ya da slayt tarayıcısı, Fotoğraflar); fotoğraf kaydın şu anına eklenir.
    let onCapturePhoto: @MainActor (PhotoCaptureSource) -> Void
    @State private var markedAt: Date?
    @State private var isNotesOpen: Bool = false
    /// Asistana sorulacak soru (kart açıkken ya da soru alanı ⋯ menüsünden açıldıysa).
    @State private var question: String = ""
    /// Soru alanı kartsız açık (⋯ › "Toplantıya sor…").
    @State private var isAskOpen: Bool = false
    @FocusState private var isQuestionFocused: Bool
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    /// "Tümünü kopyala"ya basılan an: üstte kısa "Kopyalandı" bildirimi.
    @State private var copiedAt: Date?
    /// Canlı metin en alttaki yeni satırı izliyor mu; kullanıcı yukarı kaydırınca durur, en alta dönünce sürer.
    @State private var isFollowing: Bool = true
    /// Kullanıcı parmağıyla kaydırıyor mu (metin büyüyünce alttan uzaklaşmak izlemeyi durdurmasın diye).
    @State private var isUserScrolling: Bool = false
    /// Kullanıcı yukarıdayken yeni metin geldi mi ("Yeni metin" düğmesi).
    @State private var hasUnseenText: Bool = false
    /// Canlı çeviri (Ayarlar › Toplantı'daki gösterimle aynı ayar; ⋯ menüsünden de açılıp kapanır).
    @AppStorage(PhoneSettingsKey.displayMode) private var displayMode: String = DisplayMode.bilingual.rawValue
    /// ⋯ › "Kaydı sil…" onayı bekleniyor.
    @State private var isConfirmingDiscard: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    /// Konuşmacı düzeltmeleri uygulanmış transkriptin blokları (kaydedicide her canlı güncellemede bir kez kurulur; bkz.
    /// `PhoneRecorder.liveView`).
    private var blocks: [SpeakerBlock] {
        recorder.liveView.blocks
    }

    private var liveTranslationOn: Bool {
        (DisplayMode(rawValue: displayMode) ?? .bilingual).needsLiveTranslation
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 10) {
                if recorder.isPaused, recorder.phase == .recording {
                    PausedNotice()
                }
                MicrophoneNotice(status: recorder.microphoneStatus, recoveredVisible: recorder.microphoneRecoveredNoticeVisible)
                if recorder.phase == .recording, recorder.isOfflineRecording {
                    OfflineRecordingNotice()
                }
                if recorder.phase == .recording, let deadline = recorder.shortMeetingDeadline {
                    MeetingLimitNotice(deadline: deadline)
                }
                if recorder.phase == .recording, let reason = recorder.meetingOverPrompt {
                    MeetingOverCard(reason: reason) {
                        recorder.stop()
                    } onContinue: {
                        recorder.dismissMeetingOverPrompt()
                    }
                    .transition(.opacity)
                }
                PhoneErrorList(messages: recorder.errorMessages + [photoError].compactMap { $0 })
                // Açık görevler yalnız takvim toplantısına bağlı kayıtta bulunur (`relatedOpenTasks`).
                if recorder.phase == .recording, !recorder.relatedTasks.isEmpty, let meeting = recorder.recordingCalendarMeeting {
                    PhoneRelatedTasksCard(tasks: recorder.relatedTasks) {
                        onBriefing(meeting)
                    } onDismiss: {
                        recorder.relatedTasks = []
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 20)
            .animation(.smooth(duration: 0.25), value: recorder.isPaused)
            .animation(.smooth(duration: 0.25), value: recorder.relatedTasks.isEmpty)
            .animation(.smooth(duration: 0.25), value: recorder.meetingOverPrompt)
            if blocks.isEmpty {
                listening
            } else {
                transcript
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if let card = recorder.assistantCard {
                    assistant(card: card)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else if isAskOpen, recorder.phase == .recording {
                    questionField(onClose: {
                        question = ""
                        isAskOpen = false
                    })
                    .padding(.horizontal, 16)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    // Menü kapanırken alan henüz yoktu: klavye alan görününce açılır.
                    .onAppear { isQuestionFocused = true }
                }
                controls
            }
            .animation(.smooth(duration: 0.3), value: recorder.assistantCard != nil)
            .animation(.smooth(duration: 0.3), value: isAskOpen)
        }
        .overlay(alignment: .top) {
            if recorder.consentReminderVisible {
                ConsentToast(language: recorder.lockedLanguage ?? phonePrimaryMeetingLanguage()) { recorder.consentReminderVisible = false }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if copiedAt != nil {
                CopiedToast()
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.smooth(duration: 0.35), value: recorder.consentReminderVisible)
        .animation(.smooth(duration: 0.3), value: copiedAt)
        .sensoryFeedback(.success, trigger: copiedAt) { (_: Date?, new: Date?) -> Bool in new != nil }
        .task(id: copiedAt) {
            // "Kopyalandı" kısa süre görünür.
            guard copiedAt != nil else {
                return
            }
            do {
                try await Task.sleep(for: .seconds(copiedToastSeconds))
            } catch {
                return
            }
            copiedAt = nil
        }
        .task(id: recorder.consentReminderVisible) {
            // Hatırlatma 3 saniye sonra kendiliğinden kalkar (kalıcı kart değil); dokununca hemen kapanır.
            guard recorder.consentReminderVisible else {
                return
            }
            do {
                try await Task.sleep(for: .seconds(consentToastSeconds))
            } catch {
                return
            }
            recorder.consentReminderVisible = false
        }
        .toolbar(.hidden, for: .navigationBar)
        .confirmationDialog("Kayıt silinsin mi?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("Kaydı sil", role: .destructive) { recorder.discard() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Kaydedilen ses ve metin silinir, not yazılmaz. Geçen süre aylık kullanımına sayılır.")
        }
        .sheet(isPresented: $isNotesOpen) {
            PhoneMyNotesSheet(text: Binding<String>(get: { recorder.myNotes }, set: { (text: String) -> Void in recorder.myNotes = text }))
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private let bottomID: String = "son"

    /// Sabit başlık: solda kayıt durumu, sağda dil ve ⋯ (Tümünü kopyala, Canlı çeviri); ortada büyük süre (duraklatılan
    /// süreyi saymaz), altında ses dalgası ve işaretlenen an sayısı.
    private var header: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                RecordingStatusPill(isFinishing: recorder.phase == .finishing, isPaused: recorder.isPaused)
                Spacer()
                Menu {
                    LanguageMenuItems { (language: MeetingLanguage) -> Void in recorder.setLanguage(language: language) }
                } label: {
                    HStack(spacing: 5) {
                        Text(languageText(locked: recorder.lockedLanguage, mode: recorder.languageMode, isRecording: true))
                        Image(systemName: "chevron.down").appFont(size: 9, weight: .bold)
                    }
                    .appFont(size: 13, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.line))
                }
                .disabled(recorder.phase != .recording)
                photoMenu
                moreMenu
            }
            VStack(spacing: 12) {
                if let startedAt = recorder.startedAt {
                    ElapsedClock(startedAt: startedAt, stoppedAt: recorder.stoppedAt, pause: recorder.pauseClock)
                }
                PhoneLevelBars(levels: recorder.levels)
                    .frame(maxWidth: 280)
                    .opacity(recorder.isPaused ? 0.35 : 1)
                Text(liveCountsText)
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(Theme.muted)
                    .frame(height: 14)
                    .contentTransition(.numericText())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// İşaretlenen an ve eklenen fotoğraf sayısı (ikisi de yoksa boş).
    private var liveCountsText: String {
        [
            recorder.highlights.isEmpty ? nil : String(localized: "\(recorder.highlights.count) an işaretlendi"),
            photosAdded == 0 ? nil : String(localized: "\(photosAdded) fotoğraf eklendi"),
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    /// Kamera: tahtanın, slaytın ya da bir krokinin fotoğrafı kaydın şu anına eklenir (notta o sırada konuşulanlarla
    /// birlikte okunur; ayar açıksa). Kayıt sürer.
    private var photoMenu: some View {
        Menu {
            PhotoCaptureMenuItems(source: Binding<PhotoCaptureSource?>(
                get: { nil },
                set: { (source: PhotoCaptureSource?) -> Void in
                    if let source {
                        onCapturePhoto(source)
                    }
                }
            ))
        } label: {
            Image(systemName: "camera")
                .appFont(size: 14, weight: .semibold)
                .foregroundStyle(Theme.ink)
                .frame(width: 34, height: 34)
                .background(Theme.card, in: Circle())
                .overlay(Circle().strokeBorder(Theme.line))
                .contentShape(Circle())
        }
        .disabled(recorder.phase != .recording)
        .accessibilityLabel("Fotoğraf ekle")
        .sensoryFeedback(.success, trigger: photosAdded)
    }

    /// ⋯ menüsü (Mac panelindeki gibi): "Ne kaçırdım?", Notlarım, toplantıya soru sor (Mac'te panelin altındaki soru
    /// alanı), canlı metnin tümünü ekrandaki gibi kopyala, canlı çeviriyi aç/kapat ve onaylı "Kaydı sil".
    private var moreMenu: some View {
        Menu {
            Button("Ne kaçırdım?", systemImage: "sparkles") {
                recorder.askWhatIMissed()
            }
            .disabled(recorder.phase != .recording || blocks.isEmpty)
            Button("Notlarım", systemImage: recorder.myNotes.isEmpty ? "square.and.pencil" : "square.and.pencil.circle.fill") {
                isNotesOpen = true
            }
            .disabled(recorder.phase != .recording)
            Button("Toplantıya sor…", systemImage: "questionmark.bubble") {
                isAskOpen = true
            }
            .disabled(recorder.phase != .recording || recorder.assistantCard != nil)
            Button("Tümünü kopyala", systemImage: "doc.on.doc") {
                copyToPasteboard(text: recorder.displayedText)
                copiedAt = Date()
            }
            .disabled(blocks.isEmpty)
            Toggle(isOn: Binding<Bool>(get: { liveTranslationOn }, set: { (isOn: Bool) -> Void in
                recorder.selectDisplayMode(mode: isOn ? .bilingual : .originalOnly)
            })) {
                Label("Canlı çeviri", systemImage: "character.bubble")
            }
            .disabled(recorder.phase != .recording)
            Divider()
            Button("Kaydı sil…", systemImage: "trash", role: .destructive) {
                isConfirmingDiscard = true
            }
            .disabled(recorder.phase != .recording)
        } label: {
            Image(systemName: "ellipsis")
                .appFont(size: 14, weight: .semibold)
                .foregroundStyle(Theme.ink)
                .frame(width: 34, height: 34)
                .background(Theme.card, in: Circle())
                .overlay(Circle().strokeBorder(Theme.line))
                .contentShape(Circle())
        }
        .accessibilityLabel("Diğer")
    }

    /// Henüz metin yok: kalan alanın ortasında sakin bir "Dinliyor" durumu.
    private var listening: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .appFont(size: 26, weight: .regular)
                .foregroundStyle(Theme.muted)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
            Text("Dinliyor… Konuşma başlayınca metin burada akar.")
                .appFont(size: 15, weight: .regular)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Canlı metin: konuşmacı blokları; yeni metin gelince en alta kayar, üst kenarda başlığın altına doğru solar.
    private var transcript: some View {
        ScrollViewReader { (proxy: ScrollViewProxy) in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    // Her güncellemede bir kez: bloklar başına yeniden hesaplanmaz.
                    let view: LiveTranscriptView = recorder.liveView
                    let otherLanguage: Set<SegmentID> = recorder.otherLanguageSegments
                    let persons: [Int] = view.persons
                    ForEach(view.blocks) { (block: SpeakerBlock) in
                        LiveBlockView(
                            block: block, translations: recorder.translations, otherLanguage: otherLanguage,
                            failedTranslations: failedTranslationIDs(block: block, failed: recorder.failedTranslations),
                            canRetry: recorder.phase == .recording, persons: persons, newPersonNumber: recorder.newPersonNumber,
                            onRetry: { (ids: [SegmentID]) -> Void in recorder.retryTranslations(ids: ids) },
                            onReassign: { (ids: [SegmentID], person: Int) -> Void in recorder.reassignBlock(segments: ids, person: person) },
                            onMerge: { (from: Int, into: Int) -> Void in recorder.mergeLivePersons(from: from, into: into) }
                        )
                        .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                    // Son satırın altındaki boşluk: Ayarlar › Görünüm › Alt boşluk (Mac'teki gibi).
                    Color.clear.frame(height: max(1, appearance.bottomSpacing)).id(bottomID)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .animation(.smooth(duration: 0.3), value: blocks.map(\.id))
            }
            .scrollIndicators(.hidden)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 18)
                    Rectangle()
                }
            }
            .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) }
            .onScrollPhaseChange { (_: ScrollPhase, phase: ScrollPhase) in
                isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            }
            .onScrollGeometryChange(for: Bool.self) { (geometry: ScrollGeometry) -> Bool in
                // Alta 60 pt'den yakınsa kullanıcı canlı metni izliyor sayılır (Mac'teki gibi).
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 60
            } action: { (_: Bool, atBottom: Bool) in
                if atBottom {
                    isFollowing = true
                    hasUnseenText = false
                } else if isUserScrolling {
                    // Yalnızca kullanıcı yukarı kaydırınca izleme durur; yeni metin içeriği büyütünce durmaz.
                    isFollowing = false
                }
            }
            .onChange(of: recorder.transcript) {
                if isFollowing {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                } else {
                    hasUnseenText = true
                }
            }
            .overlay(alignment: .bottom) {
                if hasUnseenText {
                    Button {
                        isFollowing = true
                        hasUnseenText = false
                        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(bottomID, anchor: .bottom) }
                    } label: {
                        Label("Yeni metin", systemImage: "arrow.down")
                            .appFont(size: 13, weight: .medium)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Theme.primary, in: Capsule())
                            .foregroundStyle(Theme.onPrimary)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.2), value: hasUnseenText)
        }
    }

    /// Asistan kartı ve altında toplantıya soru alanı; kartın "x"i ikisini de kapatır.
    private func assistant(card: AssistantCard) -> some View {
        VStack(spacing: 8) {
            AssistantCardView(card: card) {
                question = ""
                isAskOpen = false
                recorder.closeAssistantCard()
            }
            questionField(onClose: nil)
        }
        .padding(.horizontal, 16)
    }

    /// Toplantıya soru alanı ve gönder düğmesi; kartsız açıldıysa (`onClose`) solda kapatma düğmesi.
    private func questionField(onClose: (@MainActor () -> Void)?) -> some View {
        HStack(spacing: 8) {
            if let onClose {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .appFont(size: 13, weight: .semibold)
                        .foregroundStyle(Theme.muted)
                        .frame(width: 40, height: 40)
                        .background(Theme.card, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.line))
                }
                .buttonStyle(PressableCardStyle())
                .accessibilityLabel("Kapat")
            }
            TextField("Toplantıya sor…", text: $question)
                .appFont(size: 15, weight: .regular)
                .focused($isQuestionFocused)
                .submitLabel(.send)
                .onSubmit(sendQuestion)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.card, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.line))
            Button(action: sendQuestion) {
                Image(systemName: "arrow.up")
                    .appFont(size: 15, weight: .semibold)
                    .foregroundStyle(Theme.onPrimary)
                    .frame(width: 40, height: 40)
                    .background(Theme.primary, in: Circle())
            }
            .buttonStyle(PressableCardStyle())
            .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Sor")
        }
    }

    /// Soruyu gönderir: cevap asistan kartında açılır (kart soru alanını da taşır).
    private func sendQuestion() {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        recorder.askDuringMeeting(question: question)
        question = ""
        isAskOpen = false
    }

    /// "Bitir" düğmesinin içi: kırmızı kare ve yazı (tek satır, gerekirse küçülür) ya da yalnız kare.
    @ViewBuilder
    private func finishLabel(showsTitle: Bool) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(red: 0.93, green: 0.27, blue: 0.23))
                .frame(width: 13, height: 13)
            if showsTitle {
                Text("Bitir")
                    .appFont(size: 17, weight: .semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
    }

    /// Yüzen eylem çubuğu: üç düğme, her biri yazısıyla: solda "Duraklat"/"Devam", ortada geniş "Bitir", sağda
    /// "İşaretle" ("Ne kaçırdım?" ve "Notlarım" ⋯ menüsünde). Küçük ekranda (iPhone SE) ve büyük yazıda "Bitir" sığmazsa
    /// küçülür, yine sığmazsa yalnız simge kalır. Bitirilirken yalnız durum.
    private var controls: some View {
        HStack(spacing: 10) {
            if recorder.phase == .finishing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Bitiriliyor… Son cümleler ve konuşmacılar tamamlanıyor.")
                        .appFont(size: 14, weight: .medium)
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 54)
            } else {
                Button {
                    if recorder.isPaused {
                        recorder.resume()
                    } else {
                        recorder.pause()
                    }
                } label: {
                    RecordingControlIcon(systemImage: recorder.isPaused ? "play.fill" : "pause.fill", title: recorder.isPaused ? "Devam ettir" : "Duraklat")
                }
                .buttonStyle(PressableCardStyle())
                .accessibilityLabel(recorder.isPaused ? "Devam ettir" : "Duraklat")
                .sensoryFeedback(.impact(weight: .medium), trigger: recorder.isPaused)
                Button {
                    recorder.stop()
                } label: {
                    ViewThatFits(in: .horizontal) {
                        finishLabel(showsTitle: true)
                        finishLabel(showsTitle: false)
                    }
                    .foregroundStyle(Theme.onPrimary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(Theme.primary, in: Capsule())
                }
                .buttonStyle(PressableCardStyle())
                .accessibilityLabel("Kaydı bitir")
                .sensoryFeedback(.success, trigger: recorder.phase)
                Button {
                    recorder.markMoment()
                    markedAt = Date()
                } label: {
                    RecordingControlIcon(systemImage: markedAt.map { Date().timeIntervalSince($0) < 2 } == true ? "bookmark.fill" : "bookmark", title: "İşaretle")
                }
                .buttonStyle(PressableCardStyle())
                // Duraklatılmışken işaretlenecek konuşma yok.
                .disabled(recorder.isPaused)
                .accessibilityLabel("Bu anı işaretle")
                .sensoryFeedback(.impact(weight: .light), trigger: recorder.highlights.count)
            }
        }
        .padding(10)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.10), radius: 20, y: 8)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background {
            // Kayan metin çubuğun arkasında zemine doğru solar.
            LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .center)
                .padding(.top, -24)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
    }
}

/// Rıza bildiriminin ekranda kalma süresi (saniye).
private let consentToastSeconds: Double = 3

/// Kayıt çubuğundaki simge düğmesi (Duraklat, İşaretle): kullanıcının vurgu renginde yuvarlak simge ve altında kısa
/// yazısı (simgenin ne yaptığı görülsün).
private struct RecordingControlIcon: View {
    let systemImage: String
    let title: LocalizedStringKey
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage)
                .appFont(size: 17, weight: .medium)
                .frame(width: 40, height: 40)
                .background(appearance.accent.color.opacity(0.12), in: Circle())
                .contentTransition(.symbolEffect(.replace))
            Text(title)
                .appFont(size: 11, weight: .medium)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(appearance.accent.color)
        .frame(width: 64, height: 60)
    }
}

/// "Toplantı bitti mi?": takvim etkinliği bitti ya da uzun süredir konuşma yok; "Bitir" kaydı bitirir, "Sürüyor"
/// soruyu kapatır (aynı soru bildirim olarak da gelir).
private struct MeetingOverCard: View {
    let reason: MeetingOverReason
    let onFinish: @MainActor () -> Void
    let onContinue: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Toplantı bitti mi?")
                    .appFont(size: 14, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                Text(reason == .calendarEnded ? "Takvimdeki toplantının süresi doldu ama kayıt sürüyor." : "10 dakikadır konuşma duyulmadı ama kayıt sürüyor.")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Kaydı bitir", action: onFinish)
                    .buttonStyle(.accentPill)
                Button("Sürüyor", action: onContinue)
                    .buttonStyle(.plain)
                    .appFont(size: 14, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 10)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// "Kopyalandı" bildiriminin ekranda kalma süresi (saniye).
private let copiedToastSeconds: Double = 1.6

/// Kayıt durumu hapı: kayıtta yavaşça nefes alan kırmızı nokta ve "Kaydediliyor"; duraklatılmışken duraklatma simgesi ve
/// "Duraklatıldı"; bitirilirken durgun nokta ve "Bitiriliyor".
private struct RecordingStatusPill: View {
    let isFinishing: Bool
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 7) {
            if isPaused, !isFinishing {
                Image(systemName: "pause.fill")
                    .appFont(size: 10, weight: .bold)
                    .foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
                Text("Duraklatıldı")
                    .appFont(size: 13, weight: .semibold)
                    .foregroundStyle(Theme.ink)
            } else {
                RecordingDot(isFinishing: isFinishing)
                Text(isFinishing ? "Bitiriliyor" : "Kaydediliyor")
                    .appFont(size: 13, weight: .semibold)
                    .foregroundStyle(isFinishing ? Theme.muted : Theme.ink)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isFinishing || isPaused ? AnyShapeStyle(Theme.soft) : AnyShapeStyle(Color.red.opacity(0.10)), in: Capsule())
    }
}

/// Kaydın süresi: kayıtta saniyede bir ilerler; duraklatılan süreyi saymaz, duraklatılınca ve "Bitir"e basılınca o anda
/// durur (bitirme sürerken saymaz).
private struct ElapsedClock: View {
    let startedAt: Date
    let stoppedAt: Date?
    let pause: PauseClock

    var body: some View {
        if let frozenAt = stoppedAt ?? pause.pausedAt {
            clockText(seconds: recordingActiveSec(startedAt: startedAt, stoppedAt: stoppedAt, pause: pause, now: frozenAt))
        } else {
            TimelineView(.periodic(from: pause.timerStart(startedAt: startedAt), by: 1)) { (context: TimelineViewDefaultContext) in
                clockText(seconds: recordingActiveSec(startedAt: startedAt, stoppedAt: nil, pause: pause, now: context.date))
            }
        }
    }

    private func clockText(seconds: TimeInterval) -> some View {
        Text(timestamp(seconds: seconds))
            .appFont(size: 56, weight: .light)
            .tracking(-1.5)
            .monospacedDigit()
            .foregroundStyle(Theme.ink)
    }
}

/// Kayıt duraklatıldı: tek cümlelik açıklama.
private struct PausedNotice: View {
    var body: some View {
        Label("Duraklatıldı; ses kaydedilmez. Duraklatılan süre toplantının süre sınırına ve aylık kullanıma sayılmaz.", systemImage: "pause.circle.fill")
            .appFont(size: 13, weight: .medium)
            .foregroundStyle(Theme.muted)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .transition(.opacity)
    }
}

/// Sunucuya ulaşılamadan süren kayıt (Mac'teki "Çevrimdışı kaydediliyor" şeridi): canlı metin bu iPhone'da yazılır,
/// konuşmacılar ve not bağlantı gelince hazırlanır.
private struct OfflineRecordingNotice: View {
    var body: some View {
        // Tek satır başlık ve kısa açıklama: küçük ekranda canlı metne yer kalsın.
        VStack(alignment: .leading, spacing: 2) {
            Label("Çevrimdışı kaydediliyor", systemImage: "wifi.slash")
                .appFont(size: 13, weight: .semibold)
                .foregroundStyle(Theme.ink)
            Text("Not bağlantı gelince hazırlanır.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }
}

/// Aylık sınıra az kaldığı için kısaltılan toplantının kalan dakikası ve bitiş saati (Mac'teki `HostedMeetingLimitStrip`);
/// 15 saniyede bir güncellenir.
private struct MeetingLimitNotice: View {
    let deadline: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { (context: TimelineViewDefaultContext) in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "hourglass")
                    .appFont(size: 13, weight: .semibold)
                    .foregroundStyle(NoticeSeverity.attention.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bu toplantıya \(hostedMinutesLeft(deadline: deadline, now: context.date)) dakika kaldı")
                        .appFont(size: 13, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                    Text("Aylık sınırına göre kayıt \(deadline.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(interfaceLocale()))) itibarıyla biter.")
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
                .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NoticeSeverity.attention.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
        }
        .transition(.opacity)
    }
}

/// Kayıt başında: bu toplantıyla ilgili önceki toplantılardan açık görevler (en çok 5), her biri kaynak toplantının
/// başlığıyla. Yalnız hatırlatmadır (dokunmak görevi işaretlemez); "Tümünü gör" toplantının brifingini Sor'da açar,
/// kapatılınca bu kayıt boyunca görünmez (Mac'teki şeridin eşi).
private struct PhoneRelatedTasksCard: View {
    let tasks: [RelatedOpenTask]
    let onShowAll: @MainActor () -> Void
    let onDismiss: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Açık görevler (önceki toplantılardan)", systemImage: "checklist")
                    .appFont(size: 13, weight: .semibold)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .appFont(size: 12, weight: .semibold)
                        .foregroundStyle(Theme.muted)
                        .frame(width: 28, height: 28)
                        // Dokunma alanı en az 44 pt (Apple HIG); simge küçük kalır.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Kapat"))
            }
            ForEach(tasks.prefix(5)) { (item: RelatedOpenTask) in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: item.task.description)
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(verbatim: "\(item.task.owner) · \(item.meetingTitle)")
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
            Button {
                onShowAll()
            } label: {
                HStack(spacing: 3) {
                    Text(tasks.count > 5 ? String(localized: "Tümünü gör (\(tasks.count))") : String(localized: "Tümünü gör"))
                    Image(systemName: "chevron.right").appFont(size: 10, weight: .semibold)
                }
                .appFont(size: 13, weight: .medium)
                .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// "Tümünü kopyala"dan sonra üstte kısa süre görünen "Kopyalandı".
private struct CopiedToast: View {
    var body: some View {
        Label("Kopyalandı", systemImage: "checkmark")
            .appFont(size: 13, weight: .semibold)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Mikrofonun durumu kayıt ekranında: kesinti (çağrı, alarm) ve yeniden bağlanma turuncu uyarıyla; ses geri gelince
/// birkaç saniye vurgu renginde "yeniden bağlandı". Kayıt her durumda açık kalır.
private struct MicrophoneNotice: View {
    let status: MicrophoneStatus
    let recoveredVisible: Bool
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        switch status {
        case .interrupted:
            notice(text: "Mikrofon kesildi (arama ya da alarm). Kesinti bitince kayıt kendiliğinden sürer.", systemImage: "mic.slash.fill", color: .orange)
        case .reconnecting:
            notice(text: "Mikrofon yeniden bağlanıyor… Kayıt açık; ses gelince kendiliğinden sürer.", systemImage: "arrow.triangle.2.circlepath", color: .orange)
        case .running:
            if recoveredVisible {
                notice(text: "Mikrofon yeniden bağlandı; kayıt sürüyor.", systemImage: "checkmark.circle.fill", color: appearance.accent.color)
                    .transition(.opacity)
            }
        }
    }

    private func notice(text: LocalizedStringKey, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .appFont(size: 14, weight: .medium)
            .foregroundStyle(color)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Kayıt noktası: kayıtta yavaşça yanıp söner, bitirilirken durgun.
private struct RecordingDot: View {
    let isFinishing: Bool
    @State private var isDim: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    var body: some View {
        // Sakin nefes (1,6 sn); hareketi azalt açıkken sabit.
        Circle()
            .fill(isFinishing ? Theme.muted : .red)
            .frame(width: 11, height: 11)
            .opacity(isDim && !reduceMotion ? 0.4 : 1)
            .animation(isFinishing || reduceMotion ? .default : .easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: isDim)
            .onAppear { isDim = true }
            .accessibilityHidden(true)
    }
}

/// Geniş ses dalgası: son seviyeler ortalanmış yuvarlak çubuklar (sessizde alçak).
private struct PhoneLevelBars: View {
    let levels: AudioLevels
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.values.enumerated()), id: \.offset) { (item: (offset: Int, element: Float)) in
                Capsule()
                    .fill(appearance.accent.color.opacity(0.35 + Double(item.element) * 0.65))
                    .frame(maxWidth: .infinity)
                    .frame(height: 4 + CGFloat(item.element) * 34)
            }
        }
        .frame(height: 40)
        .animation(.easeOut(duration: 0.12), value: levels.values)
        .accessibilityHidden(true)
    }
}

/// "Kaydettiğini katılımcılara söyle": kayıt başında üstte 3 saniye görünen bildirim (toplantının dilinde ve İngilizce
/// söylenecek cümleyle; `consentNoticeSentences`); dokununca hemen kapanır. Ayarlar'daki hatırlatma kapalıysa hiç
/// görünmez.
private struct ConsentToast: View {
    let language: MeetingLanguage
    let onDismiss: @MainActor () -> Void

    var body: some View {
        Button(action: onDismiss) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .appFont(size: 15, weight: .semibold)
                    .foregroundStyle(Color(red: 0.72, green: 0.52, blue: 0.32))
                    .frame(width: 34, height: 34)
                    .background(Color(red: 0.72, green: 0.52, blue: 0.32).opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Kaydettiğini katılımcılara söyle")
                        .appFont(size: 14, weight: .semibold)
                        .foregroundStyle(Theme.ink)
                    Text(verbatim: consentNoticeSentences(language: language).map { "\u{201C}\($0)\u{201D}" }.joined(separator: " · "))
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Kapat")
    }
}

/// Bir konuşmacının ardışık cümleleri (sohbet gibi): rozet, ad ve saat; özgün metin (geçici kısım soluk) ve not dilindeki
/// çevirisi. Mac panelindeki gibi: ada dokununca konuşmacı düzeltilir (bölümü başka kişiye ata, kişinin tümünü birleştir),
/// çevirisi alınamayan cümlede "Tekrar dene", uzun basınca "Kopyala".
struct LiveBlockView: View {
    let block: SpeakerBlock
    let translations: [SegmentID: String]
    /// Sabit toplantı dilinden başka dildeki bölümler: soluk ve eğik (çevrilmez, toplantıdan atlanır).
    let otherLanguage: Set<SegmentID>
    /// Bu bloğun çevirisi başarısız bölümleri.
    let failedTranslations: [SegmentID]
    /// Çeviri yeniden denenebilir (yalnız kayıt sürerken: sonra çevrilen cümle toplantıya yazılmaz).
    let canRetry: Bool
    /// Transkriptteki kişiler ve "Yeni konuşmacı"nın numarası (düzeltme menüsü).
    let persons: [Int]
    let newPersonNumber: Int
    let onRetry: @MainActor ([SegmentID]) -> Void
    let onReassign: @MainActor ([SegmentID], Int) -> Void
    let onMerge: @MainActor (Int, Int) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    /// Konuşmacıların bilinen adları (karşılamadaki örnek toplantı: Maya, Leo); yoksa "Konuşmacı N".
    @Environment(\.liveSpeakerNames) private var speakerNames: [Int: String]
    /// "Sadece çeviri" (Ayarlar › Toplantı › Gösterim): çevirisi gelen blokta orijinal gizlenir.
    @AppStorage(PhoneSettingsKey.displayMode) private var displayMode: String = DisplayMode.bilingual.rawValue

    private var mode: DisplayMode {
        DisplayMode(rawValue: displayMode) ?? .bilingual
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SpeakerBadge(speaker: block.speaker, person: block.person, size: 30)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    speakerName
                    Text(timestamp(seconds: block.startSec))
                        .appFont(size: 11, weight: .regular)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
                if mode == .turkishOnly {
                    // Yalnız çeviri: çevirisi henüz gelmeyen metin orijinal haliyle soluk (Mac'teki gibi).
                    if translation.isEmpty {
                        Text("\(finalText)\(Text(partialText))")
                            .readingText(size: 18, weight: .regular, lineSpacing: 5)
                            .foregroundStyle(Theme.muted)
                    } else {
                        Text(translation)
                            .readingText(size: 18, weight: .regular, lineSpacing: 5)
                            .foregroundStyle(Theme.ink)
                    }
                } else {
                    original
                }
                if canRetry, !failedTranslations.isEmpty, mode.needsLiveTranslation {
                    Button {
                        onRetry(failedTranslations)
                    } label: {
                        Label("Çeviri alınamadı · Tekrar dene", systemImage: "arrow.clockwise")
                            .appFont(size: 13, weight: .medium)
                            .foregroundStyle(NoticeSeverity.attention.tint)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("Kopyala", systemImage: "doc.on.doc") {
                copyToPasteboard(text: displayedPlainText(blocks: [block], translations: translations, displayMode: mode))
            }
        }
    }

    /// Konuşmacının adı; "Diğerleri" bloğunda dokununca düzeltme menüsü açılır (otomatik ayırma yanıldıysa).
    @ViewBuilder
    private var speakerName: some View {
        let name: some View = Text(block.person.flatMap { speakerNames[$0] } ?? speakerLabel(speaker: block.speaker, person: block.person))
            .appFont(size: 13, weight: .semibold)
            .foregroundStyle(block.person.map { personColor(person: $0) } ?? Theme.ink)
        if block.speaker == .others {
            Menu {
                SpeakerCorrectionMenu(block: block, persons: persons, newPersonNumber: newPersonNumber, onReassign: onReassign, onMerge: onMerge)
            } label: {
                HStack(spacing: 3) {
                    name
                    Image(systemName: "chevron.down")
                        .appFont(size: 8, weight: .bold)
                        .foregroundStyle(Theme.muted)
                }
                .contentShape(Rectangle())
            }
            .accessibilityHint("Konuşmacıyı düzelt")
        } else {
            name
        }
    }

    /// Orijinal metin ve altında (varsa) not dilindeki çevirisi.
    @ViewBuilder
    private var original: some View {
        Text("\(finalText)\(Text(partialText).foregroundStyle(Theme.muted))")
            .readingText(size: 18, weight: .regular, lineSpacing: 5)
            .foregroundStyle(Theme.ink)
        if !translation.isEmpty {
            Text(translation)
                .readingText(size: 15, weight: .regular, lineSpacing: 4)
                .foregroundStyle(Theme.muted)
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Capsule().fill(appearance.accent.color.opacity(0.35)).frame(width: 2)
                }
                .padding(.top, 2)
        }
    }

    /// Kesin bölümler; başka dildeki bölüm soluk ve eğik.
    private var finalText: Text {
        block.segments.filter(\.isFinal).enumerated().reduce(Text(verbatim: "")) { (combined: Text, item: (offset: Int, element: LiveSegment)) -> Text in
            let piece: Text = Text(verbatim: (item.offset == 0 ? "" : " ") + item.element.text)
            let styled: Text = otherLanguage.contains(item.element.id) ? piece.italic().foregroundStyle(Theme.muted) : piece
            return Text("\(combined)\(styled)")
        }
    }

    private var partialText: String {
        let partial: String = block.segments.filter { !$0.isFinal }.map(\.text).joined(separator: " ")
        return !block.segments.contains(where: \.isFinal) || partial.isEmpty ? partial : " " + partial
    }

    /// Bloğun çevirisi; kapsanan bölümlerin boş çevirisi atlanır (çevirileri birimin son bölümünde).
    private var translation: String {
        blockTurkishText(block: block, translations: translations) ?? ""
    }
}

/// Toplantı hazırlanıyor: hazırlık katmanıyla aynı adımlar (biten ✓, süren gösterge, bekleyen soluk) ve ilerleme
/// çubuğu; kayıt bitmiş olduğundan ilk adım hep tamamdır.
struct PreparingCard: View {
    let step: ProcessingStep
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    private let titles: [LocalizedStringKey] = phoneProcessingStepTitles

    /// Gösterilen adım: işleme adımları kayıt bitirme adımından sonra gelir.
    private var stepIndex: Int {
        step.rawValue + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Toplantı hazırlanıyor")
                    .appFont(size: 16, weight: .semibold)
                Spacer()
                Text(verbatim: "\(stepIndex + 1)/\(titles.count)")
                    .appFont(size: 12, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            ProgressView(value: Double(stepIndex) + 0.5, total: Double(titles.count))
                .tint(appearance.accent.color)
            ForEach(Array(titles.enumerated()), id: \.offset) { (item: (offset: Int, element: LocalizedStringKey)) in
                HStack(spacing: 10) {
                    Group {
                        if item.offset < stepIndex {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        } else if item.offset == stepIndex {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(item.element)
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(item.offset > stepIndex ? Theme.muted : Theme.ink)
                }
            }
            Text("Not hazır olunca ana ekranda görünür. Uygulamayı kapatırsan hazırlık sonraki açılışta sürer.")
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line))
    }
}


/// Kayıt sırasında "Notlarım": kendi notların (madde, başlık); not bunları öncelik sayıp transkriptten tamamlar.
private struct PhoneMyNotesSheet: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Notlarım", systemImage: "square.and.pencil")
                    .appFont(size: 17, weight: .semibold)
                Text("Önemli gördüğünü yaz; toplantı notu bunlara öncelik verir.")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextEditor(text: $text)
                .readingText(size: 16, weight: .regular, lineSpacing: 3)
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .padding(10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
        }
        .padding(20)
        .background(Theme.background)
        .onAppear { isFocused = true }
    }
}
