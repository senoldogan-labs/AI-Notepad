import Foundation
import Testing
@testable import AINotepadCore

/// Deneme hesabının hak durumu (`trialLeft` toplantı kaldı; `endsAt` doluysa süre o an biter).
private func trialEntitlements(left: Int, endsAt: String?) throws -> HostedEntitlements {
    let ends: String = endsAt.map { #""trialEndsAt":"\#($0)","# } ?? ""
    let json: String = #"""
    {"userId":"u","plan":"trial","trialMeetingsTotal":3,"trialMeetingsLeft":\#(left),"accountTrialMeetingsLeft":\#(left),"deviceTrialMeetingsLeft":null,\#(ends)
     "monthlyHoursUsed":0,"monthlyHoursCap":10,"subscription":null}
    """#
    return try hostedJSONDecoder().decode(HostedEntitlements.self, from: Data(json.utf8))
}

/// Stripe abonesi (`tier` katmanında, `plan` döneminde; `complimentary` ücretsiz erişim); sunucu Pro'yu da satar.
private func subscriberEntitlements(tier: String, plan: String, complimentary: Bool) throws -> HostedEntitlements {
    let json: String = #"""
    {"userId":"u","plan":"subscription","trialMeetingsTotal":3,"trialMeetingsLeft":0,"accountTrialMeetingsLeft":0,"deviceTrialMeetingsLeft":null,
     "monthlyHoursUsed":9,"monthlyHoursCap":10,"tier":"\#(tier)",
     "offeredTiers":[{"tier":"personal","monthlyHours":10,"meetingMaxMinutes":240},{"tier":"pro","monthlyHours":30,"meetingMaxMinutes":240}],
     "subscription":{"status":"active","complimentary":\#(complimentary),"currentPeriodEnd":"2026-11-29T00:00:00.000Z","access":"active","source":"stripe","plan":"\#(plan)","tier":"\#(tier)"}}
    """#
    return try hostedJSONDecoder().decode(HostedEntitlements.self, from: Data(json.utf8))
}

/// Bitmiş toplantı (`minutes` sürdü, notunda `tasks` görev).
private func finishedMeeting(id: String, minutes: Double, tasks: Int) -> MeetingRecord {
    let start: Date = Date(timeIntervalSince1970: 1_000_000)
    let noteTasks: [NoteTask] = (0..<tasks).map { NoteTask(owner: "Sen", description: "Görev \($0)", dueDate: nil, isMine: true) }
    return MeetingRecord(
        id: id, title: id, startedAt: start, endedAt: start.addingTimeInterval(minutes * 60), language: .english, status: .done, failureMessage: nil,
        liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:],
        note: MeetingNote(title: id, summary: "S", decisions: [], tasks: noteTasks, glossary: []), audioDeleted: false, engine: .cloud, notice: nil,
        meNeedsFinalPass: nil
    )
}

@Suite struct HostedConversionTests {
    // Başlık kullanıcının kendi denemesinden: görev varsa görev, yoksa süre, veri yoksa sonuç cümlesi; örnek toplantı
    // sayılmaz; abone sonuçsuz başlık görür; toplantı başlarken ve planlar kendisi açıldığında o anın başlığı.
    @Test func headlineUsesOwnTrialValueOnly() throws {
        let trial: HostedEntitlements = try trialEntitlements(left: 1, endsAt: nil)
        let meetings: [MeetingRecord] = [finishedMeeting(id: "a", minutes: 50, tasks: 4), finishedMeeting(id: "b", minutes: 40, tasks: 3)]
        let sample: MeetingRecord = finishedMeeting(id: "s", minutes: 300, tasks: 9).markedAsSample()
        let value: HostedTrialValue = hostedTrialValue(meetings: meetings + [sample])
        #expect(value.meetings == 2 && value.tasks == 7)
        #expect(hostedPaywallHeadline(value: value, entitlements: trial, trigger: .trialEnding) == .meetingsAndTasks(meetings: 2, tasks: 7))
        let noTasks: HostedTrialValue = hostedTrialValue(meetings: [finishedMeeting(id: "a", minutes: 40.9, tasks: 0)])
        #expect(hostedPaywallHeadline(value: noTasks, entitlements: trial, trigger: .trialNoteReady) == .meetingsAndTime(meetings: 1, minutes: 40))
        #expect(hostedPaywallHeadline(value: hostedTrialValue(meetings: [sample]), entitlements: trial, trigger: .trialEnded) == .outcomeOnly)
        #expect(hostedPaywallHeadline(value: value, entitlements: trial, trigger: .meetingStart) == .meetingStarting)
        #expect(hostedPaywallHeadline(value: value, entitlements: trial, trigger: .planChoice) == .choosePlan)
        let subscriber: HostedEntitlements = try subscriberEntitlements(tier: "personal", plan: "monthly", complimentary: false)
        #expect(hostedPaywallHeadline(value: value, entitlements: subscriber, trigger: .subscriptionRequired) == .outcomeOnly)
        #expect(hostedPaywallHeadline(value: value, entitlements: nil, trigger: .trialEnded) == .outcomeOnly)
    }

    // Tek tasarruf rakamı, aşağı yuvarlanır (Mac ve web sabit fiyatlarla, iPhone App Store fiyatlarıyla aynı fonksiyon).
    @Test func savingsRoundDownEverywhere() {
        #expect(hostedYearlySavingsPercent(tier: .personal) == 31)
        #expect(hostedYearlySavingsPercent(tier: .pro) == 30)
        #expect(yearlySavingsPercent(monthlyPrice: Decimal(string: "12.99")!, yearlyPrice: 109) == 30)
    }

    // Hatırlatma bitişten 24 saat önce, yerel 09:00–20:00'e çekilir; geçmişse ya da 2 saatten az kaldıysa yok.
    @Test func trialReminderFiresInsideTheDaytimeWindow() throws {
        var calendar: Calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Helsinki") ?? .gmt
        func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        let now: Date = at(10, 12, 0)
        #expect(trialReminderFireDate(endsAt: at(14, 15, 30), now: now, calendar: calendar) == at(13, 15, 30))
        #expect(trialReminderFireDate(endsAt: at(14, 6, 0), now: now, calendar: calendar) == at(13, 9, 0))
        #expect(trialReminderFireDate(endsAt: at(14, 23, 0), now: now, calendar: calendar) == at(13, 20, 0))
        #expect(trialReminderFireDate(endsAt: at(11, 10, 0), now: now, calendar: calendar) == nil)
        #expect(trialReminderFireDate(endsAt: at(10, 13, 0), now: now, calendar: calendar) == nil)
        let notification: EngagementNotification = try #require(trialEndingNotification(trial: EngagementTrial(endsAt: at(14, 15, 30), meetingsLeft: 2), now: now, calendar: calendar))
        #expect(notification.identifier == EngagementNotificationID.trialEnding)
        #expect(trialEndingNotification(trial: EngagementTrial(endsAt: at(14, 15, 30), meetingsLeft: 0), now: now, calendar: calendar) == nil)
        #expect(engagementRoute(categoryIdentifier: EngagementNotificationID.trialEndingCategory, actionIdentifier: "tap", meetingID: nil, taskKey: nil) == .plans)
        // Kapalıyken (varsayılan) ve deneme yokken plana girmez; aylık sınır ve geri çağırma hiç bildirim olmaz.
        let input: (Bool, EngagementTrial?) -> EngagementPlanInput = { (on: Bool, trial: EngagementTrial?) -> EngagementPlanInput in
            EngagementPlanInput(
                records: [], userName: "", settings: EngagementSettings(noteReady: true, taskDue: true, weeklySummary: true, inactive: true, trialReminder: on),
                calendarMeetings: [], otherPendingCount: 0, trial: trial, now: now, calendar: calendar, locale: Locale(identifier: "en_US")
            )
        }
        let trial: EngagementTrial = EngagementTrial(endsAt: at(14, 15, 30), meetingsLeft: 2)
        #expect(plannedEngagementNotifications(input: input(true, trial)).map(\.identifier) == [EngagementNotificationID.trialEnding])
        #expect(plannedEngagementNotifications(input: input(false, trial)).isEmpty)
        #expect(plannedEngagementNotifications(input: input(true, nil)).isEmpty)
    }

    // "Bir gün önce hatırlat" yalnızca süreyle sınırlı denemede, bitişe 24 saatten çok varken.
    @Test func reminderIsOfferedOnlyWhenItCanStillFire() throws {
        let now: Date = try #require(ISO8601DateFormatter().date(from: "2026-11-10T12:00:00Z"))
        #expect(hostedTrialReminderOfferable(entitlements: try trialEntitlements(left: 2, endsAt: "2026-11-13T12:00:00.000Z"), now: now))
        #expect(!hostedTrialReminderOfferable(entitlements: try trialEntitlements(left: 2, endsAt: "2026-11-11T10:00:00.000Z"), now: now))
        #expect(!hostedTrialReminderOfferable(entitlements: try trialEntitlements(left: 2, endsAt: nil), now: now))
        #expect(!hostedTrialReminderOfferable(entitlements: try trialEntitlements(left: 0, endsAt: "2026-11-13T12:00:00.000Z"), now: now))
        #expect(hostedTrialEndingDetail(entitlements: try trialEntitlements(left: 1, endsAt: nil), now: now) == .lastMeeting)
        let soon: Date = try #require(ISO8601DateFormatter().date(from: "2026-11-11T18:00:00Z"))
        #expect(hostedTrialEndingDetail(entitlements: try trialEntitlements(left: 2, endsAt: "2026-11-11T18:00:00.000Z"), now: now) == .endsSoon(endsAt: soon, meetingsLeft: 2))
    }

    // Kendiliğinden teklif günde en çok bir; kayıt ya da karşılama sürerken hiç.
    @Test func autoPromptsAreRateLimitedAndNeverInterrupt() {
        let now: Date = Date(timeIntervalSince1970: 5_000_000)
        #expect(hostedAutoPromptAllowed(lastAutoPromptAt: nil, now: now, activity: .idle))
        #expect(!hostedAutoPromptAllowed(lastAutoPromptAt: now.addingTimeInterval(-3600), now: now, activity: .idle))
        #expect(hostedAutoPromptAllowed(lastAutoPromptAt: now.addingTimeInterval(-hostedAutoPromptIntervalSec), now: now, activity: .idle))
        #expect(!hostedAutoPromptAllowed(lastAutoPromptAt: nil, now: now, activity: .meetingInProgress))
        #expect(!hostedAutoPromptAllowed(lastAutoPromptAt: nil, now: now, activity: .onboarding))
    }

    // Geri çağırma 3. ve 14. günde, en çok iki kez, 45. günden sonra hiç; yalnızca hiç abone olmamış bitmiş denemede.
    @Test func winBackDaysAndCap() throws {
        let ended: Date = Date(timeIntervalSince1970: 7_000_000)
        let day: Double = 86_400
        #expect(!hostedWinBackDue(trialEndedAt: ended, shownCount: 0, now: ended.addingTimeInterval(2.9 * day)))
        #expect(hostedWinBackDue(trialEndedAt: ended, shownCount: 0, now: ended.addingTimeInterval(3 * day)))
        #expect(!hostedWinBackDue(trialEndedAt: ended, shownCount: 1, now: ended.addingTimeInterval(10 * day)))
        #expect(hostedWinBackDue(trialEndedAt: ended, shownCount: 1, now: ended.addingTimeInterval(14 * day)))
        #expect(!hostedWinBackDue(trialEndedAt: ended, shownCount: 2, now: ended.addingTimeInterval(20 * day)))
        #expect(!hostedWinBackDue(trialEndedAt: ended, shownCount: 0, now: ended.addingTimeInterval(46 * day)))
        #expect(hostedTrialEndedAt(trialEndsAt: ended, observedAt: nil, now: ended.addingTimeInterval(day)) == ended)
        #expect(hostedTrialEndedAt(trialEndsAt: ended.addingTimeInterval(day), observedAt: ended, now: ended) == ended)
        #expect(hostedWinBackEligible(entitlements: try trialEntitlements(left: 0, endsAt: nil)))
        #expect(!hostedWinBackEligible(entitlements: try trialEntitlements(left: 1, endsAt: nil)))
        #expect(!hostedWinBackEligible(entitlements: try subscriberEntitlements(tier: "personal", plan: "monthly", complimentary: false)))
    }

    // Aylık sınırda Pro yalnızca Kişisel aboneye; seçili plan abonenin şimdiki dönemi.
    @Test func proUpsellAtTheMonthlyLimit() throws {
        let monthly: HostedEntitlements = try subscriberEntitlements(tier: "personal", plan: "monthly", complimentary: false)
        #expect(hostedProUpsell(entitlements: monthly)?.monthlyHours == 30)
        #expect(hostedCurrentBillingPlan(entitlements: monthly) == .monthly)
        #expect(hostedPreselectedTier(trigger: .monthlyFull, entitlements: monthly) == .pro)
        #expect(hostedPreselectedTier(trigger: .planChoice, entitlements: monthly) == .personal)
        #expect(hostedProUpsell(entitlements: try subscriberEntitlements(tier: "pro", plan: "yearly", complimentary: false)) == nil)
        #expect(hostedProUpsell(entitlements: try subscriberEntitlements(tier: "personal", plan: "yearly", complimentary: true)) == nil)
        #expect(hostedProUpsell(entitlements: try trialEntitlements(left: 1, endsAt: nil)) == nil)
        #expect(hostedPreselectedTier(trigger: .monthlyFull, entitlements: try trialEntitlements(left: 1, endsAt: nil)) == .personal)
    }

    // Hata sınıfları açık eşlenir; hata metni gönderilmez.
    @Test func failureReasonsAreMappedExhaustively() {
        #expect(conversionReason(clientError: .notSignedIn) == .notSignedIn)
        #expect(conversionReason(clientError: .network(path: "/v1/billing/checkout", reason: "offline")) == .network)
        #expect(conversionReason(clientError: .invalidBaseURL(value: "")) == .configuration)
        #expect(conversionReason(error: HostedClientError.sessionEnded) == .notSignedIn)
        #expect(conversionReason(error: HostedAppStoreEntitlementMissing(attempts: 7, lastError: nil)) == .entitlementTimeout)
        #expect(conversionReason(error: HostedAPIError(code: nil, rawCode: "x", status: 500, serverMessage: "", path: "/v1/billing/checkout")) == .server)
    }

    // Aynı olay tek satırda toplanır; gövdede yalnızca türün alanları; eski bekleyen kayıt okunur; tek gövde 50 olayı aşmaz.
    @Test func conversionEventsAggregateAndEncodeStrictly() throws {
        let shown: ConversionEvent = .paywallShown(surface: .paywall, trigger: .trialEnded, tiersOffered: .personal)
        let pending: TelemetryPendingEvents = [shown, shown, .trialReminderOptIn, .upsellShown(trigger: .winBack)].reduce(emptyTelemetryPendingEvents()) {
            addingConversion(pending: $0, event: $1)
        }
        #expect(pending.conversions.count == 3)
        #expect(pending.conversions.first { $0.event == shown }?.count == 2)
        let body: Data = try #require(try hostedTelemetryEventsBody(pending: pending))
        let events: [[String: Any]] = try #require((try JSONSerialization.jsonObject(with: body) as? [String: Any])?["events"] as? [[String: Any]])
        let paywall: [String: Any] = try #require(events.first { $0["kind"] as? String == "paywall_shown" })
        #expect(Set(paywall.keys) == ["kind", "surface", "trigger", "tiersOffered", "count"])
        #expect(paywall["tiersOffered"] as? String == "personal" && paywall["count"] as? Int == 2)
        let optIn: [String: Any] = try #require(events.first { $0["kind"] as? String == "trial_reminder_opt_in" })
        #expect(Set(optIn.keys) == ["kind", "count"])
        let old: Data = Data(#"{"counts":[{"kind":"recording_overrun","count":1}],"durations":[]}"#.utf8)
        #expect(try JSONDecoder().decode(TelemetryPendingEvents.self, from: old).conversions.isEmpty)
        let roundTrip: TelemetryPendingEvents = try JSONDecoder().decode(TelemetryPendingEvents.self, from: JSONEncoder().encode(pending))
        #expect(roundTrip == pending)
        let many: TelemetryPendingEvents = ConversionTrigger.allCases.flatMap { (trigger: ConversionTrigger) -> [ConversionEvent] in
            ConversionSurface.allCases.map { ConversionEvent.paywallClosed(surface: $0, trigger: trigger) }
        }.reduce(emptyTelemetryPendingEvents()) { addingConversion(pending: $0, event: $1) }
        let batch: TelemetryPendingEvents = telemetryBatch(pending: many)
        #expect(batch.conversions.count == telemetryMaxEventsPerBatch)
        #expect(subtractingTelemetry(sent: batch, from: many).conversions.count == many.conversions.count - telemetryMaxEventsPerBatch)
    }

    // iPhone'da huni olayları yalnızca kullanıcının kendisi açtığı paylaşımla; Mac'te paylaşım ayarı yeter.
    @Test func iPhoneNeedsExplicitOptIn() {
        #expect(conversionTelemetryAllowed(edition: .hosted, sharingEnabled: true, consent: .sharingSetting))
        #expect(!conversionTelemetryAllowed(edition: .hosted, sharingEnabled: true, consent: .explicitOptIn(given: false)))
        #expect(conversionTelemetryAllowed(edition: .hosted, sharingEnabled: true, consent: .explicitOptIn(given: true)))
        #expect(!conversionTelemetryAllowed(edition: .hosted, sharingEnabled: false, consent: .explicitOptIn(given: true)))
        #expect(!conversionTelemetryAllowed(edition: .developer, sharingEnabled: true, consent: .sharingSetting))
    }
}
