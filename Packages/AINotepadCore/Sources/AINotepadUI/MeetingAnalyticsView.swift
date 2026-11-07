import AINotepadCore
import Charts
import SwiftUI

// İstatistikler sayfasının içeriği (Mac ve iPhone aynı): dönem seçici, özet kutuları, grafikler ve sıralı listeler.
// Veri `meetingAnalytics` ile cihazda hesaplanır; burada yalnızca gösterilir. Grafikler kullanıcının Görünüm'deki vurgu
// rengini alır; hiçbir şey sürekli kıpırdamaz.

/// İstatistikler: dönem seçici ve dönemin özeti; hiç toplantı yokken ilk açılış sahnesi.
public struct MeetingAnalyticsView: View {
    let analytics: MeetingAnalytics
    @Binding var period: AnalyticsPeriod
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    public init(analytics: MeetingAnalytics, period: Binding<AnalyticsPeriod>) {
        self.analytics = analytics
        self._period = period
    }

    public var body: some View {
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
            VStack(alignment: .leading, spacing: 18) {
                PillPicker(selection: $period, options: [
                    (value: AnalyticsPeriod.week, title: "7 gün"), (value: AnalyticsPeriod.month, title: "30 gün"),
                    (value: AnalyticsPeriod.quarter, title: "90 gün"), (value: AnalyticsPeriod.all, title: "Tümü"),
                ])
                .frame(maxWidth: 420)
                AnalyticsTiles(totals: analytics.totals, previous: analytics.previous, accent: appearance.accent.color)
                if analytics.totals.meetings == 0 {
                    EmptyStateCard(symbol: "calendar", title: "Bu dönemde toplantı yok", message: "Daha uzun bir dönem seç.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                        AnalyticsCard(title: "Toplantı saatleri", subtitle: bucketSubtitle) {
                            HoursChart(timeline: analytics.timeline, bucketSize: analytics.bucketSize, accent: appearance.accent.color)
                        }
                        AnalyticsCard(title: "Ne zaman toplanıyorsun", subtitle: "Toplantıların başladığı gün ve saat") {
                            WeekHeatmap(cells: analytics.heatmap, weekdays: analytics.weekdays, accent: appearance.accent.color)
                        }
                        if analytics.totals.tasksCreated > 0 {
                            AnalyticsCard(title: "Görevler", subtitle: "Toplantının tarihine göre açık ve tamamlanan") {
                                TasksChart(timeline: analytics.timeline, bucketSize: analytics.bucketSize, accent: appearance.accent.color)
                            }
                        }
                        if !analytics.people.isEmpty {
                            AnalyticsCard(title: "En çok görüştüğün kişiler", subtitle: "Toplantı sayısı") {
                                RankedBars(rows: analytics.people.map { (title: $0.name, count: $0.meetings) }, accent: appearance.accent.color)
                            }
                        }
                        if !analytics.folders.isEmpty {
                            AnalyticsCard(title: "Klasörler", subtitle: "Toplantı sayısı") {
                                RankedBars(rows: analytics.folders.map { (title: $0.name, count: $0.meetings) }, accent: appearance.accent.color)
                            }
                        }
                        if !analytics.templates.isEmpty {
                            AnalyticsCard(title: "Toplantı türleri", subtitle: "Not şablonuna göre") {
                                RankedBars(rows: analytics.templates.map { (title: $0.kind.displayName, count: $0.meetings) }, accent: appearance.accent.color)
                            }
                        }
                    }
                }
                Label("İstatistikler toplantılarından bu cihazda hesaplanır.", systemImage: "lock")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
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

/// Saati ve dakikayı arayüz dilinde kısa yazar ("2 sa 15 dk"). Saf fonksiyondur.
func analyticsDurationText(seconds: Double) -> String {
    let rounded: Double = (seconds / 60).rounded() * 60
    return Duration.seconds(rounded).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated).locale(interfaceLocale()))
}

/// Özet kutuları: toplantı sayısı, toplam ve ortalama süre, görevler ve notlar; önceki döneme göre değişimle.
private struct AnalyticsTiles: View {
    let totals: AnalyticsTotals
    let previous: AnalyticsTotals?
    let accent: Color

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
            tile(label: "Toplantılar", value: totals.meetings.formatted(.number.locale(interfaceLocale())), detail: nil,
                 change: change(current: Double(totals.meetings), previous: previous.map { Double($0.meetings) }))
            tile(label: "Toplantı süresi", value: analyticsDurationText(seconds: totals.seconds), detail: nil,
                 change: change(current: totals.seconds, previous: previous.map(\.seconds)))
            tile(label: "Ortalama süre", value: totals.averageSeconds.map { analyticsDurationText(seconds: $0) } ?? "–", detail: nil,
                 change: totals.averageSeconds.flatMap { (current: Double) -> Double? in
                     change(current: current, previous: previous?.averageSeconds)
                 })
            tile(label: "Görevler", value: totals.tasksCreated.formatted(.number.locale(interfaceLocale())),
                 detail: Text("\(totals.tasksCompleted) tamamlandı"),
                 change: change(current: Double(totals.tasksCreated), previous: previous.map { Double($0.tasksCreated) }))
            tile(label: "Yazılan not", value: totals.notes.formatted(.number.locale(interfaceLocale())), detail: nil,
                 change: change(current: Double(totals.notes), previous: previous.map { Double($0.notes) }))
        }
    }

    private func change(current: Double, previous: Double?) -> Double? {
        previous.flatMap { analyticsChange(current: current, previous: $0) }
    }

    private func tile(label: LocalizedStringKey, value: String, detail: Text?, change: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .appFont(size: 12, weight: .regular)
                .foregroundStyle(Theme.muted)
            Text(verbatim: value)
                .appFont(size: 24, weight: .medium)
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            // Dar kutuda değişim ve ayrıntı alt alta (yüzde ortadan bölünmesin).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { footer(change: change, detail: detail) }
                VStack(alignment: .leading, spacing: 2) { footer(change: change, detail: detail) }
            }
            .appFont(size: 12, weight: .regular)
            .frame(minHeight: 16)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 14)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func footer(change: Double?, detail: Text?) -> some View {
        if let change {
            // Artış vurgu renginde, azalış sakin gri: ikisi de uyarı değildir.
            Label {
                Text(verbatim: abs(change).formatted(.percent.precision(.fractionLength(0)).locale(interfaceLocale())))
            } icon: {
                Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
            }
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(change >= 0 ? accent : Theme.muted)
            .accessibilityLabel(Text(change >= 0 ? "Önceki döneme göre arttı" : "Önceki döneme göre azaldı"))
            .accessibilityValue(Text(verbatim: abs(change).formatted(.percent.precision(.fractionLength(0)).locale(interfaceLocale()))))
        }
        if let detail {
            detail.foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
        }
    }
}

/// Başlıklı grafik kartı.
private struct AnalyticsCard<Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let content: Content

    init(title: LocalizedStringKey, subtitle: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .appFont(size: 14, weight: .medium)
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(cornerRadius: 16)
    }
}

/// Toplantı saatleri: dönemin her aralığı için bir çubuk.
private struct HoursChart: View {
    let timeline: [AnalyticsTimePoint]
    let bucketSize: AnalyticsBucketSize
    let accent: Color

    var body: some View {
        Chart(timeline) { (point: AnalyticsTimePoint) in
            BarMark(
                x: .value(String(localized: "Tarih"), point.start, unit: analyticsCalendarComponent(size: bucketSize)),
                y: .value(String(localized: "Saat"), point.hours)
            )
            .foregroundStyle(accent.gradient)
            .cornerRadius(3)
        }
        .chartYAxis {
            AxisMarks(position: .leading) { (_: AxisValue) in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel().foregroundStyle(Theme.muted)
            }
        }
        .chartXAxis {
            AxisMarks { (_: AxisValue) in
                AxisValueLabel().foregroundStyle(Theme.muted)
            }
        }
        .environment(\.locale, interfaceLocale())
        .frame(height: 180)
        .accessibilityLabel(Text("Toplantı saatleri"))
    }
}

/// Görevler: aralıktaki toplantıların görevleri, tamamlanan (vurgu) ve açık (soluk vurgu) üst üste.
private struct TasksChart: View {
    let timeline: [AnalyticsTimePoint]
    let bucketSize: AnalyticsBucketSize
    let accent: Color

    var body: some View {
        let done: String = String(localized: "Tamamlanan")
        let open: String = String(localized: "Açık görev")
        Chart(timeline) { (point: AnalyticsTimePoint) in
            BarMark(
                x: .value(String(localized: "Tarih"), point.start, unit: analyticsCalendarComponent(size: bucketSize)),
                y: .value(String(localized: "Görevler"), point.completedTasks)
            )
            .foregroundStyle(by: .value(String(localized: "Durum"), done))
            BarMark(
                x: .value(String(localized: "Tarih"), point.start, unit: analyticsCalendarComponent(size: bucketSize)),
                y: .value(String(localized: "Görevler"), point.openTasks)
            )
            .foregroundStyle(by: .value(String(localized: "Durum"), open))
        }
        .chartForegroundStyleScale([done: accent, open: accent.opacity(0.3)])
        .chartLegend(position: .bottom, alignment: .leading)
        .chartYAxis {
            AxisMarks(position: .leading) { (_: AxisValue) in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel().foregroundStyle(Theme.muted)
            }
        }
        .chartXAxis {
            AxisMarks { (_: AxisValue) in
                AxisValueLabel().foregroundStyle(Theme.muted)
            }
        }
        .environment(\.locale, interfaceLocale())
        .frame(height: 180)
    }
}

/// Gün × saat ısı haritası: satırlar günler, sütunlar saatler; hücrenin rengi o saatte başlayan toplantı sayısıyla
/// koyulaşır (boş hücre soluk). Sütun çoksa saat etiketleri birer atlanır.
private struct WeekHeatmap: View {
    let cells: [AnalyticsHeatCell]
    let weekdays: [Int]
    let accent: Color

    var body: some View {
        let maximum: Int = max(1, cells.map(\.meetings).max() ?? 1)
        let hours: [Int] = Array(Set(cells.map(\.hour))).sorted()
        let labelStep: Int = hours.count > 10 ? 2 : 1
        let symbols: [String] = weekdaySymbols
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(weekdays, id: \.self) { (weekday: Int) in
                GridRow {
                    Text(verbatim: symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : "")
                        .appFont(size: 11, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .gridColumnAlignment(.leading)
                    ForEach(hours, id: \.self) { (hour: Int) in
                        let count: Int = cells.first { $0.weekday == weekday && $0.hour == hour }?.meetings ?? 0
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(count == 0 ? Theme.soft : accent.opacity(0.3 + 0.7 * Double(count) / Double(maximum)))
                            .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18)
                    }
                }
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                ForEach(Array(hours.enumerated()), id: \.element) { (item: (offset: Int, element: Int)) in
                    Text(verbatim: item.offset % labelStep == 0 ? String(format: "%02d", item.element) : "")
                        .appFont(size: 10, weight: .regular)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Toplantıların başladığı gün ve saat"))
    }

    /// Günlerin arayüz dilindeki kısa adları (Pazar'dan).
    private var weekdaySymbols: [String] {
        var calendar: Calendar = Calendar.current
        calendar.locale = interfaceLocale()
        return calendar.shortWeekdaySymbols
    }
}

/// Sıralı liste: ad, sayı ve en büyüğe oranlı vurgu çubuğu.
private struct RankedBars: View {
    let rows: [(title: String, count: Int)]
    let accent: Color

    var body: some View {
        let maximum: Int = max(1, rows.map(\.count).max() ?? 1)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { (item: (offset: Int, element: (title: String, count: Int))) in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(verbatim: item.element.title)
                            .appFont(size: 13, weight: .regular)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(verbatim: item.element.count.formatted(.number.locale(interfaceLocale())))
                            .appFont(size: 13, weight: .medium)
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                    }
                    GeometryReader { (proxy: GeometryProxy) in
                        Capsule()
                            .fill(accent.opacity(0.85))
                            .frame(width: max(6, proxy.size.width * Double(item.element.count) / Double(maximum)))
                    }
                    .frame(height: 6)
                    .background(Theme.soft, in: Capsule())
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
