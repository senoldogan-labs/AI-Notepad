import Foundation
import Testing
@testable import AINotepadCore

/// Üç satırlık kısa örnek toplantı metni (iki kişi; aralarda sessizlik).
private func shortScript() -> SampleMeetingScript {
    SampleMeetingScript(durationSec: 12, lines: [
        SampleMeetingLine(person: 1, text: "Are we on track for Tuesday?", startSec: 0.5, endSec: 3),
        SampleMeetingLine(person: 2, text: "Mostly, previews still break.", startSec: 3.5, endSec: 6),
        SampleMeetingLine(person: 1, text: "Then ship without previews.", startSec: 7, endSec: 11.5),
    ])
}

private func sampleNote() -> MeetingNote {
    MeetingNote(
        title: "Sharing launch", summary: "Ships Tuesday.", decisions: ["Ship Tuesday"],
        tasks: [NoteTask(owner: "Sen", description: "Send the recap", dueDate: "Friday", isMine: true)], glossary: []
    )
}

private func plainRecord(id: String, startedAt: Date) -> MeetingRecord {
    MeetingRecord(
        id: id, title: "Weekly", startedAt: startedAt, endedAt: startedAt.addingTimeInterval(600), language: .english, status: .done,
        failureMessage: nil, liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:],
        note: MeetingNote(title: "Weekly", summary: "S", decisions: [], tasks: [NoteTask(owner: "Sen", description: "Real task", dueDate: "tomorrow", isMine: true)], glossary: []),
        audioDeleted: false, engine: .cloud, notice: nil, meNeedsFinalPass: nil
    )
}

@Suite struct OnboardingFlowTests {
    // İleri ve geri adım listesinde sırayla gider; son adımdan sonra karşılama biter (nil), ilk adımdan geri gidilmez.
    @Test func stepsMoveInOrderAndEnd() {
        #expect(nextOnboardingStep(steps: hostedOnboardingSteps, current: .welcome) == .calendar)
        #expect(nextOnboardingStep(steps: hostedOnboardingSteps, current: .permissions) == .sampleMeeting)
        #expect(nextOnboardingStep(steps: hostedOnboardingSteps, current: .ready) == nil)
        #expect(previousOnboardingStep(steps: hostedOnboardingSteps, current: .welcome) == nil)
        #expect(previousOnboardingStep(steps: hostedOnboardingSteps, current: .calendar) == .welcome)
        #expect(nextOnboardingStep(steps: ownKeysOnboardingSteps, current: .welcome) == .engine)
        // Bu sürümde olmayan adımdan ileri gidilmez (karşılama biter).
        #expect(nextOnboardingStep(steps: hostedOnboardingSteps, current: .keys) == nil)
    }

    // Saklanan adım bu sürümde varsa oradan sürer; hiç saklanmadıysa, tanınmıyorsa ya da bu sürümde yoksa ilk adım.
    @Test func resumeUsesStoredStepOnlyWhenValid() {
        #expect(resumedOnboardingStep(steps: hostedOnboardingSteps, stored: nil) == .welcome)
        #expect(resumedOnboardingStep(steps: hostedOnboardingSteps, stored: "sample") == .sampleMeeting)
        #expect(resumedOnboardingStep(steps: hostedOnboardingSteps, stored: "permissions") == .permissions)
        #expect(resumedOnboardingStep(steps: hostedOnboardingSteps, stored: "keys") == .welcome)
        #expect(resumedOnboardingStep(steps: hostedOnboardingSteps, stored: "bilinmeyen") == .welcome)
        #expect(resumedOnboardingStep(steps: ownKeysOnboardingSteps, stored: "keys") == .keys)
        // Saklanan değerler değişmez (eski sürümlerin kaydı okunsun).
        #expect(OnboardingStep.allCases.map(\.rawValue) == ["welcome", "engine", "keys", "calendar", "permissions", "sample", "ready"])
    }

    @Test func progressAndPermissionActions() {
        #expect(onboardingProgress(steps: hostedOnboardingSteps, current: .permissions) == (index: 2, count: 5))
        #expect(permissionAction(status: .granted) == .none)
        #expect(permissionAction(status: .checking) == .none)
        #expect(permissionAction(status: .notDetermined) == .request)
        #expect(permissionAction(status: .denied) == .openSettings)
        #expect(permissionAction(status: .requested) == .openSettings)
    }

    // Takvimden kanıt: bitmemiş toplantılar başlangıç sırasıyla, en fazla üç tane.
    @Test func proofMeetingsAreUpcomingAndLimited() {
        let now: Date = Date(timeIntervalSince1970: 2_000_000_000)
        let meeting: (String, Double) -> CalendarMeeting = { (id: String, offset: Double) -> CalendarMeeting in
            CalendarMeeting(id: id, title: id, start: now.addingTimeInterval(offset), end: now.addingTimeInterval(offset + 1800), attendees: [], joinURL: nil)
        }
        let meetings: [CalendarMeeting] = [meeting("later", 7200), meeting("past", -7200), meeting("now", -600), meeting("soon", 600), meeting("last", 9000)]
        #expect(upcomingProofMeetings(meetings: meetings, now: now, limit: 3).map(\.id) == ["now", "soon", "later"])
    }
}

@Suite struct SampleMeetingTests {
    // Canlı metin sesin konumuna göre akar: başlamamış satır yok, konuşulan satır kelime kelime ve kesin değil, biten kesin.
    @Test func transcriptStreamsWithTheAudio() {
        let script: SampleMeetingScript = shortScript()
        #expect(sampleMeetingTranscript(script: script, elapsed: 0.2).isEmpty)
        let speaking: [LiveSegment] = sampleMeetingTranscript(script: script, elapsed: 1.75)
        #expect(speaking.count == 1)
        #expect(speaking[0].isFinal == false)
        #expect(speaking[0].text == "Are we on")
        #expect(speaking[0].person == 1)
        let later: [LiveSegment] = sampleMeetingTranscript(script: script, elapsed: 6.5)
        #expect(later.map(\.isFinal) == [true, true])
        #expect(later.map(\.text) == ["Are we on track for Tuesday?", "Mostly, previews still break."])
        #expect(later.map(\.id) == [SegmentID(speaker: .others, index: 0), SegmentID(speaker: .others, index: 1)])
        let ended: [LiveSegment] = sampleMeetingTranscript(script: script, elapsed: 12)
        #expect(ended.map(\.isFinal) == [true, true, true])
        #expect(sampleMeetingSpeaker(script: script, elapsed: 4) == 2)
        #expect(sampleMeetingSpeaker(script: script, elapsed: 6.5) == nil)
    }

    // Bozuk metin (sırasız, süre dışı, boş) reddedilir.
    @Test func invalidScriptsAreRejected() throws {
        let encoder: JSONEncoder = JSONEncoder()
        #expect(try decodeSampleMeetingScript(data: try encoder.encode(shortScript())) == shortScript())
        let overlapping: Data = try encoder.encode(SampleMeetingScript(durationSec: 10, lines: [
            SampleMeetingLine(person: 1, text: "One", startSec: 0, endSec: 5), SampleMeetingLine(person: 2, text: "Two", startSec: 3, endSec: 6),
        ]))
        let outside: Data = try encoder.encode(SampleMeetingScript(durationSec: 4, lines: [SampleMeetingLine(person: 1, text: "One", startSec: 0, endSec: 5)]))
        let empty: Data = try encoder.encode(SampleMeetingScript(durationSec: 4, lines: []))
        for data in [overlapping, outside, empty, Data("{}".utf8)] {
            #expect(throws: SampleMeetingError.self) { try decodeSampleMeetingScript(data: data) }
        }
    }

    // Uygulamayla gelen örnek toplantı geçerli, yaklaşık bir dakika (50–90 sn) ve iki kişili; ses 1,5 MB'tan küçük.
    @Test func bundledSampleMeetingIsValidAndSmall() throws {
        let folder: URL = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../../App/SampleMeeting").standardizedFileURL
        let script: SampleMeetingScript = try decodeSampleMeetingScript(data: Data(contentsOf: folder.appending(path: "sample-meeting.json")))
        #expect((50...90).contains(script.durationSec))
        #expect(Set(script.lines.map(\.person)) == [1, 2])
        let size: Int = try #require(try FileManager.default.attributesOfItem(atPath: folder.appending(path: "sample-meeting.m4a").path)[.size] as? Int)
        #expect(size < 1_500_000)
    }

    // Saklanan örnek toplantı bitmiş, işaretli, transkripti satırlar; işaret yazılıp okunur, eski kayıtlarda yoktur.
    @Test func recordIsMarkedAndRoundTrips() throws {
        let startedAt: Date = Date(timeIntervalSince1970: 2_000_000_000)
        let record: MeetingRecord = sampleMeetingRecord(
            id: "20330518-033320", script: shortScript(), note: sampleNote(), speakerNames: [1: "Maya", 2: "Leo"], startedAt: startedAt, myNotes: "My line"
        )
        #expect(record.isSampleMeeting)
        #expect(record.status == .done)
        #expect(record.finalSegments.map(\.text) == shortScript().lines.map(\.text))
        #expect(record.endedAt == startedAt.addingTimeInterval(12))
        #expect(record.myNotes == "My line")
        let folder: URL = FileManager.default.temporaryDirectory.appending(path: "sample-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }  // Geçici klasör: silinemezse test sonucu değişmez.
        try saveMeeting(record: record, directory: folder)
        let decoded: MeetingRecord = try loadMeeting(directory: folder)
        #expect(decoded == record)
        #expect(decoded.isSampleMeeting)
        try saveMeeting(record: plainRecord(id: "a", startedAt: startedAt), directory: folder)
        let old: MeetingRecord = try loadMeeting(directory: folder)
        #expect(!old.isSampleMeeting)
        #expect(old.isSample == nil)
    }

    // Örnek toplantı gerçek toplantılardan, bildirim planından, kendiliğinden gönderimden ve Markdown klasöründen çıkar;
    // deneme yeniden açılınca saklı örnek bulunur.
    @Test func sampleIsExcludedEverywhere() {
        let now: Date = Date(timeIntervalSince1970: 2_000_000_000)
        let real: MeetingRecord = plainRecord(id: "real", startedAt: now.addingTimeInterval(-3600))
        let sample: MeetingRecord = sampleMeetingRecord(
            id: "sample", script: shortScript(), note: sampleNote(), speakerNames: [:], startedAt: now.addingTimeInterval(-60), myNotes: ""
        )
        #expect(realMeetings(records: [real, sample]).map(\.id) == ["real"])
        #expect(existingSampleMeetingID(records: [real, sample]) == "sample")
        #expect(existingSampleMeetingID(records: [real]) == nil)
        #expect(noteReadyNotification(record: sample, userName: "") == nil)
        let destination: NoteDestination = NoteDestination(
            id: "hook", target: .webhook(URL(string: "https://hooks.zapier.com/x")!), autoSend: true, createdAt: now.addingTimeInterval(-86_400),
            autoSendSince: nil, needsReconnect: false
        )
        #expect(pendingAutoSends(records: [real, sample], destinations: [destination], now: now).map(\.meetingID) == ["real"])
        let edited: MeetingRecord = sample.with(myNotes: "changed").with(note: sampleNote().with(title: "Edited"))
        #expect(markdownFolderRefreshes(previous: [sample], current: [edited], userName: "").isEmpty)
        var calendar: Calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let plan: (MeetingRecord) -> [EngagementNotification] = { (record: MeetingRecord) -> [EngagementNotification] in
            plannedEngagementNotifications(input: EngagementPlanInput(
                records: [record], userName: "", settings: EngagementSettings(noteReady: true, taskDue: true, weeklySummary: true, inactive: true, trialReminder: true),
                calendarMeetings: [], otherPendingCount: 0, trial: nil, now: now, calendar: calendar, locale: Locale(identifier: "en_US")
            ))
        }
        #expect(!plan(real).isEmpty)
        #expect(plan(sample).isEmpty)
    }
}
