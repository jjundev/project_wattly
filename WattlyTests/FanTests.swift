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

    // MARK: - fanCount(fromRawFNum:)

    /// Regression for the `Int(v)` trap: a corrupted SMC key-info `dataSize` can make
    /// `smcDouble` return a finite-but-huge value for the 1-byte `FNum` key, and `Int(v)`
    /// crashes the process for anything outside `Int`'s range. `fanCount(fromRawFNum:)` must
    /// reject that case (and negatives/non-finite) with `nil` instead of trapping.
    @Test func fanCountNormalValue() {
        #expect(fanCount(fromRawFNum: 2) == 2)
    }

    @Test func fanCountZeroIsFanless() {
        #expect(fanCount(fromRawFNum: 0) == 0)   // FanProvider treats 0 as the fanless path
    }

    @Test func fanCountNegativeIsNil() {
        #expect(fanCount(fromRawFNum: -1) == nil)
    }

    @Test func fanCountNonFiniteIsNil() {
        #expect(fanCount(fromRawFNum: .nan) == nil)
        #expect(fanCount(fromRawFNum: .infinity) == nil)
    }

    @Test func fanCountHugeValueIsNilNotTrap() {
        // Would trap on plain `Int(v)` — this is the crash this function exists to prevent.
        #expect(fanCount(fromRawFNum: 1e19) == nil)
    }

    // MARK: - plausibleRPM(_:in:)

    /// Regression for the `Int(...)` trap at render sites (`CardPresentation.subText(.fan)`,
    /// `MetricCardView.fanRow`): `smcDouble` decodes a `flt ` SMC key from a `Float32`, which
    /// can be finite yet astronomically larger than `Int64.max`. `plausibleRPM` must reject
    /// that (and negatives/non-finite) with `0` instead of letting it reach `Int(...)`.
    @Test func plausibleRPMInRangePasses() {
        #expect(plausibleRPM(3000, in: 0...12000) == 3000)
    }

    @Test func plausibleRPMNegativeIsZero() {
        #expect(plausibleRPM(-1, in: 0...12000) == 0)
    }

    @Test func plausibleRPMNonFiniteIsZero() {
        #expect(plausibleRPM(.nan, in: 0...12000) == 0)
        #expect(plausibleRPM(.infinity, in: 0...12000) == 0)
    }

    @Test func plausibleRPMHugeFiniteIsZeroNotTrap() {
        // Would trap on plain `Int(v)` at a render site — this is the crash this function
        // exists to prevent.
        #expect(plausibleRPM(1e19, in: 0...12000) == 0)
    }

    @Test func plausibleRPMBoundary() {
        #expect(plausibleRPM(12000, in: 0...12000) == 12000)   // upper bound inclusive
        #expect(plausibleRPM(12001, in: 0...12000) == 0)       // just past the bound
    }
}
