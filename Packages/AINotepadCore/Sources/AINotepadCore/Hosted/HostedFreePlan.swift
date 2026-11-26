import Foundation

// The permanent free plan (spec docs/superpowers/specs/2026-11-23-free-plan.md, server `server/src/freePlan.ts`). After
// the trial, an account without paid access keeps Gistsmith on a capped plan: recordings are transcribed on the device
// (no meeting session, no audio to the server), the server grants a few AI notes a month for meetings up to a length,
// and a few Ask answers. The app learns the plan from `GET /v1/me` (`plan: "free"` and the `free*` fields) and only
// because it sends a build at or above the server's `FREE_PLAN_MIN_BUILD`.

/// Why the free plan refused a request: the server's `error.reason` next to an error code every app already knows
/// (`server/src/errors.ts` `freePlanRefusals`, one to one).
public enum HostedFreePlanRefusal: String, Sendable, Equatable, CaseIterable {
    /// The account isn't on the free plan (paid, in trial, the plan is off, or the app doesn't know it).
    case freePlanUnavailable = "free_plan_unavailable"
    /// The free plan doesn't cover this AI feature (live features, integrations, transcript translation…).
    case planRequired = "plan_required"
    /// This month's free AI notes are used.
    case freeNotesUsed = "free_notes_used"
    /// The meeting is longer than a free note covers.
    case freeMeetingTooLong = "free_meeting_too_long"
    /// This month's free Ask answers are used.
    case freeAsksUsed = "free_asks_used"
    /// This month's free AI allowance outside notes is used (Ask, note edits, follow-up e-mails).
    case freeAccountCapReached = "free_account_cap_reached"
    /// The note grant's token budget is used (rewriting a note too many times).
    case freeNoteBudgetExhausted = "free_note_budget_exhausted"
    /// The note grant isn't valid any more (refunded after a day without use, or another account's).
    case freeNoteInvalid = "free_note_invalid"
    /// The free plan is already bound to another account on this device.
    case freeDeviceUsed = "free_device_used"
    /// Too many new free accounts started on this network today.
    case freeIPLimit = "free_ip_limit"
    /// Free AI requests are paused for today (the free plan's spend ceiling).
    case freeCapacityReached = "free_capacity_reached"
}

/// The free plan's limits and what is left of them this UTC month (`GET /v1/me`, `POST /v1/free/notes`).
public struct HostedFreeAllowance: Sendable, Equatable {
    public let notesLeft: Int
    public let notesTotal: Int
    public let asksLeft: Int
    public let asksTotal: Int
    /// The longest meeting a free note covers (minutes).
    public let maxMeetingMinutes: Int
    /// When the month's counters reset (start of the next UTC month).
    public let resetsAt: Date

    public init(notesLeft: Int, notesTotal: Int, asksLeft: Int, asksTotal: Int, maxMeetingMinutes: Int, resetsAt: Date) {
        self.notesLeft = notesLeft
        self.notesTotal = notesTotal
        self.asksLeft = asksLeft
        self.asksTotal = asksTotal
        self.maxMeetingMinutes = maxMeetingMinutes
        self.resetsAt = resetsAt
    }
}

/// The free plan's allowance from `GET /v1/me`: present while the plan applies to the account and the app knows it, also
/// during the trial (so the trial's offer can say what follows it); nil otherwise (an older server, the plan is off, or a
/// field is missing). Pure function.
public func hostedFreeAllowance(entitlements: HostedEntitlements) -> HostedFreeAllowance? {
    guard let notesLeft = entitlements.freeNotesLeft, let notesTotal = entitlements.freeNotesTotal, let asksLeft = entitlements.freeAsksLeft,
          let asksTotal = entitlements.freeAsksTotal, let maxMinutes = entitlements.freeMaxMeetingMinutes, let resetsAt = entitlements.freeResetsAt else {
        return nil
    }
    return HostedFreeAllowance(
        notesLeft: notesLeft, notesTotal: notesTotal, asksLeft: asksLeft, asksTotal: asksTotal, maxMeetingMinutes: maxMinutes, resetsAt: resetsAt
    )
}

/// The allowance after a note grant (`POST /v1/free/notes` answers the month's counters). Pure function.
public func hostedFreeAllowance(note: HostedFreeNote) -> HostedFreeAllowance {
    HostedFreeAllowance(
        notesLeft: note.freeNotesLeft, notesTotal: note.freeNotesTotal, asksLeft: note.freeAsksLeft, asksTotal: note.freeAsksTotal,
        maxMeetingMinutes: note.freeMaxMeetingMinutes, resetsAt: note.freeResetsAt
    )
}

// MARK: Recording

/// Why a recording runs on this device without a meeting session.
public enum HostedOnDeviceReason: Sendable, Equatable {
    /// The account is on the free plan: transcripts are always written on the device.
    case freePlan
    /// A subscriber's monthly recording hours are used: recording continues on the device until they reset.
    case monthlyHoursUsed
}

/// How a new recording starts.
public enum HostedRecordingStart: Sendable, Equatable {
    /// A meeting session on the server (cloud live text, final pass and note).
    case server
    /// On this device only: live text and transcript on the device, no audio to the server.
    case onDevice(HostedOnDeviceReason)
    /// It can't start (the reason and its one remedy: `hostedStartBlockRemedy`).
    case blocked(HostedStartBlock)
}

/// How a new recording starts from the entitlements: the free plan and a subscriber over the monthly hours record on
/// the device; any other block stops the start; otherwise a server session. Pure function.
public func hostedRecordingStart(entitlements: HostedEntitlements, now: Date) -> HostedRecordingStart {
    if case .free = hostedPlanStatus(entitlements: entitlements, now: now) {
        return .onDevice(.freePlan)
    }
    switch hostedStartBlock(entitlements: entitlements, now: now) {
    case .none:
        return .server
    case .monthlyCapReached:
        return .onDevice(.monthlyHoursUsed)
    case .some(let block):
        return .blocked(block)
    }
}

// MARK: Notes

/// The shortest speech a free note is spent on (seconds): shorter test recordings keep their transcript and spend no note.
public let hostedFreeNoteMinSpeechSec: Double = 120

/// What happens to an on-device recording's note on the free plan.
public enum HostedFreeNoteDecision: Sendable, Equatable {
    /// Ask the server for a note grant for a meeting of this many minutes (rounded up).
    case request(meetingMinutes: Int)
    /// Less than `hostedFreeNoteMinSpeechSec` of speech: no note is spent, the transcript is kept.
    case tooShort
    /// The meeting is longer than a free note covers.
    case tooLong(maxMinutes: Int)
    /// This month's free notes are used.
    case notesUsed(total: Int, resetsAt: Date)
}

/// The free note's decision from the meeting's transcript and the last known allowance: the meeting's length is where
/// its last segment ends, its speech the sum of its non-empty segments. Pure function.
public func hostedFreeNoteDecision(segments: [StoredSegment], allowance: HostedFreeAllowance) -> HostedFreeNoteDecision {
    let spoken: [StoredSegment] = segments.filter { (segment: StoredSegment) -> Bool in !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    let speechSec: Double = spoken.reduce(0) { (total: Double, segment: StoredSegment) -> Double in total + max(0, segment.endSec - segment.startSec) }
    guard speechSec >= hostedFreeNoteMinSpeechSec else {
        return .tooShort
    }
    let minutes: Int = Int((meetingEndSec(segments: spoken) / 60).rounded(.up))
    guard minutes <= allowance.maxMeetingMinutes else {
        return .tooLong(maxMinutes: allowance.maxMeetingMinutes)
    }
    guard allowance.notesLeft > 0 else {
        return .notesUsed(total: allowance.notesTotal, resetsAt: allowance.resetsAt)
    }
    return .request(meetingMinutes: max(1, minutes))
}

/// `POST /v1/free/notes` body: the recording's ID (a repeat returns the same grant), its length, and the device's proof
/// (DeviceCheck for the account's first grant, App Attest when available).
struct HostedFreeNoteBody: Encodable, Equatable {
    let clientRef: String
    let meetingMinutes: Int
    let deviceCheckToken: String?
    let device: HostedDeviceAssertion?
}

/// `POST /v1/free/notes` answer: the grant (its ID goes on note calls as `x-free-note`) and the month's counters.
public struct HostedFreeNote: Decodable, Sendable, Equatable {
    public let noteId: String
    public let tokenBudget: Int
    public let tokensUsed: Int
    /// False when the recording already had a grant (nothing counted again).
    public let created: Bool
    public let freeNotesLeft: Int
    public let freeNotesTotal: Int
    public let freeAsksLeft: Int
    public let freeAsksTotal: Int
    public let freeMaxMeetingMinutes: Int
    public let freeResetsAt: Date
}

// MARK: Ask

/// The UTF-8 size of a free Ask request (archive, prompt, history and question): the server estimates input tokens as
/// UTF-8 bytes / 3 and refuses a free call over `FREE_LLM_MAX_INPUT_TOKENS` (30 000); 3 × (30 000 − 8 000 headroom).
public let hostedFreeAskRequestBytes: Int = 66_000

/// The UTF-8 size of one free note chunk: a 20 000-character chunk is ~60 KB in Chinese, Japanese or Korean.
public let hostedFreeNoteChunkBytes: Int = 45_000

// MARK: Copy

/// The free plan refusal's text: what happened, what is kept, and what unlocks it. Never calls the plan a trial. Pure
/// function.
public func hostedFreePlanMessage(reason: HostedFreePlanRefusal) -> String {
    switch reason {
    case .freePlanUnavailable:
        #if os(macOS)
        String(localized: "Ücretsiz plan bu hesapta şu an kullanılamıyor. Devam etmek için Ayarlar › Plan ve faturalandırma'dan bir plan seç.")
        #else
        String(localized: "Ücretsiz plan bu hesapta şu an kullanılamıyor.")
        #endif
    case .planRequired:
        String(localized: "Bu yapay zekâ özelliği ücretsiz planda yok; Kişisel planla açılır.")
    case .freeNotesUsed:
        String(localized: "Bu ayki ücretsiz yapay zekâ notların bitti; transkript kaydedildi. Kişisel planla her toplantının notu kendiliğinden çıkar.")
    case .freeMeetingTooLong:
        String(localized: "Bu toplantı ücretsiz notun kapsadığından uzun; transkript kaydedildi. Kişisel planla uzun toplantıların da notu çıkar.")
    case .freeAsksUsed:
        String(localized: "Bu ayki ücretsiz soruların bitti; ay başında yenilenir. Kişisel planla çok daha fazla soru sorabilirsin.")
    case .freeAccountCapReached:
        String(localized: "Ücretsiz planın bu ayki yapay zekâ payı doldu (Sor, not düzenleme, e-posta); ay başında yenilenir.")
    case .freeNoteBudgetExhausted:
        String(localized: "Bu toplantının ücretsiz notu yeterince yeniden yazıldı; mevcut not korunur.")
    case .freeNoteInvalid:
        String(localized: "Bu toplantının ücretsiz not hakkı artık geçerli değil; \"Notu yenile\" ile yeniden dene.")
    case .freeDeviceUsed:
        #if os(macOS)
        String(localized: "Bu Mac'te ücretsiz plan başka bir hesapla kullanılıyor. Bu hesapla devam etmek için bir plan seç.")
        #else
        String(localized: "Bu iPhone'da ücretsiz plan başka bir hesapla kullanılıyor.")
        #endif
    case .freeIPLimit:
        String(localized: "Bu ağdan bugün çok fazla yeni ücretsiz hesap başladı; yarın yeniden dene.")
    case .freeCapacityReached:
        String(localized: "Ücretsiz yapay zekâ istekleri bugünlük durdu; transkript kaydedildi. Notu yarın \"Notu yenile\" ile yazdırabilirsin.")
    }
}

/// The meeting's notice when a free note isn't written (the transcript is kept); nil when the note is requested. Pure
/// function.
public func hostedFreeNoteNotice(decision: HostedFreeNoteDecision) -> String? {
    switch decision {
    case .request:
        nil
    case .tooShort:
        String(localized: "Kısa kayıt: ücretsiz not harcanmadı, transkript kaydedildi. Notu istersen \"Notu yenile\"ye bas.")
    case .tooLong(let maxMinutes):
        String(localized: "Ücretsiz notlar en çok \(maxMinutes) dakikalık toplantıları kapsar; transkript kaydedildi. Kişisel planla uzun toplantıların da notu çıkar.")
    case .notesUsed(let total, _):
        String(localized: "Bu ayki \(total) ücretsiz yapay zekâ notun bitti; transkript kaydedildi. Kişisel planla her toplantının notu kendiliğinden çıkar.")
    }
}

/// The free note's decision when the user asks for the note ("Write the note again", a meeting without a note): only the
/// length is checked here. The month's count is the server's: a meeting that already has its grant gets it again
/// without counting, and a new one past the month's notes is refused with `free_notes_used`. Pure function.
public func hostedFreeNoteDecisionOnRequest(segments: [StoredSegment], allowance: HostedFreeAllowance) -> HostedFreeNoteDecision {
    let minutes: Int = Int((meetingEndSec(segments: segments) / 60).rounded(.up))
    guard minutes <= allowance.maxMeetingMinutes else {
        return .tooLong(maxMinutes: allowance.maxMeetingMinutes)
    }
    return .request(meetingMinutes: max(1, minutes))
}

// MARK: On-device transcript

/// The notice on a meeting transcribed on this device (Gistsmith's free plan, or a subscriber over the monthly hours):
/// where it was written, what it lacks and what adds it. Pure function.
public func hostedOnDeviceTranscriptNotice(reason: HostedOnDeviceReason) -> String {
    switch reason {
    case .freePlan:
        #if os(macOS)
        String(localized: "Bu Mac'te yazıya döküldü (ücretsiz plan): konuşmacılar ayrılmaz. Kişisel plan konuşmacıları ve adları ekler.")
        #else
        String(localized: "Bu iPhone'da yazıya döküldü (ücretsiz plan): konuşmacılar ayrılmaz. Kişisel plan konuşmacıları ve adları ekler.")
        #endif
    case .monthlyHoursUsed:
        #if os(macOS)
        String(localized: "Bu ayki kayıt saatlerin dolduğu için bu Mac'te yazıya döküldü: konuşmacılar ayrılmaz. Saatler ay başında yenilenir.")
        #else
        String(localized: "Bu ayki kayıt saatlerin dolduğu için bu iPhone'da yazıya döküldü: konuşmacılar ayrılmaz. Saatler ay başında yenilenir.")
        #endif
    }
}

/// The final pass of a recording made on this device: Apple's on-device recognition (macOS and iOS 26+; nothing leaves
/// the device), with Gistsmith's notice instead of the developer edition's.
public struct HostedOnDeviceFinalTranscriber: FinalTranscriber {
    private let inner: AppleSpeechFinalTranscriber
    private let reason: HostedOnDeviceReason

    public var source: FinalPassSource {
        inner.source
    }

    public init(primaryLanguage: MeetingLanguage, reason: HostedOnDeviceReason) {
        self.inner = AppleSpeechFinalTranscriber(primaryLanguage: primaryLanguage)
        self.reason = reason
    }

    public func transcribeFinal(audioURL: URL, languageMode: LanguageMode) async throws -> FinalPassResult {
        let result: FinalPassResult = try await inner.transcribeFinal(audioURL: audioURL, languageMode: languageMode)
        return FinalPassResult(segments: result.segments, language: result.language, coverage: .complete(notice: hostedOnDeviceTranscriptNotice(reason: reason)))
    }
}

/// The final pass of a recording made on this device: Apple's recognition where the system has it (`systemSupported`:
/// macOS or iOS 26+), otherwise none (the live transcript, written on the device, is kept and the notice says so). Pure
/// function.
public func hostedOnDeviceFinalPassPlan(systemSupported: Bool, primaryLanguage: MeetingLanguage, reason: HostedOnDeviceReason) -> FinalPassPlan {
    guard systemSupported else {
        return .skip(reason: hostedOnDeviceTranscriptNotice(reason: reason))
    }
    return .run(HostedOnDeviceFinalTranscriber(primaryLanguage: primaryLanguage, reason: reason))
}

/// The live routes of a recording made on this device: Mac "Sen" on the local engine (its live text is the saved
/// transcript), "Diğerleri" on Apple's on-device recognition when the language's model is ready, else the local
/// engine. Nothing streams to the cloud. Pure function.
public func hostedOnDeviceLiveRoutes(support: OnDeviceLiveSupport) -> HostedLiveRoutes {
    guard case .ready(let choice) = support else {
        return HostedLiveRoutes(me: .local, others: .local)
    }
    return HostedLiveRoutes(me: .local, others: .onDevice(choice))
}

/// Why the free plan can't record on this device (iPhone: Apple's on-device recognition is its only engine).
public enum HostedFreeRecordingBlock: Sendable, Equatable {
    /// The system is older than iOS 26 (no `SpeechAnalyzer`).
    case requiresNewerSystem
    /// Apple has no on-device recognition for the meeting language.
    case unsupportedLanguage
}

/// Why the free plan can't record on this device, or nil when it can (a model that isn't installed yet is installed
/// when the recording starts). Pure function.
public func hostedFreeRecordingBlock(support: OnDeviceLiveSupport) -> HostedFreeRecordingBlock? {
    switch support {
    case .ready, .modelNotInstalled: nil
    case .requiresNewerSystem: .requiresNewerSystem
    case .unsupportedLanguage: .unsupportedLanguage
    }
}

/// The reason text when a recording can't run on this iPhone's own recognition, with what still works: on the free plan
/// a paid plan; for a subscriber over the monthly hours, when the hours renew. Pure function.
public func hostedOnDeviceRecordingBlockText(block: HostedFreeRecordingBlock, reason: HostedOnDeviceReason) -> String {
    switch (block, reason) {
    case (.requiresNewerSystem, .freePlan):
        String(localized: "Ücretsiz plan toplantıları cihazda yazıya döker; bunun için iOS 26 ya da sonrası gerekiyor. Kişisel planla bu iPhone'da kayda devam edebilirsin.")
    case (.unsupportedLanguage, .freePlan):
        String(localized: "Ücretsiz plan toplantıları cihazda yazıya döker; Apple bu toplantı dilini cihazda tanımıyor. Kişisel planla bu dilde kayda devam edebilirsin.")
    case (.requiresNewerSystem, .monthlyHoursUsed):
        String(localized: "Bu ayki kayıt saatlerin doldu; kayıt ancak cihazda yazıya dökülebilir ve bunun için iOS 26 ya da sonrası gerekiyor. Saatler ay başında yenilenir.")
    case (.unsupportedLanguage, .monthlyHoursUsed):
        String(localized: "Bu ayki kayıt saatlerin doldu; kayıt ancak cihazda yazıya dökülebilir ve Apple bu toplantı dilini cihazda tanımıyor. Saatler ay başında yenilenir.")
    }
}

/// What a recording on this device leaves out while it runs (the recording screen's notice, and the refusal of live AI
/// requests during it). Pure function.
public func hostedOnDeviceRecordingText(reason: HostedOnDeviceReason) -> String {
    switch reason {
    case .freePlan:
        String(localized: "Kayıt bu cihazda yazıya dökülüyor (ücretsiz plan): canlı çeviri, \"Ne kaçırdım?\" ve canlı sorular Kişisel planla açılır.")
    case .monthlyHoursUsed:
        String(localized: "Bu ayki kayıt saatlerin doldu; kayıt bu cihazda yazıya dökülüyor. Canlı çeviri ve canlı sorular saatler yenilenince açılır.")
    }
}

/// The longest recording the Apple Watch may make for this account: a meeting session's allowance, or for an account
/// that records on the device (no session; transcribed on the iPhone) the usual meeting length. Nil without the field
/// (an older server). Pure function.
public func hostedWatchMeetingMinutes(entitlements: HostedEntitlements, now: Date) -> Int? {
    guard case .onDevice = hostedRecordingStart(entitlements: entitlements, now: now) else {
        return entitlements.meetingMaxMinutes
    }
    return hostedUsualSubscriberMeetingMinutes
}

/// What a free account can do about a finished meeting without a note.
public enum HostedFreeNoteAction: Sendable, Equatable {
    /// Write it with one of the month's free notes (the user asks; nothing is spent on its own).
    case write
    /// A paid plan writes it: the limit that keeps it (`freeNotesUsed` or `freeMeetingTooLong`).
    case upgrade(HostedUpsellMoment)
}

/// The action for a meeting without a note on the free plan: write it when a note is left and the meeting fits, else
/// the limit's upgrade. Pure function.
public func hostedFreeNoteAction(segments: [StoredSegment], allowance: HostedFreeAllowance) -> HostedFreeNoteAction {
    switch hostedFreeNoteDecisionOnRequest(segments: segments, allowance: allowance) {
    case .tooLong:
        .upgrade(.freeMeetingTooLong)
    case .request where allowance.notesLeft > 0:
        .write
    case .request, .tooShort, .notesUsed:
        .upgrade(.freeNotesUsed)
    }
}

/// How an account came to the free plan (the "you're on Free" strip says which ended).
public enum HostedFreePlanOrigin: Sendable, Equatable {
    /// Its trial ended without a purchase.
    case trialEnded
    /// Its subscription (Stripe or App Store) ended.
    case subscriptionEnded
}

/// How the account came to the free plan: an account that ever had a subscription lost it, any other one ended its
/// trial. Pure function.
public func hostedFreePlanOrigin(entitlements: HostedEntitlements) -> HostedFreePlanOrigin {
    entitlements.subscription != nil || entitlements.appStoreSubscription != nil ? .subscriptionEnded : .trialEnded
}

/// The meeting's transcript has no separated speakers (no segment carries a person): it was written on the device (or
/// kept from its live text) rather than by the server's final pass. Pure function.
public func hostedHasNoSeparatedSpeakers(record: MeetingRecord) -> Bool {
    let segments: [StoredSegment] = meetingSegments(record: record)
    return !segments.isEmpty && segments.allSatisfy { (segment: StoredSegment) -> Bool in segment.person == nil }
}
