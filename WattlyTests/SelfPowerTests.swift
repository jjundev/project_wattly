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
}
