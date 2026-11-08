import Testing
@testable import AINotepadCore

@Suite struct CallRecordingAvailabilityTests {
    // Apple's list: all 27 EU member states plus the other named regions; the EEA-only states and supported regions are
    // not on it.
    @Test func matchesApplesList() {
        #expect(callRecordingUnavailableRegions.count == 27 + 18)
        for region in ["FI", "DE", "FR", "SE", "IE", "TR", "AE", "RU", "ZA", "fi"] {
            #expect(callRecordingLikelyUnavailable(regionCode: region), "\(region)")
        }
        for region in ["US", "GB", "NO", "IS", "LI", "CH", "CA", "JP", "AU"] {
            #expect(!callRecordingLikelyUnavailable(regionCode: region), "\(region)")
        }
        #expect(!callRecordingLikelyUnavailable(regionCode: nil))
    }
}
