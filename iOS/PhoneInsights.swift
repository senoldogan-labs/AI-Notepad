import AINotepadCore
import AINotepadUI
import SwiftUI

/// İstatistikler (Mac'teki İstatistikler sayfası): toplantılardan bu iPhone'da hesaplanan sayılar ve grafikler (bkz.
/// `meetingAnalytics`); içerik Mac'le aynıdır (`MeetingAnalyticsView`). Kitaplık sayfasından açılır.
struct PhoneInsightsScreen: View {
    let store: PhoneStore
    @State private var period: AnalyticsPeriod = .month

    var body: some View {
        let analytics: MeetingAnalytics = meetingAnalytics(
            records: store.meetings, period: period, userName: store.userName, now: Date(), calendar: Calendar.current
        )
        ScrollView {
            MeetingAnalyticsView(analytics: analytics, period: $period)
                .animation(.smooth(duration: 0.25), value: period)
                .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("İstatistikler")
    }
}
