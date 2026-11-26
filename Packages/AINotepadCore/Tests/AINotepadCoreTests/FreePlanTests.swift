import Foundation
import Testing
@testable import AINotepadCore

/// A `GET /v1/me` answer on the free plan (the server's JSON), with the month's counters.
private func freeEntitlements(notesLeft: Int, asksLeft: Int) throws -> HostedEntitlements {
    let json: String = """
    {"userId":"u1","plan":"free","trialMeetingsTotal":3,"trialDays":7,"trialMeetingsLeft":0,"accountTrialMeetingsLeft":0,
     "deviceTrialMeetingsLeft":null,"trialEndsAt":"2026-11-01T00:00:00.000Z","monthlyHoursUsed":0,"monthlyHoursCap":10,
     "subscription":null,"meetingMaxMinutes":90,"freeNotesLeft":\(notesLeft),"freeNotesTotal":4,"freeAsksLeft":\(asksLeft),
     "freeAsksTotal":5,"freeMaxMeetingMinutes":45,"freeResetsAt":"2026-12-01T00:00:00.000Z"}
    """
    return try hostedJSONDecoder().decode(HostedEntitlements.self, from: Data(json.utf8))
}

/// Segments of a meeting: one every 30 s up to `minutes`, each 25 s of speech.
private func meeting(minutes: Double) -> [StoredSegment] {
    stride(from: 0, to: minutes * 60, by: 30).enumerated().map { (item: (offset: Int, element: Double)) -> StoredSegment in
        StoredSegment(key: "s\(item.offset)", speaker: .others, person: nil, startSec: item.element, endSec: item.element + 25, text: "Hello there.", words: nil)
    }
}

@Suite struct FreePlanTests {
    private let allowance: HostedFreeAllowance = HostedFreeAllowance(
        notesLeft: 2, notesTotal: 4, asksLeft: 5, asksTotal: 5, maxMeetingMinutes: 45, resetsAt: Date(timeIntervalSince1970: 0)
    )

    @Test func freeAccountIsItsOwnPlanAndRecordsOnTheDevice() throws {
        let free: HostedEntitlements = try freeEntitlements(notesLeft: 3, asksLeft: 4)
        guard case .free(let allowance) = hostedPlanStatus(entitlements: free, now: Date()) else {
            Issue.record("A free account must read as the free plan, not an ended trial")
            return
        }
        #expect(allowance.notesLeft == 3 && allowance.notesTotal == 4 && allowance.asksLeft == 4 && allowance.maxMeetingMinutes == 45)
        #expect(hostedRecordingStart(entitlements: free, now: Date()) == .onDevice(.freePlan))
        #expect(hostedStartBlock(entitlements: free, now: Date()) == nil)
        // No automatic trial-ended paywall or notice: the free plan's own strip says it.
        #expect(hostedUsageNotice(entitlements: free, now: Date()) == nil)
        #expect(hostedWatchMeetingMinutes(entitlements: free, now: Date()) == hostedUsualSubscriberMeetingMinutes)
    }

    @Test func subscriberOverTheMonthlyHoursRecordsOnTheDevice() throws {
        let json: String = """
        {"userId":"u1","plan":"subscription","trialMeetingsTotal":3,"trialMeetingsLeft":0,"accountTrialMeetingsLeft":0,
         "deviceTrialMeetingsLeft":null,"monthlyHoursUsed":10,"monthlyHoursCap":10,
         "subscription":{"status":"active","complimentary":false,"currentPeriodEnd":"2027-01-01T00:00:00.000Z","cancelAt":null,"access":"active","graceEndsAt":null,"plan":"monthly"}}
        """
        let full: HostedEntitlements = try hostedJSONDecoder().decode(HostedEntitlements.self, from: Data(json.utf8))
        #expect(hostedRecordingStart(entitlements: full, now: Date()) == .onDevice(.monthlyHoursUsed))
    }

    @Test func subscriberOverTheHoursIsNeverToldToBuyAPlan() throws {
        // The same device limit reads differently for a subscriber over the monthly hours than for the free plan.
        #expect(hostedOnDeviceRecordingBlockText(block: .requiresNewerSystem, reason: .monthlyHoursUsed)
            != hostedOnDeviceRecordingBlockText(block: .requiresNewerSystem, reason: .freePlan))
        #expect(mediaImportMessage(error: HostedImportError.onDeviceTranscriptionUnavailable(reason: .monthlyHoursUsed))
            != mediaImportMessage(error: HostedImportError.onDeviceTranscriptionUnavailable(reason: .freePlan)))
        let free: HostedEntitlements = try freeEntitlements(notesLeft: 3, asksLeft: 4)
        #expect(throws: HostedImportError.onDeviceTranscriptionUnavailable(reason: .freePlan)) {
            try requireHostedImportTranscribable(durationSec: 600, entitlements: free, systemSupportsAppleSpeech: false, now: Date())
        }
        #expect(conversionTrigger(moment: .freePlanStarted) == .freePlanStarted)
    }

    @Test func freeNoteDecisionChecksSpeechLengthAndTheMonth() {
        #expect(hostedFreeNoteDecision(segments: meeting(minutes: 2), allowance: allowance) == .tooShort)
        #expect(hostedFreeNoteDecision(segments: meeting(minutes: 30), allowance: allowance) == .request(meetingMinutes: 30))
        #expect(hostedFreeNoteDecision(segments: meeting(minutes: 50), allowance: allowance) == .tooLong(maxMinutes: 45))
        let used: HostedFreeAllowance = HostedFreeAllowance(notesLeft: 0, notesTotal: 4, asksLeft: 5, asksTotal: 5, maxMeetingMinutes: 45, resetsAt: allowance.resetsAt)
        #expect(hostedFreeNoteDecision(segments: meeting(minutes: 30), allowance: used) == .notesUsed(total: 4, resetsAt: allowance.resetsAt))
        // Asked by the user, only the length counts: the server returns the meeting's own grant without counting.
        #expect(hostedFreeNoteDecisionOnRequest(segments: meeting(minutes: 30), allowance: used) == .request(meetingMinutes: 30))
        #expect(hostedFreeNoteAction(segments: meeting(minutes: 30), allowance: used) == .upgrade(.freeNotesUsed))
        #expect(hostedFreeNoteAction(segments: meeting(minutes: 50), allowance: allowance) == .upgrade(.freeMeetingTooLong))
        #expect(hostedFreeNoteAction(segments: meeting(minutes: 30), allowance: allowance) == .write)
    }

    @Test func refusalReasonIsDecodedAndExplained() {
        let body: Data = Data(#"{"error":{"code":"monthly_cap_reached","message":"x","reason":"free_asks_used"}}"#.utf8)
        let error: HostedAPIError = parseHostedAPIError(status: 403, data: body, path: "/v1/llm/messages")
        #expect(error.code == .monthlyCapReached && error.freePlanReason == .freeAsksUsed)
        #expect(hostedErrorMessage(error: error) == hostedFreePlanMessage(reason: .freeAsksUsed))
        // An unknown reason keeps the code's own text.
        let unknown: HostedAPIError = parseHostedAPIError(status: 403, data: Data(#"{"error":{"code":"monthly_cap_reached","message":"x","reason":"new"}}"#.utf8), path: "/v1/llm/messages")
        #expect(unknown.freePlanReason == nil)
        #expect(hostedFreeRefusalMoment(reason: .freeNotesUsed) == .freeNotesUsed)
        #expect(hostedFreeRefusalMoment(reason: .freeCapacityReached) == nil)
    }

    @Test func freeNoteCallsCarryTheGrantAndNoMeeting() throws {
        let request: LLMRequest = LLMRequest(purpose: .noteChunk, tier: .smart, system: "s", userText: "u", maxTokens: 9000, jsonSchema: nil, timeoutSec: 30, images: [], webSearch: nil)
        let urlRequest: URLRequest = try hostedLLMURLRequest(
            baseURL: try #require(URL(string: "https://api.example.com")),
            credentials: HostedLLMCredentials(accessToken: "t", meetingID: nil, freeNoteID: "11111111-1111-4111-8111-111111111111"),
            clientInfo: HostedClientInfo(appVersion: "0.2.18 (69)", osVersion: "macOS 26.0"), request: request
        )
        #expect(urlRequest.value(forHTTPHeaderField: "x-free-note") == "11111111-1111-4111-8111-111111111111")
        #expect(urlRequest.value(forHTTPHeaderField: "x-meeting-id") == nil)
    }

    @Test func freeChunksAreCutByBytesInWideScripts() {
        // 20 000 characters of Japanese is ~60 KB: a free chunk stops at 45 000 bytes.
        let japanese: [StoredSegment] = (0..<200).map { (index: Int) -> StoredSegment in
            StoredSegment(key: "j\(index)", speaker: .others, person: nil, startSec: Double(index), endSec: Double(index) + 1, text: String(repeating: "会", count: 100), words: nil)
        }
        let chunks: [[StoredSegment]] = noteChunks(segments: japanese, maxChars: noteChunkMaxChars, maxBytes: hostedFreeNoteChunkBytes)
        #expect(chunks.count == 2)
        #expect(chunks.allSatisfy { $0.map(\.text.utf8.count).reduce(0, +) <= hostedFreeNoteChunkBytes })
        // Latin text: the character limit still applies first (same chunks as paid plans).
        let latin: [StoredSegment] = (0..<200).map { (index: Int) -> StoredSegment in
            StoredSegment(key: "l\(index)", speaker: .others, person: nil, startSec: Double(index), endSec: Double(index) + 1, text: String(repeating: "a", count: 100), words: nil)
        }
        #expect(noteChunks(segments: latin, maxChars: noteChunkMaxChars, maxBytes: hostedFreeNoteChunkBytes) == noteChunks(segments: latin, maxChars: noteChunkMaxChars))
    }

    @Test func freeAskArchiveFitsTheByteCap() {
        let limits: NoteLimits = NoteLimits(chunkChars: noteChunkMaxChars, chunkBytes: hostedFreeNoteChunkBytes, summaryChars: nil, archiveChars: 60_000, requestBytes: hostedFreeAskRequestBytes)
        let passage: ArchivePassage = ArchivePassage(
            id: "p", meetingID: "m", meetingTitle: "t", meetingDate: Date(timeIntervalSince1970: 0), kind: .note, startSec: 0, text: String(repeating: "会", count: 10)
        )
        let chars: Int = askArchiveCharBudget(limits: limits, passages: [passage], otherBytes: 4_000)
        #expect(chars * 3 + askFixedPromptBytes + 4_000 <= hostedFreeAskRequestBytes)
        // Paid plans keep the character budget.
        #expect(askArchiveCharBudget(limits: NoteLimits(chunkChars: 20_000, summaryChars: nil, archiveChars: 60_000), passages: [passage], otherBytes: 4_000) == 60_000)
    }
}
