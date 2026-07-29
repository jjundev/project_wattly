import Testing
@testable import Wattly

/// Deterministic memory derivation from synthetic page counts — no hardware
/// (issue 18, plan 05-memory-and-top-processes.md §수용 기준).
struct MemoryUsageTests {
    private let gib = UInt64(1024 * 1024 * 1024)

    // MARK: usedBytes (the acceptance-criterion pure function)

    @Test func usedBytesSumsActiveWiredCompressed() {
        // (100 + 50 + 10) pages × 16384 = 160 × 16384 = 2_621_440
        #expect(usedBytes(active: 100, wire: 50, compressor: 10, pageSize: 16384) == 2_621_440)
    }

    @Test func usedBytesZeroIsZero() {
        #expect(usedBytes(active: 0, wire: 0, compressor: 0, pageSize: 16384) == 0)
    }

    @Test func usedBytesScalesWithPageSize() {
        // Same page counts, Intel 4K vs Apple-silicon 16K.
        #expect(usedBytes(active: 1, wire: 0, compressor: 0, pageSize: 4096) == 4096)
        #expect(usedBytes(active: 1, wire: 0, compressor: 0, pageSize: 16384) == 16384)
    }

    // MARK: memorySample — GiB conversion

    @Test func memorySampleConvertsToGiB() {
        let oneGiBPages = gib / 16384            // pages that make exactly 1 GiB
        let s = memorySample(active: oneGiBPages, wire: 0, compressor: 0,
                             pageSize: 16384, memsize: 16 * gib, processes: [])
        #expect(abs(s.usedGB - 1.0) < 1e-9)
        #expect(abs(s.totalGB - 16.0) < 1e-9)
    }

    @Test func memorySampleWiredAndCompressed() {
        let g = gib / 16384
        let s = memorySample(active: 0, wire: 2 * g, compressor: 1 * g,
                             pageSize: 16384, memsize: 16 * gib, processes: [])
        #expect(abs(s.wiredGB - 2.0) < 1e-9)
        #expect(abs(s.compressedGB - 1.0) < 1e-9)
        #expect(abs(s.usedGB - 3.0) < 1e-9)      // active 0 + wire 2 + compressor 1
    }

    @Test func memorySampleConvertsSwapToGiB() {
        // 3 GiB of swap, expressed in bytes, should read back as 3.0 GB (GiB).
        let s = memorySample(active: 0, wire: 0, compressor: 0,
                             pageSize: 16384, memsize: 16 * gib, processes: [],
                             swapUsedBytes: 3 * gib)
        #expect(abs(s.swapUsedGB - 3.0) < 1e-9)
    }

    @Test func memorySampleSwapDefaultsToZero() {
        // Callers that don't pass swap (older paths) get 0, never a crash or garbage.
        let s = memorySample(active: 0, wire: 0, compressor: 0,
                             pageSize: 16384, memsize: 16 * gib, processes: [])
        #expect(s.swapUsedGB == 0)
    }

    // MARK: MemoryPressure — kernel sysctl mapping (issue: pressure coloring)

    @Test func memoryPressureMapsSysctlLevels() {
        // kern.memorystatus_vm_pressure_level: 1 NORMAL / 2 WARN / 4 CRITICAL.
        #expect(MemoryPressure(fromSysctl: 1) == .normal)
        #expect(MemoryPressure(fromSysctl: 2) == .warn)
        #expect(MemoryPressure(fromSysctl: 4) == .critical)
        // Defensive: 0 and unknown future values fall to normal (never crashes/over-alarms).
        #expect(MemoryPressure(fromSysctl: 0) == .normal)
        #expect(MemoryPressure(fromSysctl: 99) == .normal)
    }

    @Test func memoryPressureMapsToThresholdLevel() {
        #expect(MemoryPressure.normal.thresholdLevel == .normal)
        #expect(MemoryPressure.warn.thresholdLevel == .warn)
        #expect(MemoryPressure.critical.thresholdLevel == .crit)
    }

    @Test func memorySampleCarriesPressureWhenGiven() {
        let s = memorySample(active: 0, wire: 0, compressor: 0,
                             pageSize: 16384, memsize: 16 * gib, processes: [], pressure: .warn)
        #expect(s.pressure == .warn)
        // Default is nil — the occupancy-only path (sysctl unavailable / not requested).
        let bare = memorySample(active: 0, wire: 0, compressor: 0,
                                pageSize: 16384, memsize: 16 * gib, processes: [])
        #expect(bare.pressure == nil)
    }

    // MARK: memoryPressurePercent — kernel free% → pressure% (100 − free, clamped)

    @Test func pressurePercentInvertsAndClamps() {
        // memorystatus_get_level returns FREE %, so pressure = 100 − free.
        #expect(memoryPressurePercent(freeLevel: 60) == 40)   // 활동 상태 보기와 동일
        #expect(memoryPressurePercent(freeLevel: 100) == 0)   // all free → no pressure
        #expect(memoryPressurePercent(freeLevel: 0) == 100)   // none free → max pressure
        // Defensive clamp: a garbage free > 100 never yields a negative percent.
        #expect(memoryPressurePercent(freeLevel: 150) == 0)
    }

    @Test func memorySampleCarriesPressurePercentWhenGiven() {
        let s = memorySample(active: 0, wire: 0, compressor: 0,
                             pageSize: 16384, memsize: 16 * gib, processes: [],
                             pressurePercent: 42)
        #expect(s.pressurePercent == 42)
        // Default is nil — the path where the syscall was unavailable / not requested.
        let bare = memorySample(active: 0, wire: 0, compressor: 0,
                                pageSize: 16384, memsize: 16 * gib, processes: [])
        #expect(bare.pressurePercent == nil)
    }

    // MARK: topMemoryApps

    @Test func topMemoryAppsCoalescesHelpersAndUsesAppName() {
        let top = topMemoryApps(perProcess: [
            (key: "/Applications/Codex.app", bytes: 50),
            (key: "/Applications/Codex.app", bytes: 30),
            (key: "/Applications/Google Chrome.app", bytes: 70),
            (key: "/Applications/Xcode.app", bytes: 20),
        ], limit: 7)

        #expect(top.map(\.id) == [
            "/Applications/Codex.app",
            "/Applications/Google Chrome.app",
            "/Applications/Xcode.app",
        ])
        #expect(top.map(\.name) == ["Codex", "Google Chrome", "Xcode"])
        #expect(top.map(\.footprintBytes) == [80, 70, 20])
        #expect(top.map(\.iconPath) == [
            "/Applications/Codex.app",
            "/Applications/Google Chrome.app",
            "/Applications/Xcode.app",
        ])
    }

    @Test func topMemoryAppsRanksBySumThenStableKeyAndCaps() {
        let top = topMemoryApps(perProcess: [
            (key: "/Applications/B.app", bytes: 40),
            (key: "/Applications/A.app", bytes: 40),
            (key: "/Applications/C.app", bytes: 20),
        ], limit: 2)

        #expect(top.map(\.id) == ["/Applications/A.app", "/Applications/B.app", "/Applications/C.app"])
        #expect(top.map(\.footprintBytes) == [40, 40, 20])
    }

    @Test func topMemoryAppsClampsDirectLimit() {
        let processes = [
            (key: "/Applications/A.app", bytes: UInt64(8)),
            (key: "/Applications/B.app", bytes: UInt64(7)),
            (key: "/Applications/C.app", bytes: UInt64(6)),
            (key: "/Applications/D.app", bytes: UInt64(5)),
            (key: "/Applications/E.app", bytes: UInt64(4)),
            (key: "/Applications/F.app", bytes: UInt64(3)),
            (key: "/Applications/G.app", bytes: UInt64(2)),
            (key: "/Applications/H.app", bytes: UInt64(1)),
        ]

        #expect(topMemoryApps(perProcess: processes, limit: 1).map(\.id) == [
            "/Applications/A.app", "/Applications/B.app", "/Applications/C.app",
        ])
        #expect(topMemoryApps(perProcess: processes, limit: 99).map(\.id) == [
            "/Applications/A.app", "/Applications/B.app", "/Applications/C.app",
            "/Applications/D.app", "/Applications/E.app", "/Applications/F.app",
            "/Applications/G.app",
        ])
    }

    @Test func memoryProcessLimitClampsToSupportedRange() {
        #expect(memoryProcessLimit(nil) == 3)
        #expect(memoryProcessLimit(1) == 3)
        #expect(memoryProcessLimit(3) == 3)
        #expect(memoryProcessLimit(5) == 5)
        #expect(memoryProcessLimit(7) == 7)
        #expect(memoryProcessLimit(99) == 7)
    }

    // MARK: barFraction — zero-denominator guard

    @Test func barFractionProportionalAndGuarded() {
        #expect(barFraction(footprint: 50, maxBytes: 100) == 0.5)
        #expect(barFraction(footprint: 100, maxBytes: 100) == 1.0)
        #expect(barFraction(footprint: 10, maxBytes: 0) == 0)   // no divide-by-zero
    }

    // MARK: appBundlePath — outermost-.app heuristic for the row icon

    @Test func appBundlePathPicksOutermostDotApp() {
        // Helper nested inside the main app → the OUTER app (Chrome icon, not the helper's).
        #expect(appBundlePath(forExecutable:
            "/Applications/Google Chrome.app/Contents/Frameworks/Chrome.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)")
            == "/Applications/Google Chrome.app")
        // CLI tool bundled in an app → that app (Xcode icon).
        #expect(appBundlePath(forExecutable: "/Applications/Xcode.app/Contents/Developer/usr/bin/lldb-rpc-server")
            == "/Applications/Xcode.app")
        // Plain CLI tool, no enclosing .app → the executable itself (generic icon).
        #expect(appBundlePath(forExecutable: "/usr/sbin/cfprefsd") == "/usr/sbin/cfprefsd")
        #expect(appBundlePath(forExecutable: "") == nil)
    }
}
