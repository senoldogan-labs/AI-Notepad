import Foundation
import Testing
@testable import AINotepadCore

@Suite struct AppLinksTests {
    private func route(_ address: String) -> AppLinkRoute? {
        appLinkRoute(url: URL(string: address)!)
    }

    // Şemadaki yerler: büyük harfli şema ya da yer, sondaki eğik çizgi, sorgu ve `#` parçası aynı yeri açar.
    @Test func customSchemeRoutes() {
        #expect(route("gistsmith://record") == .record)
        #expect(route("gistsmith://ask") == .ask)
        #expect(route("gistsmith://tasks") == .tasks)
        #expect(route("gistsmith://insights") == .insights)
        #expect(route("GISTSMITH://Record/") == .record)
        #expect(route("gistsmith://record?source=event#x") == .record)
        #expect(route("gistsmith://meeting/20261105-103000") == .meeting("20261105-103000"))
        #expect(route("gistsmith://meeting/0A4F2C1E-7B7D-4C33-9E55-2F3B6A1C9D10/") == .meeting("0A4F2C1E-7B7D-4C33-9E55-2F3B6A1C9D10"))
    }

    // Evrensel bağlantılar: asistanın toplantı adresi ve /open/ altındaki yerler; www da kabul edilir.
    @Test func universalLinkRoutes() {
        #expect(route("https://gistsmith.com/m/20261105-103000") == .meeting("20261105-103000"))
        #expect(route("https://www.gistsmith.com/m/abc_1/") == .meeting("abc_1"))
        #expect(route("https://gistsmith.com/open/record") == .record)
        #expect(route("https://gistsmith.com/open/tasks") == .tasks)
        #expect(route("https://gistsmith.com/open/meeting/abc") == .meeting("abc"))
    }

    // Tanınmayan, eksik ya da fazla parçalı adres, başka şema ya da alan adı, kimlik bilgisi ya da kapı taşıyan adres ve
    // kurala uymayan kimlik yok sayılır (uygulama hiçbir yeri açmaz).
    @Test func rejectsUnknownAndMalformedLinks() {
        let rejected: [String] = [
            "gistsmith://", "gistsmith:record", "gistsmith://settings", "gistsmith://record/now", "gistsmith://meeting",
            "gistsmith://meeting/", "gistsmith://meeting/a/b", "gistsmith://meeting/..", "gistsmith://meeting/-abc",
            "gistsmith://meeting/a%2Fb", "gistsmith://meeting/a%20b", "gistsmith://meeting/%C3%A7", "gistsmith://user@record",
            "gistsmith://record:80", "https://gistsmith.com/", "https://gistsmith.com/m", "https://gistsmith.com/m/a/b",
            "https://gistsmith.com/meeting", "https://gistsmith.com/open", "https://gistsmith.com/open/settings",
            "http://gistsmith.com/m/abc", "https://evil.com/m/abc", "https://gistsmith.com.evil.com/m/abc",
            "https://gistsmith.com:8443/m/abc", "https://u:p@gistsmith.com/m/abc", "com.senoldogan.ainotepad://record",
            "file:///tmp/record", "gistsmith://meeting/\(String(repeating: "a", count: 65))",
        ]
        for address in rejected {
            #expect(route(address) == nil, "kabul edilmemeli: \(address)")
        }
        #expect(route("gistsmith://meeting/\(String(repeating: "a", count: 64))") == .meeting(String(repeating: "a", count: 64)))
    }

    // Bağlantıdaki kimlik: önce birebir; UUID büyük-küçük harf gözetmeden eşleşir, diğer kimlikler eşleşmez.
    @Test func linkedMeetingIDMatchesUUIDCaseInsensitively() {
        let upper: String = "0A4F2C1E-7B7D-4C33-9E55-2F3B6A1C9D10"
        let ids: [String] = ["20261105-103000", upper, "Weekly"]
        #expect(linkedMeetingID(linkID: "20261105-103000", meetingIDs: ids) == "20261105-103000")
        #expect(linkedMeetingID(linkID: upper.lowercased(), meetingIDs: ids) == upper)
        #expect(linkedMeetingID(linkID: "weekly", meetingIDs: ids) == nil)
        #expect(linkedMeetingID(linkID: "missing", meetingIDs: ids) == nil)
    }
}
