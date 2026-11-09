import AINotepadCore
import AINotepadUI
import SwiftUI

/// Görevlerim sayfasının süzgeci.
private enum TaskFilter: Hashable {
    case open
    case done
}

/// Görevlerim: toplantı notlarında sana yazılan işler. Açık görevler son günlerine göre gruplu (gecikmiş, bugün,
/// önümüzdeki 7 gün, daha sonra, tarihsiz; grup içinde yakın tarih önce), tamamlananlar toplantıya göre (en yeni
/// toplantı önce); üstte ilerleme. Satır sağa kaydırılınca tamamlanır, sola kaydırılınca toplantı açılır (elle eklenen
/// görev silinir); "+" ile elle görev eklenir. İşaretler toplantıya yazılır (Mac'te de aynı işaret görünür).
struct TasksTab: View {
    let store: PhoneStore
    let router: PhoneRouter
    @State private var filter: TaskFilter = .open
    @State private var isAdding: Bool = false
    /// Kullanıcının adı (Ayarlar): girilince "Adını yaz" düğmesi hemen kalksın.
    private var userName: String { store.userName }
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        let all: [(record: MeetingRecord, task: NoteTask)] = myTasks(meetings: store.meetings, userName: userName)
        let doneCount: Int = all.filter { isTaskDone(record: $0.record, task: $0.task) }.count
        let open: [(record: MeetingRecord, task: NoteTask)] = all.filter { !isTaskDone(record: $0.record, task: $0.task) }
        let done: [(record: MeetingRecord, task: NoteTask)] = all.filter { isTaskDone(record: $0.record, task: $0.task) }
        Group {
            if all.isEmpty {
                // Hiç görev yok: ilerleme ve süzgeç yerine yalnız ortada boş durum; konuşmacısı seçilmemiş yüz yüze
                // toplantı varsa üstte (görevleri seçilince buraya gelir).
                VStack(spacing: 0) {
                    pendingSpeakerMeetings
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    emptyState(hasTasks: false, doneCount: 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(Theme.background)
                .navigationTitle("Görevlerim")
            } else {
                taskList(all: all, doneCount: doneCount, open: open, done: done)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Görev ekle", systemImage: "plus") { isAdding = true }
                    .disabled(addableMeetings.isEmpty)
            }
        }
        .sheet(isPresented: $isAdding) {
            NavigationStack {
                AddTaskForm(meetings: addableMeetings, fixedMeetingID: nil) { (meetingID: String, text: String, dueDay: Date?) -> Void in
                    store.addTask(meetingID: meetingID, description: text, dueDay: dueDay)
                    isAdding = false
                } onCancel: {
                    isAdding = false
                }
                .navigationTitle("Görev ekle")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// Görev eklenebilecek toplantılar: notu olan, örnek olmayan, kayıtta ya da işlenmekte olmayan (en yeni önce).
    private var addableMeetings: [MeetingRecord] {
        store.meetings.filter { $0.note != nil && !$0.isSampleMeeting && $0.status != .recording && $0.status != .processing }
    }

    /// Görev listesi: ilerleme, süzgeç ve gruplu görevler; süzgeçte görev yoksa ortada boş durum.
    private func taskList(
        all: [(record: MeetingRecord, task: NoteTask)], doneCount: Int, open: [(record: MeetingRecord, task: NoteTask)],
        done: [(record: MeetingRecord, task: NoteTask)]
    ) -> some View {
        let shown: [(record: MeetingRecord, task: NoteTask)] = filter == .done ? done : open
        let sections: [TaskSection] = filter == .done
            ? doneSections(done: done)
            : groupedByDueDay(items: open, now: Date(), calendar: Calendar.current).map { (group: TaskDueGroup) -> TaskSection in
                TaskSection(id: "\(group.bucket.rawValue)", title: taskDueBucketTitle(bucket: group.bucket), isOverdue: group.bucket == .overdue, items: group.tasks)
            }
        return List {
            Section {
                VStack(alignment: .leading, spacing: 18) {
                    // Görev işareti saklanamadıysa (ya da toplantı işlenirken) nedeni burada.
                    PhoneDismissibleErrorList(messages: store.actionProblems) { store.dismissActionProblems() }
                    if filter == .open {
                        pendingSpeakerMeetings
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(verbatim: "\(doneCount)/\(all.count)")
                                .appFont(size: 30, weight: .regular)
                                .tracking(-0.6)
                                .monospacedDigit()
                            Text("tamamlandı")
                                .appFont(size: 14, weight: .regular)
                                .foregroundStyle(Theme.muted)
                        }
                        ProgressView(value: Double(doneCount), total: Double(max(all.count, 1)))
                            .tint(appearance.accent.color)
                    }
                    PillTabs(selection: $filter, options: [
                        (TaskFilter.open, "Açık · \(all.count - doneCount)"),
                        (TaskFilter.done, "Tamamlanan · \(doneCount)"),
                    ])
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            ForEach(sections, id: \.id) { (section: TaskSection) in
                Section {
                    ForEach(section.items, id: \.rowID) { (item: DatedTask) in
                        row(item: item)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(verbatim: section.title)
                            .foregroundStyle(section.isOverdue ? NoticeSeverity.error.tint : Theme.ink)
                            .lineLimit(1)
                        Text(verbatim: "\(section.items.count)")
                            .foregroundStyle(Theme.muted)
                            .monospacedDigit()
                    }
                    .appFont(size: 13, weight: .semibold)
                    .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .animation(.smooth(duration: 0.3), value: shown.map(\.task.trackingKey))
        .overlay {
            if shown.isEmpty {
                emptyState(hasTasks: !all.isEmpty, doneCount: doneCount)
            }
        }
        .background(Theme.background)
        .navigationTitle("Görevlerim")
    }

    /// Tamamlananlar: toplantıya göre (en yeni toplantı önce), başlık toplantının adı.
    private func doneSections(done: [(record: MeetingRecord, task: NoteTask)]) -> [TaskSection] {
        done.reduce(into: [TaskSection]()) { (result: inout [TaskSection], item: (record: MeetingRecord, task: NoteTask)) -> Void in
            let dated: DatedTask = DatedTask(record: item.record, task: item.task, due: nil)
            if let last = result.last, last.id == item.record.id {
                result[result.count - 1] = TaskSection(id: last.id, title: last.title, isOverdue: false, items: last.items + [dated])
            } else {
                result.append(TaskSection(id: item.record.id, title: item.record.note?.title ?? item.record.title, isOverdue: false, items: [dated]))
            }
        }
    }

    /// Görev satırı: kutuya dokununca işaretlenir; sağa kaydırınca tamamlanır (tamamlananda geri alınır), sola
    /// kaydırınca toplantı açılır ya da elle eklenen görev silinir. Açık görevlerde altta toplantının adı.
    private func row(item: DatedTask) -> some View {
        let isDone: Bool = isTaskDone(record: item.record, task: item.task)
        return PhoneTaskRowContent(record: item.record, task: item.task, showsMeeting: filter == .open, metrics: .regular) {
            withAnimation(.smooth(duration: 0.25)) {
                store.toggleTask(meetingID: item.record.id, task: item.task)
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Theme.card)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(isDone ? "Tamamlanmadı olarak işaretle" : "Tamamlandı olarak işaretle", systemImage: isDone ? "arrow.uturn.backward" : "checkmark") {
                withAnimation(.smooth(duration: 0.25)) {
                    store.toggleTask(meetingID: item.record.id, task: item.task)
                }
            }
            .labelStyle(.iconOnly)
            .tint(appearance.accent.systemLabelFill)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if item.task.isAdded == true {
                Button("Görevi sil", systemImage: "trash", role: .destructive) {
                    store.removeAddedTask(meetingID: item.record.id, task: item.task)
                }
            }
            Button("Toplantıyı aç", systemImage: "doc.text") { router.open(meetingID: item.record.id) }
                .tint(Theme.muted)
        }
    }

    /// Yüz yüze toplantıda kullanıcı da "Konuşmacı N": hangisi olduğu seçilmemiş toplantılar (dokununca toplantı açılır).
    private var pendingSpeakerMeetings: some View {
        PendingUserSpeakerMeetings(meetings: store.meetings, userName: userName) { (meetingID: String) -> Void in
            router.open(meetingID: meetingID)
        }
    }

    /// Ekranın ortasındaki boş durum: hiç görev yok, açık görev kalmadı ya da henüz tamamlanan yok.
    @ViewBuilder
    private func emptyState(hasTasks: Bool, doneCount: Int) -> some View {
        if !hasTasks {
            PhoneEmptyScene(
                symbol: "checklist", palette: .sunset, title: "Henüz görev yok",
                message: "Toplantılarda sana düşen işler burada toplanır; bitirdiklerini işaretle, ilerlemen üstte görünsün."
            ) {
                if userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Adını yaz", systemImage: "person.text.rectangle") { router.push(route: .profile) }
                        .buttonStyle(.accentPill)
                        .controlSize(.large)
                }
            }
        } else if filter == .done {
            PhoneEmptyState(symbol: "checkmark.circle", title: "Henüz tamamlanan yok", message: "Bitirdiğin görevler burada birikir.") {
                EmptyView()
            }
        } else if doneCount > 0 {
            PhoneEmptyState(symbol: "party.popper.fill", title: "Açık görevin kalmadı", message: "Yeni toplantılarda sana düşen işler buraya gelir.") {
                EmptyView()
            }
            .overlay { ConfettiBurst(palette: .sunset) }
        }
    }
}

/// Görevlerim'de bir bölüm: son güne göre grup ya da (tamamlananlarda) toplantı.
private struct TaskSection {
    let id: String
    let title: String
    let isOverdue: Bool
    let items: [DatedTask]
}

/// Görev satırı: tamamlandı kutusu, iş, sahibi ve tarihi; istenirse toplantı adı. Uzun basınca Anımsatıcılar'a eklenir
/// (eklendiyse satırda zil görünür) ya da metni kopyalanır.
struct PhoneTaskRow: View {
    let record: MeetingRecord
    let task: NoteTask
    let showsMeeting: Bool
    let onToggle: @MainActor () -> Void

    var body: some View {
        PhoneTaskRowContent(record: record, task: task, showsMeeting: showsMeeting, metrics: .regular, onToggle: onToggle)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
    }
}

/// Görev satırının ölçüleri: Görevlerim ve toplantı notunda ferah (`regular`), ana ekranın kısa listesinde sık (`compact`).
struct PhoneTaskRowMetrics {
    let insets: EdgeInsets
    let checkboxSize: CGFloat
    let titleSize: CGFloat
    /// Görev metninin en çok satırı; nil ise tamamı.
    let titleLineLimit: Int?
    /// Kutuyla metin arası.
    let spacing: CGFloat

    static let regular: PhoneTaskRowMetrics = PhoneTaskRowMetrics(
        insets: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14), checkboxSize: 22, titleSize: 15, titleLineLimit: nil, spacing: 12
    )
    /// Inside the meeting note's "Your tasks" card: the note row (`NoteSourceRow`) already pads each row, so the task adds
    /// only a little vertical room; with `regular` the rows stood about 40 pt apart.
    static let inNote: PhoneTaskRowMetrics = PhoneTaskRowMetrics(
        insets: EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0), checkboxSize: 22, titleSize: 15, titleLineLimit: nil, spacing: 12
    )
    static let compact: PhoneTaskRowMetrics = PhoneTaskRowMetrics(
        insets: EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12), checkboxSize: 20, titleSize: 15, titleLineLimit: 2, spacing: 10
    )

    /// Satırlar arasındaki çizginin soldan boşluğu: metnin başladığı yer.
    var separatorInset: CGFloat {
        insets.leading + checkboxSize + spacing
    }
}

/// Görev satırının zeminsiz içeriği: tek başına kartta (`PhoneTaskRow`) ya da toplantı notundaki ince çizgili listede.
struct PhoneTaskRowContent: View {
    let record: MeetingRecord
    let task: NoteTask
    let showsMeeting: Bool
    let metrics: PhoneTaskRowMetrics
    let onToggle: @MainActor () -> Void
    @Environment(\.panelAppearance) private var appearance: PanelAppearance
    @Environment(PhoneStore.self) private var store: PhoneStore
    /// Anımsatıcılar'a eklenemediyse nedeni (satırın altında).
    @State private var reminderError: String?

    var body: some View {
        let isDone: Bool = isTaskDone(record: record, task: task)
        HStack(alignment: .top, spacing: metrics.spacing) {
            Button(action: onToggle) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .appFont(size: metrics.checkboxSize, weight: .regular)
                    .foregroundStyle(isDone ? appearance.accent.color : Theme.muted)
                    .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDone ? "Tamamlanmadı olarak işaretle" : "Tamamlandı olarak işaretle")
            VStack(alignment: .leading, spacing: 3) {
                Text(task.description)
                    .appFont(size: metrics.titleSize, weight: .regular)
                    .strikethrough(isDone, color: Theme.muted)
                    .foregroundStyle(isDone ? Theme.muted : Theme.ink)
                    .lineLimit(metrics.titleLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    if isTaskReminded(record: record, task: task) {
                        Image(systemName: "bell.fill")
                            .appFont(size: 10, weight: .semibold)
                            .foregroundStyle(appearance.accent.color)
                            .accessibilityLabel(Text("Anımsatıcılarda"))
                    }
                    // Son gün toplantı gününe göre çözülür, arayüz dilinde göreli ("Yarın", "2 gün gecikti").
                    TaskDueText(record: record, task: task, size: 12)
                    if task.dueDate != nil, !detail.isEmpty {
                        Text(verbatim: "·").appFont(size: 12, weight: .regular).foregroundStyle(Theme.muted)
                    }
                    if !detail.isEmpty {
                        Text(detail)
                            .appFont(size: 12, weight: .regular)
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                    }
                }
                if let reminderError {
                    Text(reminderError)
                        .appFont(size: 12, weight: .regular)
                        .foregroundStyle(NoticeSeverity.attention.tint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(metrics.insets)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .sensoryFeedback(.selection, trigger: isDone)
        .contextMenu {
            let reminded: Bool = isTaskReminded(record: record, task: task)
            Button(reminded ? "Anımsatıcılarda" : "Anımsatıcılara ekle", systemImage: reminded ? "bell.badge.fill" : "bell") {
                Task { await addToReminders() }
            }
            .disabled(reminded || record.note == nil)
            Button("Metni kopyala", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = task.description
            }
            // Yalnız elle eklenen görev silinir; nottan gelen görev notun parçasıdır.
            if task.isAdded == true {
                Button("Görevi sil", systemImage: "trash", role: .destructive) {
                    store.removeAddedTask(meetingID: record.id, task: task)
                }
            }
        }
    }

    /// Görevi Anımsatıcılar'a ekler; olmazsa nedeni satırın altında görünür.
    private func addToReminders() async {
        do {
            try await store.addToReminders(meetingID: record.id, task: task)
            reminderError = nil
        } catch {
            reminderError = phoneEventKitMessage(error: error)
        }
    }

    /// Tarihin yanındaki soluk metin: sahibi (kendi görevinde yazılmaz) ve istenirse toplantının adı.
    private var detail: String {
        let meeting: [String] = showsMeeting ? [record.note?.title ?? record.title] : []
        let owner: [String] = task.isMine ? [] : [task.owner]
        return (owner + meeting).joined(separator: " · ")
    }
}

/// Anımsatıcılar hatasının iPhone metni (Mac'teki `eventKitMessage`'ın iPhone Ayarları yoluyla). Saf fonksiyondur.
func phoneEventKitMessage(error: any Error) -> String {
    switch error {
    case EventKitError.remindersAccessDenied:
        String(localized: "Anımsatıcılar'a erişim izni yok: iPhone Ayarları › Gizlilik ve Güvenlik › Anımsatıcılar'dan \(appName)'e tam erişim ver.")
    case EventKitError.noReminderList:
        String(localized: "Anımsatıcılar'da liste yok: Anımsatıcılar uygulamasında bir liste oluştur.")
    case EventKitError.saveFailed(let reason):
        String(localized: "Anımsatıcı kaydedilemedi: \(reason)")
    default:
        userFacingMessage(error: error)
    }
}
