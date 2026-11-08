import AINotepadCore
import AINotepadUI
import SwiftUI

/// İstatistikler: toplantılardan bu Mac'te hesaplanan sayılar ve grafikler (bkz. `meetingAnalytics`), pencereyi dolduran
/// bir pano olarak (`MeetingAnalyticsDashboard`); iPhone aynı veriyi tek sütunda gösterir (`MeetingAnalyticsView`).
struct InsightsPage: View {
    let model: AppModel
    @State private var period: AnalyticsPeriod = .month

    var body: some View {
        let analytics: MeetingAnalytics = model.analytics(period: period)
        ScrollView {
            MeetingAnalyticsDashboard(analytics: analytics, period: $period)
                .animation(.smooth(duration: 0.25), value: period)
                .padding(.horizontal, 36)
                .padding(.top, 28)
                .padding(.bottom, 36)
                // Çok geniş ekranda satırlar okunur uzunlukta kalsın; pano ortalanır.
                .frame(maxWidth: 1600)
                .frame(maxWidth: .infinity)
        }
    }
}
