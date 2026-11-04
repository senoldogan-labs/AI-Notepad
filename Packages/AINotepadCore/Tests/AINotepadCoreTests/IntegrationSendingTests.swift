import Foundation
import Testing
@testable import AINotepadCore

private func sendingRecord(id: String, endedAt: Date, tasks: [NoteTask]) -> MeetingRecord {
    MeetingRecord(
        id: id, title: "T", startedAt: endedAt.addingTimeInterval(-600), endedAt: endedAt, language: nil, status: .done, failureMessage: nil,
        liveSegments: [], finalSegments: [], translations: [:], speakerNames: [:],
        note: MeetingNote(title: "Not", summary: "Özet", decisions: [], tasks: tasks, glossary: []), audioDeleted: false, engine: .cloud,
        notice: nil, meNeedsFinalPass: nil
    )
}

private func destination(id: String, target: DestinationTarget, createdAt: Date) -> NoteDestination {
    NoteDestination(id: id, target: target, autoSend: true, createdAt: createdAt, needsReconnect: false)
}

@Suite struct IntegrationSendingTests {
    // Hedefin türü ayarlardaki kartı seçer: hesap bağlantısı servisine, webhook adresinin servisine, Discord girişi
    // Discord'a, tanınmayan adres genel webhook'a düşer.
    @Test func destinationKindFollowsTarget() {
        let now: Date = Date(timeIntervalSince1970: 2_000_000_000)
        let teams: ChannelConnection = ChannelConnection(
            service: .teams, tokens: OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: now), workspace: "",
            channel: ChannelOption(id: "C", teamID: "T", name: "Takım › Genel")
        )
        let cases: [(DestinationTarget, DestinationKind)] = [
            (.account(teams), .teams),
            (.discordSignIn(URL(string: "https://discord.com/api/webhooks/1/abc")!), .discord),
            (.webhook(URL(string: "https://hooks.slack.com/services/T/B/x")!), .slack),
            (.webhook(URL(string: "https://hooks.zapier.com/x")!), .webhook),
        ]
        for (target, kind) in cases {
            #expect(destinationKind(destination: destination(id: "x", target: target, createdAt: now)) == kind)
        }
        #expect(DestinationKind.slack.channelService == .slack && DestinationKind.zoom.channelService == nil)
    }

    // Kendiliğinden gönderim kuyruğu: işareti henüz yazılamamış, kilitli (kayıtta ya da işleniyor), sonucu belirsiz ve
    // hedefin kalıcı olarak reddettiği gönderimler atlanır.
    @Test func autoSendQueueSkipsPendingLockedUncertainAndRejected() {
        let now: Date = Date(timeIntervalSince1970: 2_000_000_000)
        let target: DestinationTarget = .webhook(URL(string: "https://hooks.zapier.com/x")!)
        let destinations: [NoteDestination] = [destination(id: "d", target: target, createdAt: now.addingTimeInterval(-86_400))]
        let records: [MeetingRecord] = ["serbest", "isaretli", "kilitli", "belirsiz", "reddedildi"].map {
            sendingRecord(id: $0, endedAt: now.addingTimeInterval(-60), tasks: [])
        }
        let queue: [(meetingID: String, destinationID: String)] = autoSendQueue(
            records: records, destinations: destinations, now: now, pendingMarks: ["isaretli": ["d"]], locked: ["kilitli"],
            uncertain: [meetingDestinationKey(meetingID: "belirsiz", destinationID: "d")],
            rejected: [meetingDestinationKey(meetingID: "reddedildi", destinationID: "d")]
        )
        #expect(queue.map { "\($0.meetingID)>\($0.destinationID)" } == ["serbest>d"])
    }

    // Hedefin bilerek reddi (silinmiş webhook, geçersiz istek) kalıcıdır: saatte bir 7 gün yeniden denenmez. Zaman aşımı,
    // hız sınırı, sunucu ve ağ hataları geçicidir.
    @Test func permanentDeliveryFailuresAreClientRejections() {
        for status in [400, 401, 403, 404, 410, 422] {
            #expect(isPermanentDeliveryFailure(error: WebhookError.http(host: "hooks.zapier.com", status: status, body: "")), "durum \(status)")
        }
        #expect(isPermanentDeliveryFailure(error: WebhookError.invalidURL))
        #expect(isPermanentDeliveryFailure(error: ChannelAuthError.http(service: .slack, status: 404, body: "")))
        #expect(isPermanentDeliveryFailure(error: MCPRemoteError.http(server: "mcp.notion.com", status: 400, body: "")))
        for status in [408, 429] {
            #expect(!isPermanentDeliveryFailure(error: WebhookError.http(host: "hooks.zapier.com", status: status, body: "")), "durum \(status)")
        }
        #expect(!isPermanentDeliveryFailure(error: WebhookError.network(host: "hooks.zapier.com", reason: "çevrimdışı")))
        #expect(!isPermanentDeliveryFailure(error: DeliveryUncertainError(host: "hooks.zapier.com", reason: "HTTP 502")))
        #expect(!isPermanentDeliveryFailure(error: URLError(.notConnectedToInternet)))
    }

    // Görev aracına yalnızca kapsamdaki, gönderilmemiş ve tamamlanmamış görevler gider.
    @Test func tasksToSendSkipsSentAndDone() {
        let now: Date = Date(timeIntervalSince1970: 2_000_000_000)
        let mine: NoteTask = NoteTask(owner: "Ben", description: "Bütçeyi yaz", dueDate: nil, isMine: true)
        let sent: NoteTask = NoteTask(owner: "Ben", description: "Sunumu hazırla", dueDate: nil, isMine: true)
        let done: NoteTask = NoteTask(owner: "Ben", description: "Ara", dueDate: nil, isMine: true)
        let other: NoteTask = NoteTask(owner: "Aino", description: "Teklif gönder", dueDate: nil, isMine: false)
        let tracker: TaskTracker = TaskTracker(
            id: "t", service: .linear,
            connection: MCPConnection(
                serverURL: MCPService.linear.serverURL, clientID: "c", tokenEndpoint: URL(string: "https://mcp.linear.app/token")!,
                tokens: OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: now)
            ),
            target: "", identity: nil
        )
        let base: MeetingRecord = sendingRecord(id: "m", endedAt: now, tasks: [mine, sent, done, other])
        let record: MeetingRecord = togglingTask(record: markingTasksSent(record: base, tracker: tracker, tasks: [sent]), task: done)
        let note: MeetingNote = record.note!
        #expect(tasksToSend(record: record, note: note, tracker: tracker, scope: .mine) == [mine])
        #expect(tasksToSend(record: record, note: note, tracker: tracker, scope: .all) == [mine, other])
    }

    // Hesabın Anahtar Zinciri servisi uygulamanın servisinin altında; geçersiz anahtar reddedilir.
    @Test func accountKeychainServiceIsScoped() throws {
        let key: String = accountDataKey(userId: "kullanici-1")
        #expect(try accountKeychainService(appService: "AINotepadHosted", accountKey: key) == "AINotepadHosted.account.\(key)")
        #expect(throws: StorageError.invalidAccountKey(key: "../x")) {
            try accountKeychainService(appService: "AINotepadHosted", accountKey: "../x")
        }
    }

    // Gönderim sonucu bir süre sonra kalkar; "gönderiliyor" kalır.
    @Test func sendStateFadeDelays() {
        #expect(sendResultFadeDelay(state: .sending) == nil)
        #expect(sendResultFadeDelay(state: .sent) == .seconds(3.5))
        #expect(sendResultFadeDelay(state: .failed("x")) == .seconds(5))
    }
}
