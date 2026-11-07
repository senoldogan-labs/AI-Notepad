import Foundation
import Testing
@testable import AINotepadCore

/// The in-app dialer's number rules and server answers (pure functions; the server's own tests are in
/// `server/test/phone.test.ts`).
@Suite struct PhoneDialerTests {
    private let northAmerica: [PhoneDialCountry] = [.us, .ca]

    @Test func emergencyAndShortNumbersGoToThePhoneApp() {
        for number in ["911", "112", "988", "999", "411", "1 1 2"] {
            #expect(phoneDialTarget(input: number, allowed: northAmerica) == .phoneApp(number: number.replacingOccurrences(of: " ", with: "")))
        }
        #expect(phoneTelURL(number: "911")?.absoluteString == "tel:911")
        // With a `+` it is a (malformed) international number, not a short code.
        #expect(phoneDialTarget(input: "+911", allowed: northAmerica) == .invalid)
    }

    @Test func northAmericanFormatsBecomeE164() {
        let expected: PhoneDialTarget = .call(e164: "+12125550199", country: .us)
        for input in ["(212) 555-0199", "212.555.0199", "1 212 555 0199", "+1 212 555 0199", "011 1 212 555 0199", "0012125550199"] {
            #expect(phoneDialTarget(input: input, allowed: northAmerica) == expected, "\(input)")
        }
        #expect(phoneDialTarget(input: "416 555 0199", allowed: northAmerica) == .call(e164: "+14165550199", country: .ca))
        #expect(phoneDialTarget(input: "800 555 0199", allowed: northAmerica) == .call(e164: "+18005550199", country: .us))
        // Without US or Canada allowed, a bare 10-digit number has no country.
        #expect(phoneDialTarget(input: "212 555 0199", allowed: [.fi]) == .invalid)
    }

    @Test func premiumForeignAndPartialNumbersAreRefused() {
        #expect(phoneDialTarget(input: "1 900 555 0199", allowed: northAmerica) == .blocked(.premium))
        #expect(phoneDialTarget(input: "212 976 5555", allowed: northAmerica) == .blocked(.premium))
        #expect(phoneDialTarget(input: "876 555 0199", allowed: northAmerica) == .blocked(.unsupported))
        #expect(phoneDialTarget(input: "+44 7700 900123", allowed: northAmerica) == .blocked(.unsupported))
        #expect(phoneDialTarget(input: "+90 532 123 45 67", allowed: northAmerica) == .blocked(.notAllowed))
        #expect(phoneDialTarget(input: "+90 532 123 45 67", allowed: [.tr]) == .call(e164: "+905321234567", country: .tr))
        #expect(phoneDialTarget(input: "+90 900 123 45 67", allowed: [.tr]) == .blocked(.premium))
        #expect(phoneDialTarget(input: "+358 600 1234", allowed: [.fi]) == .blocked(.premium))
        for partial in ["", "21", "212 555", "+1 212 555 019", "+1 211 555 0199", "+1 212 111 0199"] {
            #expect(phoneDialTarget(input: partial, allowed: northAmerica) == .invalid, "\(partial)")
        }
    }

    @Test func numbersAreGroupedForReading() {
        #expect(phoneNumberDisplay(e164: "+12125550199") == "+1 212 555 0199")
        #expect(phoneNumberDisplay(e164: "+905321234567") == "+90 532 123 4567")
        #expect(phoneNumberDisplay(e164: "+358401234567") == "+358 40 123 4567")
        #expect(phoneNumberDisplay(e164: "+447700900123") == "+447700900123")
    }

    @Test func statusDecodesAndDropsUnknownCountries() throws {
        let json: Data = Data(#"""
        {"available":true,"reason":null,"countries":["US","CA","GB"],"provider":"Twilio","consentVersion":1,"consentAccepted":false,
         "number":{"e164":"+14155550142","status":"verified"},"maxCallMinutes":60,"monthlyMinutes":120,"usedMinutes":130}
        """#.utf8)
        let status: HostedPhoneStatus = try JSONDecoder().decode(HostedPhoneStatus.self, from: json)
        #expect(status.countries == [.us, .ca])
        #expect(status.number == HostedPhoneNumber(e164: "+14155550142", status: .verified))
        #expect(status.remainingMinutes == 0)
        let off: Data = Data(#"""
        {"available":false,"reason":"policy_off","countries":[],"provider":null,"consentVersion":1,"consentAccepted":false,"number":null,
         "maxCallMinutes":0,"monthlyMinutes":0,"usedMinutes":0}
        """#.utf8)
        #expect(try JSONDecoder().decode(HostedPhoneStatus.self, from: off).reason == .policyOff)
    }

    @Test func recordingStepFollowsTheCall() {
        let state: (HostedPhoneCallState.Status, HostedPhoneCallState.Recording) -> HostedPhoneCallState = { status, recording in
            HostedPhoneCallState(callId: "c", status: status, billedSeconds: nil, recording: recording)
        }
        #expect(phoneRecordingStep(state: state(.dialing, .pending)) == .wait)
        #expect(phoneRecordingStep(state: state(.completed, .pending)) == .wait)
        #expect(phoneRecordingStep(state: state(.completed, .ready)) == .download)
        #expect(phoneRecordingStep(state: state(.failed, .absent)) == .none)
        #expect(phoneRecordingStep(state: state(.completed, .deleted)) == .none)
        #expect(phoneRecordingStep(state: state(.expired, .pending)) == .none)
    }
}

/// The client's number lists must equal the server's (`server/src/phone/numbers.ts`): a number the app offers to call
/// would otherwise be refused by the server, or the other way round.
@Suite struct PhoneDialerParityTests {
    private func serverList(source: String, name: String) throws -> Set<String> {
        let start: Substring = try #require(source.firstRange(of: "export const \(name): readonly string[] = [").map { source[$0.upperBound...] })
        let body: Substring = try #require(start.firstRange(of: "];").map { start[..<$0.lowerBound] })
        return Set(body.matches(of: #/"([0-9]+)"/#).map { String($0.output.1) })
    }

    @Test func numberListsMatchServer() throws {
        let source: String = try String(contentsOf: serverDirectory().appending(path: "src/phone/numbers.ts"), encoding: .utf8)
        #expect(try serverList(source: source, name: "canadianAreaCodes") == phoneCanadianAreaCodes)
        #expect(try serverList(source: source, name: "otherNanpAreaCodes") == phoneOtherNanpAreaCodes)
        #expect(try serverList(source: source, name: "nanpBlockedAreaCodes") == phoneNanpBlockedAreaCodes)
        #expect(try serverList(source: source, name: "nanpBlockedExchanges") == phoneNanpBlockedExchanges)
        let prefixes: Substring = try #require(source.firstRange(of: "export const blockedNationalPrefixes").map { source[$0.upperBound...] })
        let fi: Substring = try #require(prefixes.firstRange(of: "FI: [").map { prefixes[$0.upperBound...] })
        let tr: Substring = try #require(prefixes.firstRange(of: "TR: [").map { prefixes[$0.upperBound...] })
        let list: (Substring) throws -> [String] = { tail in
            try #require(tail.firstRange(of: "]").map { tail[..<$0.lowerBound] }).matches(of: #/"([0-9]+)"/#).map { String($0.output.1) }
        }
        #expect(try list(fi) == phoneBlockedNationalPrefixes[.fi])
        #expect(try list(tr) == phoneBlockedNationalPrefixes[.tr])
        let countries: Substring = try #require(source.firstRange(of: "export const phoneCountries = [").map { source[$0.upperBound...] })
        let countryBody: Substring = try #require(countries.firstRange(of: "]").map { countries[..<$0.lowerBound] })
        #expect(countryBody.matches(of: #/"([A-Z]{2})"/#).map { String($0.output.1) } == PhoneDialCountry.allCases.map(\.rawValue))
    }

    @Test func consentVersionMatchesServer() throws {
        let source: String = try String(contentsOf: serverDirectory().appending(path: "src/phone/calls.ts"), encoding: .utf8)
        #expect(source.contains("export const phoneConsentVersion: number = \(phoneDialerConsentVersion);"))
    }
}
