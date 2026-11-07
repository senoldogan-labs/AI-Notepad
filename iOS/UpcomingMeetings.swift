import AINotepadCore
import AINotepadUI
import SwiftUI

/// Ana ekranda sıradaki toplantılar (takvim açıksa, önümüzdeki 12 saat): saat, başlık, katılımcılar; görüşme
/// bağlantısı varsa "Katıl", arşivde toplantı varsa "Brifing". Süren toplantı "Şimdi" ile işaretlenir: o sırada başlatılan
/// kayıt onun adını alır. Altında bugün biten toplantılar (Mac'teki gibi): kaydı olanın notu buradan açılır. İkisi de
/// boşsa bölüm görünmez. Takvim izni yoksa kısa bir uyarı ve Ayarlar'a geçiş.
struct UpcomingCalendarSection: View {
    let calendar: PhoneCalendar
    let router: PhoneRouter
    /// Bugün biten toplantının kaydı arşivde aranır (sekmelerin ortamından).
    @Environment(PhoneStore.self) private var store: PhoneStore
    /// Arşivde toplantı var: brifing sorulabilir (boş arşivde düğme görünmez, Mac'teki gibi).
    let canBrief: Bool
    let onBriefing: @MainActor (CalendarMeeting) -> Void

    var body: some View {
        switch calendar.state {
        case .on:
            // Saat ilerledikçe (dakikada bir) "Şimdi", vurgular ve biten toplantılar güncellenir; liste yalnız takvim
            // değişince çizilseydi eskirdi.
            TimelineView(.everyMinute) { (context: TimelineViewDefaultContext) in
                let now: Date = context.date
                let items: [CalendarMeeting] = upcomingMeetings(meetings: calendar.meetings, now: now, horizonSec: 12 * 3600)
                let current: CalendarMeeting? = currentMeeting(meetings: calendar.meetings, now: now)
                let ended: [CalendarMeeting] = meetingsEndedToday(meetings: calendar.meetings, now: now, calendar: Calendar.current)
                // Sıradaki ve bugün biten toplantı yoksa bölüm hiç görünmez (boş ana ekran sade kalsın).
                if !items.isEmpty || !ended.isEmpty {
                    VStack(alignment: .leading, spacing: 18) {
                        if !items.isEmpty {
                            group(title: "Sıradaki toplantılar", meetings: Array(items.prefix(4))) { (meeting: CalendarMeeting) in
                                UpcomingMeetingRow(meeting: meeting, isCurrent: meeting.id == current?.id, now: now, canBrief: canBrief, onBriefing: onBriefing)
                            }
                        }
                        if !ended.isEmpty {
                            group(title: "Bugün biten toplantılar", meetings: Array(ended.prefix(4))) { (meeting: CalendarMeeting) in
                                EndedMeetingRow(meeting: meeting, record: recordedMeeting(meeting: meeting, records: store.meetings), userName: store.userName) { (meetingID: String) -> Void in
                                    router.open(meetingID: meetingID)
                                }
                            }
                        }
                    }
                }
            }
        case .denied:
            Button {
                router.push(route: .settings)
            } label: {
                Label("Takvime erişim izni yok; sıradaki toplantılar görünmüyor. Ayarlar'a git.", systemImage: "calendar.badge.exclamationmark")
                    .appFont(size: 13, weight: .regular)
                    .foregroundStyle(NoticeSeverity.attention.tint)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        case .failed(let message):
            PhoneErrorList(messages: [message])
        case .off:
            EmptyView()
        }
    }

    /// Başlıklı kart: satırlar arasında ince çizgi.
    private func group(title: LocalizedStringKey, meetings: [CalendarMeeting], @ViewBuilder row: @escaping (CalendarMeeting) -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PhoneSectionHeader(title: title, actionTitle: nil, action: nil)
            VStack(spacing: 0) {
                ForEach(Array(meetings.enumerated()), id: \.element.id) { (item: (offset: Int, element: CalendarMeeting)) in
                    if item.offset > 0 {
                        Rectangle().fill(Theme.line).frame(height: 1).padding(.leading, 14)
                    }
                    row(item.element)
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
        }
    }
}

/// Bugün biten toplantı satırı (Mac'teki gibi): saat aralığı, başlık ve notun özeti; kaydı varsa "Notu aç" (not henüz
/// yoksa "Kaydı aç") toplantıyı Toplantılar'da açar, yoksa "Kaydedilmedi".
private struct EndedMeetingRow: View {
    let meeting: CalendarMeeting
    /// Etkinliğin kaydı (bkz. `recordedMeeting`); yoksa nil.
    let record: MeetingRecord?
    /// Yüklü hesabın adı (özetteki "Sen" etiketi için; bkz. `PhoneStore.userName`).
    let userName: String
    let onOpen: @MainActor (String) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let format: Date.FormatStyle = Date.FormatStyle(date: .omitted, time: .shortened).locale(interfaceLocale())
        let time: String = meeting.start.formatted(format) + "–" + meeting.end.formatted(format)
        // Özetteki konuşmacı etiketleri adlarla (notun kendisindeki gibi).
        let summary: String? = record.map { namedRecord(record: $0, userName: userName) }?.note?.summary
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: time)
                    .appFont(size: 12, weight: .medium)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                Text(meeting.title)
                    .appFont(size: 15, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if let summary, !summary.isEmpty {
                    Text(summary)
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let record {
                Button {
                    onOpen(record.id)
                } label: {
                    Text(record.note == nil ? LocalizedStringKey("Kaydı aç") : LocalizedStringKey("Notu aç"))
                        .appFont(size: 13, weight: .semibold)
                        .foregroundStyle(appearance.accent.color)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(appearance.accent.color.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(record.note == nil ? Text("Kaydı aç: \(meeting.title)") : Text("Notu aç: \(meeting.title)"))
            } else {
                Text("Kaydedilmedi")
                    .appFont(size: 12, weight: .regular)
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// Sıradaki toplantı satırı: saat aralığı (süren ya da 10 dk içinde başlayan vurgulu), başlık, katılımcılar, "Brifing" ve
/// "Katıl".
private struct UpcomingMeetingRow: View {
    let meeting: CalendarMeeting
    /// Şu an süren toplantı: yeni kayıt buna bağlanır.
    let isCurrent: Bool
    let now: Date
    let canBrief: Bool
    /// Brifing: bu kişilerle ya da konuda önceki toplantılar, kararlar ve açık görevler (Sor'da açılır).
    let onBriefing: @MainActor (CalendarMeeting) -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize: DynamicTypeSize

    var body: some View {
        // Erişilebilirlik boyutlarında düğmeler başlığın altına iner (yan yana saat dört satıra, başlık "Viikkop…"a
        // bölünüyordu).
        let isLarge: Bool = dynamicTypeSize.isAccessibilitySize
        let rowLayout: AnyLayout = isLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        let isSoon: Bool = isCurrent || meeting.start.timeIntervalSince(now) <= 600
        let format: Date.FormatStyle = Date.FormatStyle(date: .omitted, time: .shortened).locale(interfaceLocale())
        let time: String = meeting.start.formatted(format) + "–" + meeting.end.formatted(format)
        rowLayout {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isCurrent {
                        Text("Şimdi")
                            .appFont(size: 12, weight: .semibold)
                            .foregroundStyle(appearance.accent.color)
                    }
                    Text(verbatim: time)
                        .appFont(size: 12, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(isSoon ? appearance.accent.color : Theme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(meeting.title)
                    .appFont(size: 15, weight: .medium)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(isLarge ? 3 : 1)
                if !meeting.attendees.isEmpty {
                    Text(verbatim: meeting.attendees.prefix(3).joined(separator: ", ") + (meeting.attendees.count > 3 ? " +\(meeting.attendees.count - 3)" : ""))
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            if !isLarge {
                Spacer(minLength: 8)
            }
            HStack(spacing: 8) {
                if canBrief {
                    Button {
                        onBriefing(meeting)
                    } label: {
                        Text("Brifing")
                            .appFont(size: 13, weight: .semibold)
                            .foregroundStyle(appearance.accent.color)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(appearance.accent.color.opacity(0.14), in: Capsule())
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Brifing: \(meeting.title)"))
                    .accessibilityHint(Text("Bu kişilerle ve konuda önceki toplantılar, kararlar, açık görevler"))
                }
                if let url = meeting.joinURL {
                    Link(destination: url) {
                        Text("Katıl")
                            .appFont(size: 13, weight: .semibold)
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Theme.soft, in: Capsule())
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(Text("Görüşmeye katıl: \(meeting.title)"))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
