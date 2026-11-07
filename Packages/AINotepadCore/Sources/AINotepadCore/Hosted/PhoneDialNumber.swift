import Foundation

/// Countries the in-app dialer knows how to classify (`server/src/phone/numbers.ts` `phoneCountries`); the server's
/// `PHONE_CALLS_COUNTRIES` is a subset.
public enum PhoneDialCountry: String, Sendable, CaseIterable, Codable, Equatable {
    case us = "US"
    case ca = "CA"
    case fi = "FI"
    case tr = "TR"
}

/// Why a number can't be called from the dialer.
public enum PhoneDialBlock: Sendable, Equatable {
    /// Premium-rate or special-service range.
    case premium
    /// A country the dialer doesn't support (including Caribbean and US-territory NANP codes).
    case unsupported
    /// A supported country that the server doesn't allow (yet).
    case notAllowed
}

/// What dialing the typed number does.
public enum PhoneDialTarget: Sendable, Equatable {
    /// A callable number in an allowed country.
    case call(e164: String, country: PhoneDialCountry)
    /// Emergency and short service numbers: opened in the Phone app (`tel:`), never placed through the provider (an
    /// emergency call needs the phone network's location and callback, which a VoIP leg can't give).
    case phoneApp(number: String)
    case blocked(PhoneDialBlock)
    /// Not a full number yet, or malformed.
    case invalid
}

/// Emergency and short service numbers the dialer hands to the Phone app (US/Canada N11 and 988, EU 112, Turkey's
/// and Finland's emergency and service numbers, and other common emergency numbers a traveller may type).
public let phoneAppOnlyNumbers: Set<String> = [
    "911", "112", "999", "000", "988", "933", "110", "119", "118", "100", "101", "102", "103", "104", "108", "155", "156",
    "158", "177", "15", "17", "18", "08", "061", "062", "063", "065", "066", "211", "311", "411", "511", "611", "711", "811",
]

/// Canadian NANP area codes (mirrors `canadianAreaCodes` in `server/src/phone/numbers.ts`; `PhoneDialerParityTests`).
public let phoneCanadianAreaCodes: Set<String> = [
    "204", "226", "236", "249", "250", "257", "263", "289", "306", "343", "354", "365", "367", "368", "382", "403", "416",
    "418", "428", "431", "437", "438", "450", "460", "468", "474", "506", "514", "519", "548", "579", "581", "584", "587",
    "600", "604", "613", "622", "639", "647", "672", "683", "705", "709", "742", "753", "778", "780", "782", "807", "819",
    "825", "867", "873", "879", "902", "905", "942",
]

/// NANP area codes outside the US 50 states and Canada (mirrors `otherNanpAreaCodes`).
public let phoneOtherNanpAreaCodes: Set<String> = [
    "242", "246", "264", "268", "284", "340", "345", "441", "473", "649", "658", "664", "670", "671", "684", "721", "758",
    "767", "784", "787", "809", "829", "849", "868", "869", "876", "939",
]

/// NANP premium-rate and special-service area codes (mirrors `nanpBlockedAreaCodes`).
public let phoneNanpBlockedAreaCodes: Set<String> = [
    "500", "521", "522", "523", "524", "525", "526", "527", "528", "529", "532", "533", "535", "538", "542", "543", "544",
    "545", "546", "547", "549", "550", "552", "553", "554", "556", "558", "566", "569", "577", "578", "588", "589", "700",
    "710", "900",
]

/// NANP premium-rate exchange codes (mirrors `nanpBlockedExchanges`).
public let phoneNanpBlockedExchanges: Set<String> = ["976"]

/// Blocked national prefixes outside NANP (mirrors `blockedNationalPrefixes`).
public let phoneBlockedNationalPrefixes: [PhoneDialCountry: [String]] = [
    .fi: ["100", "106", "118", "200", "202", "203", "204", "209", "600", "700"],
    .tr: ["444", "800", "822", "888", "900"],
]

/// Calling code and national number length of the non-NANP countries (mirrors `nationalNumbers`).
private let phoneNationalPlans: [(country: PhoneDialCountry, code: String, minLength: Int, maxLength: Int)] = [
    (.fi, "358", 5, 12),
    (.tr, "90", 10, 10),
]

/// The digits of the input, with a leading `+` kept: spaces, dashes, dots and brackets are dropped. Pure function.
public func phoneDialDigits(input: String) -> String {
    let trimmed: String = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let digits: String = trimmed.filter(\.isASCIIDigit)
    return trimmed.hasPrefix("+") ? "+" + digits : digits
}

/// The input as an E.164 candidate: `+…` as typed, `00…` and (with US or Canada allowed) `011…` as international
/// prefixes, and (with US or Canada allowed) 10 digits or 11 digits starting with 1 as a NANP number. `nil` otherwise
/// (national formats of other countries need the `+` and country code). Pure function.
public func phoneE164Candidate(input: String, allowed: [PhoneDialCountry]) -> String? {
    let digits: String = phoneDialDigits(input: input)
    let nanp: Bool = allowed.contains(.us) || allowed.contains(.ca)
    if digits.hasPrefix("+") {
        return digits
    }
    if digits.hasPrefix("00") {
        return "+" + digits.dropFirst(2)
    }
    if nanp, digits.hasPrefix("011") {
        return "+" + digits.dropFirst(3)
    }
    if nanp, digits.count == 10 {
        return "+1" + digits
    }
    if nanp, digits.count == 11, digits.hasPrefix("1") {
        return "+" + digits
    }
    return nil
}

/// Classifies a +1 number's 10 national digits. Pure function.
private func classifyNanp(e164: String, national: String) -> PhoneDialTarget {
    let characters: [Character] = Array(national)
    guard characters.count == 10, characters.allSatisfy(\.isASCIIDigit), characters[0] >= "2", characters[3] >= "2" else {
        return .invalid
    }
    let areaCode: String = String(characters[0..<3])
    let exchange: String = String(characters[3..<6])
    if areaCode.hasSuffix("11") || exchange.hasSuffix("11") {
        return .invalid
    }
    if phoneNanpBlockedAreaCodes.contains(areaCode) || phoneNanpBlockedExchanges.contains(exchange) {
        return .blocked(.premium)
    }
    if phoneOtherNanpAreaCodes.contains(areaCode) {
        return .blocked(.unsupported)
    }
    return .call(e164: e164, country: phoneCanadianAreaCodes.contains(areaCode) ? .ca : .us)
}

/// Classifies an E.164 number like the server (`classifyNumber`): callable with its country, blocked or invalid. Pure
/// function.
public func phoneClassifyE164(_ value: String) -> PhoneDialTarget {
    guard value.hasPrefix("+") else {
        return .invalid
    }
    let digits: String = String(value.dropFirst())
    guard (7...15).contains(digits.count), digits.allSatisfy(\.isASCIIDigit), !digits.hasPrefix("0") else {
        return .invalid
    }
    if digits.hasPrefix("1") {
        return digits.count == 11 ? classifyNanp(e164: value, national: String(digits.dropFirst())) : .invalid
    }
    guard let plan = phoneNationalPlans.first(where: { digits.hasPrefix($0.code) }) else {
        return .blocked(.unsupported)
    }
    let national: String = String(digits.dropFirst(plan.code.count))
    guard (plan.minLength...plan.maxLength).contains(national.count), !national.hasPrefix("0") else {
        return .invalid
    }
    if (phoneBlockedNationalPrefixes[plan.country] ?? []).contains(where: { national.hasPrefix($0) }) {
        return .blocked(.premium)
    }
    return .call(e164: value, country: plan.country)
}

/// What dialing `input` does when the server allows `allowed`: emergency and short numbers go to the Phone app, full
/// numbers are classified, a supported country the server doesn't allow is `notAllowed`. Pure function.
public func phoneDialTarget(input: String, allowed: [PhoneDialCountry]) -> PhoneDialTarget {
    let digits: String = phoneDialDigits(input: input)
    if !digits.hasPrefix("+"), phoneAppOnlyNumbers.contains(digits) {
        return .phoneApp(number: digits)
    }
    guard let candidate = phoneE164Candidate(input: input, allowed: allowed) else {
        return .invalid
    }
    let classified: PhoneDialTarget = phoneClassifyE164(candidate)
    if case .call(_, let country) = classified, !allowed.contains(country) {
        return .blocked(.notAllowed)
    }
    return classified
}

/// An E.164 number grouped for reading: `+1 212 555 0199`, `+90 532 123 4567`, `+358 40 123 4567`. Pure function.
public func phoneNumberDisplay(e164: String) -> String {
    let digits: String = String(e164.drop { $0 == "+" })
    let code: String
    if digits.hasPrefix("1") {
        code = "1"
    } else if let plan = phoneNationalPlans.first(where: { digits.hasPrefix($0.code) }) {
        code = plan.code
    } else {
        return e164
    }
    let national: [Character] = Array(digits.dropFirst(code.count))
    // NANP: 3-3-4; others: the last 7 digits as 3-4, anything before them as one group.
    let groups: [String]
    if code == "1", national.count == 10 {
        groups = [String(national[0..<3]), String(national[3..<6]), String(national[6...])]
    } else if national.count > 7 {
        let head: Int = national.count - 7
        groups = [String(national[0..<head]), String(national[head..<(head + 3)]), String(national[(head + 3)...])]
    } else {
        groups = [String(national)]
    }
    return "+\(code) " + groups.joined(separator: " ")
}

/// The Phone app's `tel:` address of a number (digits and a leading `+`); `nil` when empty. Pure function.
public func phoneTelURL(number: String) -> URL? {
    let digits: String = phoneDialDigits(input: number)
    return digits.isEmpty ? nil : URL(string: "tel:\(digits)")
}

extension Character {
    /// `0`–`9` only (not other scripts' digits).
    fileprivate var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
