import Testing
import Foundation
@testable import Wattly

/// Phase A — fan speed. Pure helpers tested directly (no hardware); the provider's
/// connection / fanless / backoff machine is tested with a fake transport in
/// `FanProviderTests`.
struct FanTests {

    @Test func averageRPMEmptyIsNil() {
        #expect(averageRPM([]) == nil)
    }

    @Test func averageRPMMeanAcrossFans() {
        let fans = [
            FanReading(index: 0, actualRPM: 3000, minRPM: 1200, maxRPM: 6000, targetRPM: 3200),
            FanReading(index: 1, actualRPM: 5000, minRPM: 1200, maxRPM: 6000, targetRPM: 5200),
        ]
        #expect(averageRPM(fans) == 4000)   // (3000 + 5000) / 2
    }

    @Test func fanBarFractionScalesAndClamps() {
        #expect(CardPresentation.fanBarFraction(actual: 2000, max: 4000) == 0.5)
        #expect(CardPresentation.fanBarFraction(actual: 9000, max: 4000) == 1.0)   // clamp high
        #expect(CardPresentation.fanBarFraction(actual: -100, max: 4000) == 0.0)   // clamp low
        #expect(CardPresentation.fanBarFraction(actual: 2000, max: 0) == 0.0)      // no max → 0
    }
}
