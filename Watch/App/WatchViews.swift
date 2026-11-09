import AINotepadWatchLink
import SwiftUI

/// Root: the running Watch recording takes the whole screen; otherwise the home list.
struct WatchRootView: View {
    let model: WatchAppModel

    var body: some View {
        NavigationStack {
            if let active = model.active {
                WatchRecordingView(model: model, active: active)
            } else {
                WatchHomeView(model: model)
            }
        }
        .tint(watchAccent)
        .alert(
            Text(verbatim: model.problem?.message ?? ""),
            isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
        ) {
            Button("Tamam", role: .cancel) { model.problem = nil }
        }
    }
}

/// Home: record, the iPhone's recording, today's meetings, tasks and the recordings still on the Watch.
struct WatchHomeView: View {
    let model: WatchAppModel
    /// The recording waiting for "Delete" to be confirmed (its audio is the only copy).
    @State private var pendingDelete: WatchDeletion?
    #if DEBUG
    @State private var showsDemoTasks: Bool = WatchDemoOptions.current.screen == "gorevler"
    @State private var showsDemoPhone: Bool = WatchDemoOptions.current.screen == "iphone"
    #endif

    var body: some View {
        List {
            if !model.snapshot.signedIn {
                Section {
                    Label("iPhone'da Gistsmith'i aç ve giriş yap; saat ondan sonra kayıt yapar.", systemImage: "iphone")
                        .font(.footnote)
                }
            }
            if let recording = model.snapshot.recording {
                Section {
                    NavigationLink {
                        WatchPhoneRecordingView(model: model)
                    } label: {
                        WatchPhoneRecordingRow(recording: recording)
                    }
                }
            }
            Section {
                // Off by the server's switch (`watchRecordingEnabled`): only the iPhone's recording is offered.
                if watchCanRecord(snapshot: model.snapshot) || !model.snapshot.signedIn {
                    WatchRecordButton(isStarting: model.isStarting) {
                        model.startWatchRecording(title: "")
                    }
                    .listRowBackground(Color.clear)
                }
                if watchCanStartOnPhone(snapshot: model.snapshot) {
                    Button {
                        model.send(request: .startPhoneRecording)
                    } label: {
                        Label("iPhone'da kaydet", systemImage: "iphone.radiowaves.left.and.right")
                    }
                    .disabled(model.isSending)
                }
            } footer: {
                if model.snapshot.signedIn, !watchCanRecord(snapshot: model.snapshot) {
                    Text("Saatte kayıt henüz açılmadı. Şimdilik iPhone'da kaydet.")
                } else {
                    Text("Kaydettiğini katılımcılara söyle.")
                }
            }
            let meetings: [WatchMeeting] = watchUpcomingMeetings(meetings: model.snapshot.meetings, now: Date())
            if !meetings.isEmpty {
                Section("Bugün") {
                    ForEach(meetings) { (meeting: WatchMeeting) in
                        if watchCanRecord(snapshot: model.snapshot) {
                            Button {
                                model.startWatchRecording(title: meeting.title)
                            } label: {
                                WatchMeetingRow(meeting: meeting)
                            }
                            .accessibilityHint(Text("Bu toplantıyı saatte kaydeder"))
                        } else {
                            WatchMeetingRow(meeting: meeting)
                        }
                    }
                }
            }
            if model.snapshot.signedIn {
                Section {
                    NavigationLink {
                        WatchTasksView(model: model)
                    } label: {
                        HStack {
                            Label("Görevlerim", systemImage: "checklist")
                            Spacer()
                            Text(model.visibleTasks.count, format: .number)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            let failedImports: [WatchFailedImport] = watchFailedImports(reports: model.snapshot.imports)
            if !failedImports.isEmpty {
                Section("iPhone'da içe aktarılamadı") {
                    ForEach(failedImports) { (failed: WatchFailedImport) in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: failed.title.isEmpty ? String(localized: "Yeni not") : failed.title)
                                .font(.footnote)
                                .lineLimit(1)
                                .privacySensitive()
                            Text(verbatim: failed.reason)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                pendingDelete = .phone(recordingID: failed.id)
                            } label: {
                                Label("Sil", systemImage: "trash")
                            }
                            Button {
                                model.send(request: .retryImport(recordingID: failed.id))
                            } label: {
                                Label("Yeniden dene", systemImage: "arrow.clockwise")
                            }
                        }
                    }
                }
            }
            if !model.recordings.isEmpty {
                Section {
                    ForEach(model.recordings) { (recording: WatchLocalRecording) in
                        WatchLocalRecordingRow(recording: recording)
                            .swipeActions {
                                Button(role: .destructive) {
                                    pendingDelete = .watch(recordingID: recording.id)
                                } label: {
                                    Label("Sil", systemImage: "trash")
                                }
                                if watchCanSendAgain(state: recording.state) {
                                    Button {
                                        model.retry(recordingID: recording.id)
                                    } label: {
                                        Label("Yeniden gönder", systemImage: "arrow.clockwise")
                                    }
                                }
                            }
                    }
                } header: {
                    Text("Bu saatte")
                } footer: {
                    Text("iPhone yakındayken gönderilir. iPhone'da Gistsmith'i açmak gönderimi hızlandırır.")
                }
            }
        }
        .navigationTitle(Text(verbatim: "Gistsmith"))
        #if DEBUG
        // `--ekran gorevler|iphone` (WatchDemo.swift): opens that screen for a Simulator check.
        .navigationDestination(isPresented: $showsDemoTasks) { WatchTasksView(model: model) }
        .navigationDestination(isPresented: $showsDemoPhone) { WatchPhoneRecordingView(model: model) }
        #endif
        .confirmationDialog(
            Text("Kaydı sil?"), isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { (deletion: WatchDeletion) in
            Button("Sil", role: .destructive) {
                switch deletion {
                case .watch(let recordingID):
                    model.delete(recordingID: recordingID)
                case .phone(let recordingID):
                    model.send(request: .deleteImport(recordingID: recordingID))
                }
            }
        } message: { (_: WatchDeletion) in
            Text("Ses silinir; geri alınamaz.")
        }
    }
}

/// A recording whose deletion waits for confirmation.
enum WatchDeletion: Equatable {
    /// Still on the watch.
    case watch(recordingID: String)
    /// Held by the iPhone after a failed import.
    case phone(recordingID: String)
}

/// The big record button: a static orange disc (no animated gradients: they cost battery).
struct WatchRecordButton: View {
    let isStarting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [watchAccent, Color(red: 0.98, green: 0.55, blue: 0.30)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    if isStarting {
                        ProgressView()
                    } else {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 76, height: 76)
                Text("Saatte kaydet")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(isStarting)
    }
}

/// The timer: runs from `timerStart`, frozen at `stoppedAt`. The system draws a running timer (no per-second redraw).
struct WatchTimerText: View {
    let timerStart: Date
    let stoppedAt: Date?

    var body: some View {
        if let stoppedAt {
            Text(Duration.seconds(max(0, stoppedAt.timeIntervalSince(timerStart))), format: .time(pattern: .hourMinuteSecond))
        } else {
            Text(timerInterval: timerStart...Date.distantFuture, countsDown: false)
        }
    }
}

/// The Watch recording: timer, title, pause/resume and End.
struct WatchRecordingView: View {
    let model: WatchAppModel
    let active: WatchActiveRecording

    var body: some View {
        // Scrolls (under the title, never behind it) so the consent line is never cut on a small watch or at a large
        // text size.
        ScrollView {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("Kaydediliyor")
                        .font(.footnote.weight(.semibold))
                }
                WatchTimerText(timerStart: active.startedAt, stoppedAt: nil)
                    .font(.system(size: 34, weight: .semibold).monospacedDigit())
                if !active.title.isEmpty {
                    Text(verbatim: active.title)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .privacySensitive()
                }
                // No pause on the Watch (see `WatchActiveRecording`): Finish, then a new recording.
                Button(role: .destructive) {
                    model.endWatchRecording()
                } label: {
                    Label("Bitir", systemImage: "stop.fill")
                        .fontWeight(.semibold)
                }
                .tint(.red)
                Text("Kaydettiğini katılımcılara söyle.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle(Text("Saatte"))
    }
}

/// The iPhone's recording in the home list.
struct WatchPhoneRecordingRow: View {
    let recording: WatchPhoneRecording

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(phoneRecordingTitle(phase: recording.phase), systemImage: "iphone")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(recording.phase == .recording ? Color.red : Color.secondary)
            if let timerStart = recording.timerStart {
                WatchTimerText(timerStart: timerStart, stoppedAt: recording.timerStoppedAt)
                    .font(.title3.monospacedDigit())
            }
            if !recording.title.isEmpty {
                Text(verbatim: recording.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .privacySensitive()
            }
        }
    }
}

/// The iPhone's recording with Pause/Resume and End (the commands name this recording).
struct WatchPhoneRecordingView: View {
    let model: WatchAppModel

    var body: some View {
        ScrollView {
            if let recording = model.snapshot.recording {
                VStack(spacing: 10) {
                    WatchPhoneRecordingRow(recording: recording)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    switch recording.phase {
                    case .recording:
                        Button {
                            model.send(request: .pausePhoneRecording(recordingID: recording.recordingID))
                        } label: {
                            Label("Duraklat", systemImage: "pause.fill")
                        }
                        .disabled(model.isSending)
                    case .paused:
                        Button {
                            model.send(request: .resumePhoneRecording(recordingID: recording.recordingID))
                        } label: {
                            Label("Devam", systemImage: "play.fill")
                        }
                        .disabled(model.isSending)
                    case .starting, .finishing:
                        EmptyView()
                    }
                    if recording.phase != .finishing {
                        Button(role: .destructive) {
                            model.send(request: .stopPhoneRecording(recordingID: recording.recordingID))
                        } label: {
                            Label("Bitir", systemImage: "stop.fill")
                        }
                        .tint(.red)
                        .disabled(model.isSending)
                    }
                }
            } else {
                Text("iPhone'da kayıt yok.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(Text(verbatim: "iPhone"))
    }
}

/// The phase's title on the Watch.
func phoneRecordingTitle(phase: WatchPhoneRecordingPhase) -> LocalizedStringKey {
    switch phase {
    case .starting: "Başlatılıyor"
    case .recording: "iPhone kaydediyor"
    case .paused: "Duraklatıldı"
    case .finishing: "Bitiriliyor"
    }
}

/// A meeting of today: time and title.
struct WatchMeetingRow: View {
    let meeting: WatchMeeting

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.start, format: .dateTime.hour().minute())
                .font(.caption)
                .foregroundStyle(watchAccent)
            Text(verbatim: meeting.title)
                .font(.footnote)
                .lineLimit(2)
                .privacySensitive()
        }
    }
}

/// A recording still on the Watch: title, length and where it is.
struct WatchLocalRecordingRow: View {
    let recording: WatchLocalRecording
    /// The iPhone's reason for not keeping the recording is shown in full after a tap: in full it filled the screen.
    @State private var isReasonExpanded: Bool = false

    private var isProblem: Bool {
        switch recording.state {
        case .failed, .rejected:
            true
        case .compressing, .queued, .delivered:
            false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: recording.info.title.isEmpty ? String(localized: "Yeni not") : recording.info.title)
                .font(.footnote)
                .lineLimit(1)
                .privacySensitive()
            // Length (and "interrupted") on one line, where it is on the next: one HStack wraps mid-word on a 41 mm watch.
            HStack(spacing: 4) {
                Text(Duration.seconds(recording.info.durationSec), format: .time(pattern: .hourMinuteSecond))
                    .monospacedDigit()
                    .fixedSize()
                if recording.info.interrupted {
                    Text(verbatim: "·")
                    Text("Kesildi")
                        .lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Group {
                switch recording.state {
                case .compressing:
                    Text("Hazırlanıyor")
                case .queued:
                    Text("iPhone'a gidecek")
                case .delivered:
                    Text("iPhone'a gönderildi")
                case .failed:
                    Text("Gönderilemedi")
                case .rejected(let reason):
                    // The iPhone received it but could not keep it: its reason (two lines; a tap shows all of it),
                    // with "Send again" in the swipe actions.
                    Text(verbatim: reason)
                        .lineLimit(isReasonExpanded ? nil : 2)
                }
            }
            .font(.caption2)
            .foregroundStyle(isProblem ? Color.orange : Color.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if case .rejected = recording.state {
                withAnimation(.smooth(duration: 0.2)) { isReasonExpanded.toggle() }
            }
        }
    }
}

/// The user's open tasks, most urgent first; tapping the circle marks one done.
struct WatchTasksView: View {
    let model: WatchAppModel

    var body: some View {
        List {
            let tasks: [WatchTask] = model.visibleTasks
            if tasks.isEmpty {
                Text("Açık görevin yok.")
                    .foregroundStyle(.secondary)
            }
            ForEach(tasks) { (task: WatchTask) in
                Button {
                    model.completeTask(task: task)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "circle")
                            .foregroundStyle(watchAccent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: task.text)
                                .font(.footnote)
                                .lineLimit(3)
                            if let due = task.due {
                                Text(verbatim: due)
                                    .font(.caption2)
                                    .foregroundStyle(watchAccent)
                            }
                            Text(verbatim: task.meetingTitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .privacySensitive()
                }
                .accessibilityHint(Text("Görevi tamamlandı diye işaretler"))
            }
        }
        .navigationTitle(Text("Görevlerim"))
    }
}
