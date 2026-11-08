import Foundation

/// Regions (ISO 3166-1 alpha-2) where Apple says iPhone call recording isn't currently available: Azerbaijan, Bahrain,
/// Egypt, the European Union, Iran, Iraq, Jordan, Kuwait, Morocco, Nigeria, Oman, Pakistan, Qatar, Russia, Saudi Arabia,
/// South Africa, Turkey, United Arab Emirates and Yemen ("Record and transcribe a call on iPhone",
/// https://support.apple.com/guide/iphone/record-and-transcribe-a-call-iph57c6590e9/ios, checked 2026-11-09). The
/// European Union is its 27 member states; Apple names the EU, not the EEA, so Norway, Iceland and Liechtenstein are not
/// listed.
public let callRecordingUnavailableRegions: Set<String> = [
    // European Union.
    "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE", "IT", "LV", "LT", "LU", "MT",
    "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE",
    // Other regions on Apple's list.
    "AZ", "BH", "EG", "IR", "IQ", "JO", "KW", "MA", "NG", "OM", "PK", "QA", "RU", "SA", "ZA", "TR", "AE", "YE",
]

/// Whether the device's region (`Locale.Region.identifier`, e.g. "FI") is one where Apple doesn't offer iPhone call
/// recording. Only a hint for ordering the phone call guide: Apple's availability also depends on language and other
/// settings, so nothing is hidden or blocked on it. An unknown region (nil) is not treated as unavailable. Pure function.
public func callRecordingLikelyUnavailable(regionCode: String?) -> Bool {
    guard let regionCode else {
        return false
    }
    return callRecordingUnavailableRegions.contains(regionCode.uppercased())
}
