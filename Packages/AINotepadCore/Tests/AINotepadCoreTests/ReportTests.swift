import Foundation
import Testing
@testable import AINotepadCore

@Suite struct ReportTests {
    // Geri bildirim kırpılır; boş e-posta ve istenmeyen tanılama gönderilmez; sınırlar ve e-posta kuralı sunucununkiyle aynı.
    @Test func feedbackReportValidation() throws {
        let diagnostics: ReportDiagnostics = ReportDiagnostics(appVersion: "0.1.3 (4)", os: "macOS Version 26.1 (Build 25B78)")
        #expect(try feedbackReport(message: "  Not yazılmadı.\n", email: " ", diagnostics: nil, quoteFirstName: nil)
            == ReportRequest(kind: .feedback, message: "Not yazılmadı.", email: nil, appVersion: nil, os: nil, payload: nil, quoteFirstName: nil))
        #expect(try feedbackReport(message: "Merhaba", email: "aino@ornek.fi", diagnostics: diagnostics, quoteFirstName: nil)
            == ReportRequest(kind: .feedback, message: "Merhaba", email: "aino@ornek.fi", appVersion: "0.1.3 (4)", os: "macOS Version 26.1 (Build 25B78)", payload: nil, quoteFirstName: nil))
        #expect(throws: ReportError.emptyMessage) { try feedbackReport(message: " \n", email: "", diagnostics: nil, quoteFirstName: nil) }
        #expect(throws: ReportError.invalidEmail) { try feedbackReport(message: "x", email: "aino@ornek", diagnostics: nil, quoteFirstName: nil) }
        #expect(throws: ReportError.invalidEmail) { try feedbackReport(message: "x", email: "a b@ornek.fi", diagnostics: nil, quoteFirstName: nil) }
        // Sunucunun `z.email()` kuralı: ASCII yerel kısım, boş noktalı parça yok, alan adı harf/rakamla başlar, uzantı ≥ 2 harf.
        for rejected in ["doğan@ornek.fi", "a@b.c", "a..b@ornek.fi", "a@-x.fi", "\"a\"@x.com"] {
            #expect(throws: ReportError.invalidEmail) { try feedbackReport(message: "x", email: rejected, diagnostics: nil, quoteFirstName: nil) }
        }
        #expect(isPlausibleEmail(text: "first.last+tag@sub.example.com"))
        #expect(try feedbackReport(message: String(repeating: "a", count: reportMessageLimit), email: "", diagnostics: nil, quoteFirstName: nil).message?.count == reportMessageLimit)
        // Sunucu UTF-16 birimi sayar: emoji iki birimdir.
        #expect(throws: ReportError.messageTooLong(count: reportMessageLimit + 2, limit: reportMessageLimit)) {
            try feedbackReport(message: String(repeating: "a", count: reportMessageLimit) + "🙂", email: "", diagnostics: nil, quoteFirstName: nil)
        }
        let encoded: [String: String] = try JSONDecoder().decode([String: String].self, from: try JSONEncoder().encode(try feedbackReport(message: "x", email: "", diagnostics: nil, quoteFirstName: nil)))
        #expect(encoded == ["kind": "feedback", "message": "x"])
    }

    // Alıntı izni: ön ad kırpılıp gönderilir; izin yoksa alan hiç gönderilmez; kural sunucununkiyle aynı.
    @Test func feedbackQuoteConsent() throws {
        let consented: ReportRequest = try feedbackReport(message: "Harika", email: "", diagnostics: nil, quoteFirstName: "  Aino ")
        #expect(consented.quoteFirstName == "Aino")
        let encoded: [String: String] = try JSONDecoder().decode([String: String].self, from: try JSONEncoder().encode(consented))
        #expect(encoded == ["kind": "feedback", "message": "Harika", "quoteFirstName": "Aino"])
        for accepted in ["Şenol", "Anna-Liisa", "O'Brien", "J. R.", "Jyväskylä", "Zoë", "Zoe\u{0308}", "李"] {
            #expect(try feedbackReport(message: "x", email: "", diagnostics: nil, quoteFirstName: accepted).quoteFirstName == accepted)
        }
        for rejected in ["", "  ", "-Aino", "Aino1", "a@b", "<b>", "Aino\nX", String(repeating: "a", count: feedbackQuoteNameLimit + 1)] {
            #expect(throws: ReportError.invalidQuoteName) { try feedbackReport(message: "x", email: "", diagnostics: nil, quoteFirstName: rejected) }
        }
        #expect(isValidQuoteFirstName(text: String(repeating: "a", count: feedbackQuoteNameLimit)))
        // Klavyenin akıllı tırnağı (’) kabul edilir ve düz kesme olarak gönderilir.
        #expect(try feedbackReport(message: "x", email: "", diagnostics: nil, quoteFirstName: " O\u{2019}Brien ").quoteFirstName == "O'Brien")
        // Birleşen işaret ayrı kod noktası sayılır (sunucu da öyle sayar).
        #expect(!isValidQuoteFirstName(text: String(repeating: "e\u{0301}", count: feedbackQuoteNameLimit / 2 + 1)))
        // Tanılama eklenince izin korunur.
        #expect(try appendingDiagnostics(report: consented, diagnosticsText: "d", limit: reportMessageLimit).quoteFirstName == "Aino")
    }

    // Rapor sunucusu https olmalı.
    @Test func reportsBaseURLRequiresHTTPS() throws {
        #expect(try reportsAPIBaseURL(value: "https://api.gistsmith.com").absoluteString == "https://api.gistsmith.com")
        #expect(throws: HostedClientError.insecureBaseURL(url: "http://localhost:8787")) { try reportsAPIBaseURL(value: "http://localhost:8787") }
        #expect(throws: HostedClientError.invalidBaseURL(value: "")) { try reportsAPIBaseURL(value: "") }
    }
}
