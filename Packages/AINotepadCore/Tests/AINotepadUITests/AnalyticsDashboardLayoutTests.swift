import AINotepadCore
import CoreGraphics
import Foundation
import Testing
@testable import AINotepadUI

@Suite struct AnalyticsDashboardLayoutTests {
    @Test func columnsFollowWidth() {
        #expect(analyticsDashboardColumns(width: 600) == 1)
        #expect(analyticsDashboardColumns(width: 980) == 2)
        #expect(analyticsDashboardColumns(width: 1370) == 3)
    }

    /// Her satır sütunları tam doldurur ve her kart bir kez yer alır: yalnız kalan kart ya da boşluk olmaz.
    @Test func everyRowFillsTheColumns() {
        for columns in 1...3 {
            for hasBreakdown in [false, true] {
                let rows: [[AnalyticsDashboardSlot]] = analyticsDashboardRows(columns: columns, hasBreakdown: hasBreakdown)
                for row in rows {
                    #expect(row.map(\.span).reduce(0, +) == columns, "columns: \(columns), breakdown: \(hasBreakdown)")
                }
                let cards: [AnalyticsDashboardCard] = rows.flatMap { $0.map(\.card) }
                let expected: [AnalyticsDashboardCard] = hasBreakdown ? [.time, .heatmap, .tasks, .people, .breakdown] : [.time, .heatmap, .tasks, .people]
                #expect(cards == expected)
            }
        }
    }

    @Test func wideLayoutPairsChartWithHeatmap() {
        #expect(analyticsDashboardRows(columns: 3, hasBreakdown: false) == [
            [AnalyticsDashboardSlot(card: .time, span: 2), AnalyticsDashboardSlot(card: .heatmap, span: 1)],
            [AnalyticsDashboardSlot(card: .tasks, span: 2), AnalyticsDashboardSlot(card: .people, span: 1)],
        ])
    }

    @Test func sparklinesAccumulateOverThePeriod() {
        #expect(analyticsRunningTotals(values: [0, 2, 0, 1]) == [0, 2, 2, 3])
        let start: Date = Date(timeIntervalSince1970: 0)
        let timeline: [AnalyticsTimePoint] = [(0.0, 0), (1.0, 2), (0.5, 1)].enumerated().map { (item: (offset: Int, element: (Double, Int))) -> AnalyticsTimePoint in
            AnalyticsTimePoint(start: start.addingTimeInterval(Double(item.offset) * 86_400), hours: item.element.0, meetings: item.element.1, openTasks: 0, completedTasks: 0)
        }
        // İlk toplantıdan önceki gün atlanır; sonra (1 sa / 2), (1,5 sa / 3).
        #expect(analyticsRunningAverages(timeline: timeline) == [0.5, 0.5])
    }

    @Test func heatmapCoversWorkingHoursAndOutliers() {
        #expect(analyticsHeatmapHours(cells: []) == Array(8...18))
        let early: [AnalyticsHeatCell] = [AnalyticsHeatCell(weekday: 2, hour: 7, meetings: 1), AnalyticsHeatCell(weekday: 2, hour: 20, meetings: 2)]
        #expect(analyticsHeatmapHours(cells: early) == Array(7...20))
        // Boş hücre aralığı genişletmez.
        #expect(analyticsHeatmapHours(cells: [AnalyticsHeatCell(weekday: 3, hour: 22, meetings: 0)]) == Array(8...18))
    }
}
