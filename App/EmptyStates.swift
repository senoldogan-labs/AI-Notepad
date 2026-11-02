import AINotepadCore
import AINotepadUI
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Mac'in boş durumları tek ailede: büyük sahne (hiç veri yokken: durgun pastel gradyanlı kart, başlık, tek satır,
// eylemler), sakin yer tutucu (seçim ya da sonuç yokken: vurgu renkli simge, kısa metin) ve satır içi kart. Simgeler ve
// ana düğme kullanıcının Görünüm'deki vurgu rengini alır; gri yalnızca ikincil yazıda. Hiçbir şey sürekli kıpırdamaz.

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
