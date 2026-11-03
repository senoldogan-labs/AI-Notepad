import AINotepadCore
import AINotepadUI
import SwiftUI

/// Kayıt sekmesi: boştayken tarih, büyük başlık, durağan pastel film gradyanlı kayıt kartı, görevler ve son toplantılar; kayıtta
/// odaklı tam ekran (sekme çubuğu gizli): süre, ses dalgası, konuşmacılı canlı metin ve not dilindeki çevirisi, "İşaretle"
/// ve "Bitir"; bitince hazırlanma adımları.
struct RecordTab: View {
    let recorder: PhoneRecorder
    let store: PhoneStore
    let router: PhoneRouter
    let calendar: PhoneCalendar
    /// Sıradaki toplantının brifingini Sor'da açar.
    let onBriefing: @MainActor (CalendarMeeting) -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch recorder.phase {
                case .idle, .starting:
                    RecordHome(recorder: recorder, store: store, router: router, calendar: calendar, onBriefing: onBriefing)
                case .recording, .finishing:
                    LiveRecordingView(recorder: recorder)
                }
            }
            .background(Theme.background)
            .animation(.smooth(duration: 0.35), value: recorder.phase == .recording || recorder.phase == .finishing)
            // Bitirilirken ve biten toplantı işlenirken ekran durağan bulanıklaşır, ortada hazırlık kartı (Mac'teki gibi).
            .modifier(PhoneProcessingOverlayHost(recorder: recorder, store: store, router: router))
        }
    }
}

/// Kayıt öncesi ana ekran.
private struct RecordHome: View {
    let recorder: PhoneRecorder
    let store: PhoneStore
    let router: PhoneRouter
    let calendar: PhoneCalendar
    let onBriefing: @MainActor (CalendarMeeting) -> Void

    var body: some View {
        let openTasks: [(record: MeetingRecord, task: NoteTask)] = myTasks(meetings: store.meetings).filter { !isTaskDone(record: $0.record, task: $0.task) }
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(interfaceUppercased(text: longDayTitle(date: Date(), locale: interfaceLocale())))
                        .appFont(size: 12, weight: .semibold)
                        .tracking(DesignTokens.labelTracking)
                        .foregroundStyle(Theme.muted)
                    Text("Bugün hangi toplantıyı dinleyelim?")
                        .appFont(size: 30, weight: .regular)
                        .tracking(-0.8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
                RecordHeroCard(recorder: recorder)
                PhonePlanNotice(account: HostedAccount.shared)
                PhoneUsageNotice(account: HostedAccount.shared)
                // Sunucunun "deneme bitti" gibi reddi abone olunca artık geçerli değil (Mac'teki `resolvedErrorMessages`).
                PhoneErrorList(messages: phoneUnresolvedErrors(messages: recorder.errorMessages, account: HostedAccount.shared))
                if let id = recorder.lastMeetingID, let step = recorder.processingSteps[id] {
                    PreparingCard(step: step)
                }
                UpcomingCalendarSection(calendar: calendar, router: router, canBrief: !store.meetings.isEmpty, onBriefing: onBriefing)
                if !openTasks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        PhoneSectionHeader(title: "Sana düşen görevler", actionTitle: "Tümü") { router.tab = .tasks }
                        // Görev anahtarı toplantılar arasında yinelenebilir: kimlik toplantıyla birlikte.
                        ForEach(openTasks.prefix(3).map { (item: (record: MeetingRecord, task: NoteTask)) -> (key: String, record: MeetingRecord, task: NoteTask) in
                            (key: "\(item.record.id)|\(item.task.trackingKey)", record: item.record, task: item.task)
                        }, id: \.key) { (item: (key: String, record: MeetingRecord, task: NoteTask)) in
                            PhoneTaskRow(record: item.record, task: item.task, showsMeeting: true) {
                                withAnimation(.smooth(duration: 0.25)) { store.toggleTask(meetingID: item.record.id, task: item.task) }
                            }
                        }
                    }
                }
                if !store.meetings.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        PhoneSectionHeader(title: "Son toplantılar", actionTitle: "Tümünü gör") { router.tab = .meetings }
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 12) {
                                ForEach(store.meetings.prefix(6), id: \.id) { (record: MeetingRecord) in
                                    Button {
                                        router.open(meetingID: record.id)
                                    } label: {
                                        PhoneMeetingCard(record: record, height: 150)
                                            .frame(width: 250)
                                    }
                                    .buttonStyle(PressableCardStyle())
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.viewAligned)
                        .scrollIndicators(.hidden)
                        .contentMargins(.horizontal, 20, for: .scrollContent)
                        .padding(.horizontal, -20)
                    }
                } else {
                    // Henüz toplantı yok: boş alan yerine nasıl çalıştığı, takvim ve ipuçları.
                    RecordHomeGuide(calendar: calendar)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .toolbar(.hidden, for: .navigationBar)
    }
}

/// "Salı, 27 Ekim": dilin kendi gün ve ay adlarıyla (bölge biçimi ayı sayıya çevirmesin). Saf fonksiyondur.
func longDayTitle(date: Date, locale: Locale) -> String {
    let formatter: DateFormatter = DateFormatter()
    // Yalnız dil: bölge (ör. Finlandiya) biçimi ayı sayıya çeviriyordu ("Salı 27.10.").
    formatter.locale = Locale(identifier: locale.language.languageCode?.identifier ?? "tr")
    formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
    return formatter.string(from: date)
}

/// Kayıt kartının altında hesabın durumu: kaydı engelleyen hak durumu varsa nedeni (deneme bitti, aylık sınır…) ve
/// abonelik çözecekse (deneme bitti, plan sona erdi) "Abone ol" (abonelik ekranı); yoksa denemede kalan toplantılar.
/// Abonelikte ve hak durumu okunmamışken görünmez.
private struct PhonePlanNotice: View {
    let account: HostedAccount

    var body: some View {
        if let blocked = phoneStartBlockMessage(account: account, now: Date()) {
            VStack(alignment: .leading, spacing: 10) {
                NoticeText(blocked as String, severity: .attention)
                    .appFont(size: 13, weight: .regular)
                if account.requiresSubscription {
                    Button {
                        account.showPlans()
                    } label: {
                        Text("Abone ol")
                            .appFont(size: 15, weight: .semibold)
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(.tint, in: Capsule())
                    }
                    .buttonStyle(PressableCardStyle())
                }
            }
        } else if case .signedIn(let entitlements) = account.state, case .trial(let left, _) = hostedPlanStatus(entitlements: entitlements) {
            Label(String(localized: "Ücretsiz deneme: \(hostedTrialLeftText(left: left))."), systemImage: "sparkles")
                .appFont(size: 13, weight: .medium)
                .foregroundStyle(Theme.muted)
        }
    }
}

/// Mac'teki kullanım bildiriminin iPhone karşılığı: aylık sınırın %80'i ve son deneme toplantısı (dönem başına bir kez,
/// kapatılır; bkz. `HostedAccount.visibleNotice`). Sınır dolduysa ya da deneme bittiyse neden zaten `PhonePlanNotice`'te
/// yazar.
private struct PhoneUsageNotice: View {
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

/// Kayıt kartı: durağan açık pastel film gradyanı üstünde dil seçimi, büyük kayıt düğmesi (sabit hale) ve kısa açıklama.
/// Gradyan açık tonlu olduğundan yazılar koyu mürekkeptir (Mac'teki kayıt kartı gibi).
private struct RecordHeroCard: View {
    let recorder: PhoneRecorder
    /// Not ve çeviri dili (Ayarlar): canlı çevirinin dili adıyla geçer.
    @AppStorage(PhoneSettingsKey.noteLanguage) private var noteLanguage: String = defaultNoteLanguage(interfaceLanguages: Bundle.main.preferredLocalizations).rawValue
    /// Canlı çeviri kapalıysa açıklama onu anmaz.
    @AppStorage(PhoneSettingsKey.displayMode) private var displayMode: String = DisplayMode.bilingual.rawValue

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Menu {
                    Button("Otomatik") { recorder.languageMode = .automatic }
                    LanguageMenuItems { (language: MeetingLanguage) -> Void in recorder.setLanguage(language: language) }
                } label: {
                    HStack(spacing: 5) {
                        Text(languageText(locked: nil, mode: recorder.languageMode, isRecording: false))
                        Image(systemName: "chevron.down").appFont(size: 10, weight: .bold)
                    }
                    .appFont(size: 13, weight: .semibold)
                    .foregroundStyle(Color.black.opacity(0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.9), in: Capsule())
                }
                Spacer()
                PastelChip(text: String(localized: "Yüz yüze"), systemImage: "person.2.fill")
            }
            Button {
                Task { await recorder.start() }
            } label: {
                ZStack {
                    RecordButtonHalo()
                    Circle()
                        .fill(.white)
                        .frame(width: 104, height: 104)
                        .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
                    if recorder.phase == .starting {
                        ProgressView().controlSize(.large).tint(.black)
                    } else {
                        Image(systemName: "mic.fill")
                            .appFont(size: 38, weight: .medium)
                            .foregroundStyle(Color(red: 0.91, green: 0.36, blue: 0.11))
                    }
                }
                .frame(width: 150, height: 150)
                .contentShape(Circle())
            }
            .buttonStyle(PressableCardStyle())
            .disabled(recorder.phase == .starting)
            .accessibilityLabel("Kaydı başlat")
            VStack(spacing: 4) {
                Text(startTitle)
                    .appFont(size: 20, weight: .semibold)
                    .tracking(-0.3)
                    .foregroundStyle(Color.black.opacity(0.8))
                Group {
                    if (DisplayMode(rawValue: displayMode) ?? .bilingual).needsLiveTranslation {
                        Text("Odadaki herkes konuşmacılara ayrılır, \(phoneStoredNoteLanguage(value: noteLanguage).interfaceName) çevirisi canlı akar; bitince notu yazar.")
                    } else {
                        Text("Odadaki herkes konuşmacılara ayrılır; bitince \(phoneStoredNoteLanguage(value: noteLanguage).interfaceName) notu yazar.")
                    }
                }
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Color.black.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background { FilmGradient(seed: "kayit", palette: .sunset) }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(.white.opacity(0.10)))
        // Açık gradyan her temada açık görünümle çizilir (koyu temada menü ve gösterge de koyu mürekkeple kalsın).
        .environment(\.colorScheme, .light)
    }

    /// Düğmenin altındaki başlık: başlarken (cihaz içi konuşma modeli iniyorsa ilerlemesiyle) ya da davet.
    private var startTitle: String {
        guard recorder.phase == .starting else {
            return String(localized: "Dokun, dinlemeye başlasın")
        }
        return recorder.speechModelProgress.map { (fraction: Double) -> String in
            String(localized: "Konuşma modeli indiriliyor… \(fraction.formatted(.percent.precision(.fractionLength(0))))")
        } ?? String(localized: "Başlatılıyor…")
    }
}

/// Kayıt düğmesinin çevresindeki durağan beyaz hale. Hareketsizdir: boştayken saniyede 30 kez yeniden çizim pil
/// tüketiyordu.
private struct RecordButtonHalo: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.14))
                .frame(width: 137, height: 137)
            Circle()
                .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                .frame(width: 145, height: 145)
        }
        .accessibilityHidden(true)
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

/// Kayıt sırasında odaklı tam ekran (sekme çubuğu gizli): üstte sabit başlık (kayıt durumu, dil, büyük süre ve ses
/// dalgası), ortada konuşmacılı canlı metin (en alta kayar), altta yüzen çubukta "Ne kaçırdım?", "İşaretle", "Bitir" ve
/// "Notlarım". "Ne kaçırdım?" çubuğun üstünde asistan kartını açar; kartın altındaki alanla toplantıya soru sorulur (Mac
/// panelindeki gibi). Rıza hatırlatması kayıt başında üstte 3 saniye görünen bir bildirimdir.
private struct LiveRecordingView: View {
    let recorder: PhoneRecorder
    @State private var markedAt: Date?
    @State private var isNotesOpen: Bool = false
    /// Asistana sorulacak soru (kart açıkken).
    @State private var question: String = ""

    private var blocks: [SpeakerBlock] {
        groupBySpeaker(transcript: recorder.transcript.filter { !$0.text.isEmpty })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 10) {
                MicrophoneNotice(status: recorder.microphoneStatus, recoveredVisible: recorder.microphoneRecoveredNoticeVisible)
                PhoneErrorList(messages: recorder.errorMessages)
            }
            .padding(.horizontal, 20)
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
                }
                controls
            }
            .animation(.smooth(duration: 0.3), value: recorder.assistantCard != nil)
        }
        .overlay(alignment: .top) {
            if recorder.consentReminderVisible {
                ConsentToast { recorder.consentReminderVisible = false }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.smooth(duration: 0.35), value: recorder.consentReminderVisible)
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
        .sheet(isPresented: $isNotesOpen) {
            PhoneMyNotesSheet(text: Binding<String>(get: { recorder.myNotes }, set: { (text: String) -> Void in recorder.myNotes = text }))
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private let bottomID: String = "son"

    /// Sabit başlık: solda kayıt durumu, sağda dil; ortada büyük süre, altında ses dalgası ve işaretlenen an sayısı.
    private var header: some View {
        VStack(spacing: 18) {
            HStack {
                RecordingStatusPill(isFinishing: recorder.phase == .finishing)
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
            }
            VStack(spacing: 12) {
                if let startedAt = recorder.startedAt {
                    ElapsedClock(startedAt: startedAt, stoppedAt: recorder.stoppedAt)
                }
                PhoneLevelBars(levels: recorder.levels)
                    .frame(maxWidth: 280)
                Text(recorder.highlights.isEmpty ? "" : String(localized: "\(recorder.highlights.count) an işaretlendi"))
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

    /// Henüz metin yok: kalan alanın ortasında sakin bir "Dinliyor" durumu.
    private var listening: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .appFont(size: 26, weight: .regular)
                .foregroundStyle(Theme.muted)
                .symbolEffect(.variableColor.iterative, options: .repeating)
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
                    ForEach(blocks) { (block: SpeakerBlock) in
                        LiveBlockView(block: block, translations: recorder.translations, otherLanguage: recorder.otherLanguageSegments)
                            .transition(.opacity.combined(with: .offset(y: 8)))
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
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
            .onChange(of: recorder.transcript) {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(bottomID, anchor: .bottom) }
            }
        }
    }

    /// Asistan kartı ve altında toplantıya soru alanı; kartın "x"i ikisini de kapatır.
    private func assistant(card: AssistantCard) -> some View {
        VStack(spacing: 8) {
            AssistantCardView(card: card) {
                question = ""
                recorder.closeAssistantCard()
            }
            HStack(spacing: 8) {
                TextField("Toplantıya sor…", text: $question)
                    .appFont(size: 15, weight: .regular)
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
        .padding(.horizontal, 16)
    }

    private func sendQuestion() {
        recorder.askDuringMeeting(question: question)
        question = ""
    }

    /// Yüzen eylem çubuğu: solda "Ne kaçırdım?" ve "İşaretle", ortada geniş "Bitir", sağda "Notlarım"; bitirilirken
    /// yalnız durum.
    private var controls: some View {
        HStack(spacing: 14) {
            if recorder.phase == .finishing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Bitiriliyor… Son cümleler ve konuşmacılar tamamlanıyor.")
                        .appFont(size: 14, weight: .medium)
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Button {
                    recorder.askWhatIMissed()
                } label: {
                    RecordingControlIcon(systemImage: "sparkles")
                }
                .buttonStyle(PressableCardStyle())
                .disabled(blocks.isEmpty)
                .accessibilityLabel("Ne kaçırdım?")
                .accessibilityHint("Son dakikaların özetini gösterir; toplantıya soru da sorabilirsin")
                Button {
                    recorder.markMoment()
                    markedAt = Date()
                } label: {
                    RecordingControlIcon(systemImage: markedAt.map { Date().timeIntervalSince($0) < 2 } == true ? "bookmark.fill" : "bookmark")
                }
                .buttonStyle(PressableCardStyle())
                .accessibilityLabel("Bu anı işaretle")
                .sensoryFeedback(.impact(weight: .light), trigger: recorder.highlights.count)
                Button {
                    recorder.stop()
                } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color(red: 0.93, green: 0.27, blue: 0.23))
                            .frame(width: 13, height: 13)
                        Text("Bitir")
                            .appFont(size: 17, weight: .semibold)
                    }
                    .foregroundStyle(Theme.onPrimary)
                    .frame(maxWidth: .infinity, minHeight: 60)
                    .background(Theme.primary, in: Capsule())
                }
                .buttonStyle(PressableCardStyle())
                .accessibilityLabel("Kaydı bitir")
                .sensoryFeedback(.success, trigger: recorder.phase)
                Button {
                    isNotesOpen = true
                } label: {
                    RecordingControlIcon(systemImage: recorder.myNotes.isEmpty ? "square.and.pencil" : "square.and.pencil.circle.fill")
                }
                .buttonStyle(PressableCardStyle())
                .accessibilityLabel("Notlarım")
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

/// Kayıt çubuğundaki yuvarlak simge düğmesi (İşaretle, Notlarım): kullanıcının vurgu renginde.
private struct RecordingControlIcon: View {
    let systemImage: String
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        Image(systemName: systemImage)
            .appFont(size: 19, weight: .medium)
            .foregroundStyle(appearance.accent.color)
            .frame(width: 60, height: 60)
            .background(appearance.accent.color.opacity(0.12), in: Circle())
            .contentTransition(.symbolEffect(.replace))
    }
}

/// Kayıt durumu hapı: kayıtta yavaşça nefes alan kırmızı nokta ve "Kaydediliyor"; bitirilirken durgun nokta ve
/// "Bitiriliyor".
private struct RecordingStatusPill: View {
    let isFinishing: Bool

    var body: some View {
        HStack(spacing: 7) {
            RecordingDot(isFinishing: isFinishing)
            Text(isFinishing ? "Bitiriliyor" : "Kaydediliyor")
                .appFont(size: 13, weight: .semibold)
                .foregroundStyle(isFinishing ? Theme.muted : Theme.ink)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isFinishing ? AnyShapeStyle(Theme.soft) : AnyShapeStyle(Color.red.opacity(0.10)), in: Capsule())
    }
}

/// Kaydın süresi: kayıtta saniyede bir ilerler; "Bitir"e basılınca o anda durur (bitirme sürerken saymaz).
private struct ElapsedClock: View {
    let startedAt: Date
    let stoppedAt: Date?

    var body: some View {
        if let stoppedAt {
            clockText(seconds: recordingElapsedSec(startedAt: startedAt, stoppedAt: stoppedAt, now: stoppedAt))
        } else {
            TimelineView(.periodic(from: startedAt, by: 1)) { (context: TimelineViewDefaultContext) in
                clockText(seconds: recordingElapsedSec(startedAt: startedAt, stoppedAt: nil, now: context.date))
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

/// "Kaydettiğini katılımcılara söyle": kayıt başında üstte 3 saniye görünen bildirim (Fince ve İngilizce söylenecek
/// cümleyle); dokununca hemen kapanır. Ayarlar'daki hatırlatma kapalıysa hiç görünmez.
private struct ConsentToast: View {
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
                    Text(verbatim: "„Nauhoitan tämän palaverin muistiinpanoja varten.“ · “I'm recording this meeting for my notes.”")
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
/// çevirisi.
private struct LiveBlockView: View {
    let block: SpeakerBlock
    let translations: [SegmentID: String]
    /// Sabit toplantı dilinden başka dildeki bölümler: soluk ve eğik (çevrilmez, toplantıdan atlanır).
    let otherLanguage: Set<SegmentID>
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    /// "Sadece çeviri" (Ayarlar › Toplantı › Gösterim): çevirisi gelen blokta orijinal gizlenir.
    @AppStorage(PhoneSettingsKey.displayMode) private var displayMode: String = DisplayMode.bilingual.rawValue

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SpeakerBadge(speaker: block.speaker, person: block.person, size: 30)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(speakerLabel(speaker: block.speaker, person: block.person))
                        .appFont(size: 13, weight: .semibold)
                        .foregroundStyle(block.person.map { personColor(person: $0) } ?? Theme.ink)
                    Text(timestamp(seconds: block.startSec))
                        .appFont(size: 11, weight: .regular)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                }
                if DisplayMode(rawValue: displayMode) == .turkishOnly {
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// Toplantı hazırlanıyor: adımlar (biten ✓, süren gösterge, bekleyen soluk) ve ilerleme çubuğu.
private struct PreparingCard: View {
    let step: ProcessingStep
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    private let titles: [LocalizedStringKey] = ["Ses kaydı hazırlanıyor", "Kaydın tamamı işleniyor", "Not hazırlanıyor"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Toplantı hazırlanıyor")
                    .appFont(size: 16, weight: .semibold)
                Spacer()
                Text(verbatim: "\(step.rawValue + 1)/\(titles.count)")
                    .appFont(size: 12, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            ProgressView(value: Double(step.rawValue) + 0.5, total: Double(titles.count))
                .tint(appearance.accent.color)
            ForEach(Array(titles.enumerated()), id: \.offset) { (item: (offset: Int, element: LocalizedStringKey)) in
                HStack(spacing: 10) {
                    Group {
                        if item.offset < step.rawValue {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        } else if item.offset == step.rawValue {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(item.element)
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(item.offset > step.rawValue ? Theme.muted : Theme.ink)
                }
            }
            Text("Not hazır olunca Toplantılar'da görünür. Uygulamayı kapatırsan hazırlık sonraki açılışta sürer.")
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
            Label("Notlarım", systemImage: "square.and.pencil")
                .appFont(size: 17, weight: .semibold)
            Text("Önemli gördüğünü kısaca yaz; toplantı bitince not bunları öncelik sayar, gerisini transkriptten tamamlar.")
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
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
