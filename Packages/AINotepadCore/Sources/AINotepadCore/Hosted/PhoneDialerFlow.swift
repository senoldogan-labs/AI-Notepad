import Foundation

/// Verification of the user's own number (caller ID).
public enum PhoneVerificationPhase: Sendable, Equatable {
    case idle
    case starting
    /// The provider is calling `e164`; the user types `code` on that call's keypad.
    case waiting(code: String, e164: String)
    case verified
    case failed(String)
}

/// The dialer's setup steps and the keypad, in the order the user meets them: what calling from Gistsmith does, their
/// own number verified by a call, the recording terms (everyone on the call is told; the country's rule), then the
/// number pad. The in-call and after-call screens cover these while a call runs (`PhoneActiveCall`).
public enum PhoneDialerStep: Sendable, Equatable {
    case intro
    case verifyNumber
    /// The verification call is ringing; the user types `code` on it.
    case enterCode(code: String, e164: String)
    case consent
    case dial

    /// The step's place in the setup (1…`phoneDialerSetupSteps`); `nil` for the keypad.
    public var setupIndex: Int? {
        switch self {
        case .intro: 1
        case .verifyNumber, .enterCode: 2
        case .consent: 3
        case .dial: nil
        }
    }
}

/// Number of setup steps before the first call.
public let phoneDialerSetupSteps: Int = 3

/// The step the dialer shows: a verified number goes to the recording terms until they are accepted, then to the keypad;
/// otherwise a running verification shows its code, and the introduction comes first until the user starts (or has
/// already started once: a number is on file). Pure function.
public func phoneDialerStep(status: HostedPhoneStatus, verification: PhoneVerificationPhase, introDone: Bool) -> PhoneDialerStep {
    if status.number?.status == .verified || verification == .verified {
        return status.consentAccepted ? .dial : .consent
    }
    if case .waiting(let code, let e164) = verification {
        return .enterCode(code: code, e164: e164)
    }
    return introDone || status.number != nil ? .verifyNumber : .intro
}

/// What recording a phone call needs in a country, as the consent step and the keypad say it.
public enum PhoneRecordingRule: Sendable, Equatable {
    /// Every party must agree (Turkey; the US states that require it are named in the note).
    case allParty
    /// Federal or national law lets a party record, but some states or provinces require everyone: the US.
    case mixed
    /// One party may record; telling the other side is still required for business use or by privacy law (Canada).
    case oneParty
    /// The GDPR and national law: everyone must be told before recording, with a lawful basis (EU/EEA, UK).
    case informAll
}

extension PhoneDialCountry {
    /// The country's calling code without `+`.
    public var callingCode: String {
        switch self {
        case .us, .ca: "1"
        default: phoneNationalPlans.first { $0.country == self }?.code ?? ""
        }
    }

    /// The country's flag emoji (regional indicator symbols of its ISO code).
    public var flag: String {
        let base: UInt32 = 0x1F1E6 - UInt32(("A" as Unicode.Scalar).value)
        let scalars: [Unicode.Scalar] = rawValue.unicodeScalars.compactMap { Unicode.Scalar(base + $0.value) }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Recording consent in this country (sources: docs/superpowers/specs/2026-11-08-iphone-call-recording.md).
    public var recordingRule: PhoneRecordingRule {
        switch self {
        case .us: .mixed
        case .ca: .oneParty
        case .tr: .allParty
        default: .informAll
        }
    }

    /// The trunk prefix dialled before a national number inside the country (`0` in Europe and Turkey, `1` in NANP).
    public var trunkPrefix: String {
        switch self {
        case .us, .ca: "1"
        default: "0"
        }
    }
}

/// The E.164 number for what the user typed with `country` chosen: a `+…` or `00…` input is already international;
/// otherwise the national number with its trunk prefix dropped gets the country's calling code. `nil` when empty.
/// Pure function.
public func phoneE164(input: String, country: PhoneDialCountry) -> String? {
    let digits: String = phoneDialDigits(input: input)
    if digits.hasPrefix("+") {
        return digits.count > 1 ? digits : nil
    }
    if digits.hasPrefix("00") {
        return "+" + digits.dropFirst(2)
    }
    let national: String = digits.hasPrefix(country.trunkPrefix) && (country.trunkPrefix == "0" || digits.count == 11) ? String(digits.dropFirst()) : digits
    return national.isEmpty ? nil : "+" + country.callingCode + national
}

/// What dialing `input` with `country` chosen does: emergency and short numbers go to the Phone app, others are
/// classified as E.164 (`phoneClassifyE164`) against the server's `allowed` countries, and refused in the caller's own
/// country where its carriers block such caller IDs from abroad (`callerCountry`: the verified number's country; `nil`
/// while verifying). Pure function.
public func phoneDialTarget(input: String, country: PhoneDialCountry, allowed: [PhoneDialCountry], callerCountry: PhoneDialCountry?) -> PhoneDialTarget {
    let digits: String = phoneDialDigits(input: input)
    if !digits.hasPrefix("+"), phoneAppOnlyNumbers.contains(digits) {
        return .phoneApp(number: digits)
    }
    guard let e164 = phoneE164(input: input, country: country) else {
        return .invalid
    }
    let classified: PhoneDialTarget = phoneClassifyE164(e164)
    guard case .call(_, let callee) = classified else {
        return classified
    }
    if !allowed.contains(callee) {
        return .blocked(.notAllowed)
    }
    if let callerCountry, phoneCallerIdBlocked(caller: callerCountry, destination: callee) {
        return .blocked(.callerIdBlocked)
    }
    return classified
}

/// The country of a callable E.164 number; `nil` for others. Pure function.
public func phoneCountry(e164: String) -> PhoneDialCountry? {
    if case .call(_, let country) = phoneClassifyE164(e164) {
        return country
    }
    return nil
}

/// The country the number field starts with: the device's region when the server allows it (Finland on a Finnish
/// iPhone), else the verified number's country, else the first allowed one; `nil` when nothing is allowed. Pure
/// function.
public func phoneDefaultCountry(region: String?, verifiedE164: String?, allowed: [PhoneDialCountry]) -> PhoneDialCountry? {
    if let region, let country = PhoneDialCountry(rawValue: region.uppercased()), allowed.contains(country) {
        return country
    }
    if let verifiedE164, let country = phoneCountry(e164: verifiedE164), allowed.contains(country) {
        return country
    }
    return allowed.first
}

/// The national part of an E.164 number as the field shows it after the country chip (`40 123 4567`). Pure function.
public func phoneNationalDisplay(e164: String, country: PhoneDialCountry) -> String {
    let display: String = phoneNumberDisplay(e164: e164)
    let prefix: String = "+\(country.callingCode) "
    return display.hasPrefix(prefix) ? String(display.dropFirst(prefix.count)) : display
}
