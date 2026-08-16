import Testing
@testable import Wattly

/// Deterministic per-process self-power math (issue 16) from synthetic nanojoule
/// counters — no libproc, no hardware. The live `ri_energy_nj` read in `LiveSelfEnergy`
/// is verified on-device, not here.
struct SelfPowerTests {

    @Test func wattsFromNanojouleDelta() {
        // 2 J drawn over 4 s = 0.5 W. (2e9 nJ / 1e9 / 4 s)
        #expect(SelfPower.watts(prevNanojoules: 0, currNanojoules: 2_000_000_000, dt: 4) == 0.5)
    }

    @Test func zeroDeltaIsZeroWatts() {
        // A fully-idle interval draws nothing — a valid 0 W, not an anomaly.
        #expect(SelfPower.watts(prevNanojoules: 1_000, currNanojoules: 1_000, dt: 1) == 0)
    }

    @Test func nonPositiveDtRebaselines() {
        #expect(SelfPower.watts(prevNanojoules: 0, currNanojoules: 1_000_000_000, dt: 0) == nil)
        #expect(SelfPower.watts(prevNanojoules: 0, currNanojoules: 1_000_000_000, dt: -1) == nil)
    }

    @Test func gapBeyondMaxRebaselines() {
        // > 30 s = a missed poll / sleep-wake → re-baseline, no value.
        #expect(SelfPower.watts(prevNanojoules: 0, currNanojoules: 1_000_000_000, dt: 31) == nil)
        // …but exactly the boundary still computes.
        #expect(SelfPower.watts(prevNanojoules: 0, currNanojoules: 1_000_000_000, dt: 30) == 1.0 / 30)
    }

    @Test func counterResetRebaselines() {
        // curr < prev = process restart / impossible rollover → re-baseline, not a negative watt.
        #expect(SelfPower.watts(prevNanojoules: 5_000_000_000, currNanojoules: 1_000_000_000, dt: 1) == nil)
    }

    final class MockSelfEnergy: SelfEnergySampling, @unchecked Sendable {
        var value: UInt64?
        init(_ value: UInt64? = nil) { self.value = value }
        func energyNanojoules() -> UInt64? { value }
    }

    @Test func trackerComputesWattsAndSmooths() {
        var tracker = SelfPowerTracker()
        let energy = MockSelfEnergy(1_000_000_000)
        let clock = ContinuousClock()
        let t0 = clock.now

        #expect(tracker.sample(using: energy, at: t0) == nil) // First sample -> baseline only

        energy.value = 1_000_000_000 + 5_000_000_000 // +5 J in 2 s = 2.5 W
        let result = tracker.sample(using: energy, at: t0.advanced(by: .seconds(2)))
        #expect(result != nil)
        #expect(abs((result ?? 0) - 2.5) < 1e-9)
        #expect(tracker.currentWatts == result)
    }

    @Test func trackerHandlesAnomaliesAndRetainsLastValue() {
        var tracker = SelfPowerTracker()
        let energy = MockSelfEnergy(1_000_000_000)
        let clock = ContinuousClock()
        let t0 = clock.now

        _ = tracker.sample(using: energy, at: t0)
        energy.value = 1_000_000_000 + 3_000_000_000 // 3 W over 1 s
        let warm = tracker.sample(using: energy, at: t0.advanced(by: .seconds(1)))
        #expect(warm != nil)

        // Anomaly: counter reset
        energy.value = 0
        let afterAnomaly = tracker.sample(using: energy, at: t0.advanced(by: .seconds(2)))
        #expect(afterAnomaly == warm, "Transient anomaly should retain last valid value")

        // Anomaly: unreadable energy source
        energy.value = nil
        let afterUnreadable = tracker.sample(using: energy, at: t0.advanced(by: .seconds(3)))
        #expect(afterUnreadable == warm, "Unreadable energy source should retain last valid value")
    }

    @Test func trackerResetClearsState() {
        var tracker = SelfPowerTracker()
        let energy = MockSelfEnergy(1_000_000_000)
        let clock = ContinuousClock()
        let t0 = clock.now

        _ = tracker.sample(using: energy, at: t0)
        energy.value = 1_000_000_000 + 2_000_000_000
        _ = tracker.sample(using: energy, at: t0.advanced(by: .seconds(1)))
        #expect(tracker.currentWatts != nil)

        tracker.reset()
        #expect(tracker.currentWatts == nil)
    }
}
