import Foundation
import Testing
@testable import AINotepadCore

/// The in-app dialer's number rules and server answers (pure functions; the server's own tests are in
/// `server/test/phone.test.ts`).
@Suite struct PhoneDialerTests {
    private let northAmerica: [PhoneDialCountry] = [.us, .ca]

    private func target(_ input: String, _ country: PhoneDialCountry, _ allowed: [PhoneDialCountry]) -> PhoneDialTarget {
        phoneDialTarget(input: input, country: country, allowed: allowed, callerCountry: nil)
    }

    @Test func emergencyAndShortNumbersGoToThePhoneApp() {
        for number in ["911", "112", "988", "999", "411", "1 1 2"] {
            #expect(target(number, .us, northAmerica) == .phoneApp(number: number.replacingOccurrences(of: " ", with: "")))
        }
        #expect(phoneTelURL(number: "911")?.absoluteString == "tel:911")
        // With a `+` it is a (malformed) international number, not a short code.
        #expect(target("+911", .us, northAmerica) == .invalid)
    }

    @Test func nationalNumbersGetTheChosenCountrysCode() {
        let expected: PhoneDialTarget = .call(e164: "+12125550199", country: .us)
        for input in ["(212) 555-0199", "212.555.0199", "1 212 555 0199", "+1 212 555 0199", "0012125550199"] {
            #expect(target(input, .us, northAmerica) == expected, "\(input)")
        }
        #expect(target("416 555 0199", .us, northAmerica) == .call(e164: "+14165550199", country: .ca))
        #expect(target("800 555 0199", .ca, northAmerica) == .call(e164: "+18005550199", country: .us))
        // Finland: the trunk 0 is dropped; a `+` number keeps its own country whatever is chosen.
        #expect(target("040 123 4567", .fi, [.fi]) == .call(e164: "+358401234567", country: .fi))
        #expect(target("40 123 4567", .fi, [.fi]) == .call(e164: "+358401234567", country: .fi))
        #expect(target("09 123 4567", .fi, [.fi]) == .call(e164: "+35891234567", country: .fi))
        #expect(target("+44 20 7123 4567", .fi, [.fi, .gb]) == .call(e164: "+442071234567", country: .gb))
        #expect(target("07400 123456", .gb, [.gb]) == .call(e164: "+447400123456", country: .gb))
        #expect(target("07700 900123", .gb, [.gb]) == .blocked(.premium))
        #expect(phoneE164(input: "", country: .fi) == nil)
    }

    @Test func premiumForeignAndPartialNumbersAreRefused() {
        #expect(target("1 900 555 0199", .us, northAmerica) == .blocked(.premium))
        #expect(target("212 976 5555", .us, northAmerica) == .blocked(.premium))
        #expect(target("876 555 0199", .us, northAmerica) == .blocked(.unsupported))
        #expect(target("+46 70 123 4567", .us, northAmerica) == .blocked(.unsupported))
        #expect(target("+90 532 123 45 67", .us, northAmerica) == .blocked(.notAllowed))
        #expect(target("+90 532 123 45 67", .tr, [.tr]) == .call(e164: "+905321234567", country: .tr))
        #expect(target("+90 900 123 45 67", .tr, [.tr]) == .blocked(.premium))
        // Finland: premium 0600, nationwide 07, machine-to-machine 049; UK: personal 070, pagers 076, Isle of Man 07624.
        for input in ["0600 1234", "0700 123456", "075 123 4567", "049 1234 5678"] {
            #expect(target(input, .fi, [.fi]) == .blocked(.premium), "\(input)")
        }
        for input in ["070 1234 5678", "076 1234 5678", "07624 123456", "0871 234 5678", "0901 234 5678"] {
            #expect(target(input, .gb, [.gb]) == .blocked(.premium), "\(input)")
        }
        for partial in ["", "21", "212 555", "+1 212 555 019", "+1 211 555 0199", "+1 212 111 0199"] {
            #expect(target(partial, .us, northAmerica) == .invalid, "\(partial)")
        }
    }

    @Test func callsIntoTheCallersOwnCountryAreRefusedWhereItsCarriersBlockThem() {
        let all: [PhoneDialCountry] = [.us, .ca, .fi, .gb]
        #expect(phoneDialTarget(input: "040 123 4567", country: .fi, allowed: all, callerCountry: .fi) == .blocked(.callerIdBlocked))
        #expect(phoneDialTarget(input: "020 7123 4567", country: .gb, allowed: all, callerCountry: .gb) == .blocked(.callerIdBlocked))
        #expect(phoneDialTarget(input: "212 555 0199", country: .us, allowed: all, callerCountry: .fi) == .call(e164: "+12125550199", country: .us))
        #expect(phoneDialTarget(input: "212 555 0199", country: .us, allowed: all, callerCountry: .us) == .call(e164: "+12125550199", country: .us))
        #expect(phoneDialTarget(input: "020 7123 4567", country: .gb, allowed: all, callerCountry: .fi) == .call(e164: "+442071234567", country: .gb))
    }

    @Test func countryMetadataAndDefaults() {
        #expect(PhoneDialCountry.fi.flag == "🇫🇮")
        #expect(PhoneDialCountry.fi.callingCode == "358")
        #expect(PhoneDialCountry.ca.callingCode == "1")
        #expect(PhoneDialCountry.gb.callingCode == "44")
        // A Finnish iPhone starts in Finland when Finland is allowed; otherwise the verified number's country, then the first.
        #expect(phoneDefaultCountry(region: "FI", verifiedE164: nil, allowed: [.us, .fi]) == .fi)
        #expect(phoneDefaultCountry(region: "FI", verifiedE164: "+14155550142", allowed: [.ca, .us]) == .us)
        #expect(phoneDefaultCountry(region: "DE", verifiedE164: nil, allowed: [.ca, .us]) == .ca)
        #expect(phoneDefaultCountry(region: nil, verifiedE164: nil, allowed: []) == nil)
        #expect(phoneNationalDisplay(e164: "+358401234567", country: .fi) == "40 123 4567")
    }

    private func status(consent: Bool, number: HostedPhoneNumber?) -> HostedPhoneStatus {
        HostedPhoneStatus(
            available: true, reason: nil, countries: [.us], callerCountries: [.us], provider: "Twilio", consentVersion: phoneDialerConsentVersion,
            consentAccepted: consent, number: number, maxCallMinutes: 60, monthlyMinutes: 120, usedMinutes: 0, minutesByCountry: [.us: 120]
        )
    }

    @Test func setupStepsFollowIntroVerificationConsentKeypad() {
        let verified: HostedPhoneNumber = HostedPhoneNumber(e164: "+14155550142", status: .verified)
        #expect(phoneDialerStep(status: status(consent: false, number: nil), verification: .idle, introDone: false) == .intro)
        #expect(phoneDialerStep(status: status(consent: false, number: nil), verification: .idle, introDone: true) == .verifyNumber)
        #expect(phoneDialerStep(status: status(consent: false, number: nil), verification: .failed("x"), introDone: true) == .verifyNumber)
        #expect(
            phoneDialerStep(status: status(consent: false, number: nil), verification: .waiting(code: "123456", e164: "+14155550142"), introDone: true)
                == .enterCode(code: "123456", e164: "+14155550142")
        )
        // A number tried before skips the introduction on the next visit.
        #expect(phoneDialerStep(status: status(consent: false, number: HostedPhoneNumber(e164: "+14155550142", status: .failed)), verification: .idle, introDone: false) == .verifyNumber)
        #expect(phoneDialerStep(status: status(consent: false, number: nil), verification: .verified, introDone: true) == .consent)
        #expect(phoneDialerStep(status: status(consent: false, number: verified), verification: .idle, introDone: false) == .consent)
        #expect(phoneDialerStep(status: status(consent: true, number: verified), verification: .idle, introDone: false) == .dial)
        #expect(PhoneDialerStep.dial.setupIndex == nil)
        #expect(PhoneDialerStep.consent.setupIndex == phoneDialerSetupSteps)
    }

    @Test func numbersAreGroupedForReading() {
        #expect(phoneNumberDisplay(e164: "+12125550199") == "+1 212 555 0199")
        #expect(phoneNumberDisplay(e164: "+905321234567") == "+90 532 123 4567")
        #expect(phoneNumberDisplay(e164: "+358401234567") == "+358 40 123 4567")
        #expect(phoneNumberDisplay(e164: "+447700900123") == "+44 7700 900123")
        #expect(phoneNumberDisplay(e164: "+442071234567") == "+44 20 7123 4567")
        #expect(phoneNumberDisplay(e164: "+46701234567") == "+46701234567")
    }

    @Test func statusDecodesAndDropsUnknownCountries() throws {
        let json: Data = Data(#"""
        {"available":true,"reason":null,"countries":["US","CA","SE"],"callerCountries":["US","SE"],"provider":"Twilio","consentVersion":2,"consentAccepted":false,
         "number":{"e164":"+14155550142","status":"verified"},"maxCallMinutes":60,"monthlyMinutes":120,"usedMinutes":100,
         "minutesByCountry":{"US":20,"CA":15,"SE":3}}
        """#.utf8)
        let status: HostedPhoneStatus = try JSONDecoder().decode(HostedPhoneStatus.self, from: json)
        #expect(status.countries == [.us, .ca])
        #expect(status.callerCountries == [.us])
        #expect(status.callerCountry == .us)
        #expect(status.number == HostedPhoneNumber(e164: "+14155550142", status: .verified))
        #expect(status.remainingMinutes == 20)
        #expect(status.remainingMinutes(country: .ca) == 15)
        #expect(status.remainingMinutes(country: .fi) == 0)
        let off: Data = Data(#"""
        {"available":false,"reason":"policy_off","countries":[],"callerCountries":[],"provider":null,"consentVersion":2,"consentAccepted":false,"number":null,
         "maxCallMinutes":0,"monthlyMinutes":0,"usedMinutes":0,"minutesByCountry":{}}
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
        #expect(phoneRecordingStep(state: state(.failed, .pending)) == .none)
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
        // One `{ country: "FI", code: "358", minLength: 5, maxLength: 12, allowed: [...], blocked: [...] }` line per plan.
        let plans: [PhoneNationalPlan] = try source.matches(of: #/\{ country: "([A-Z]{2})", code: "([0-9]+)", minLength: ([0-9]+), maxLength: ([0-9]+), allowed: \[([^\]]*)\], blocked: \[([^\]]*)\] \}/#).map { match in
            let strings: (Substring) -> [String] = { body in body.matches(of: #/"([0-9]*)"/#).map { String($0.output.1) } }
            return PhoneNationalPlan(
                country: try #require(PhoneDialCountry(rawValue: String(match.output.1))), code: String(match.output.2), minLength: try #require(Int(match.output.3)),
                maxLength: try #require(Int(match.output.4)), allowed: strings(match.output.5), blocked: strings(match.output.6)
            )
        }
        #expect(plans == phoneNationalPlans)
        let domestic: Substring = try #require(source.firstRange(of: "export const domesticCallerIdBlocked: readonly PhoneCountry[] = [").map { source[$0.upperBound...] })
        let domesticBody: Substring = try #require(domestic.firstRange(of: "]").map { domestic[..<$0.lowerBound] })
        #expect(Set(domesticBody.matches(of: #/"([A-Z]{2})"/#).compactMap { PhoneDialCountry(rawValue: String($0.output.1)) }) == phoneDomesticCallerIdBlocked)
        let countries: Substring = try #require(source.firstRange(of: "export const phoneCountries = [").map { source[$0.upperBound...] })
        let countryBody: Substring = try #require(countries.firstRange(of: "]").map { countries[..<$0.lowerBound] })
        #expect(countryBody.matches(of: #/"([A-Z]{2})"/#).map { String($0.output.1) } == PhoneDialCountry.allCases.map(\.rawValue))
    }

    @Test func consentVersionMatchesServer() throws {
        let source: String = try String(contentsOf: serverDirectory().appending(path: "src/phone/calls.ts"), encoding: .utf8)
        #expect(source.contains("export const phoneConsentVersion: number = \(phoneDialerConsentVersion);"))
    }
}
