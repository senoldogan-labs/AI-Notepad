import AINotepadCore
import Charts
import SwiftUI

// Mac'in İstatistikler panosu: başlık ve dönem seçici, dönemin tek cümlelik özeti, pencereyi boydan boya dolduran özet
// kutuları (önceki döneme göre değişim ve küçük eğri) ve ölçülen genişliğe göre 1, 2 ya da 3 sütunlu kart ızgarası.
// Satırlar `analyticsDashboardRows` ile kurulur: her satır sütunları tam doldurur, yalnız kalan kart ve boşluk olmaz;
// bir satırdaki kartlar aynı boydadır. iPhone `MeetingAnalyticsView`'u kullanır (tek sütun). Grafikler kullanıcının
// Görünüm'deki vurgu rengini alır; hiçbir şey sürekli kıpırdamaz.

/// Panonun kartları.
public enum AnalyticsDashboardCard: String, Sendable, Equatable {
    /// Toplantı saatleri grafiği.
    case time
    /// Gün × saat ısı haritası.
    case heatmap
    /// Görevler: tamamlanma halkası ve grafik.
    case tasks
    /// En çok görüşülen kişiler.
    case people
    /// Klasörler ve toplantı türleri.
    case breakdown
}

/// Izgarada bir kart ve kapladığı sütun sayısı.
public struct AnalyticsDashboardSlot: Sendable, Equatable {
    public let card: AnalyticsDashboardCard
    public let span: Int

    public init(card: AnalyticsDashboardCard, span: Int) {
        self.card = card
        self.span = span
    }
}

/// Kart ızgarasının sütun sayısı: geniş alanda 3 (ısı haritası tek sütunda okunur kalır), ortada 2, darda 1. Saf
/// fonksiyondur.
public func analyticsDashboardColumns(width: CGFloat) -> Int {
    width >= 1180 ? 3 : (width >= 720 ? 2 : 1)
}

/// Kart satırları: her satırın kartları sütunların hepsini doldurur. 3 sütunda grafik iki sütun, yanında ısı haritası;
/// sonra görevler, kişiler ve (varsa) dağılım; dağılım yoksa görevler iki sütun. 2 sütunda grafik ile ısı haritası,
/// görevler ile kişiler yan yana, dağılım tek başına boydan boya. Saf fonksiyondur.
public func analyticsDashboardRows(columns: Int, hasBreakdown: Bool) -> [[AnalyticsDashboardSlot]] {
    let lower: [AnalyticsDashboardCard] = hasBreakdown ? [.tasks, .people, .breakdown] : [.tasks, .people]
    switch columns {
    case 3...:
        let second: [AnalyticsDashboardSlot] = hasBreakdown
            ? lower.map { AnalyticsDashboardSlot(card: $0, span: 1) }
            : [AnalyticsDashboardSlot(card: .tasks, span: 2), AnalyticsDashboardSlot(card: .people, span: 1)]
        return [[AnalyticsDashboardSlot(card: .time, span: 2), AnalyticsDashboardSlot(card: .heatmap, span: 1)], second]
    case 2:
        let pairs: [[AnalyticsDashboardSlot]] = [
            [AnalyticsDashboardSlot(card: .time, span: 1), AnalyticsDashboardSlot(card: .heatmap, span: 1)],
            [AnalyticsDashboardSlot(card: .tasks, span: 1), AnalyticsDashboardSlot(card: .people, span: 1)],
        ]
        return hasBreakdown ? pairs + [[AnalyticsDashboardSlot(card: .breakdown, span: 2)]] : pairs
    default:
        return ([.time, .heatmap] + lower).map { [AnalyticsDashboardSlot(card: $0, span: 1)] }
    }
}

/// Dönem boyunca birikerek artan toplam (özet kutusunun eğrisi): seyrek günlük çubuklar yerine dönemin nasıl dolduğu
/// okunur. Saf fonksiyondur.
func analyticsRunningTotals(values: [Double]) -> [Double] {
    values.reduce(into: [Double]()) { (sums: inout [Double], value: Double) in sums.append((sums.last ?? 0) + value) }
}

/// Dönemin başından o aralığa kadarki ortalama toplantı süresi (saat); ilk toplantıdan önceki aralıklar atlanır. Saf
/// fonksiyondur.
func analyticsRunningAverages(timeline: [AnalyticsTimePoint]) -> [Double] {
    let hours: [Double] = analyticsRunningTotals(values: timeline.map(\.hours))
    let meetings: [Double] = analyticsRunningTotals(values: timeline.map { Double($0.meetings) })
    return zip(hours, meetings).compactMap { (pair: (hours: Double, meetings: Double)) -> Double? in
        pair.meetings > 0 ? pair.hours / pair.meetings : nil
    }
}

/// Isı haritasının saatleri: mesai saatleri (08–18) her zaman, dışındaki toplantılar varsa onların saatlerine kadar
/// genişler; boş hücreler de çizilir, gün boyu ritmi okunur. Saf fonksiyondur.
func analyticsHeatmapHours(cells: [AnalyticsHeatCell]) -> [Int] {
    let busy: [Int] = cells.filter { $0.meetings > 0 }.map(\.hour)
    return Array(min(8, busy.min() ?? 8)...max(18, busy.max() ?? 18))
}

/// İstatistikler panosu (Mac): başlık ve dönem seçici, özet, kutular ve kart ızgarası; hiç toplantı yokken ilk açılış
/// sahnesi.
public struct MeetingAnalyticsDashboard: View {
    let analytics: MeetingAnalytics
    @Binding var period: AnalyticsPeriod
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    /// İçeriğin ölçülen genişliği (sütun sayısı ve kart genişlikleri bundan).
    @State private var width: CGFloat = 0

    private let spacing: CGFloat = 16

    public init(analytics: MeetingAnalytics, period: Binding<AnalyticsPeriod>) {
        self.analytics = analytics
        self._period = period
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            if analytics.allTimeMeetings == 0 {
                EmptyScene(
                    symbol: "chart.bar.xaxis", palette: .ocean, title: "Henüz istatistik yok",
                    message: "İlk toplantından sonra toplantı saatlerin, görevlerin ve en çok görüştüğün kişiler burada belirir. Hepsi bu cihazda hesaplanır."
                ) {
                    EmptyView()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
            } else {
                DashboardTiles(analytics: analytics, accent: appearance.accent.color, columns: width >= 640 ? 4 : 2, spacing: spacing)
                if analytics.totals.meetings == 0 {
                    EmptyStateCard(symbol: "calendar", title: "Bu dönemde toplantı yok", message: "Daha uzun bir dönem seç.")
                } else {
                    grid
                }
                Label("İstatistikler toplantılarından bu cihazda hesaplanır.", systemImage: "lock")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { (proxy: GeometryProxy) -> CGFloat in
            proxy.size.width
        } action: { (newWidth: CGFloat) -> Void in
            width = newWidth
        }
    }

    /// Başlık, dönem seçici ve dönemin tek satırlık özeti.
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                Text("İstatistikler")
                    .appFont(size: 28, weight: .regular)
                    .tracking(-0.4)
                Spacer(minLength: 0)
                if analytics.allTimeMeetings > 0 {
                    PillPicker(selection: $period, options: [
                        (value: AnalyticsPeriod.week, title: "7 gün"), (value: AnalyticsPeriod.month, title: "30 gün"),
                        (value: AnalyticsPeriod.quarter, title: "90 gün"), (value: AnalyticsPeriod.all, title: "Tümü"),
                    ])
                    .frame(width: 320)
                }
            }
            if analytics.allTimeMeetings > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text(periodTitle)
                        .appFont(size: 11, weight: .semibold)
                        .tracking(DesignTokens.labelTracking)
                        .textCase(.uppercase)
                        .foregroundStyle(appearance.accent.color)
                    summary
                        .appFont(size: 18, weight: .regular)
                        .foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                }
            }
        }
    }

    /// "11 toplantı · 57 dk · 3 açık görev": dönemin sayıları tek satırda (dil bağımsız ayraçla).
    private var summary: Text {
        let totals: AnalyticsTotals = analytics.totals
        guard totals.meetings > 0 else {
            return Text("Bu dönemde toplantı yok")
        }
        let separator: Text = Text(verbatim: "  ·  ").foregroundStyle(Theme.muted)
        let base: Text = Text("\(totals.meetings) toplantı") + separator + Text(verbatim: analyticsDurationText(seconds: totals.seconds))
        let open: Int = totals.tasksCreated - totals.tasksCompleted
        return open > 0 ? base + separator + Text("\(open) açık görev") : base
    }

    private var periodTitle: LocalizedStringKey {
        switch period {
        case .week: "Son 7 gün"
        case .month: "Son 30 gün"
        case .quarter: "Son 90 gün"
        case .all: "Tüm zamanlar"
        }
    }

    /// Kart ızgarası: satırlar `analyticsDashboardRows`'tan, kart genişliği kapladığı sütunlardan.
    private var grid: some View {
        let hasBreakdown: Bool = !analytics.folders.isEmpty || !analytics.templates.isEmpty
        let columns: Int = analyticsDashboardColumns(width: width)
        let rows: [[AnalyticsDashboardSlot]] = analyticsDashboardRows(columns: columns, hasBreakdown: hasBreakdown)
        let unit: CGFloat = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        return VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { (row: (offset: Int, element: [AnalyticsDashboardSlot])) in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(row.element, id: \.card) { (slot: AnalyticsDashboardSlot) in
                        card(slot: slot)
                            .frame(width: unit * CGFloat(slot.span) + spacing * CGFloat(slot.span - 1))
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                // Satırdaki kartlar en uzununun boyunda.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func card(slot: AnalyticsDashboardSlot) -> some View {
        let accent: Color = appearance.accent.color
        switch slot.card {
        case .time:
            DashboardCard(title: "Toplantı saatleri", subtitle: bucketSubtitle) {
                Text(verbatim: analyticsDurationText(seconds: analytics.totals.seconds))
                    .appFont(size: 20, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
            } content: {
                HoursChart(timeline: analytics.timeline, bucketSize: analytics.bucketSize, accent: accent, height: 200)
            }
        case .heatmap:
            DashboardCard(title: "Ne zaman toplanıyorsun", subtitle: "Toplantıların başladığı gün ve saat") {
                EmptyView()
            } content: {
                let hours: [Int] = analyticsHeatmapHours(cells: analytics.heatmap)
                WeekHeatmap(
                    cells: analytics.heatmap, weekdays: analytics.weekdays, hours: hours,
                    labeledHours: Set(hours.filter { $0 % (hours.count > 12 ? 3 : 2) == 0 }),
                    weekdayNames: analyticsWeekdayFullNames(), accent: accent, cellHeight: 24
                )
            }
        case .tasks:
            DashboardCard(title: "Görevler", subtitle: "Toplantının tarihine göre açık ve tamamlanan") {
                EmptyView()
            } content: {
                if analytics.totals.tasksCreated == 0 {
                    EmptyStatePlaceholder(symbol: "checklist", title: "Bu dönemde görev yok", message: "Notlardaki görevler burada sayılır.")
                        .frame(minHeight: 170)
                } else {
                    TasksSummary(totals: analytics.totals, timeline: analytics.timeline, bucketSize: analytics.bucketSize, accent: accent)
                }
            }
        case .people:
            DashboardCard(title: "En çok görüştüğün kişiler", subtitle: "Toplantı sayısı") {
                EmptyView()
            } content: {
                if analytics.people.isEmpty {
                    EmptyStatePlaceholder(
                        symbol: "person.2", title: "Henüz adı verilen kişi yok",
                        message: "Transkriptte konuşmacılara ad verince burada görünürler."
                    )
                    .frame(minHeight: 170)
                } else {
                    PeopleBars(people: analytics.people, accent: accent)
                }
            }
        case .breakdown:
            BreakdownCard(folders: analytics.folders, templates: analytics.templates, accent: accent, span: slot.span)
        }
    }

    private var bucketSubtitle: LocalizedStringKey {
        switch analytics.bucketSize {
        case .day: "Günlük"
        case .week: "Haftalık"
        case .month: "Aylık"
        }
    }
}

/// Günlerin arayüz dilindeki tam adları (Pazar'dan; "Çarşamba"): panonun ısı haritası her genişlikte bunlara yer açar.
func analyticsWeekdayFullNames() -> [String] {
    analyticsInterfaceCalendar().standaloneWeekdaySymbols
}

/// Günlerin arayüz dilindeki kısa adları (Pazar'dan; "Çar"): iPhone'un dar ısı haritası.
func analyticsWeekdayShortNames() -> [String] {
    analyticsInterfaceCalendar().shortStandaloneWeekdaySymbols
}

private func analyticsInterfaceCalendar() -> Calendar {
    var calendar: Calendar = Calendar.current
    calendar.locale = interfaceLocale()
    return calendar
}

/// Saatin arayüz dilindeki kısa adı ("9 AM", "09"). Saf fonksiyondur.
func analyticsHourLabel(hour: Int, locale: Locale) -> String {
    // 1 Ocak 1970'in o saati, GMT'de biçimlenir: yaz saati ya da yerel saat dilimi saati kaydırmaz.
    let date: Date = Date(timeIntervalSince1970: Double(hour) * 3600)
    var style: Date.FormatStyle = Date.FormatStyle(locale: locale).hour(.defaultDigits(amPM: .abbreviated))
    style.timeZone = .gmt
    return date.formatted(style)
}

/// Pano kartı: başlık, alt başlık, sağda isteğe bağlı bir değer ve içerik.
private struct DashboardCard<Accessory: View, Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let accessory: Accessory
    let content: Content

    init(title: LocalizedStringKey, subtitle: LocalizedStringKey, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .appFont(size: 14, weight: .medium)
                        .foregroundStyle(Theme.ink)
                    Text(subtitle)
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
                accessory
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface(cornerRadius: 16)
    }
}

/// Özet kutuları: toplantılar, toplam ve ortalama süre, görevler; her biri önceki döneme göre değişim ve dönemin küçük
/// eğrisiyle. Kutular satırı boydan boya doldurur (geniş 4, dar 2 sütun).
private struct DashboardTiles: View {
    let analytics: MeetingAnalytics
    let accent: Color
    let columns: Int
    let spacing: CGFloat

    var body: some View {
        let totals: AnalyticsTotals = analytics.totals
        let previous: AnalyticsTotals? = analytics.previous
        let timeline: [AnalyticsTimePoint] = analytics.timeline
        let tiles: [DashboardTileData] = [
            DashboardTileData(
                label: "Toplantılar", value: totals.meetings.formatted(.number.locale(interfaceLocale())), detail: nil,
                change: change(current: Double(totals.meetings), previous: previous.map { Double($0.meetings) }),
                series: analyticsRunningTotals(values: timeline.map { Double($0.meetings) })
            ),
            DashboardTileData(
                label: "Toplantı süresi", value: analyticsDurationText(seconds: totals.seconds), detail: nil,
                change: change(current: totals.seconds, previous: previous.map(\.seconds)),
                series: analyticsRunningTotals(values: timeline.map(\.hours))
            ),
            DashboardTileData(
                label: "Ortalama süre", value: totals.averageSeconds.map { analyticsDurationText(seconds: $0) } ?? "–", detail: nil,
                change: totals.averageSeconds.flatMap { (current: Double) -> Double? in change(current: current, previous: previous?.averageSeconds) },
                series: analyticsRunningAverages(timeline: timeline)
            ),
            // Görevlerim'le aynı sayı: toplam görevin kaçı sana düşüyor (Görevlerim yalnız seninkileri sayar).
            DashboardTileData(
                label: "Görevler", value: totals.tasksCreated.formatted(.number.locale(interfaceLocale())), detail: Text("\(totals.tasksMine) sana düşen"),
                change: change(current: Double(totals.tasksCreated), previous: previous.map { Double($0.tasksCreated) }),
                series: analyticsRunningTotals(values: timeline.map { Double($0.openTasks + $0.completedTasks) })
            ),
        ]
        // Satır satır: bir satırdaki kutular aynı boyda.
        let rows: [[DashboardTileData]] = stride(from: 0, to: tiles.count, by: columns).map { Array(tiles[$0..<min($0 + columns, tiles.count)]) }
        VStack(spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { (row: (offset: Int, element: [DashboardTileData])) in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(Array(row.element.enumerated()), id: \.offset) { (item: (offset: Int, element: DashboardTileData)) in
                        DashboardTile(data: item.element, accent: accent)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func change(current: Double, previous: Double?) -> Double? {
        previous.flatMap { analyticsChange(current: current, previous: $0) }
    }
}

/// Bir özet kutusunun verisi.
private struct DashboardTileData {
    let label: LocalizedStringKey
    let value: String
    /// Değişimin yanında ek bilgi (ör. "9 sana düşen").
    let detail: Text?
    /// Önceki döneme göre değişim oranı; önceki dönem yoksa ya da sıfırsa nil.
    let change: Double?
    /// Küçük eğrinin değerleri (dönem boyunca birikerek).
    let series: [Double]
}

/// Bir özet kutusu: etiket, büyük değer, değişim (artış vurgu renginde, azalış sakin gri; ikisi de uyarı değildir) ve
/// sağ altta dönemin eğrisi.
private struct DashboardTile: View {
    let data: DashboardTileData
    let accent: Color

    private var label: LocalizedStringKey { data.label }
    private var value: String { data.value }
    private var detail: Text? { data.detail }
    private var change: Double? { data.change }
    private var series: [Double] { data.series }

    var body: some View {
        // Eğri etiketin yanında, değer kutunun bütün genişliğinde: uzun süreler ("12 sa 36 dk") kesilmez.
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Text(label)
                    .appFont(size: 12, weight: .medium)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Sparkline(values: series, accent: accent)
                    .frame(width: 84, height: 30)
            }
            Text(verbatim: value)
                .appFont(size: 28, weight: .medium)
                .tracking(-0.4)
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            footer
                .appFont(size: 12, weight: .regular)
                .frame(minHeight: 16)
                .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface(cornerRadius: 14)
        .accessibilityElement(children: .combine)
    }

    /// Üstte değişim ve ayrıntı, altta "önceki döneme göre": her kutuda aynı iki satır, kutular aynı boyda kalır.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) { changeItems }
            if change != nil {
                Text("önceki döneme göre")
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var changeItems: some View {
        if let change {
            let percent: String = abs(change).formatted(.percent.precision(.fractionLength(0)).locale(interfaceLocale()))
            Label {
                Text(verbatim: percent)
            } icon: {
                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
            }
            .labelStyle(.titleAndIcon)
            .appFont(size: 11, weight: .semibold)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(change >= 0 ? accent : Theme.muted)
            .background((change >= 0 ? accent : Theme.muted).opacity(0.12), in: Capsule())
            .accessibilityLabel(Text(change >= 0 ? "Önceki döneme göre arttı" : "Önceki döneme göre azaldı"))
            .accessibilityValue(Text(verbatim: percent))
        }
        if let detail {
            detail.foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
        }
    }
}

/// Dönemin küçük eğrisi (birikerek artan toplam): eksensiz, vurgu renginde çizgi ve altında soluk dolgu. İki noktadan azsa ya da hepsi sıfırsa
/// boş kalır (kutular yine aynı boyda).
private struct Sparkline: View {
    let values: [Double]
    let accent: Color

    var body: some View {
        if values.count >= 2, values.contains(where: { $0 > 0 }) {
            Chart(Array(values.enumerated()), id: \.offset) { (item: (offset: Int, element: Double)) in
                AreaMark(x: .value(String(localized: "Tarih"), item.offset), y: .value(String(localized: "Değer"), item.element))
                    .foregroundStyle(LinearGradient(colors: [accent.opacity(0.28), accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value(String(localized: "Tarih"), item.offset), y: .value(String(localized: "Değer"), item.element))
                    .foregroundStyle(accent)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartYScale(domain: 0...(values.max() ?? 1) * 1.1)
            .accessibilityHidden(true)
        } else {
            Color.clear.accessibilityHidden(true)
        }
    }
}

/// Görevler kartının içeriği: tamamlanma halkası, sayılar ve dönemin açık/tamamlanan grafiği.
private struct TasksSummary: View {
    let totals: AnalyticsTotals
    let timeline: [AnalyticsTimePoint]
    let bucketSize: AnalyticsBucketSize
    let accent: Color

    var body: some View {
        let ratio: Double = totals.tasksCreated > 0 ? Double(totals.tasksCompleted) / Double(totals.tasksCreated) : 0
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    Circle().stroke(Theme.soft, lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: ratio)
                        .stroke(accent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(verbatim: ratio.formatted(.percent.precision(.fractionLength(0)).locale(interfaceLocale())))
                            .appFont(size: 18, weight: .medium)
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink)
                        Text("tamamlandı")
                            .appFont(size: 10, weight: .regular)
                            .foregroundStyle(Theme.muted)
                    }
                }
                .frame(width: 88, height: 88)
                .accessibilityElement(children: .combine)
                VStack(alignment: .leading, spacing: 8) {
                    legend(color: accent, title: "Tamamlanan", count: totals.tasksCompleted)
                    legend(color: accent.opacity(0.3), title: "Açık görev", count: totals.tasksCreated - totals.tasksCompleted)
                    Text("\(totals.tasksMine) sana düşen")
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
            }
            TasksChart(timeline: timeline, bucketSize: bucketSize, accent: accent, height: 110)
                .chartLegend(.hidden)
        }
    }

    private func legend(color: Color, title: LocalizedStringKey, count: Int) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
                .appFont(size: 13, weight: .regular)
                .foregroundStyle(Theme.ink)
            Text(verbatim: count.formatted(.number.locale(interfaceLocale())))
                .appFont(size: 13, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
        }
        .accessibilityElement(children: .combine)
    }
}

/// En çok görüşülen kişiler: harf rozeti, ad, toplantı sayısı ve en büyüğe oranlı çubuk.
private struct PeopleBars: View {
    let people: [AnalyticsRankedName]
    let accent: Color

    var body: some View {
        let maximum: Int = max(1, people.map(\.meetings).max() ?? 1)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(people) { (person: AnalyticsRankedName) in
                HStack(spacing: 10) {
                    PersonAvatar(name: person.name, size: 26)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(verbatim: person.name)
                                .appFont(size: 13, weight: .regular)
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(verbatim: person.meetings.formatted(.number.locale(interfaceLocale())))
                                .appFont(size: 13, weight: .medium)
                                .monospacedDigit()
                                .foregroundStyle(Theme.muted)
                        }
                        ProportionBar(fraction: Double(person.meetings) / Double(maximum), accent: accent)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Oranlı yatay çubuk (soluk iz üstünde vurgu).
private struct ProportionBar: View {
    let fraction: Double
    let accent: Color

    var body: some View {
        GeometryReader { (proxy: GeometryProxy) in
            Capsule()
                .fill(accent.opacity(0.85))
                .frame(width: max(6, proxy.size.width * fraction))
        }
        .frame(height: 6)
        .background(Theme.soft, in: Capsule())
    }
}

/// Klasörler ve toplantı türleri tek kartta: geniş kartta yan yana, darda alt alta; yalnız biri varsa o.
private struct BreakdownCard: View {
    let folders: [AnalyticsRankedName]
    let templates: [AnalyticsTemplateCount]
    let accent: Color
    let span: Int

    var body: some View {
        let sections: AnyLayout = span > 1 ? AnyLayout(HStackLayout(alignment: .top, spacing: 32)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 22))
        sections {
            if !folders.isEmpty {
                section(title: "Klasörler", subtitle: "Toplantı sayısı", rows: folders.map { (title: $0.name, count: $0.meetings) })
            }
            if !templates.isEmpty {
                section(title: "Toplantı türleri", subtitle: "Not şablonuna göre", rows: templates.map { (title: $0.kind.displayName, count: $0.meetings) })
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface(cornerRadius: 16)
    }

    private func section(title: LocalizedStringKey, subtitle: LocalizedStringKey, rows: [(title: String, count: Int)]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .appFont(size: 14, weight: .medium)
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
            RankedBars(rows: rows, accent: accent)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
