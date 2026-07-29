# Memory Process App Grouping and Limit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show one aggregated row per application in the expanded memory card and let users choose a persisted maximum of 3 through 7 rows in Settings.

**Architecture:** Resolve every readable process to its outermost `.app` bundle before ranking, then sum physical-memory footprints by that bundle path. The app-bundle path becomes the stable row identity, icon source, and display-name source, so Electron/Chromium helpers such as `Codex (Renderer)` display once as `Codex`. Persist the selected row cap in `UserDefaults`; `MemoryProvider` reads and clamps it only while the expanded card enables enumeration.

**Tech Stack:** Swift 6, SwiftUI, Foundation/libproc, `@AppStorage`/`UserDefaults`, Swift Testing, XcodeGen/Xcode unit tests.

## Global Constraints

- Target macOS 14.0+ on Apple Silicon; keep Swift 6 strict-concurrency compatibility.
- Do not add dependencies, entitlements, private responsible-PID APIs, or privileged helpers.
- The memory process sweep must remain disabled unless the expanded memory card is visible.
- Group helper/renderer processes by the outermost `.app` path; a grouped row must show the bundle basename without `.app` (for example, `Codex`, never `Codex (Renderer)`).
- The persisted maximum must default to 3 and be clamped to the inclusive range 3...7 before ranking, including malformed persisted values.
- Keep the existing empty-state copy and row layout; only the rows’ identity, aggregation, and maximum count change.

---

## File Structure

- Modify: `Wattly/Models/MetricSample.swift:60-72` — make `ProcessUsage` represent an app-level memory row with a string grouping key rather than a single PID.
- Modify: `Wattly/Core/MemoryUsage.swift:53-96` — provide pure clamping and app-footprint aggregation/ranking helpers; retain the existing memory sample and bar-fraction seams.
- Modify: `Wattly/Providers/MemoryProvider.swift:31-50,110-128` — resolve all readable process paths, aggregate by app key, and use the persisted row cap during an enumerating read.
- Modify: `Wattly/Providers/FakeProvider.swift:100-114` — update fake memory sample rows to the app-level `ProcessUsage` initializer.
- Modify: `Wattly/Settings/Settings.swift:229-291` — declare one default and one storage key for the memory process maximum.
- Modify: `Wattly/Views/SettingsView.swift:85-99,165-190,288-304` — bind the new storage value and expose a 3/4/5/6/7 segmented setting under Display.
- Modify: `Wattly/Core/SettingsReset.swift:16-38` — reset the new persisted value with all other Settings values.
- Modify: `WattlyTests/MemoryUsageTests.swift:110-150` — replace PID-ranking expectations with deterministic app aggregation, label, identity, and bound tests.
- Modify: `WattlyTests/SettingsResetTests.swift:29-55` — verify reset overwrites the memory-process maximum with its default.

## Decision Checkpoint

No execution-level decision remains. The existing `appBundlePath(forExecutable:)` already selects the outermost bundle, and `appDisplayName(forKey:)` already strips `.app`; reusing those semantics keeps memory and power cards consistent. A five-option `WattlySegment` follows the existing settings control system and needs no new view component.

### Task 1: Pure app-level memory aggregation and row model

**Files:**
- Modify: `Wattly/Models/MetricSample.swift:60-72`
- Modify: `Wattly/Core/MemoryUsage.swift:53-96`
- Modify: `Wattly/Providers/MemoryProvider.swift:121-127`
- Modify: `Wattly/Providers/FakeProvider.swift:100-114`
- Test: `WattlyTests/MemoryUsageTests.swift:110-150`

**Interfaces:**
- Consumes: `appBundlePath(forExecutable:) -> String?` from `Wattly/Core/MemoryUsage.swift` and `appDisplayName(forKey:) -> String` from `Wattly/Core/ProcessPower.swift`.
- Produces: `ProcessUsage(id:name:footprintBytes:iconPath:)`, `memoryProcessLimit(_:) -> Int`, and `topMemoryApps(perProcess:limit:) -> [ProcessUsage]` for `MemoryProvider` and the memory expansion view.

- [ ] **Step 1: Write the failing aggregation and bound tests**

Replace the `// MARK: topProcesses` tests in `WattlyTests/MemoryUsageTests.swift` with these tests. They deliberately supply two Codex child processes so a PID-by-PID implementation fails both the count and summed-footprint assertions.

```swift
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

    #expect(top.map(\.id) == ["/Applications/A.app", "/Applications/B.app"])
    #expect(top.map(\.footprintBytes) == [40, 40])
}

@Test func memoryProcessLimitClampsToSupportedRange() {
    #expect(memoryProcessLimit(nil) == 3)
    #expect(memoryProcessLimit(1) == 3)
    #expect(memoryProcessLimit(3) == 3)
    #expect(memoryProcessLimit(5) == 5)
    #expect(memoryProcessLimit(7) == 7)
    #expect(memoryProcessLimit(99) == 7)
}
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/MemoryUsageTests
```

Expected: FAIL at compile time because `topMemoryApps(perProcess:limit:)` and `memoryProcessLimit(_:)` do not exist; the old `ProcessUsage(pid:name:footprintBytes:)` initializer also no longer matches the replacement tests.

- [ ] **Step 3: Replace the PID row model and implement aggregation**

In `Wattly/Models/MetricSample.swift`, replace `ProcessUsage` with an app-row value. `id` must be stored, not derived from a PID, because SwiftUI must preserve the row while any helper PID exits or restarts.

```swift
/// One application row in the memory card's expand. `footprintBytes` is the sum of
/// readable member processes' `ri_phys_footprint`; `id` is the outer `.app` bundle
/// path (or executable-path fallback), stable across helper-process churn.
struct ProcessUsage: Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var footprintBytes: UInt64
    /// App-bundle (or executable) path used by `NSWorkspace` for the row icon.
    /// It is a String rather than an `NSImage` so the sample remains Sendable.
    var iconPath: String? = nil
}
```

In `Wattly/Core/MemoryUsage.swift`, change `memorySample` so its call to `topProcesses` accepts a passed maximum, then replace the old `topProcesses` helper with the following pure helpers. `appDisplayName` is intentionally reused from the existing power-card app grouping code, ensuring `Codex.app` renders as `Codex` in both cards.

```swift
func memorySample(active: UInt64, wire: UInt64, compressor: UInt64,
                  pageSize: UInt64, memsize: UInt64,
                  processes: [ProcessUsage], processLimit: Int = 3,
                  pressure: MemoryPressure? = nil,
                  pressurePercent: Int? = nil,
                  swapUsedBytes: UInt64 = 0) -> MemorySample {
    MemorySample(
        usedGB: Double(usedBytes(active: active, wire: wire, compressor: compressor, pageSize: pageSize)) / bytesPerGiB,
        totalGB: Double(memsize) / bytesPerGiB,
        wiredGB: Double(wire * pageSize) / bytesPerGiB,
        compressedGB: Double(compressor * pageSize) / bytesPerGiB,
        swapUsedGB: Double(swapUsedBytes) / bytesPerGiB,
        processes: topProcesses(processes, limit: memoryProcessLimit(processLimit)),
        pressure: pressure,
        pressurePercent: pressurePercent)
}

func memoryProcessLimit(_ persisted: Int?) -> Int {
    min(7, max(3, persisted ?? 3))
}

func topMemoryApps(perProcess: [(key: String, bytes: UInt64)], limit: Int) -> [ProcessUsage] {
    var sums: [String: UInt64] = [:]
    for process in perProcess {
        sums[process.key, default: 0] += process.bytes
    }
    return sums.sorted { lhs, rhs in
        lhs.value > rhs.value || (lhs.value == rhs.value && lhs.key < rhs.key)
    }
    .prefix(memoryProcessLimit(limit))
    .map { key, bytes in
        ProcessUsage(id: key, name: appDisplayName(forKey: key), footprintBytes: bytes, iconPath: key)
    }
}

func topProcesses(_ all: [ProcessUsage], limit: Int) -> [ProcessUsage] {
    Array(all.sorted {
        $0.footprintBytes > $1.footprintBytes
            || ($0.footprintBytes == $1.footprintBytes && $0.id < $1.id)
    }.prefix(memoryProcessLimit(limit)))
}
```

Update the fake memory sample in `Wattly/Providers/FakeProvider.swift` to use stable application IDs, names, and paths:

```swift
processes: [
    ProcessUsage(id: "/Applications/Google Chrome.app", name: "Google Chrome",
                 footprintBytes: UInt64(used * 0.30 * gib), iconPath: "/Applications/Google Chrome.app"),
    ProcessUsage(id: "/Applications/Xcode.app", name: "Xcode",
                 footprintBytes: UInt64(used * 0.21 * gib), iconPath: "/Applications/Xcode.app"),
    ProcessUsage(id: "/Applications/Figma.app", name: "Figma",
                 footprintBytes: UInt64(used * 0.13 * gib), iconPath: "/Applications/Figma.app"),
],
```

To keep Task 1 buildable after `ProcessUsage.pid` is removed, update the existing per-PID construction in `Wattly/Providers/MemoryProvider.swift` only. This is a mechanical source migration, not the app-grouping behavior reserved for Task 3:

```swift
return ProcessUsage(id: "PID \(entry.pid)",
                    name: procName(of: entry.pid, path: path),
                    footprintBytes: entry.bytes,
                    iconPath: appBundlePath(forExecutable: path))
```

- [ ] **Step 4: Run the focused test to verify it passes**

Run:

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/MemoryUsageTests
```

Expected: PASS; the new tests prove that two Codex helpers become one `Codex` row with the summed footprint, ties are stable, and every cap is 3...7.

- [ ] **Step 5: Commit the pure aggregation seam**

```bash
git add Wattly/Models/MetricSample.swift Wattly/Core/MemoryUsage.swift Wattly/Providers/MemoryProvider.swift Wattly/Providers/FakeProvider.swift WattlyTests/MemoryUsageTests.swift
git commit -m "feat(memory): aggregate helper processes by app"
```

### Task 2: Persist and expose the 3...7 row cap in Settings

**Files:**
- Modify: `Wattly/Settings/Settings.swift:229-291`
- Modify: `Wattly/Views/SettingsView.swift:85-99,165-190,288-304`
- Modify: `Wattly/Core/SettingsReset.swift:16-38`
- Test: `WattlyTests/SettingsResetTests.swift:29-55`

**Interfaces:**
- Consumes: `Defaults.memoryProcessLimit: Int` and `StorageKey.memoryProcessLimit: String`.
- Produces: a `@AppStorage` integer that stores only the UI-selected values 3 through 7; `SettingsReset.applyDefaults(into:login:)` writes it back to 3.

- [ ] **Step 1: Write the failing reset test**

In `resetRestoresEveryScalarKey`, dirty and verify the new key with the other scalar Settings values:

```swift
d.set(7, forKey: StorageKey.memoryProcessLimit)
// existing SettingsReset.applyDefaults call
#expect(d.object(forKey: StorageKey.memoryProcessLimit) != nil)
#expect(d.integer(forKey: StorageKey.memoryProcessLimit) == Defaults.memoryProcessLimit)
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/SettingsResetTests/resetRestoresEveryScalarKey
```

Expected: FAIL at compile time because `StorageKey.memoryProcessLimit` and `Defaults.memoryProcessLimit` do not exist.

- [ ] **Step 3: Add the default, storage key, reset write, and Settings segment**

In `Wattly/Settings/Settings.swift`, add the default next to the other display defaults and the key next to `showBatteryEfficiency`:

```swift
static let memoryProcessLimit = 3
```

```swift
static let memoryProcessLimit = "memoryProcessLimit"
```

In `Wattly/Core/SettingsReset.swift`, write the default alongside the other scalar values:

```swift
defaults.set(Defaults.memoryProcessLimit, forKey: StorageKey.memoryProcessLimit)
```

In `Wattly/Views/SettingsView.swift`, declare the storage binding after `showBatteryEfficiency`:

```swift
@AppStorage(StorageKey.memoryProcessLimit) private var memoryProcessLimit = Defaults.memoryProcessLimit
```

Include `memoryProcessLimitSection` in `displayGroup` immediately after `showSection`. Add this new section before the existing `// MARK: 전력 표시 (EMA)` marker:

```swift
// MARK: 메모리 프로세스

private var memoryProcessLimitSection: some View {
    SettingsSection(title: "메모리 프로세스") {
        SettingsCard(padding: Tokens.cardPadding) {
            VStack(alignment: .leading, spacing: 8) {
                Text("펼침 목록 최대 표시")
                    .font(WattlyFont.at(11.5, weight: .regular))
                    .foregroundStyle(t.faint)
                WattlySegment(selection: $memoryProcessLimit, options: [
                    (3, "3개"), (4, "4개"), (5, "5개"), (6, "6개"), (7, "7개"),
                ], fontSize: 11.5, pillVPadding: 6)
            }
        }
    }
}
```

Also update the SettingsView section-order documentation comment so it names `메모리 프로세스` in the Display group. Do not add an `onChange`: `@AppStorage` writes synchronously and `MemoryProvider` reads the same `UserDefaults` value at the next active enumeration poll.

- [ ] **Step 4: Run the focused test to verify it passes**

Run:

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/SettingsResetTests/resetRestoresEveryScalarKey
```

Expected: PASS; a previously saved `7` is overwritten with the default `3` during Reset.

- [ ] **Step 5: Commit the Settings preference**

```bash
git add Wattly/Settings/Settings.swift Wattly/Views/SettingsView.swift Wattly/Core/SettingsReset.swift WattlyTests/SettingsResetTests.swift
git commit -m "feat(settings): configure memory process row limit"
```

### Task 3: Wire the live provider to app grouping and the persisted limit

**Files:**
- Modify: `Wattly/Providers/MemoryProvider.swift:31-50,110-128`
- Test: `WattlyTests/MemoryUsageTests.swift:110-150`

**Interfaces:**
- Consumes: `StorageKey.memoryProcessLimit`, `memoryProcessLimit(_:)`, `appBundlePath(forExecutable:)`, and `topMemoryApps(perProcess:limit:)`.
- Produces: `MemorySample.processes` sorted by aggregated application footprint, with at most the current 3...7 preference, without changing `ProcessEnumerating` or the existing expansion gate.


- [ ] **Step 1: Add the memory-sample cap regression test**

Append this test to `WattlyTests/MemoryUsageTests.swift`. It proves that `memorySample` preserves the selected maximum at its public seam instead of silently reverting to three.

```swift
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
```


- [ ] **Step 2: Run the focused test to verify the pure seam remains green**

Run:

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/MemoryUsageTests/memorySampleUsesSelectedProcessLimit
```

Expected: PASS. Task 1 owns the pure behavior and this test locks the selected-cap contract before the live libproc wiring below. The provider change is then verified by the full test suite, build, and manual runtime check because libproc paths are host-dependent.

- [ ] **Step 3: Use the stored cap and aggregate all readable processes before ranking**

In `MemoryProvider.read(at:)`, obtain the limit once only when enumeration is active, then pass it through to both the live top-app function and `memorySample`:

```swift
let processLimit = memoryProcessLimit(
    UserDefaults.standard.object(forKey: StorageKey.memoryProcessLimit) as? Int)
let procs = enumerating ? Self.topMemoryProcesses(limit: processLimit) : []
// retain the existing pressure reads
return .value(.memory(memorySample(
    active: UInt64(vm.active_count),
    wire: UInt64(vm.wire_count),
    compressor: UInt64(vm.compressor_page_count),
    pageSize: pageSize == 0 ? 16384 : pageSize,
    memsize: memsize,
    processes: procs,
    processLimit: processLimit,
    pressure: pressure,
    pressurePercent: pressurePercent,
    swapUsedBytes: Self.swapUsedBytes())))
```

Replace `topMemoryProcesses(limit:)` with this implementation. It deliberately resolves the executable path for every readable PID before aggregation; grouping cannot safely occur after the former Top-3 cutoff, because several smaller renderer/helper footprints may together outrank a single process. This work still occurs only while `enumerating` is true.

```swift
private static func topMemoryProcesses(limit: Int) -> [ProcessUsage] {
    var perProcess: [(key: String, bytes: UInt64)] = []
    for pid in listPIDs() where pid > 0 {
        guard let bytes = physFootprint(pid) else { continue }
        let path = pidPath(pid)
        let key = appBundlePath(forExecutable: path) ?? "PID \(pid)"
        perProcess.append((key: key, bytes: bytes))
    }
    return topMemoryApps(perProcess: perProcess, limit: limit)
}
```

Delete the now-unused `procName(of:path:)` reference from this provider only; leave the shared `ProcessList` helper intact because other code may use it later. Update the provider and model comments from “Top-3/process” to “Top-N/application” so the runtime behavior is accurately documented. `CardExpandRegion` needs no behavioral code change: it already iterates `ProcessUsage`, uses `id` for `ForEach`, and renders its `name`, `footprintBytes`, and `iconPath`.

- [ ] **Step 4: Run unit tests and build to verify the integration**

Run:

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/MemoryUsageTests -only-testing:WattlyTests/SettingsResetTests
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' build
```

Expected: both commands exit 0. The tests cover deterministic grouping, labels, ordering, caps, and reset behavior; the build catches the `ProcessUsage` API migration in the SwiftUI and fake-provider paths.

- [ ] **Step 5: Perform the on-device behavior check**

Run the Debug app from Xcode, open the memory card, and verify all of the following:

1. Start or use a multi-process app such as Codex or Google Chrome; its renderer/helper rows collapse into one application row.
2. The row text is `Codex`/`Google Chrome`, not an executable helper name such as `Codex (Renderer)`.
3. Select `7개` in Settings → `표시` → `메모리 프로세스`, collapse and re-expand the memory card, and confirm up to seven rows appear; restart the app and confirm the selection persists.
4. Select `3개` and confirm the next expansion returns to at most three rows; select Reset to defaults and confirm the control returns to `3개`.
5. Collapse the memory card or close the popover and confirm the existing `ProcessEnumerating` gate still disables the process sweep.

- [ ] **Step 6: Commit the live provider integration**

```bash
git add Wattly/Providers/MemoryProvider.swift Wattly/Models/MetricSample.swift Wattly/Core/MemoryUsage.swift Wattly/Providers/FakeProvider.swift Wattly/Settings/Settings.swift Wattly/Views/SettingsView.swift Wattly/Core/SettingsReset.swift WattlyTests/MemoryUsageTests.swift WattlyTests/SettingsResetTests.swift
git commit -m "feat(memory): honor configurable app process limit"
```

## Self-Review

1. **Spec coverage:** Task 1 converts duplicate helper rows to application rows and guarantees the display name `Codex`; Task 2 adds a persisted Settings control for exactly 3...7 plus Reset coverage; Task 3 consumes that setting in the live memory sweep while retaining the existing expansion-only gate. No requirement is uncovered.
2. **Placeholder scan:** No task uses TBD/TODO, generic test language, or undefined implementation symbols. All introduced symbols (`ProcessUsage`, `memoryProcessLimit`, `topMemoryApps`, `topProcesses`, `memorySample` parameter, `Defaults.memoryProcessLimit`, `StorageKey.memoryProcessLimit`) are defined in Task 1 or Task 2 before consumption.
3. **Type consistency:** The model key is `String` from provider grouping through SwiftUI `ForEach`; footprint totals remain `UInt64`; preference values remain `Int`; public limits are clamped by `memoryProcessLimit(_:)` at the core seam and live-provider boundary.
