import AINotepadCore
import AINotepadUI
import AppKit
import Observation
import os
import SwiftUI

/// Kayıt sırasındaki cam panelin sayfaları: canlı metin ve biten toplantının sonucu. Toplantılar, Ayarlar ve Kurulum
/// ana pencerededir (tek kopya: iki ayrı ekran birbirinden habersiz kalmasın).
enum PanelPage: Equatable {
    case live
    case meeting(id: String)
}

/// Panelde hangi sayfanın açık olduğu.
@MainActor
@Observable
final class PanelRouter {
    var page: PanelPage = .live
}

/// Modeli gözleyip sayfayı seçen kabuk; tüm sayfalara aynı cam yüzeyi verir.
struct PanelHost: View {
    let model: AppModel
    let router: PanelRouter
    let player: MeetingAudioPlayer
    let onStart: @MainActor () -> Void
    let onHide: @MainActor () -> Void
    /// Ana pencereyi bir bölümde açar (Toplantılar, Ayarlar).
    let onOpenMainWindow: @MainActor (MainSection) -> Void

    var body: some View {
        content
            // Çalan toplantı canlı sayfada da altta görünür (geri dönünce ses durmaz).
            .safeAreaInset(edge: .bottom) {
                PlayerDock(model: model, player: player) { (id: String) -> Void in router.page = .meeting(id: id) }
            }
            .modifier(ProcessingOverlayHost(model: model))
            // Canlı metin ile toplantı sayfası arasında yumuşak geçiş.
            .animation(.smooth(duration: 0.25), value: router.page)
            .frame(minWidth: 300, minHeight: 240)
            .panelSurface()
            .modifier(AppearanceEnvironment())
    }

    @ViewBuilder
    private var content: some View {
        switch router.page {
        case .live:
            VStack(spacing: 0) {
                if model.consentReminderVisible {
                    ConsentBanner { withAnimation(.smooth(duration: 0.25)) { model.consentReminderVisible = false } }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                #if HOSTED_EDITION
                // Sunucuya ulaşılamadan süren kayıt: canlı metin Mac'te, işleme bağlantı gelince.
                if model.isRecording, HostedAccount.shared.isOfflineRecording {
                    NoticeBar(
                        severity: .info,
                        title: Text("Çevrimdışı kaydediliyor"),
                        detail: Text("Canlı metin bu Mac'te yazılıyor; konuşmacılar ve not bağlantı gelince hazırlanır."),
                        onDismiss: nil
                    ) {
                        EmptyView()
                    }
                }
                // Aylık sınıra az kaldığı için kısaltılmış toplantı: kalan dakika.
                if model.isRecording, let deadline = model.shortMeetingDeadline {
                    HostedMeetingLimitStrip(deadline: deadline)
                }
                #endif
                // Görüşme bitti gibi: kayıt geri sayımla bitecek.
                if model.isRecording, let deadline = model.callEndDeadline {
                    CallEndNotice(deadline: deadline) { model.keepRecordingAfterCallEnd() } onStop: { model.stopRecording() }
                }
                // Önceki ilgili toplantılardan açık görevler (yalnız hatırlatma).
                if model.isRecording, !model.relatedTasks.isEmpty {
                    RelatedTasksStrip(tasks: model.relatedTasks) {
                        if let meeting = model.recordingCalendarMeeting, model.startBriefing(meeting: meeting) {
                            onOpenMainWindow(.ask)
                        }
                    } onDismiss: {
                        withAnimation(.smooth(duration: 0.25)) { model.relatedTasks = [] }
                    }
                }
            TranscriptPanel(
                state: model.viewState,
                actions: PanelActions(
                    onHide: onHide,
                    onStart: onStart,
                    onTogglePause: { model.togglePause() },
                    onToggleMic: { model.toggleMicrophone() },
                    onStop: { model.stopRecording() },
                    onOpenMeetings: { onOpenMainWindow(.meetings) },
                    onOpenSettings: { onOpenMainWindow(.settings) },
                    onMissed: { model.askWhatIMissed() },
                    onAsk: { (question: String) -> Void in model.ask(question: question) },
                    onCloseCard: { model.closeAssistantCard() },
                    onRetryTranslations: { (ids: [SegmentID]) -> Void in model.retryTranslations(ids: ids) },
                    onSetLanguage: { (language: MeetingLanguage) -> Void in model.setLanguage(language: language) },
                    onChooseLanguageMode: { (mode: LanguageMode) -> Void in model.languageMode = mode },
                    onReassignBlock: { (segments: [SegmentID], person: Int) -> Void in model.reassignBlock(segments: segments, person: person) },
                    onMergePerson: { (from: Int, into: Int) -> Void in model.mergeLivePersons(from: from, into: into) },
                    onBookmark: { model.bookmarkNow() }
                ),
                levels: model.audioLevels,
                myNotes: Binding<String>(get: { model.liveMyNotes }, set: { (text: String) -> Void in model.liveMyNotes = text })
            )
            }
            .animation(.smooth(duration: 0.25), value: model.consentReminderVisible)
            .animation(.smooth(duration: 0.25), value: model.callEndDeadline)
        case .meeting(let id):
            PanelPageView(model: model, router: router, title: "Toplantı", back: .live, onHide: onHide) {
                if let record = model.meetings.first(where: { $0.id == id }) {
                    MeetingDetailPage(model: model, player: player, record: record) {
                        router.page = .live
                    } onRunRecipe: { (recipe: Recipe) -> Void in
                        model.askArchive(question: recipe.prompt, meetingIDs: [record.id], recipeTitle: recipe.title)
                        onOpenMainWindow(.ask)
                    }
                        // Toplantı değişince ad alanları gibi durumlar sıfırlansın.
                        .id(record.id)
                } else {
                    ContentUnavailableView("Toplantı bulunamadı", systemImage: "doc.questionmark")
                }
            }
        }
    }
}

/// Alt sayfanın çerçevesi: geri, başlık, kayıttaysa canlı sayfaya dönüş, gizle.
private struct PanelPageView<Content: View>: View {
    let model: AppModel
    let router: PanelRouter
    let title: LocalizedStringKey
    let back: PanelPage
    let onHide: @MainActor () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.s) {
                Button {
                    router.page = back
                } label: {
                    ViewThatFits(in: .horizontal) {
                        Label("Canlı", systemImage: "chevron.left")
                        Image(systemName: "chevron.left")
                    }
                    .appFont(size: 12, weight: .medium)
                }
                .buttonStyle(.hoverPlain)
                .foregroundStyle(.secondary)
                .hoverHint("Geri", alignment: .leading, edge: .bottom)
                Spacer(minLength: DesignTokens.Spacing.s)
                Text(title)
                    .appFont(size: 13, weight: .semibold)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: DesignTokens.Spacing.s)
                if model.phase != .idle {
                    // Kayıt sürerken her sayfadan canlı metne tek dokunuşla dönülür.
                    Button {
                        router.page = .live
                    } label: {
                        ViewThatFits(in: .horizontal) {
                            Label(model.isFinishing ? "Bitiriliyor" : "Kayıtta", systemImage: "record.circle")
                            Image(systemName: "record.circle")
                        }
                        .appFont(size: 12, weight: .medium)
                        .foregroundStyle(.red)
                    }
                    .buttonStyle(.hoverPlain)
                    .hoverHint("Canlı metne dön", alignment: .trailing, edge: .bottom)
                }
                Button(action: onHide) {
                    Image(systemName: "minus")
                        .appFont(size: 12, weight: .medium)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.hoverPlain)
                .foregroundStyle(.secondary)
                .hoverHint("Paneli gizle", alignment: .trailing, edge: .bottom)
                .accessibilityLabel("Paneli gizle")
            }
            .padding(.horizontal, DesignTokens.Spacing.l)
            .padding(.vertical, DesignTokens.Spacing.m)
            // İpuçları başlığın altına taşar: içeriğin üstünde çizilsin.
            .zIndex(1)
            Divider().opacity(0.35)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// `--sayfa canli` ya da `--toplanti <kimlik>` başlatma argümanının panel sayfası (geliştirme ve görsel kontrol için;
/// ana pencere bölümleri `--bolum` ile); argüman yoksa ya da tanınmıyorsa nil. Saf fonksiyondur.
func launchPage(arguments: [String]) -> PanelPage? {
    if let index = arguments.firstIndex(of: "--toplanti"), arguments.indices.contains(index + 1) {
        return .meeting(id: arguments[index + 1])
    }
    guard let index = arguments.firstIndex(of: "--sayfa"), arguments.indices.contains(index + 1), arguments[index + 1] == "canli" else {
        return nil
    }
    return .live
}

/// Ayarlar › Görünüm değerlerini (AppStorage) okuyup görünüme uygular: panel görünümü ortamı, vurgu rengi (sistem
/// denetimleri de kullanır), yazı tipi tasarımı (yazı tipini ayrıca belirtmeyen metinler de) ve pencere teması. Panel ve
/// ana pencere aynı ayarları kullanır; değişince ikisi de hemen güncellenir.
struct AppearanceEnvironment: ViewModifier {
    @AppStorage(SettingsKey.theme) private var theme: String = AppTheme.light.rawValue
    @AppStorage(SettingsKey.accent) private var accent: String = PanelAppearance.standard.accent.rawValue
    @AppStorage(SettingsKey.fontDesign) private var fontDesign: String = PanelAppearance.standard.fontChoice.storageValue
    @AppStorage(SettingsKey.uiScale) private var uiScale: Double = PanelAppearance.standard.uiScale
    @AppStorage(SettingsKey.textSize) private var textSize: Double = PanelAppearance.standard.textSize
    @AppStorage(SettingsKey.lineSpacing) private var lineSpacing: Double = PanelAppearance.standard.lineSpacing
    @AppStorage(SettingsKey.bottomSpacing) private var bottomSpacing: Double = PanelAppearance.standard.bottomSpacing
    @AppStorage(SettingsKey.surface) private var surface: String = PanelAppearance.standard.surface.rawValue
    @AppStorage(SettingsKey.surfaceOpacity) private var surfaceOpacity: Double = PanelAppearance.standard.surfaceOpacity
    /// Yüklü yazı aileleri: seçili aile kaldırılınca varsayılan yazıya dönülür (AppKit o aileyle yazı oluşturamaz).
    /// Yazı yüklenip kaldırılınca yenilenir.
    @State private var installedFamilies: Set<String> = Set(NSFontManager.shared.availableFontFamilies)

    func body(content: Content) -> some View {
        let appearance: PanelAppearance = resolvedPanelAppearance(stored: StoredAppearance(
            fontDesign: fontDesign, uiScale: uiScale, textSize: textSize, lineSpacing: lineSpacing, bottomSpacing: bottomSpacing, accent: accent,
            surface: surface, surfaceOpacity: surfaceOpacity
        ), isFontFamilyInstalled: installedFamilies.contains)
        content
            .environment(\.panelAppearance, appearance)
            .tint(appearance.accent.color)
            .fontDesign(appearance.systemFontDesign)
            // Yazı tipi belirtilmemiş metinler ve sistem denetimleri de seçili aile ve ölçekte.
            .font(appearance.font(size: 13, weight: .regular))
            // İpuçları pencerenin en üst katmanında (metnin altında kalmasın, kesilmesin).
            .hoverHintLayer()
            // Stil belirtilmemiş tüm düğmeler hap biçiminde (el imleci ve hover dahil).
            .buttonStyle(.pill)
            // Tema uygulamanın tamamına uygulanır: ana pencere, cam zemin, panel, ada ve menüler aynı anda değişir.
            .onChange(of: theme, initial: true) { (_: String, value: String) in
                applyTheme(theme: AppTheme(rawValue: value) ?? .system)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSFont.fontSetChangedNotification)) { (_: Notification) in
                installedFamilies = Set(NSFontManager.shared.availableFontFamilies)
            }
            .onChange(of: StoredFontState(storage: fontDesign, installedFamilies: installedFamilies), initial: true) { (_: StoredFontState, state: StoredFontState) in
                if case .installed(let family) = AppFontChoice.parse(storage: state.storage), !state.installedFamilies.contains(family) {
                    appearanceLogger.warning("Seçili yazı ailesi yüklü değil, varsayılan yazı kullanılıyor; aile: \(family, privacy: .public)")
                }
            }
    }
}

/// Ana pencereden açılan sayfaların (sheet) görünümü: macOS sayfası pencerenin görünüm ortamını (vurgu rengi, yazı,
/// hap düğmeler) devralmıyor ve sistemin gri sayfa zeminini kullanıyordu (koyu temada uygulamanın zeminiyle uyuşmuyor,
/// stilsiz düğmeler vurgu renginde sistem düğmesi oluyordu). İkisi de uygulamanınkine çekilir.
struct AppSheetChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(Theme.ink)
            .modifier(AppearanceEnvironment())
            .presentationBackground(Theme.background)
    }
}

private let appearanceLogger: Logger = Logger(subsystem: "com.senoldogan.AINotepad", category: "Appearance")

/// Saklanan yazı seçimi ve yüklü aileler (yüklü olmayan aile uyarısı ikisinden biri değişince yeniden bakılır).
private struct StoredFontState: Equatable {
    let storage: String
    let installedFamilies: Set<String>
}


/// İlerleme kartının durumu: hangi toplantı (bitirilirken henüz yok), kaçıncı adım, yerel motor mu.
/// Toplantı hazırlanırken içeriği bulanıklaştırıp ortada ilerleme kartını gösterir; panel ve ana pencere aynı kartı
/// gösterir, "Arka planda devam et" ikisinde birden kapatır (durum modelde).
struct ProcessingOverlayHost: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        let progress: ProcessingProgress? = processingProgress
        content
            .blur(radius: progress == nil ? 0 : 8)
            .allowsHitTesting(progress == nil)
            .overlay {
                if let progress {
                    ProcessingOverlay(progress: progress) {
                        if let id = progress.meetingID {
                            model.dismissedProgressIDs.insert(id)
                        } else {
                            model.finishingCardDismissed = true
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: progress)
    }

    /// Gösterilecek ilerleme: kayıt bitiriliyorsa ya da son biten toplantı işleniyorsa (kullanıcı kapatmadıysa).
    private var processingProgress: ProcessingProgress? {
        if model.phase == .finishing {
            // Bitirilen kayıt şimdiki motorla tanındı (motor kayıt sürerken değişmez).
            let isLocal: Bool = model.finalPassRunsOnThisMac(engine: model.liveEngine.recordingEngine)
            return model.finishingCardDismissed ? nil : ProcessingProgress(meetingID: nil, stepIndex: 0, isLocal: isLocal)
        }
        // Bitirilirken kapatıldıysa aynı kaydın işlemesi için de yeniden açılmaz.
        guard !model.finishingCardDismissed, let id = model.lastFinishedMeetingID, let step = model.processingSteps[id],
              !model.dismissedProgressIDs.contains(id) else {
            return nil
        }
        let isLocal: Bool = model.finalPassRunsOnThisMac(engine: model.meetings.first { $0.id == id }?.engine)
        return ProcessingProgress(meetingID: id, stepIndex: step.rawValue + 1, isLocal: isLocal)
    }
}

struct ProcessingProgress: Equatable {
    let meetingID: String?
    /// 0: kayıt bitiriliyor, 1: ses, 2: son geçiş, 3: not.
    let stepIndex: Int
    let isLocal: Bool
}

/// Toplantı hazırlanırken panelin ortasındaki kart: animasyonlu simge, adımlar (biten ✓, süren gösterge, bekleyen
/// soluk), ilerleme çubuğu ve "Arka planda devam et".
private struct ProcessingOverlay: View {
    let progress: ProcessingProgress
    let onDismiss: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    private var steps: [LocalizedStringKey] {
        [
            "Kayıt bitiriliyor",
            "Ses kaydı hazırlanıyor",
            progress.isLocal ? "Konuşmacılar Mac'te ayrılıyor" : "Kaydın tamamı işleniyor",
            "Not hazırlanıyor",
        ]
    }

    var body: some View {
        // Kısa panelde önce simge ve açıklama düşer.
        ViewThatFits(in: .vertical) {
            card(isCompact: false)
            card(isCompact: true)
        }
        .padding(DesignTokens.Spacing.m)
    }

    private func card(isCompact: Bool) -> some View {
        VStack(spacing: isCompact ? DesignTokens.Spacing.m : DesignTokens.Spacing.l) {
            if !isCompact {
                waveIcon
            }
            Text("Toplantı hazırlanıyor")
                .appFont(size: 16, weight: .semibold)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.offset) { (item: (offset: Int, element: LocalizedStringKey)) in
                    HStack(spacing: DesignTokens.Spacing.s) {
                        Group {
                            if item.offset < progress.stepIndex {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                            } else if item.offset == progress.stepIndex {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "circle").foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 18, height: 18)
                        Text(item.element)
                            .appFont(size: 13, weight: item.offset == progress.stepIndex ? .semibold : .regular)
                            .foregroundStyle(item.offset > progress.stepIndex ? .secondary : .primary)
                    }
                }
            }
            ProgressView(value: Double(progress.stepIndex) + 0.5, total: Double(steps.count))
                .tint(appearance.accent.color)
            // Seçilen yazı tipi tasarımı yazı tipini ayrıca belirtmeyen tüm metinlere de uygulanır.
            .fontDesign(appearance.systemFontDesign)
            if !isCompact {
                Text("Bitince toplantının sayfası açılır; görevlerin en üstte.")
                    .appFont(size: 11, weight: .regular)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Arka planda devam et", action: onDismiss)
                .buttonStyle(.hoverPlain)
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(appearance.accent.color)
        }
        .padding(isCompact ? DesignTokens.Spacing.l : DesignTokens.Spacing.xl)
        .frame(maxWidth: 300)
        .cardSurface(cornerRadius: 20)
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .accessibilityElement(children: .combine)
    }

    private var waveIcon: some View {
        Image(systemName: "waveform")
            .appFont(size: 34, weight: .medium)
            .foregroundStyle(appearance.accent.color)
            // Durağan: işleme dakikalarca sürer; sürekli sembol animasyonu bulanık ana pencereyle birlikte her karede
            // yeniden çizim yaptırıyordu (oynatıcıda ölçülen ana iş parçacığı beklemesiyle aynı desen).
    }
}

#if HOSTED_EDITION
/// Katılımcılara kayıttan haber verme metni (toplantı sohbetine yapıştırılır). Gistsmith herkese açık ve İngilizce
/// satılır: yalnızca İngilizce.
let consentNoticeText: String = "Hi! I'm recording this meeting so I can take notes."
#else
/// Katılımcılara kayıttan haber verme metni (Fince ve İngilizce; toplantı sohbetine yapıştırılır).
let consentNoticeText: String = "Hei! Tallennan tämän palaverin, jotta voin tehdä siitä muistiinpanot.\nHi! I'm recording this meeting so I can take notes."
#endif

/// Bildirimi kopyala düğmesinin ipucu: bildirimin dilleri sürüme göre.
private var consentNoticeHint: LocalizedStringKey {
    #if HOSTED_EDITION
    "İngilizce kısa bildirim; toplantı sohbetine yapıştır"
    #else
    "Fince ve İngilizce kısa bildirim; toplantı sohbetine yapıştır"
    #endif
}

/// Kayıt başında panelin üstünde: katılımcılara haber verme hatırlatması ve kopyalanabilir bildirim. Kapatılınca o
/// kayıt boyunca görünmez; Ayarlar'dan tamamen kapatılabilir.
private struct ConsentBanner: View {
    let onDismiss: @MainActor () -> Void
    @State private var copied: Bool = false

    var body: some View {
        NoticeBar(severity: .info, title: Text("Kayıt yapıyorsun: katılımcılara haber ver."), detail: nil, onDismiss: onDismiss) {
            Button(copied ? "Kopyalandı" : "Bildirimi kopyala", systemImage: copied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(consentNoticeText, forType: .string)
                copied = true
            }
            .hoverHint(consentNoticeHint, alignment: .trailing, edge: .bottom)
        }
    }
}
