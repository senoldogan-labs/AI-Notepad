import AINotepadCore
import AINotepadUI
import SwiftUI

/// Ana ekran (sekme çubuğu yok): solda kitaplık, sağda görevler, arama ve profil; büyük "Bugün" başlığı ve günün takvim
/// toplantıları; gerektiğinde hesap, kullanım ve hata bildirimleri; sana düşen açık görevler; güne göre gruplu geçmiş
/// toplantılar (henüz yoksa nasıl çalıştığı). Kayıt seçenekleri (dil, canlı çeviri, içe aktarma) başlıktaki günün
/// altında küçük menü; altta yüzen çubukta yalnız "Bir şey sor" ve büyük kayıt düğmesi.
struct PhoneHome: View {
    let recorder: PhoneRecorder
    let store: PhoneStore
    @Bindable var router: PhoneRouter
    let calendar: PhoneCalendar
    let player: MeetingAudioPlayer
    let account: HostedAccount
    let onBriefing: @MainActor (CalendarMeeting) -> Void
    /// Ana ekrandan açılan sayfa (toplantı, görevler, arama, Sor, Ayarlar…): tek sütunda gezinme yığınının üstüne açılır,
    /// geniş ekranda (açılmış iPhone Duo) yandaki içerik sütununun yerini alır (bkz. `RootView`).
    let navigate: @MainActor (PhoneRoute) -> Void
    /// Geniş ekranda yandaki sütunda açık toplantı: satırı vurgulanır (tek sütunda nil).
    let selectedMeetingID: String?
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    @Environment(PhoneImportState.self) private var imports: PhoneImportState
    /// Uzun basınca silme onayı bekleyen toplantı.
    @State private var pendingDelete: MeetingRecord?
    /// Silme ve klasöre taşıma hataları.
    @State private var libraryErrors: [String] = []
    /// Kitaplık sayfasında seçilen ve sayfa kapanınca yapılacak iş (sayfa kapanırken yeni sunum başlatılmaz).
    @State private var pendingLibraryAction: PhoneLibraryAction?
    /// Yeni klasörün adı soruluyor: boş klasör (kitaplık) ya da toplantıyı taşımak için (uzun basma menüsü).
    @State private var newFolderRequest: HomeNewFolderRequest?

    var body: some View {
        let userName: String = store.userName
        // Satırlar konuşmacı adlarıyla (saklı not genel etiketleri korur).
        let meetings: [MeetingRecord] = store.namedMeetings()
        let sections: [MeetingSection] = meetingSections(records: meetings, now: Date(), calendar: .current, locale: interfaceLocale())
        // Aciliyet sırasıyla: önce gecikmiş ve bugünün görevleri, sonra yaklaşanlar.
        let openItems: [DatedTask] = openTasksByUrgency(items: myTasks(meetings: store.meetings, userName: userName), now: Date(), calendar: Calendar.current)
        let openTasks: Int = openItems.count
        let locked: Set<String> = phoneLockedMeetingIDs(store: store, recorder: recorder)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                todayHeader
                notices
                HomeTodaySection(calendar: calendar, router: router, hasMeetings: !meetings.isEmpty, onBriefing: onBriefing)
                // Önem sırası (Mac'teki ana sayfa gibi): günün toplantıları, sana düşen görevler, sonra geçmiş notlar.
                if !openItems.isEmpty {
                    HomeTasksSection(items: Array(openItems.prefix(3)), total: openTasks, store: store) { navigate(.tasks) }
                }
                if meetings.isEmpty {
                    // Henüz toplantı yok: boş alan yerine nasıl çalıştığı, takvim ve ipuçları.
                    RecordHomeGuide(calendar: calendar, store: store)
                } else {
                    Rectangle().fill(Theme.line).frame(height: 1)
                    ForEach(sections) { (section: MeetingSection) in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                                .appFont(size: 14, weight: .medium)
                                .foregroundStyle(Theme.muted)
                                .padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section.meetings, id: \.id) { (record: MeetingRecord) in
                                row(record: record, isLocked: locked.contains(record.id))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .refreshable { await store.reloadAndWait() }
        .background(Theme.background)
        // Çalan toplantı yüzen çubuğun üstünde (iç kenar boşluğu dıştakinin üstüne konur).
        .modifier(PhoneMiniPlayerInset(player: player, store: store, router: router, isHidden: false))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HomeBottomBar(recorder: recorder, account: account) { navigate(.ask) }
        }
        .toolbar { toolbarContent(openTasks: openTasks) }
        .sheet(isPresented: $router.isLibraryOpen, onDismiss: performPendingLibraryAction) {
            PhoneLibrarySheet(store: store) { (action: PhoneLibraryAction) -> Void in
                pendingLibraryAction = action
                router.isLibraryOpen = false
            }
        }
        .sheet(item: $newFolderRequest) { (request: HomeNewFolderRequest) in
            PhoneTextEntrySheet(title: "Yeni klasör", placeholder: "Klasör adı", actionTitle: request.actionTitle, initialText: "") { (name: String) -> Void in
                createFolder(name: name, request: request)
            }
        }
        .modifier(MeetingDeleteConfirmation(pending: $pendingDelete) { (record: MeetingRecord) -> Void in
            withAnimation(.snappy(duration: 0.3)) {
                libraryErrors = phoneTrashMeetings(ids: [record.id], store: store, recorder: recorder, player: player, router: router)
            }
        })
        // Kayıttan önce boş yer (kayıt bitince ve ana ekrana dönünce yeniden okunur).
        .task { recorder.refreshRecordingDiskSpace() }
    }

    /// Büyük "Bugün", altında günün adı ve kayıt seçenekleri.
    private var todayHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bugün")
                .appFont(size: 36, weight: .regular)
                .tracking(-0.9)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: longDayTitle(date: Date(), locale: interfaceLocale()))
                .appFont(size: 15, weight: .regular)
                .foregroundStyle(Theme.muted)
            HomeRecordOptionsChip(recorder: recorder)
                .padding(.top, 8)
        }
        .padding(.top, 8)
    }

    /// Yalnız gerektiğinde görünen bildirimler: kaydı engelleyen hak durumu (çözüm düğmesiyle), kullanım, boş yer, silinen
    /// hesaptan kalan toplantılar, hatalar, içe aktarma ve hazırlanan toplantı.
    @ViewBuilder
    private var notices: some View {
        let recordingErrors: [String] = phoneUnresolvedErrors(messages: recorder.errorMessages, account: account)
        let errors: [String] = store.loadProblems + libraryErrors + [imports.pickError].compactMap { $0 }
        PhonePlanNotice(account: account, router: router)
        if let diskSpace = phoneDiskSpaceText(space: recorder.recordingDiskSpace) {
            NoticeText(diskSpace, severity: .attention)
                .appFont(size: 13, weight: .regular)
        }
        PhoneUsageNotice(account: account)
        PhoneUpsellCard(account: account)
        PhoneDeletedMeetingsCard(deleted: .shared, store: store)
        // Sunucunun "deneme bitti" gibi reddi abone olunca artık geçerli değil (Mac'teki `resolvedErrorMessages`).
        PhoneErrorList(messages: errors)
        // İçe aktarma hataları (görüşme kaydınınki dahil) kullanıcı kapatana ya da aynı kaynaktan yeni içe aktarmaya dek.
        PhoneDismissibleErrorList(messages: recorder.importErrors) { recorder.dismissImportErrors() }
        // Kaydın hataları kapatılabilir (not hazır olunca kendiliğinden de kalkar); mikrofon izni yoksa Ayarlar'a götürür.
        PhoneDismissibleErrorList(messages: recordingErrors) { recorder.dismissErrors() }
        if recordingErrors.contains(microphonePermissionDeniedText()) {
            Button("Ayarları aç", systemImage: "gearshape") {
                openPhoneSettings(urlString: UIApplication.openSettingsURLString)
            }
            .buttonStyle(.accentPill)
        }
        // Bu iPhone'daki görüşme mikrofonu tutuyor: görüşme rehberi (iPhone'un arama kaydı, Mac) açılır.
        if recordingErrors.contains(microphoneHeldByCallText()) {
            Button("Görüşmeleri kaydetmenin yolları", systemImage: "phone") {
                imports.request = .phoneCall
            }
            .buttonStyle(.accentPill)
        }
        PhoneDismissibleErrorList(messages: store.actionProblems) { store.dismissActionProblems() }
        if recorder.importingCount > 0 || imports.isLoadingVideos {
            ImportProgressRow()
        }
        if let id = recorder.lastMeetingID, let step = recorder.processingSteps[id] {
            PreparingCard(step: step)
        }
    }

    /// Geçmiş toplantı satırı: dokununca toplantı açılır; uzun basınca Markdown kopyası, bekleyen kaydı deneme, klasöre
    /// taşıma ve silme (kitaplıktaki kart menüsü gibi).
    private func row(record: MeetingRecord, isLocked: Bool) -> some View {
        Button {
            navigate(.meeting(record.id))
        } label: {
            HomeMeetingRow(record: record)
                .padding(.horizontal, 8)
                .background(
                    record.id == selectedMeetingID ? appearance.accent.softFill(tintOpacity: 0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .padding(.horizontal, -8)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(record.id == selectedMeetingID ? .isSelected : [])
        .contextMenu {
            Button("Markdown olarak kopyala", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = meetingMarkdown(record: record)
                recordFeatureUsage(feature: .export(.copyMarkdown))
            }
            if record.status == .queued {
                Button("Şimdi dene", systemImage: "arrow.clockwise") {
                    Task { await recorder.retryQueuedNow(meetingID: record.id) }
                }
                .disabled(recorder.phase != .idle || recorder.isRunningQueue)
            }
            Menu("Klasöre taşı", systemImage: "folder") {
                ForEach(store.folders) { (folder: FolderSummary) in
                    Button(folder.name, systemImage: "folder") { move(ids: [record.id], folder: folder.name) }
                }
                Button("Yeni klasör…", systemImage: "folder.badge.plus") { newFolderRequest = .move(record.id) }
                if record.folder != nil {
                    Button("Klasörden çıkar", systemImage: "folder.badge.minus") { move(ids: [record.id], folder: nil) }
                }
            }
            .disabled(isLocked)
            Divider()
            Button("Sil", systemImage: "trash", role: .destructive) { pendingDelete = record }
                .disabled(isLocked)
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent(openTasks: Int) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Kitaplık", systemImage: "folder") { router.isLibraryOpen = true }
                .tint(Theme.ink)
        }
        // Sağdaki üç düğme tek cam kapsülde (iOS 26; iOS 18–25 ayrı simgeler): görevler (VoiceOver açık görev sayısını okur), arama ve profil
        // (Ayarlar).
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                navigate(.tasks)
            } label: {
                Label("Görevlerim", systemImage: "checklist")
            }
            .tint(Theme.ink)
            .accessibilityValue(openTasks > 0 ? Text("\(openTasks) açık görev") : Text(verbatim: ""))
            Button("Ara", systemImage: "magnifyingglass") { navigate(.search) }
                .tint(Theme.ink)
            Button {
                navigate(.settings)
            } label: {
                ProfileAvatar(imageURL: account.avatarURL, initial: accountAvatarInitial(userName: store.userName, email: account.signedInIdentity?.email), size: 28)
            }
            .accessibilityLabel(Text("Ayarlar"))
        }
    }

    /// Kitaplık sayfası kapanınca seçilen iş: sayfayı açar, içe aktarma seçicisini ya da yeni klasör adını sorar.
    private func performPendingLibraryAction() {
        guard let action = pendingLibraryAction else {
            return
        }
        pendingLibraryAction = nil
        switch action {
        case .route(let route):
            navigate(route)
        case .importFrom(let source):
            imports.request = source
        case .createFolder:
            newFolderRequest = .create
        }
    }

    /// Toplantıları klasöre taşır (nil: klasörden çıkarır); hatalar bildirimlerde görünür.
    private func move(ids: Set<String>, folder: String?) {
        libraryErrors = store.moveMeetings(ids: ids, to: folder, locked: phoneLockedMeetingIDs(store: store, recorder: recorder))
    }

    /// Yeni klasör: boş olarak oluşturulur; bir toplantı için açıldıysa o da oraya taşınır.
    private func createFolder(name: String, request: HomeNewFolderRequest) {
        store.createFolder(name: name)
        if case .move(let id) = request {
            move(ids: [id], folder: name)
        }
    }
}

/// Ana ekranda yeni klasör adının sorulma nedeni: boş klasör ya da toplantıyı yeni klasöre taşımak.
private enum HomeNewFolderRequest: Identifiable {
    case create
    case move(String)

    var id: String {
        switch self {
        case .create: "create"
        case .move(let id): "move.\(id)"
        }
    }

    var actionTitle: LocalizedStringKey {
        switch self {
        case .create: "Oluştur"
        case .move: "Taşı"
        }
    }
}

/// "Bugün"ün altı: takvim açıksa sıradaki ve bugün biten toplantılar (Katıl, Brifing, notu aç), yoksa sakin "Bugün başka
/// toplantı yok"; takvim kapalıysa (toplantı varken; yokken rehberde kart var) takvimi bağlama satırı; izin yoksa ya da
/// okunamadıysa nedeni.
private struct HomeTodaySection: View {
    let calendar: PhoneCalendar
    let router: PhoneRouter
    /// Arşivde toplantı var: brifing sorulabilir; takvimi bağlama satırı yalnız o zaman (yokken rehberde kart var).
    let hasMeetings: Bool
    let onBriefing: @MainActor (CalendarMeeting) -> Void
    @State private var isRequesting: Bool = false

    var body: some View {
        switch calendar.state {
        case .on:
            // Saat ilerledikçe (dakikada bir) boş gün satırı da güncellenir.
            TimelineView(.everyMinute) { (context: TimelineViewDefaultContext) in
                let now: Date = context.date
                let hasToday: Bool = !upcomingMeetings(meetings: calendar.meetings, now: now, horizonSec: 12 * 3600).isEmpty
                    || !meetingsEndedToday(meetings: calendar.meetings, now: now, calendar: Calendar.current).isEmpty
                if hasToday {
                    UpcomingCalendarSection(calendar: calendar, router: router, canBrief: hasMeetings, onBriefing: onBriefing)
                } else {
                    QuietRail {
                        Text("Bugün başka toplantı yok")
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
        case .off:
            if hasMeetings {
                QuietRail {
                    Button {
                        isRequesting = true
                        Task {
                            await calendar.enable()
                            isRequesting = false
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text("Takvimini bağla; günün toplantıları burada görünür.")
                                .foregroundStyle(Theme.muted)
                                .multilineTextAlignment(.leading)
                            if isRequesting {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isRequesting)
                    .accessibilityHint(Text("Takvim izni sorulur"))
                }
            }
        case .denied, .failed:
            UpcomingCalendarSection(calendar: calendar, router: router, canBrief: hasMeetings, onBriefing: onBriefing)
        }
    }
}

/// Solda ince vurgu çizgisiyle sakin tek satır (boş gün, takvim daveti).
private struct QuietRail<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        HStack(spacing: 14) {
            Capsule()
                .fill(appearance.accent.color.opacity(0.45))
                .frame(width: 3)
            content()
                .appFont(size: 16, weight: .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Sana düşen açık görevler: başlık ve "Tümü" (açık görev sayısıyla), altında ilk birkaç görev; kutuya dokununca
/// tamamlanır, satıra dokununca toplantı yerine Görevlerim açılır.
private struct HomeTasksSection: View {
    let items: [DatedTask]
    /// Bütün açık görevlerin sayısı ("Tümü · 8").
    let total: Int
    let store: PhoneStore
    let onShowAll: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sana düşen görevler")
                    .appFont(size: 14, weight: .medium)
                    .foregroundStyle(Theme.muted)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button(action: onShowAll) {
                    Text("Tümü · \(total)")
                        .appFont(size: 14, weight: .medium)
                        .monospacedDigit()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.rowID) { (item: (offset: Int, element: DatedTask)) in
                    if item.offset > 0 {
                        Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, PhoneTaskRowMetrics.compact.separatorInset)
                    }
                    PhoneTaskRowContent(record: item.element.record, task: item.element.task, showsMeeting: true, metrics: .compact) {
                        withAnimation(.smooth(duration: 0.25)) {
                            store.toggleTask(meetingID: item.element.record.id, task: item.element.task)
                        }
                    }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line))
        }
    }
}

/// Toplantı satırı (ana ekran ve arama): pastel kutu, başlık, saat · süre · durum ya da sana düşen görevler.
struct HomeMeetingRow: View {
    let record: MeetingRecord

    var body: some View {
        HStack(spacing: 14) {
            MeetingTile(record: record, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.note?.title ?? record.title)
                    .appFont(size: 16, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(verbatim: homeMeetingSubtitle(record: record, now: Date(), calendar: .current, locale: interfaceLocale()))
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Satırın alt yazısı: bugün ve dün yalnız saat, daha eskide gün ve saat; süre; işlenmemişse durumu, işlendiyse sana
/// düşen açık görev sayısı. Saf fonksiyondur.
func homeMeetingSubtitle(record: MeetingRecord, now: Date, calendar: Calendar, locale: Locale) -> String {
    let days: Int = calendar.dateComponents([.day], from: calendar.startOfDay(for: record.startedAt), to: calendar.startOfDay(for: now)).day ?? 0
    let style: Date.FormatStyle = days <= 1
        ? Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
        : Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
    let time: String = record.startedAt.formatted(style)
    let minutes: [String] = meetingDurationMinutes(record: record).map { [String(localized: "\($0) dk")] } ?? []
    let mine: Int = (record.note?.tasks ?? []).filter { $0.isMine && !isTaskDone(record: record, task: $0) }.count
    let state: [String]
    if let status = meetingStatusText(status: record.status) {
        state = [status]
    } else if mine > 0 {
        state = [String(localized: "\(mine) görev")]
    } else {
        state = []
    }
    return ([time] + minutes + state).joined(separator: " · ")
}

/// Kor bandının düğme satırının altında kalan derinliği (ekranın alt kenarına, ev çubuğunun altına uzanır).
private let homeHorizonDepth: CGFloat = 120

/// Ana ekranın altında yüzen çubuk: "Bir şey sor" ve büyük kayıt düğmesi; başlarken (konuşma modeli iniyorsa
/// ilerlemesiyle) üstünde kısa durum. Telefon görüşmesi rehberi (iPhone'un arama kaydı her bölgede yok) burada değil; kayıt
/// seçenekleri menüsünden, kitaplıktan ve Ayarlar › Özellikler'den açılır.
private struct HomeBottomBar: View {
    let recorder: PhoneRecorder
    let account: HostedAccount
    /// "Bir şey sor": Sor'u açar.
    let onAsk: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if recorder.phase == .starting {
                Text(verbatim: startTitle)
                    .appFont(size: 13, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassSurface(in: Capsule())
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            }
            HStack(spacing: 12) {
                Button {
                    onAsk()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "sparkle.magnifyingglass")
                            .foregroundStyle(appearance.accent.color)
                            .accessibilityHidden(true)
                        Text("Bir şey sor")
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .appFont(size: 17, weight: .medium)
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .modifier(HomeAskPillSurface())
                recordButton
            }
            // Kor: düğme satırının ortasından ekranın altına durgun bant; "Bir şey sor" hapı bandın üst kenarına oturur.
            .background(alignment: .top) {
                if ThemeStore.shared.palette.brand == .ember {
                    GeometryReader { (proxy: GeometryProxy) in
                        EmberBand(contourSeed: "iphone-dock", contourCount: 3)
                            .frame(width: proxy.size.width + 32, height: proxy.size.height / 2 + homeHorizonDepth)
                            .offset(x: -16, y: proxy.size.height / 2)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 6)
        // Altına kayan içerik çubuğun hemen üstünde solar: cam düğmelerin arkasında liste yazısı okunmaz hâle gelmez;
        // durağan geçiş.
        .background {
            LinearGradient(
                stops: [
                    .init(color: Theme.background.opacity(0), location: 0),
                    .init(color: Theme.background.opacity(0.9), location: 0.35),
                    .init(color: Theme.background, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(.top, -16)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
        .animation(.smooth(duration: 0.25), value: recorder.phase == .starting)
    }

    /// Büyük yuvarlak kayıt düğmesi (Klasik'te vurgu renginde, Kor'da marka küresi: vurgudan bağımsız); kayıt engelliyse
    /// nedeni ipucunda (bildirim ve çözümü başlığın altında).
    private var recordButton: some View {
        Button {
            Task { await recorder.start() }
        } label: {
            ZStack {
                switch ThemeStore.shared.palette.brand {
                case .film:
                    Circle()
                        .fill(appearance.accent.color)
                        .shadow(color: appearance.accent.color.opacity(0.35), radius: 14, y: 6)
                case .ember:
                    EmberOrb(gradient: .recordButton)
                        .background(Circle().fill(Color(red: 1, green: 251 / 255, blue: 245 / 255).opacity(0.35)).padding(-3))
                        .shadow(color: Color(red: 60 / 255, green: 24 / 255, blue: 12 / 255).opacity(0.4), radius: 8, y: 6)
                }
                if recorder.phase == .starting {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "mic.fill")
                        .appFont(size: 24, weight: .semibold)
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 62, height: 62)
            .contentShape(Circle())
        }
        .buttonStyle(PressableCardStyle())
        .disabled(recorder.phase == .starting)
        .accessibilityLabel(Text("Kaydı başlat"))
        .accessibilityHint(phoneStartBlockMessage(account: account, now: Date()).map { Text(verbatim: $0) } ?? Text("Odadaki toplantıyı dinler; bitince notu yazar."))
    }

    /// Başlarken (cihaz içi konuşma modeli iniyorsa ilerlemesiyle) kısa durum.
    private var startTitle: String {
        recorder.speechModelProgress.map { (fraction: Double) -> String in
            String(localized: "Konuşma modeli indiriliyor… \(fraction.formatted(.percent.precision(.fractionLength(0))))")
        } ?? String(localized: "Başlatılıyor…")
    }
}

/// "Bir şey sor" hapının yüzeyi: Klasik'te etkileşimli cam; Kor'da bandın üst kenarına oturan dolu krem hap (cam bandın
/// rengini alırdı), her temada açık görünümle (koyu yazı ve koyu bakır simge krem üstünde okunur).
private struct HomeAskPillSurface: ViewModifier {
    func body(content: Content) -> some View {
        switch ThemeStore.shared.palette.brand {
        case .film:
            content.interactiveGlassSurface(in: Capsule())
        case .ember:
            content
                .environment(\.colorScheme, .light)
                .background(Color(hex: ThemeColorSet.emberLight.card), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.6)))
                .shadow(color: Color(red: 50 / 255, green: 22 / 255, blue: 10 / 255).opacity(0.22), radius: 9, y: 6)
        }
    }
}

/// Ana ekran başlığındaki kayıt seçenekleri: seçili toplantı dili ve canlı çeviri küçük bir çipte görünür; dokununca dil,
/// canlı çeviri ve içe aktarma menüsü. Kayıt başlarken kapalı.
private struct HomeRecordOptionsChip: View {
    let recorder: PhoneRecorder
    @Environment(PhoneImportState.self) private var imports: PhoneImportState
    /// Canlı çeviri (Ayarlar'daki gösterimle aynı ayar).
    /// Erişilebilirlik boyutlarında çipte yalnız dil yazar ("Otomatik / dil" iki satıra bölünüyordu); canlı çeviri menüde.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize
    @AppStorage(PhoneSettingsKey.displayMode) private var displayMode: String = DisplayMode.bilingual.rawValue

    var body: some View {
        Menu {
            Section("Toplantı dili") {
                Button("Otomatik") { recorder.languageMode = .automatic }
                LanguageMenuItems { (language: MeetingLanguage) -> Void in recorder.setLanguage(language: language) }
            }
            Toggle(isOn: Binding<Bool>(
                get: { liveTranslationOn },
                set: { (enabled: Bool) -> Void in recorder.selectDisplayMode(mode: enabled ? .bilingual : .originalOnly) }
            )) {
                Label("Canlı çeviri", systemImage: "character.bubble")
            }
            PhoneImportMenuItems { (source: PhoneImportSource) -> Void in imports.request = source }
        } label: {
            HStack(spacing: 5) {
                Text(verbatim: languageText(locked: nil, mode: recorder.languageMode, isRecording: false))
                if liveTranslationOn, !dynamicTypeSize.isAccessibilitySize {
                    Text(verbatim: "·").accessibilityHidden(true)
                    Text("Canlı çeviri")
                }
                Image(systemName: "chevron.up.chevron.down")
                    .appFont(size: 10, weight: .semibold)
                    .accessibilityHidden(true)
            }
            .lineLimit(1)
            .appFont(size: 13, weight: .medium)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.soft, in: Capsule())
            .contentShape(Capsule())
        }
        .disabled(recorder.phase == .starting)
        .accessibilityLabel(Text("Kayıt seçenekleri"))
    }

    /// Canlı çeviri açık mı (Ayarlar'daki gösterimle aynı ayar).
    private var liveTranslationOn: Bool {
        (DisplayMode(rawValue: displayMode) ?? .bilingual).needsLiveTranslation
    }
}

/// Kitaplık sayfasında seçilen iş (sayfa kapanınca yapılır).
enum PhoneLibraryAction {
    case route(PhoneRoute)
    case importFrom(PhoneImportSource)
    case createFolder
}

/// Kitaplık (ana ekranın sol üstü): tüm toplantılar, görevler, kişiler, istatistikler, son silinenler, klasörler
/// (sayılarıyla) ve yeni klasör, ses ya da video içe aktarma.
private struct PhoneLibrarySheet: View {
    let store: PhoneStore
    let onSelect: @MainActor (PhoneLibraryAction) -> Void
    @Environment(\.dismiss) private var dismiss: DismissAction

    var body: some View {
        let openTasks: Int = myTasks(meetings: store.meetings, userName: store.userName).filter { !isTaskDone(record: $0.record, task: $0.task) }.count
        NavigationStack {
            List {
                Section {
                    row(title: "Tüm toplantılar", symbol: "tray.full", count: store.meetings.count, action: .route(.library(.filter(.all))))
                    row(title: "Görevlerim", symbol: "checklist", count: openTasks, action: .route(.tasks))
                    row(title: "Kişiler", symbol: "person.2", count: nil, action: .route(.people))
                    row(title: "İstatistikler", symbol: "chart.bar.xaxis", count: nil, action: .route(.insights))
                    if !store.deletedMeetings.isEmpty {
                        row(title: "Son silinenler", symbol: "trash", count: store.deletedMeetings.count, action: .route(.recentlyDeleted))
                    }
                }
                Section("Klasörler") {
                    ForEach(store.folders) { (folder: FolderSummary) in
                        Button {
                            onSelect(.route(.library(.folder(folder.name))))
                        } label: {
                            LabeledContent {
                                Text(verbatim: "\(folder.count)")
                            } label: {
                                PhoneSettingLabel(icon: "folder", title: Text(verbatim: folder.name))
                            }
                        }
                        .tint(Theme.ink)
                    }
                    Button {
                        onSelect(.createFolder)
                    } label: {
                        PhoneSettingLabel(icon: "folder.badge.plus", title: Text("Yeni klasör"))
                    }
                    .tint(Theme.ink)
                }
                PhoneImportMenuItems { (source: PhoneImportSource) -> Void in onSelect(.importFrom(source)) }
                    .tint(Theme.ink)
            }
            .navigationTitle("Kitaplık")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    CloseToolbarButton { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        // Yarım yükseklikte cam sayfanın arkasından ana ekranın turuncu kayıt düğmesi seçiliyordu: düz zemin.
        .presentationBackground(Theme.background)
    }

    private func row(title: LocalizedStringKey, symbol: String, count: Int?, action: PhoneLibraryAction) -> some View {
        Button {
            onSelect(action)
        } label: {
            LabeledContent {
                if let count {
                    Text(verbatim: "\(count)")
                }
            } label: {
                PhoneSettingLabel(icon: symbol, title: Text(title))
            }
        }
        .tint(Theme.ink)
    }
}

/// Arama: boşken ortada kısa açıklama, alan altta (iOS 26; iOS 18–25 başlığın altında); yazınca eşleşen toplantılar (başlık, not, görev, kişi adı,
/// transkript) eşleşen cümleleri ve transkriptteki anlarıyla, en üstte soruyu Sor'a soran satır. Arama yazmayı
/// `searchDebounce` kadar bekler ve ana iş parçacığının dışında önbellekli çalışır (`PhoneStore.searchCache`). Klasör ya
/// da süzgeç içinde arama kitaplıkta.
struct PhoneSearchScreen: View {
    let store: PhoneStore
    let router: PhoneRouter
    let ask: PhoneAsk
    @State private var query: String = ""
    @State private var isSearching: Bool = false
    /// Son biten aramanın sorgusu ve sonuçları (yeni arama bitene dek eskisi görünür).
    @State private var searched: PhoneSearchResults = PhoneSearchResults(query: "", hits: [])

    var body: some View {
        let trimmed: String = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let meetings: [MeetingRecord] = store.namedMeetings()
        let byID: [String: MeetingRecord] = Dictionary(meetings.map { ($0.id, $0) }) { (first: MeetingRecord, _: MeetingRecord) -> MeetingRecord in first }
        Group {
            if trimmed.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .appFont(size: 40, weight: .light)
                        .foregroundStyle(Theme.muted)
                        .accessibilityHidden(true)
                    Text("Notlarında ara")
                        .appFont(size: 22, weight: .regular)
                        .foregroundStyle(Theme.ink)
                    Text("Başlık, not, görev ya da kişi adıyla bul.")
                        .appFont(size: 15, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        askRow(question: trimmed)
                        if searched.query == trimmed, searched.hits.isEmpty {
                            Text("Eşleşen toplantı yok")
                                .appFont(size: 15, weight: .regular)
                                .foregroundStyle(Theme.muted)
                                .padding(.vertical, 16)
                        }
                        ForEach(searched.hits) { (hit: MeetingSearchHit) in
                            if let record = byID[hit.meetingID] {
                                NavigationLink(value: PhoneRoute.meeting(record.id)) {
                                    PhoneSearchHitRow(record: record, hit: hit)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .task(id: PhoneSearchRequest(query: trimmed, stamps: meetings.map(searchStamp(record:)))) {
            guard !trimmed.isEmpty else {
                searched = PhoneSearchResults(query: "", hits: [])
                return
            }
            // Yazarken her harfte aranmaz: yeni harf bu görevi iptal eder.
            do {
                try await Task.sleep(for: searchDebounce)
            } catch {
                return
            }
            let hits: [MeetingSearchHit] = await store.searchCache.search(records: meetings, query: trimmed)
            guard !Task.isCancelled else {
                return
            }
            searched = PhoneSearchResults(query: trimmed, hits: hits)
        }
        .background(Theme.background)
        .navigationTitle("Ara")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, isPresented: $isSearching, prompt: Text("Toplantılarda ara"))
        .searchFieldInBottomBar()
        .onAppear { isSearching = true }
    }

    /// Aramanın en üstündeki satır: sorguyu bütün toplantılara Sor'da sorar.
    private func askRow(question: String) -> some View {
        Button {
            askEverything(question: question)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .appFont(size: 17, weight: .medium)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Theme.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                Text("Sor: \u{201C}\(question)\u{201D}")
                    .appFont(size: 16, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Bütün toplantılarına sorar"))
    }

    /// Sorguyu yeni bir Sor sohbetinde bütün toplantılara sorar; hakkı yoksa abonelik ekranı açılır.
    private func askEverything(question: String) {
        guard !HostedAccount.shared.requiresSubscription else {
            HostedAccount.shared.requestSubscription()
            return
        }
        ask.startConversation(question: question, scope: .allMeetings, mentionIDs: [], recipeTitle: nil)
        router.openAskConversation()
    }
}

/// Aramanın son sonucu: hangi sorgunun sonucu olduğu ve eşleşen toplantılar.
private struct PhoneSearchResults: Equatable {
    let query: String
    let hits: [MeetingSearchHit]
}

/// Aramayı yeniden çalıştıran girdiler: sorgu ve toplantıların değişiklik izleri (`searchStamp`).
struct PhoneSearchRequest: Equatable {
    let query: String
    let stamps: [MeetingSearchStamp]
}

/// Arama sonucu satırı: toplantı, altında eşleşen cümle ve transkriptteki anı.
struct PhoneSearchHitRow: View {
    let record: MeetingRecord
    let hit: MeetingSearchHit

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            MeetingTile(record: record, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.note?.title ?? record.title)
                    .appFont(size: 16, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let snippet = hit.snippet {
                    Text(verbatim: snippet)
                        .appFont(size: 14, weight: .regular)
                        .foregroundStyle(Theme.ink.opacity(0.8))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: 6) {
                    if let startSec = hit.startSec {
                        Text(verbatim: timestamp(seconds: startSec))
                            .monospacedDigit()
                            .accessibilityLabel(Text("Transkriptte \(timestamp(seconds: startSec))"))
                        Text(verbatim: "·").accessibilityHidden(true)
                    }
                    Text(verbatim: homeMeetingSubtitle(record: record, now: Date(), calendar: .current, locale: interfaceLocale()))
                        .lineLimit(1)
                }
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
