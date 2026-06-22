import Testing
@testable import Wattly

/// Deterministic per-app power ranking (issue 16 follow-up) from synthetic per-pid
/// nanojoule snapshots — no libproc, no hardware. The live `ri_energy_nj` per-pid read +
/// path resolution in `PowerProvider` is verified on-device, not here.
struct ProcessPowerTests {

    // MARK: processWatts — per-pid deltas → watts

    @Test func processWattsPositiveDeltaOnly() {
        let prev: [Int32: UInt64] = [1: 0, 2: 1_000_000_000, 9: 5_000_000_000]   // pid 9 will be "dead"
        let curr: [Int32: UInt64] = [1: 2_000_000_000,        // +2 J over 2 s = 1 W
                                     2: 1_000_000_000,         // idle (0 delta) → skip
                                     7: 3_000_000_000]         // new pid (no prev) → skip
        let w = processWatts(prev: prev, curr: curr, dt: 2)
        #expect(w.count == 1)
        #expect(w[0].pid == 1 && abs(w[0].watts - 1) < 1e-9)
    }

    @Test func processWattsCounterResetAndDtAnomaly() {
        #expect(processWatts(prev: [1: 5_000_000_000], curr: [1: 1_000_000_000], dt: 1).isEmpty) // reset
        #expect(processWatts(prev: [1: 0], curr: [1: 1_000_000_000], dt: 0).isEmpty)             // dt ≤ 0
        #expect(processWatts(prev: [1: 0], curr: [1: 1_000_000_000], dt: 31).isEmpty)            // gap
    }

    // MARK: topAppPower — coalesce helper pids into the owning app

    @Test func coalescesHelpersSoFragmentedAppOutranksSingleProcess() {
        // The real-world bug: Claude's draw spread across 3 helpers (Σ 0.346 W) was buried
        // under a single Codex process (0.212 W). Coalesced, Claude must outrank it.
        let perPid: [(pid: Int32, watts: Double)] = [
            (1, 0.178), (2, 0.110), (3, 0.058),   // Claude helpers
            (4, 0.212)]                            // Codex single process
        let appKey: [Int32: String] = [
            1: "/Applications/Claude.app", 2: "/Applications/Claude.app", 3: "/Applications/Claude.app",
            4: "/Applications/Codex.app"]
        let top = topAppPower(perPidWatts: perPid, appKey: appKey, limit: 3)
        #expect(top.count == 2)
        #expect(top[0].key == "/Applications/Claude.app")     // 0.346 Σ > 0.212
        #expect(abs(top[0].watts - 0.346) < 1e-9)
        #expect(top[1].key == "/Applications/Codex.app")
    }

    @Test func fallbackKeyAndStableTieOrder() {
        // Missing appKey → per-pid fallback; equal watts → key asc (no jitter between polls).
        let perPid: [(pid: Int32, watts: Double)] = [(1, 0.5), (2, 0.5)]
        let appKey: [Int32: String] = [1: "/Applications/B.app"]   // pid 2 has no key
        let top = topAppPower(perPidWatts: perPid, appKey: appKey, limit: 3)
        #expect(top.count == 2)
        #expect(top[0].key == "/Applications/B.app")               // "/…" < "PID 2" lexically
        #expect(top[1].key == "PID 2")
    }

    @Test func limitCaps() {
        let perPid: [(pid: Int32, watts: Double)] = [(1, 3), (2, 2), (3, 1)]
        let appKey: [Int32: String] = [1: "a", 2: "b", 3: "c"]
        #expect(topAppPower(perPidWatts: perPid, appKey: appKey, limit: 2).map(\.key) == ["a", "b"])
    }

    // MARK: name + bar helpers

    @Test func appDisplayNameStripsDotApp() {
        #expect(appDisplayName(forKey: "/Applications/Claude.app") == "Claude")
        #expect(appDisplayName(forKey: "/usr/bin/node") == "node")
        #expect(appDisplayName(forKey: "PID 42") == "PID 42")
    }

    @Test func wattFractionRelativeAndClamped() {
        #expect(wattFraction(watts: 2, maxWatts: 4) == 0.5)
        #expect(wattFraction(watts: 4, maxWatts: 4) == 1)
        #expect(wattFraction(watts: 1, maxWatts: 0) == 0)   // flat/zero guard
    }
}
