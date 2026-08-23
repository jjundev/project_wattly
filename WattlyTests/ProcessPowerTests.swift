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
        let claude = AppIdentity(key: "com.anthropic.claudefordesktop", name: "Claude",
                                 iconPath: "/Applications/Claude.app")
        let codex = AppIdentity(key: "com.openai.codex", name: "Codex",
                                iconPath: "/Applications/Codex.app")
        let perPid: [(pid: Int32, watts: Double)] = [
            (1, 0.178), (2, 0.110), (3, 0.058),   // Claude helpers
            (4, 0.212)]                            // Codex single process
        let identity: [Int32: AppIdentity] = [1: claude, 2: claude, 3: claude, 4: codex]

        let top = topAppPower(perPidWatts: perPid, identity: identity, limit: 3)

        #expect(top.count == 2)
        #expect(top[0].identity.key == "com.anthropic.claudefordesktop")   // 0.346 Σ > 0.212
        #expect(top[0].identity.name == "Claude")
        #expect(top[0].identity.iconPath == "/Applications/Claude.app")
        #expect(abs(top[0].watts - 0.346) < 1e-9)
        #expect(top[1].identity.key == "com.openai.codex")
    }

    @Test func fallbackKeyAndStableTieOrder() {
        // No identity for pid 2 (proc_pidpath failed) → per-pid fallback group, no icon.
        // Equal watts order by key asc so rows don't jitter between polls; in ASCII "P" (0x50)
        // sorts before "c" (0x63), so the fallback group leads here.
        let perPid: [(pid: Int32, watts: Double)] = [(1, 0.5), (2, 0.5)]
        let identity: [Int32: AppIdentity] = [
            1: AppIdentity(key: "com.example.b", name: "B", iconPath: "/Applications/B.app")]

        let top = topAppPower(perPidWatts: perPid, identity: identity, limit: 3)

        #expect(top.count == 2)
        #expect(top[0].identity == AppIdentity(key: "PID 2", name: "PID 2", iconPath: nil))
        #expect(top[1].identity.key == "com.example.b")
        #expect(top[1].identity.name == "B")
    }

    @Test func limitCaps() {
        let perPid: [(pid: Int32, watts: Double)] = [(1, 3), (2, 2), (3, 1)]
        let identity: [Int32: AppIdentity] = [
            1: AppIdentity(key: "a", name: "a", iconPath: nil),
            2: AppIdentity(key: "b", name: "b", iconPath: nil),
            3: AppIdentity(key: "c", name: "c", iconPath: nil)]

        #expect(topAppPower(perPidWatts: perPid, identity: identity, limit: 2)
            .map(\.identity.key) == ["a", "b"])
    }

    @Test func powerProcessLimitClampsToSupportedRange() {
        #expect(powerProcessLimit(nil) == 5)
        #expect(powerProcessLimit(1) == 3)
        #expect(powerProcessLimit(3) == 3)
        #expect(powerProcessLimit(5) == 5)
        #expect(powerProcessLimit(7) == 7)
        #expect(powerProcessLimit(99) == 7)
    }

    // MARK: name + bar helpers

    @Test func wattFractionRelativeAndClamped() {
        #expect(wattFraction(watts: 2, maxWatts: 4) == 0.5)
        #expect(wattFraction(watts: 4, maxWatts: 4) == 1)
        #expect(wattFraction(watts: 1, maxWatts: 0) == 0)   // flat/zero guard
    }
}
