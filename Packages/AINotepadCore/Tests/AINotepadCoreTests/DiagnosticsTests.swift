import AINotepadCore
import Foundation
import Testing

@Suite struct DiagnosticsTests {
    // Tanılamaya yol, e-posta, jeton, API anahtarı ve kullanıcı adı girmez; mesaj kısa kalır.
    @Test func redactsPersonalAndSecretParts() {
        let text: String = "Dosya yazılamadı: /Users/ayse/Library/Application Support/AINotepad/x.json, ayse@ornek.com, "
            + "Bearer abc.def, eyJhbGciOi.eyJzdWIiOjF9.c2ln, sk-ant-api03-AbCdEf0123456789xyz, sk_0123456789abcdef0123, Ayşe Yılmaz"
        let redacted: String = redactedDiagnosticText(text: text, userNames: ["ayse", "Ayşe Yılmaz", "a"])
        #expect(!redacted.contains("/Users"))
        #expect(!redacted.contains("ornek.com"))
        #expect(!redacted.contains("abc.def"))
        #expect(!redacted.contains("eyJ"))
        #expect(!redacted.contains("sk-ant") && !redacted.contains("sk_0123"))
        #expect(!redacted.contains("Ayşe Yılmaz"))
        #expect(redacted.contains("‹yol›") && redacted.contains("‹e-posta›") && redacted.contains("‹jeton›") && redacted.contains("‹anahtar›"))
        #expect(redactedDiagnosticText(text: String(repeating: "x", count: 500), userNames: []).count == diagnosticMessageMaxLength)
    }

    // Uygulamanın taşıdığı her kimlik bilgisi biçimi (sahte değerlerle) silinir; hata ayıklamaya yarayan sunucu adı,
    // UUID, bellek adresi aralığı ve hata kodu kalır.
    @Test func redactsEveryCredentialFormat() {
        let secrets: [String] = [
            "FAKErefresh0token-for_tests0123456789abcdEF",
            "0123456789abcdef0123456789abcdef01234567",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmYWtlIn0.ZmFrZS1zaWduYXR1cmU",
            "sk-ant-api03-FAKEfakeFAKEfake0000",
            "sk-proj-FAKEfakeFAKEfake0000",
            "sk_FAKEfakeFAKEfake0000",
            "rk_live_FAKEFAKE00000000",
            "whsec_FAKEFAKE0000000000",
            "appl_FAKEfakeFAKE00000",
            "xoxb-0000-FAKE-not-real",
            "xoxp-0000-FAKE-not-real",
            "ntn_FAKEfakeFAKE00000000",
            "secret_FAKEfakeFAKE00000000",
            "lin_oauth_FAKEfakeFAKE00000000",
            "lin_api_FAKEfakeFAKE00000000",
            "ATATTFAKEfakeFAKE00000000",
            "ghp_FAKEfakeFAKE00000000",
            "ya29.FAKEfakeFAKE00000000",
            "cus_FAKEfake000000",
            "sub_FAKEfake000000",
            "$RCAnonymousID:0123456789abcdef0123456789abcdef",
            "TFAKE/BFAKE/slacksecret",
            "webhooks/123/discordsecret",
            "IncomingWebhook/teamssecret",
            "querysecret",
            "Ym9iOnBhc3N3b3JkMTIz",
            "deepgramkey0000000000000",
            "jsonsecret",
            "formsecret",
            "/Users/ayse/Desktop/Q3 board meeting.m4a",
            "ayse@ornek.com",
        ]
        let text: String = """
            refresh FAKErefresh0token-for_tests0123456789abcdEF deepgram 0123456789abcdef0123456789abcdef01234567
            Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmYWtlIn0.ZmFrZS1zaWduYXR1cmU grant eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmYWtlIn0.ZmFrZS1zaWduYXR1cmU
            sk-ant-api03-FAKEfakeFAKEfake0000 sk-proj-FAKEfakeFAKEfake0000 sk_FAKEfakeFAKEfake0000 rk_live_FAKEFAKE00000000
            whsec_FAKEFAKE0000000000 appl_FAKEfakeFAKE00000 xoxb-0000-FAKE-not-real xoxp-0000-FAKE-not-real
            ntn_FAKEfakeFAKE00000000 secret_FAKEfakeFAKE00000000 lin_oauth_FAKEfakeFAKE00000000 lin_api_FAKEfakeFAKE00000000
            ATATTFAKEfakeFAKE00000000 ghp_FAKEfakeFAKE00000000 ya29.FAKEfakeFAKE00000000 cus_FAKEfake000000 sub_FAKEfake000000
            $RCAnonymousID:0123456789abcdef0123456789abcdef
            NSErrorFailingURLStringKey=https://hooks.slack.com/services/TFAKE/BFAKE/slacksecret, https://discord.com/api/webhooks/123/discordsecret
            https://contoso.webhook.office.com/webhookb2/x@y/IncomingWebhook/teamssecret wss://api.deepgram.com/v1/listen?token=querysecret
            Authorization: Basic Ym9iOnBhc3N3b3JkMTIz Authorization: Token deepgramkey0000000000000
            {"refreshToken":"jsonsecret"} refresh_token=formsecret
            Dosya açılamadı: /Users/ayse/Desktop/Q3 board meeting.m4a, kod 5; ayse@ornek.com
            meeting 8C0F3D9E-1A2B-4C3D-8E9F-0123456789AB region 0000000102d8c000-0000000102d90000 Code=-1009 HTTP 401
            """
        let redacted: String = redactedSensitiveText(text: text, userNames: [])
        for secret in secrets {
            #expect(!redacted.contains(secret), "sızdı: \(secret)")
        }
        #expect(redacted.contains("https://hooks.slack.com/‹yol›") && redacted.contains("wss://api.deepgram.com/‹yol›"))
        #expect(redacted.contains("8C0F3D9E-1A2B-4C3D-8E9F-0123456789AB"))
        #expect(redacted.contains("0000000102d8c000-0000000102d90000"))
        #expect(redacted.contains("Code=-1009") && redacted.contains("HTTP 401") && redacted.contains("kod 5"))
    }

    // Son hatalar en yeni 50 tanedir, eskiden yeniye.
    @Test func keepsNewestErrors() {
        let entries: [DiagnosticErrorEntry] = (0..<60).reversed().map { (index: Int) -> DiagnosticErrorEntry in
            DiagnosticErrorEntry(date: Date(timeIntervalSince1970: Double(index)), code: "c", message: "\(index)")
        }
        let recent: [DiagnosticErrorEntry] = recentDiagnosticErrors(entries: entries, capacity: diagnosticErrorCapacity)
        #expect(recent.count == 50)
        #expect(recent.first?.message == "10")
        #expect(recent.last?.message == "59")
    }

    // Geri bildirime eklenen tanılama sunucunun mesaj sınırına sığdırılır; kullanıcının mesajı kısaltılmaz.
    @Test func diagnosticsFitFeedbackLimit() throws {
        let report: ReportRequest = try feedbackReport(message: "Merhaba", email: "", diagnostics: nil)
        let long: String = diagnosticsText(
            sections: [DiagnosticsSection(title: "Uygulama", items: (0..<500).map { DiagnosticsItem(label: "satır \($0)", value: "değer", status: .plain) })],
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let appended: ReportRequest = try appendingDiagnostics(report: report, diagnosticsText: long, limit: reportMessageLimit)
        let message: String = try #require(appended.message)
        #expect(message.hasPrefix("Merhaba"))
        #expect(reportMessageLength(text: message) <= reportMessageLimit)
        #expect(message.hasSuffix("…"))
        let full: ReportRequest = try feedbackReport(message: String(repeating: "x", count: reportMessageLimit), email: "", diagnostics: nil)
        #expect(throws: ReportError.self) { try appendingDiagnostics(report: full, diagnosticsText: long, limit: reportMessageLimit) }
    }

    // Güncelleme kartı: sürüm notlarının maddeleri sırayla, işaretsiz ve sınırlı; başlık ve paragraflar atlanır.
    @Test func releaseNoteBulletsFromMarkdown() {
        let notes: String = "Intro line.\n\n## What's new\n- **Faster.** Words appear sooner.\n- Import a file.\n\n## Fixes\n* Fewer sign-outs.\n-   \n"
        #expect(releaseNoteBullets(markdown: notes, limit: 10) == ["**Faster.** Words appear sooner.", "Import a file.", "Fewer sign-outs."])
        #expect(releaseNoteBullets(markdown: notes, limit: 2).count == 2)
        #expect(releaseNoteBullets(markdown: "No bullets here.", limit: 4).isEmpty)
    }
}
