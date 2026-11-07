import AINotepadCore
import AINotepadUI
import SwiftUI

/// İstatistikler: toplantılardan bu Mac'te hesaplanan sayılar ve grafikler (bkz. `meetingAnalytics`); içerik iPhone'la
/// aynıdır (`MeetingAnalyticsView`).
struct InsightsPage: View {
    let model: AppModel
    @State private var period: AnalyticsPeriod = .month

    var body: some View {
        let analytics: MeetingAnalytics = model.analytics(period: period)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("İstatistikler")
                    .appFont(size: 28, weight: .regular)
                    .tracking(-0.4)
                MeetingAnalyticsView(analytics: analytics, period: $period)
            }
            .animation(.smooth(duration: 0.25), value: period)
            .padding(36)
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}
