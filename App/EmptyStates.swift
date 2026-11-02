import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Mac'in boş durumları tek ailede: büyük sahne (hiç veri yokken: durgun pastel gradyanlı kart, başlık, tek satır,
// eylemler), sakin yer tutucu (seçim ya da sonuç yokken: vurgu renkli simge, kısa metin) ve satır içi kart. Simgeler ve
// ana düğme kullanıcının Görünüm'deki vurgu rengini alır; gri yalnızca ikincil yazıda. Hiçbir şey sürekli kıpırdamaz.

// MARK: Büyük sahne

/// Boş sayfanın sahnesi: üstte durgun film gradyanlı kart ve içinde örnek bir not kartı çizimi; altında başlık, tek satır
/// açıklama ve eylemler. Sahne açılışta bir kez yumuşakça belirir ("Hareketi azalt" açıksa hemen); sonra durgundur.
struct EmptyScene<Actions: View>: View {
    let symbol: String
    let palette: FilmPalette
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let actions: Actions
    @State private var isShown: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    init(symbol: String, palette: FilmPalette, title: LocalizedStringKey, message: LocalizedStringKey, @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.palette = palette
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 26) {
            EmptySceneArt(symbol: symbol, palette: palette)
                .scaleEffect(isShown ? 1 : 0.97)
            VStack(spacing: 8) {
                Text(title)
                    .appFont(size: 26, weight: .semibold)
                    .tracking(-0.6)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                Text(message)
                    .appFont(size: 14, weight: .regular)
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }
            actions
        }
        .frame(maxWidth: 600)
        .opacity(isShown ? 1 : 0)
        .onAppear {
            withAnimation(reduceMotion ? .none : .easeOut(duration: 0.4)) { isShown = true }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Sahnenin çizimi: pastel film gradyanı (koyu temada kısılır) üstünde iki soluk kâğıt ve önde örnek bir not kartı
/// (vurgu renkli simge, iskelet satırlar, işaretlenmemiş bir görev). Her temada açık görünümle çizilir.
private struct EmptySceneArt: View {
    let symbol: String
    let palette: FilmPalette
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 24, style: .continuous)
        ZStack {
            FilmGradient(seed: "bos-sahne-\(symbol)", palette: palette)
                .dimmedInDarkTheme()
            paper
                .rotationEffect(.degrees(-8))
                .offset(x: -46, y: 14)
                .opacity(0.45)
            paper
                .rotationEffect(.degrees(7))
                .offset(x: 48, y: 8)
                .opacity(0.6)
            noteCard
        }
        .environment(\.colorScheme, .light)
        .frame(maxWidth: 560)
        .frame(height: 188)
        .clipShape(shape)
        .accessibilityHidden(true)
    }

    private var paper: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white)
            .frame(width: 200, height: 118)
    }

    private var noteCard: some View {
        let accent: Color = appearance.accent.color
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .appFont(size: 15, weight: .semibold)
                    .foregroundStyle(Color.white)
                    .frame(width: 34, height: 34)
                    .background(accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    skeleton(width: 104, height: 7, opacity: 0.22)
                    skeleton(width: 64, height: 6, opacity: 0.1)
                }
            }
            skeleton(width: 178, height: 6, opacity: 0.09)
            skeleton(width: 146, height: 6, opacity: 0.09)
            HStack(spacing: 7) {
                Circle()
                    .strokeBorder(accent, lineWidth: 1.5)
                    .frame(width: 11, height: 11)
                skeleton(width: 112, height: 6, opacity: 0.12)
            }
        }
        .padding(16)
        .frame(width: 226, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
    }

    private func skeleton(width: CGFloat, height: CGFloat, opacity: Double) -> some View {
        Capsule()
            .fill(Color.black.opacity(opacity))
            .frame(width: width, height: height)
    }
}

/// Sahneyi kullanılabilir yüksekliğin ortasına koyar; alan dar kalırsa kaydırılır (en küçük pencerede kesilmez).
struct CenteredScroll<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        GeometryReader { (proxy: GeometryProxy) in
            ScrollView {
                content
                    .padding(.horizontal, 40)
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollIndicators(.hidden)
        }
    }
}

// MARK: Sakin yer tutucu

/// Alanın ortasında sakin boş durum (seçim yok, eşleşen sonuç yok): vurgu renkli simge kutusu, kısa başlık, en çok bir
/// satır açıklama ve (varsa) eylemler.
struct QuietEmptyState<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey?
    let actions: Actions

    init(symbol: String, title: LocalizedStringKey, message: LocalizedStringKey?, @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 14) {
            AccentSymbolTile(symbol: symbol, size: 52)
            VStack(spacing: 4) {
                Text(title)
                    .appFont(size: 15, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 300)
                }
            }
            actions
        }
        .padding(DesignTokens.Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// Sayfa içindeki boş bölüm kartı (not yok, tamamlanan görev yok…): solda vurgu renkli simge kutusu, yanında başlık ve
/// (varsa) açıklama. Gerçek uyarılar için değil (onlar `NoticeText`).
struct QuietEmptyCard: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            AccentSymbolTile(symbol: symbol, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .appFont(size: 14, weight: .medium)
                    .foregroundStyle(Theme.ink)
                if let message {
                    Text(message)
                        .appFont(size: 13, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 14)
        .accessibilityElement(children: .combine)
    }
}

/// Vurgu renginde simge, aynı rengin soluk zemininde yuvarlatılmış kare içinde.
struct AccentSymbolTile: View {
    let symbol: String
    let size: CGFloat
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        Image(systemName: symbol)
            .appFont(size: size * 0.4, weight: .medium)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(appearance.accent.color)
            .frame(width: size, height: size)
            .background(appearance.accent.color.opacity(0.11), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: Vurgu düğmesi

/// Boş durumun ana eylemi: vurgu renginde dolu kapsül, beyaz yazı (ölçüler denetim boyutuna göre hap düğmeyle aynı). Fare üstündeyken hafif
/// açılır, basılınca küçülür; etkin değilse soluk zemin.
struct AccentPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AccentPillBody(configuration: configuration)
    }
}

private struct AccentPillBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled: Bool
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    @Environment(\.controlSize) private var controlSize: ControlSize
    @State private var isHovering: Bool = false

    var body: some View {
        let accent: Color = appearance.accent.color
        let metrics: AccentPillMetrics = accentPillMetrics(controlSize: controlSize)
        configuration.label
            .appFont(size: metrics.size, weight: .medium)
            .lineLimit(1)
            .foregroundStyle(isEnabled ? Color.white : Theme.muted)
            .padding(.horizontal, metrics.horizontal)
            .padding(.vertical, metrics.vertical)
            .background(isEnabled ? accent.opacity(isHovering ? 0.86 : 1) : Theme.soft, in: Capsule())
            .shadow(color: accent.opacity(isEnabled ? 0.28 : 0), radius: 10, y: 4)
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .onHover { (hovering: Bool) -> Void in isHovering = hovering }
            .linkPointer(isEnabled: isEnabled)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// Vurgu düğmesinin dolgu ve yazı ölçüsü.
private struct AccentPillMetrics {
    let horizontal: CGFloat
    let vertical: CGFloat
    let size: CGFloat
}

/// Denetim boyutunun ölçüleri (`.pill` ile aynı: yan yana duran iki düğme aynı boyda). Saf fonksiyondur.
private func accentPillMetrics(controlSize: ControlSize) -> AccentPillMetrics {
    switch controlSize {
    case .mini, .small: AccentPillMetrics(horizontal: 11, vertical: 5, size: 12)
    case .large, .extraLarge: AccentPillMetrics(horizontal: 18, vertical: 10, size: 15)
    default: AccentPillMetrics(horizontal: 14, vertical: 7, size: 13)
    }
}

extension ButtonStyle where Self == AccentPillButtonStyle {
    static var accentPill: AccentPillButtonStyle { AccentPillButtonStyle() }
}

// MARK: Toplantılar: ilk açılış

/// Hiç toplantı yokken Toplantılar bölümü (liste sütunu yerine tek düzen): sahne, "Kaydı başlat" (kısayoluyla), "Dosya
/// içe aktar", sürükle-bırak ipucu; takvim bağlıysa sıradaki toplantı. Bırakılan ses/video dosyası içe aktarılır.
struct MeetingsFirstRun: View {
    let model: AppModel
    let router: MainWindowRouter
    /// Kayıt kısayolu, ekranda gösterildiği biçimde (ör. "⌥⌘R").
    let recordShortcut: String
    let onStartRecording: @MainActor () -> Void

    var body: some View {
        let startBlock: StartBlockNotice? = startBlockNotice(model: model)
        let next: CalendarMeeting? = nextCalendarMeeting(meetings: model.upcomingMeetings, now: Date())
        CenteredScroll {
            EmptyScene(
                symbol: "waveform", palette: .sunset, title: "Henüz toplantı yok",
                message: "İlk toplantını kaydet ya da bir kaydı içe aktar; not, görevler ve transkript burada hazır olur."
            ) {
                VStack(spacing: 14) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { buttons(startBlock: startBlock) }
                        VStack(spacing: 10) { buttons(startBlock: startBlock) }
                    }
                    status(startBlock: startBlock)
                    if let next {
                        NextMeetingCard(meeting: next)
                            .frame(maxWidth: 440)
                            .padding(.top, 8)
                    }
                }
            }
        }
        // Ses/video dosyası sayfaya bırakılınca toplantı olarak içe aktarılır (liste sütunundaki gibi).
        .dropDestination(for: URL.self) { (urls: [URL], _: CGPoint) -> Bool in
            let media: [URL] = mediaFileURLs(urls: urls)
            guard !media.isEmpty else {
                return false
            }
            model.importMedia(urls: media)
            return true
        }
    }

    @ViewBuilder
    private func buttons(startBlock: StartBlockNotice?) -> some View {
        Button(action: onStartRecording) {
            HStack(spacing: 8) {
                Label("Kaydı başlat", systemImage: "record.circle")
                if !recordShortcut.isEmpty {
                    Text(verbatim: recordShortcut)
                        .appFont(size: 12, weight: .medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.22), in: Capsule())
                }
            }
        }
        .buttonStyle(.accentPill)
        .controlSize(.large)
        .disabled(model.phase != .idle || !model.isReadyToRecord || model.isStarting || startBlock != nil)
        Button("Dosya içe aktar", systemImage: "square.and.arrow.down") { chooseMediaToImport(model: model) }
            .buttonStyle(.pill)
            .controlSize(.large)
    }

    /// Düğmelerin altındaki tek satır: kayıt engeli, konuşma modeli, kayıt ya da içe aktarma durumu; yoksa sürükleme
    /// ipucu. Hatalar (içe aktarma, okunamayan toplantılar) ayrıca gösterilir.
    @ViewBuilder
    private func status(startBlock: StartBlockNotice?) -> some View {
        VStack(spacing: 8) {
            if let startBlock {
                StartBlockView(notice: startBlock) { (action: StartBlockAction) -> Void in resolveStartBlock(action: action, router: router) }
            } else if model.phase != .idle {
                Text("Kayıt sürüyor; bitince toplantı burada görünür.")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
            } else if let notice = model.localModelNotice {
                LocalModelNoticeView(notice: notice) { Task { await model.retryLocalModel() } }
            }
            if model.importingCount > 0 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("İçe aktarılıyor…")
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
            } else if startBlock == nil, model.phase == .idle {
                Text("ya da ses/video dosyasını buraya sürükle")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
            if let error = model.importError {
                NoticeText(error, severity: .error)
                    .appFont(size: 12, weight: .regular)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.visibleLoadFailures.isEmpty {
                NoticeText("\(model.visibleLoadFailures.count) toplantı okunamadı: \(model.visibleLoadFailures.map(\.folder).joined(separator: ", "))", severity: .error)
                    .appFont(size: 12, weight: .regular)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.center)
    }
}

/// Takvimdeki sıradaki toplantı: vurgu renkli takvim simgesi, saat ve başlık; görüşme bağlantısı varsa "Katıl".
private struct NextMeetingCard: View {
    let meeting: CalendarMeeting

    var body: some View {
        HStack(spacing: 12) {
            AccentSymbolTile(symbol: "calendar", size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sıradaki: \(calendarMeetingTimeText(meeting: meeting, now: Date(), calendar: .current, locale: interfaceLocale()))")
                    .appFont(size: 12, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                Text(verbatim: meeting.title)
                    .appFont(size: 14, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let url = meeting.joinURL {
                Button("Katıl", systemImage: "video") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.pill)
                    .controlSize(.small)
                    .hoverHint("Görüşme bağlantısını aç: \(url.host() ?? "")", alignment: .trailing, edge: .bottom)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .cardSurface(cornerRadius: 16)
    }
}

// MARK: Saf yardımcılar

/// Takvimde henüz bitmemiş en erken toplantı; yoksa nil. Saf fonksiyondur.
func nextCalendarMeeting(meetings: [CalendarMeeting], now: Date) -> CalendarMeeting? {
    meetings.filter { $0.end > now }.min { $0.start < $1.start }
}

/// Toplantının saati: bugünse "14:00–14:30", değilse gün ve saat ("3 Kas 14:00"). Saf fonksiyondur.
func calendarMeetingTimeText(meeting: CalendarMeeting, now: Date, calendar: Calendar, locale: Locale) -> String {
    let time: Date.FormatStyle = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    guard calendar.isDate(meeting.start, inSameDayAs: now) else {
        let day: Date.FormatStyle = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        return meeting.start.formatted(day)
    }
    return meeting.start.formatted(time) + "–" + meeting.end.formatted(time)
}

/// Bırakılan dosyalardan ses ve video olanlar (uzantıya göre). Saf fonksiyondur.
func mediaFileURLs(urls: [URL]) -> [URL] {
    urls.filter { (url: URL) -> Bool in
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }
        return type.conforms(to: .audio) || type.conforms(to: .audiovisualContent)
    }
}
