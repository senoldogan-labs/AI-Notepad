import Foundation
import Testing
@testable import AINotepadCore

@Suite struct UserProfileTests {
    @Test func emptyProfileRendersNoBlock() {
        #expect(userProfilePromptBlock(profile: .empty).isEmpty)
        // Ad istemde zaten `promptUserRule` ile gider: yalnız adı olan profil blok yazmaz.
        #expect(userProfilePromptBlock(profile: UserProfile(name: "Doğan", jobTitle: " ", companyName: "\n", companyDescription: "")).isEmpty)
        #expect(withUserProfile(system: "Sistem", profile: .empty) == "Sistem")
    }

    @Test func blockKeepsFieldOrderAndCapsDescription() {
        let long: String = String(repeating: "a", count: profileDescriptionLimit + 50)
        let block: String = userProfilePromptBlock(profile: UserProfile(
            name: "Doğan", jobTitle: "  Ürün yöneticisi ", companyName: "Gistsmith", companyDescription: long
        ))
        let lines: [String] = block.components(separatedBy: "\n").filter { $0.contains(": ") && !$0.contains("arka plan") }
        #expect(lines == ["Unvan: Ürün yöneticisi", "Şirket: Gistsmith", "Şirket açıklaması: \(String(repeating: "a", count: profileDescriptionLimit))"])
        #expect(!block.contains("Doğan"))
        #expect(block.contains("Toplantıda söylenmiş gibi yazma"))
        // Boş alan atlanır, sıra korunur.
        let partial: String = userProfilePromptBlock(profile: UserProfile(name: "", jobTitle: "", companyName: "", companyDescription: "Muhasebe yazılımı"))
        #expect(partial.contains("<kullanici_hakkinda>\nŞirket açıklaması: Muhasebe yazılımı\n</kullanici_hakkinda>"))
        #expect(cappedProfileText(text: long, limit: profileDescriptionLimit).count == profileDescriptionLimit)
    }

    @Test func notePromptsUnchangedWithoutProfile() throws {
        let segments: [StoredSegment] = [stored("final-0", .others, 1, 5, "Voisitko tehdä diat?"), stored("me-0", .me, nil, 9, "Teen ne.")]
        let profile: UserProfile = UserProfile(name: "Doğan", jobTitle: "Satış müdürü", companyName: "Acme", companyDescription: "Lojistik yazılımı")
        let block: String = userProfilePromptBlock(profile: profile)
        let note: (UserProfile) throws -> LLMRequest = { (profile: UserProfile) throws -> LLMRequest in
            try #require(meetingNoteRequest(
                segments: segments, speakerNames: [:], userName: "Doğan", profile: profile, template: .general, myNotes: "", language: .turkish, screens: []
            ))
        }
        let plain: LLMRequest = try note(.empty)
        let withProfile: LLMRequest = try note(profile)
        #expect(!plain.system.contains("kullanici_hakkinda"))
        // Profil yalnızca sistemin sonuna eklenir; geri kalan her şey aynı.
        #expect(withProfile.system == plain.system + "\n" + block)
        #expect(withProfile.userText == plain.userText)
        #expect(try note(UserProfile(name: "Doğan", jobTitle: "", companyName: "", companyDescription: "")) == plain)
        // Uzun notun parçası, özeti, düzenleme, Sor ve takip e-postası da aynı bloğu alır.
        let chunk: (UserProfile) -> String = { (profile: UserProfile) -> String in
            noteChunkRequest(
                chunk: segments, part: 1, partCount: 2, state: .empty, speakerNames: [:], userName: "Doğan", profile: profile, template: .general,
                myNotes: "", language: .turkish
            ).system
        }
        #expect(chunk(profile) == chunk(.empty) + "\n" + block)
        let overview: (UserProfile) -> String = { (profile: UserProfile) -> String in
            noteOverviewRequest(state: .empty, userName: "Doğan", profile: profile, template: .general, myNotes: "", language: .turkish, screens: []).system
        }
        #expect(overview(profile) == overview(.empty) + "\n" + block)
        let utc: TimeZone = try #require(TimeZone(identifier: "UTC"))
        let meetingNote: MeetingNote = MeetingNote(title: "Demo", summary: "Özet", decisions: [], tasks: [], glossary: [])
        let edit: (UserProfile) -> String = { (profile: UserProfile) -> String in
            noteEditRequest(note: meetingNote, instruction: "Kısalt", segments: segments, speakerNames: [:], userName: "Doğan", profile: profile, language: .turkish).system
        }
        #expect(edit(profile) == edit(.empty) + "\n" + block)
        let email: (UserProfile) -> String = { (profile: UserProfile) -> String in
            followUpEmailRequest(
                note: meetingNote, startedAt: Date(timeIntervalSince1970: 0), attendees: [], userName: "Doğan", profile: profile, language: .turkish,
                timeZone: utc
            ).system
        }
        #expect(email(profile) == email(.empty) + "\n" + block)
        let ask: (UserProfile) -> String = { (profile: UserProfile) -> String in
            archiveAnswerRequest(
                question: "Ne konuşuldu?", passages: [], coverage: archiveCoverage(read: [], candidates: []), screens: [], history: [], userName: "Doğan",
                profile: profile, now: Date(timeIntervalSince1970: 0), language: .turkish, webSearch: false
            ).system
        }
        #expect(ask(profile) == ask(.empty) + "\n" + block)
    }
}
