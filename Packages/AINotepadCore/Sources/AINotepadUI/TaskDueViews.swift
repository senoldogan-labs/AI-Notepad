import AINotepadCore
import SwiftUI

/// Görev satırındaki son gün (bkz. `taskDueLabel`): gecikmişte kırmızı, bugünse vurgu renginde, diğerlerinde soluk.
/// Tarihsiz görevde hiçbir şey çizmez. Mac ve iPhone aynı görünümü kullanır.
public struct TaskDueText: View {
    let label: TaskDueLabel?
    let size: CGFloat

    public init(record: MeetingRecord, task: NoteTask, size: CGFloat) {
        label = taskDueLabel(record: record, task: task, now: Date(), calendar: Calendar.current, locale: interfaceLocale())
        self.size = size
    }

    /// Kişiler sayfasındaki görev için.
    public init(personTask: PersonTask, size: CGFloat) {
        label = personTaskDueLabel(task: personTask, now: Date(), calendar: Calendar.current, locale: interfaceLocale())
        self.size = size
    }

    public var body: some View {
        if let label {
            DueLabelText(label: label, size: size)
        }
    }
}

/// Tarih etiketinin çizimi: gecikmişte kırmızı ünlemli, bugünse vurgu renginde kalın.
private struct DueLabelText: View {
    let label: TaskDueLabel
    let size: CGFloat
    @Environment(\.panelAppearance) private var appearance: PanelAppearance

    var body: some View {
        HStack(spacing: 3) {
            if label.isOverdue {
                Image(systemName: "exclamationmark.circle.fill")
                    .appFont(size: size - 2, weight: .semibold)
                    .accessibilityHidden(true)
            }
            Text(verbatim: label.text)
                .appFont(size: size, weight: label.isOverdue || label.isToday ? .semibold : .regular)
        }
        .foregroundStyle(label.isOverdue ? NoticeSeverity.error.tint : label.isToday ? appearance.accent.color : Theme.muted)
        .lineLimit(1)
    }
}

/// Görevlerim'deki grubun başlığı (arayüz dilinde).
public func taskDueBucketTitle(bucket: TaskDueBucket) -> String {
    switch bucket {
    case .overdue: String(localized: "Gecikmiş")
    case .today: String(localized: "Bugün")
    case .nextSevenDays: String(localized: "Önümüzdeki 7 gün")
    case .later: String(localized: "Daha sonra")
    case .undated: String(localized: "Tarihsiz")
    }
}

/// Elle görev ekleme formu (Mac'te açılır kutuda, iPhone'da sayfada): iş, isteğe bağlı son gün ve görevin ekleneceği
/// toplantı (`fixedMeetingID` verilmişse seçilmez, o toplantıya eklenir). Görev kullanıcınındır.
public struct AddTaskForm: View {
    let meetings: [MeetingRecord]
    let fixedMeetingID: String?
    let onAdd: @MainActor (_ meetingID: String, _ text: String, _ dueDay: Date?) -> Void
    let onCancel: @MainActor () -> Void
    @State private var text: String = ""
    @State private var hasDueDay: Bool = false
    @State private var dueDay: Date = Calendar.current.startOfDay(for: Date())
    @State private var meetingID: String = ""
    @FocusState private var isTextFocused: Bool

    public init(
        meetings: [MeetingRecord], fixedMeetingID: String?,
        onAdd: @escaping @MainActor (_ meetingID: String, _ text: String, _ dueDay: Date?) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.meetings = meetings
        self.fixedMeetingID = fixedMeetingID
        self.onAdd = onAdd
        self.onCancel = onCancel
    }

    private var chosenMeetingID: String {
        fixedMeetingID ?? (meetingID.isEmpty ? meetings.first?.id ?? "" : meetingID)
    }

    private var canAdd: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chosenMeetingID.isEmpty
    }

    public var body: some View {
        Form {
            TextField("Ne yapılacak?", text: $text, axis: .vertical)
                .lineLimit(1...3)
                .focused($isTextFocused)
                .onSubmit(add)
            Toggle("Son gün", isOn: $hasDueDay.animation(.smooth(duration: 0.2)))
            if hasDueDay {
                DatePicker("Tarih", selection: $dueDay, displayedComponents: .date)
            }
            if fixedMeetingID == nil {
                Picker("Toplantı", selection: $meetingID) {
                    ForEach(meetings) { (record: MeetingRecord) in
                        Text(verbatim: record.note?.title ?? record.title).tag(record.id)
                    }
                }
            }
            HStack {
                Spacer(minLength: 0)
                Button("Vazgeç", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Ekle", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .onAppear {
            meetingID = fixedMeetingID ?? meetings.first?.id ?? ""
            isTextFocused = true
        }
        #if os(macOS)
        .formStyle(.grouped)
        .frame(width: 380)
        #endif
    }

    private func add() {
        guard canAdd else {
            return
        }
        onAdd(chosenMeetingID, text, hasDueDay ? dueDay : nil)
    }
}
