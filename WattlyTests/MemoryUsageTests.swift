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

    @Test func memorySampleUsesSelectedProcessLimit() {
        let sample = memorySample(
            active: 0, wire: 0, compressor: 0, pageSize: 16384, memsize: 16 * gib,
            processes: [
                ProcessUsage(id: "a", name: "a", footprintBytes: 7),
                ProcessUsage(id: "b", name: "b", footprintBytes: 6),
                ProcessUsage(id: "c", name: "c", footprintBytes: 5),
                ProcessUsage(id: "d", name: "d", footprintBytes: 4),
                ProcessUsage(id: "e", name: "e", footprintBytes: 3),
            ],
            processLimit: 5)

        #expect(sample.processes.map(\.id) == ["a", "b", "c", "d", "e"])
    }

    // MARK: topMemoryApps

    /// Terse identity builder for the ranking tables below: bundle-id key, real display name,
    /// and the `.app` path the row's icon comes from.
    private func app(_ key: String, _ name: String, _ iconPath: String) -> AppIdentity {
        AppIdentity(key: key, name: name, iconPath: iconPath)
    }

    @Test func topMemoryAppsCoalescesHelpersAndUsesAppName() {
        let codex = app("com.openai.codex", "Codex", "/Applications/Codex.app")
        let chrome = app("com.google.Chrome", "Google Chrome", "/Applications/Google Chrome.app")
        let xcode = app("com.apple.dt.Xcode", "Xcode", "/Applications/Xcode.app")

        let top = topMemoryApps(perProcess: [
            (identity: codex, bytes: 50),
            (identity: codex, bytes: 30),
            (identity: chrome, bytes: 70),
            (identity: xcode, bytes: 20),
        ], limit: 7)

        #expect(top.map(\.id) == ["com.openai.codex", "com.google.Chrome", "com.apple.dt.Xcode"])
        #expect(top.map(\.name) == ["Codex", "Google Chrome", "Xcode"])
        #expect(top.map(\.footprintBytes) == [80, 70, 20])
        #expect(top.map(\.iconPath) == [
            "/Applications/Codex.app",
            "/Applications/Google Chrome.app",
            "/Applications/Xcode.app",
        ])
    }

    /// The reported bug (2026-08-22): the list showed "Claude" and "claude" as two rows.
    /// They ARE two different programs (the desktop app and the Claude Code CLI), so two rows
    /// is correct — but the CLI must be labelled from its Info.plist ("Claude Code"), not from
    /// its bundle DIRECTORY name ("claude"). And because the CLI's path carries its version,
    /// two concurrently-running versions (an update lands while older sessions keep running)
    /// must still coalesce into ONE row.
    @Test func claudeDesktopAndClaudeCodeAreDistinctRowsWithRealNames() {
        let desktop = app("com.anthropic.claudefordesktop", "Claude", "/Applications/Claude.app")
        let cli237 = app("com.anthropic.claude-code", "Claude Code",
                         "/Users/me/Library/Application Support/Claude/claude-code/2.1.237/claude.app")
        let cli236 = app("com.anthropic.claude-code", "Claude Code",
                         "/Users/me/Library/Application Support/Claude/claude-code/2.1.236/claude.app")

        let top = topMemoryApps(perProcess: [
            (identity: desktop, bytes: 300),   // main process + helpers
            (identity: desktop, bytes: 200),
            (identity: cli237, bytes: 400),    // several CLI sessions, two versions live
            (identity: cli237, bytes: 300),
            (identity: cli236, bytes: 100),
        ], limit: 3)

        #expect(top.count == 2)
        #expect(top[0].id == "com.anthropic.claude-code")
        #expect(top[0].name == "Claude Code")                 // not "claude"
        #expect(top[0].footprintBytes == 800)                 // both versions in ONE row
        #expect(top[0].iconPath                                // icon from the biggest member
            == "/Users/me/Library/Application Support/Claude/claude-code/2.1.237/claude.app")
        #expect(top[1].id == "com.anthropic.claudefordesktop")
        #expect(top[1].name == "Claude")
        #expect(top[1].footprintBytes == 500)
    }

    @Test func topMemoryAppsRanksBySumThenStableKeyAndCaps() {
        let top = topMemoryApps(perProcess: [
            (identity: app("com.example.b", "B", "/Applications/B.app"), bytes: 40),
            (identity: app("com.example.a", "A", "/Applications/A.app"), bytes: 40),
            (identity: app("com.example.c", "C", "/Applications/C.app"), bytes: 20),
        ], limit: 2)

        // limit 2 clamps up to the 3-row floor; equal sums order by key asc (no poll-to-poll jitter).
        #expect(top.map(\.id) == ["com.example.a", "com.example.b", "com.example.c"])
        #expect(top.map(\.footprintBytes) == [40, 40, 20])
    }

    @Test func topMemoryAppsClampsDirectLimit() {
        let names = ["A", "B", "C", "D", "E", "F", "G", "H"]
        let processes: [(identity: AppIdentity, bytes: UInt64)] = names.enumerated().map { index, name in
            (identity: app("com.example.\(name.lowercased())", name, "/Applications/\(name).app"),
             bytes: UInt64(8 - index))
        }

        #expect(topMemoryApps(perProcess: processes, limit: 1).map(\.name) == ["A", "B", "C"])
        #expect(topMemoryApps(perProcess: processes, limit: 99).map(\.name)
            == ["A", "B", "C", "D", "E", "F", "G"])
    }

    @Test func memoryProcessLimitClampsToSupportedRange() {
        #expect(memoryProcessLimit(nil) == 5)
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
}
