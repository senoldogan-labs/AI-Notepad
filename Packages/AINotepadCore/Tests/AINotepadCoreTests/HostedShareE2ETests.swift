import Foundation
import Testing
@testable import AINotepadCore

// Local server (`wrangler dev`) only, like the rest of `HostedE2ETests` (enable with `AINOTEPAD_HOSTED_E2E=1` and
// `AINOTEPAD_HOSTED_BASE`); macOS only because the helpers prepare the local D1 with `Process`.
#if os(macOS)

/// The site origin the local server allows for CORS (`SITE_ORIGIN` in the development `vars`).
private let localSiteOrigin: String = "http://localhost:8788"

/// `GET /v1/public/shares/:id` as the site's share page sends it: no session, the site as `Origin`.
private func publicShare(baseURL: URL, shareID: String) async throws -> (status: Int, body: Data, allowOrigin: String?) {
    var request: URLRequest = URLRequest(url: baseURL.appending(path: "v1/public/shares/\(shareID)"))
    request.setValue(localSiteOrigin, forHTTPHeaderField: "origin")
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let (data, response): (Data, URLResponse) = try await URLSession.shared.data(for: request)
    let http: HTTPURLResponse = try #require(response as? HTTPURLResponse)
    return (http.statusCode, data, http.value(forHTTPHeaderField: "access-control-allow-origin"))
}

extension HostedE2ETests {
    // Share a note with a link against the local server: the app seals the note and uploads only ciphertext; the share
    // page's public endpoint returns exactly those bytes to the site's origin; they open with the link's key; the
    // server's copy never holds the plaintext; removing the link makes the public endpoint answer 404.
    @Test func noteShareRoundTripAgainstLocalServer() async throws {
        let baseURL: URL = try localServerBase()
        let refresh: String = randomToken()
        let userID: String = try insertSession(refreshToken: refresh)
        // A started trial may create links (like sync writes).
        try executeLocalD1(sql: "UPDATE users SET trial_started_at = \(nowMs()) WHERE id = '\(userID)';")
        let storage: MemoryTokenStorage = MemoryTokenStorage(tokens: HostedTokens(accessToken: "gecersiz", refreshToken: refresh, accessExpiresAt: Date.distantPast, userId: userID))
        let session: HostedClient = HostedClient(clientInfo: e2eClientInfo, baseURL: baseURL, storage: storage) { () async -> Void in }
        // The app agrees to the AI disclosure before any AI request (see `HostedAIConsent.swift`).
        session.setAIConsent(granted: true)
        _ = try await awaitingAuthLimit { try await session.validAccessToken() }
        let shares: HostedShareClient = HostedShareClient(baseURL: baseURL, credentials: session)

        let marker: String = "Secret-\(UUID().uuidString)"
        let payload: SharedNotePayload = SharedNotePayload(
            v: 1, lang: "en", rtl: false, title: "Budget \(marker)", subtitle: "November 6, 2026", headings: SharedNoteHeadings(
                summary: "Summary", outline: "Topics", decisions: "Decisions", openQuestions: "Open questions", tasks: "Tasks", glossary: "Glossary",
                transcript: "Transcript"
            ),
            summary: "The budget grows. \(marker)", outline: [], decisions: ["Grow the budget."], openQuestions: [],
            tasks: [SharedTask(owner: "Aino", description: "Send the deck", due: nil)], glossary: [], transcript: nil
        )
        let secret: NoteShareSecret = newNoteShareSecret()
        let blob: Data = try sealNoteShare(payload: payload, secret: secret, nonce: nil)
        let created: HostedNoteShare = try await shares.create(shareID: secret.shareID, blob: blob, expiry: .week)
        #expect(created.shareId == secret.shareID && created.size == blob.count)
        #expect(created.expiresAt - created.createdAt == 7 * 86_400_000)
        // Repeating the upload (lost response) returns the same link.
        #expect(try await shares.create(shareID: secret.shareID, blob: blob, expiry: .week) == created)
        #expect(try await shares.list().map(\.shareId) == [secret.shareID])

        let fetched = try await publicShare(baseURL: baseURL, shareID: secret.shareID)
        #expect(fetched.status == 200 && fetched.allowOrigin == localSiteOrigin)
        #expect(fetched.body == blob)
        let link: URL = noteShareLink(siteOrigin: try #require(URL(string: localSiteOrigin)), secret: secret)
        #expect(try openNoteShare(blob: fetched.body, secret: try noteShareSecret(link: link)) == payload)
        let stored: [StoredShare] = try localD1Rows(sql: "SELECT size, hex(ciphertext) AS hex FROM note_shares WHERE share_id = '\(secret.shareID)';", as: StoredShare.self)
        #expect(stored.count == 1 && stored.first?.size == blob.count)
        #expect(stored.first?.hex.contains(Data(marker.utf8).map { String(format: "%02X", $0) }.joined()) == false)

        try await shares.delete(shareID: secret.shareID)
        #expect(try await publicShare(baseURL: baseURL, shareID: secret.shareID).status == 404)
        #expect(try await shares.list().isEmpty)
        await #expect(throws: HostedAPIError.self) { try await shares.delete(shareID: secret.shareID) }
    }
}

/// `note_shares` row as stored (ciphertext as hex).
private struct StoredShare: Decodable {
    let size: Int
    let hex: String
}

#endif
