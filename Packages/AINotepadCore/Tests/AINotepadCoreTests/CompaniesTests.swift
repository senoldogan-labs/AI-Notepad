import Foundation
import Testing
@testable import AINotepadCore

@Suite struct CompaniesTests {
    private func person(_ name: String, _ email: String, _ meetings: [(id: String, at: Double, seconds: Double)]) -> PersonSummary {
        PersonSummary(
            name: name, role: "", email: email, isSaved: true,
            meetings: meetings.map { PersonMeeting(meetingID: $0.id, title: "T\($0.id)", date: Date(timeIntervalSince1970: $0.at), seconds: $0.seconds, fraction: 0) },
            tasks: [], hasVoiceprint: false
        )
    }

    // Alan adına göre gruplanır; ücretsiz sağlayıcılar ve e-postasızlar dışarıda; kendi alan adı işaretli; toplantılar tekil.
    @Test func groupsPeopleByEmailDomain() {
        let people: [PersonSummary] = [
            person("Jonas", "Jonas@Nordia.fi ", [(id: "1", at: 100, seconds: 30), (id: "2", at: 300, seconds: 10)]),
            person("Maria", "maria@nordia.fi", [(id: "2", at: 300, seconds: 20)]),
            person("Elif", "elif@lumora.io", [(id: "3", at: 200, seconds: 60)]),
            person("Ayşe", "ayse@gmail.com", [(id: "4", at: 400, seconds: 5)]),
            person("Can", "can@hotmail.co.uk", []),
            person("Ola", "ola@yahoo.fr", []),
            person("Mikko", "", [(id: "5", at: 500, seconds: 5)]),
            person("Lena", "lena@acme.co.uk", []),
        ]
        let result: [CompanySummary] = companies(people: people, ownEmail: "me@lumora.io")
        #expect(result.map(\.domain) == ["nordia.fi", "lumora.io", "acme.co.uk"])
        #expect(result.map(\.name) == ["Nordia", "Lumora", "Acme"])
        #expect(result.map(\.isOwn) == [false, true, false])
        let nordia: CompanySummary? = result.first
        #expect(nordia?.people.map(\.name) == ["Jonas", "Maria"])
        #expect(nordia?.meetingCount == 2)
        #expect(nordia?.meetings.map(\.meetingID) == ["2", "1"])
        #expect(nordia?.meetings.first?.people == ["Jonas", "Maria"])
        #expect(nordia?.meetings.first?.seconds == 30)
        #expect(nordia?.totalSeconds == 60)
        #expect(nordia?.lastSeen == Date(timeIntervalSince1970: 300))
        #expect(result.last?.lastSeen == nil)
    }

    @Test func domainHelpers() {
        #expect(emailDomain(email: "a@b") == nil)
        #expect(emailDomain(email: "@nordia.fi") == nil)
        #expect(emailDomain(email: "a@nordia..fi") == nil)
        #expect(emailDomain(email: "a@EU.Nordia.fi") == "eu.nordia.fi")
        #expect(companyName(domain: "eu.nordia.fi") == "Nordia")
        #expect(companyName(domain: "acme.com.tr") == "Acme")
        #expect(isFreeMailDomain(domain: "gmx.de") && isFreeMailDomain(domain: "proton.me") && !isFreeMailDomain(domain: "gmxlabs.com"))
        #expect(companies(people: [], ownEmail: nil).isEmpty)
    }
}
