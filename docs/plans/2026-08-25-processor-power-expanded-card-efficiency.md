# Processor Power Expanded-Card Efficiency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the expanded processor-power app list on its current one-second measurement cadence while reducing Wattly's incremental energy use from repeated app-icon lookup and unchanged SwiftUI process-row rendering.

**Architecture:** Preserve `PowerProvider`'s existing expanded-only, all-readable-PID sampling and stable Top-N ranking. Move process-row presentation into a small equatable SwiftUI component whose inputs are quantized only below visible precision, and add a bounded main-actor icon cache so unchanged rows do not redo `NSWorkspace.icon(forFile:)` or layout work. Measure the Release app before and after with the same external `ri_energy_nj` sampler and keep automated evidence separate from physical energy evidence.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSWorkspace`/`NSImage`, Darwin `proc_pid_rusage(RUSAGE_INFO_V6)`, Swift Testing, Xcode 17/macOS 14+

## Global Constraints

- Keep the processor-power provider at exactly one-second cadence while the panel is open; do not modify `PollPolicy.swift`, `SystemMonitor.setPowerProcessEnumeration`, or `PowerProvider` cadence/gating behavior.
- Keep app-level measurement disabled until the processor-power card is both visible and expanded in Mode A or is the expanded Mode C hero.
- Continue sweeping every readable PID on every expanded-card sample so a newly power-hungry app can enter Top-N on the next sample; do not alternate partial and full sweeps.
- Do not exclude Wattly from measurement or ranking; hiding Wattly would conceal consumption without reducing it.
- Preserve the three list states exactly: `nil` shows `측정 중…`, an empty array shows `프로세스를 읽을 수 없음`, and a non-empty array shows the configured Top-N.
- Preserve current visible precision and ordering: app watts remain `%.2f W`, rows remain watts-descending with stable tie ordering, and bar proportions remain visually equivalent to the current raw fractions.
- Add no third-party dependency and no additional private API.
- Keep macOS deployment target 14.0 and Swift language version 6.0.
- Validate on a Release build with Wattly Settings closed, the same power source, the same menu-bar motion settings, and three 60-second runs per state.
- Treat automated tests/builds as proof of behavior and type safety only; only the controlled Release A/B run is evidence of physical energy improvement.
- The worktree was clean and detached before this plan file was added; execution must create a `codex/processor-power-efficiency` branch before the first implementation commit, keep this plan file, and preserve any later unrelated user changes.

---

## File Structure

- Create `scripts/measure-process-energy.swift` — read-only external sampler that reports any process's `ri_energy_nj` average over repeated fixed-duration runs.
- Create `Wattly/Views/ProcessListRowsView.swift` — pure process-row presentation mapping, bounded app-icon cache, and equatable shared row renderer for memory and processor-power lists.
- Create `WattlyTests/ProcessListRowsViewTests.swift` — deterministic tests for visible-precision equality, immediate identity/value changes, memory-row mapping, theme-sensitive equality, and one-load-per-path icon caching.
- Modify `Wattly/Views/CardExpandRegion.swift` — replace inline memory/power row layout and direct icon lookup with `ProcessListRowsView`; retain empty/measuring copy in the parent.
- Modify `Wattly.xcodeproj/project.pbxproj` — register the new app source and test source with fixed non-colliding object identifiers.
- Modify `docs/self-power-baseline.md` — preserve the general OPEN/CLOSED regression procedure and add a separate controlled collapsed-versus-expanded protocol, before/after results, formulas, and acceptance verdict.

## Decision Checkpoint

No unresolved execution-level decision remains. The current source and live diagnosis settle the boundary: keep exact one-second global ranking and optimize only presentation/cache work. Changing sampling cadence, omitting PIDs, or hiding Wattly would reverse explicit requirements and is out of scope.

---

### Task 1: Add the external energy sampler and capture the pre-change baseline

**Files:**
- Create: `scripts/measure-process-energy.swift`
- Modify: `docs/self-power-baseline.md`

**Interfaces:**
- Consumes: a live same-user process ID, duration in seconds, and run count from `CommandLine.arguments`
- Produces: `run,watts` CSV rows followed by `mean,<watts>`; the pre-change collapsed and expanded three-run means consumed by Task 3

- [ ] **Step 1: Create the execution branch**

Run:

```bash
git switch -c codex/processor-power-efficiency
```

Expected: `Switched to a new branch 'codex/processor-power-efficiency'`; the only allowed status entry is this untracked plan document.

- [ ] **Step 2: Run the absent-script check**

Run:

```bash
swift scripts/measure-process-energy.swift 2>&1
```

Expected: nonzero exit because `scripts/measure-process-energy.swift` does not exist yet.

- [ ] **Step 3: Create the read-only energy sampler**

Create `scripts/measure-process-energy.swift` with this complete content:

```swift
#!/usr/bin/env swift

import Darwin
import Foundation

private struct Arguments {
    let pid: Int32
    let seconds: TimeInterval
    let runs: Int

    init?(_ raw: [String]) {
        guard raw.count == 3,
              let pid = Int32(raw[0]), pid > 0,
              let seconds = TimeInterval(raw[1]), seconds > 0,
              let runs = Int(raw[2]), runs > 0 else { return nil }
        self.pid = pid
        self.seconds = seconds
        self.runs = runs
    }
}

private func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

private func energyNanojoules(pid: Int32) -> UInt64? {
    var info = rusage_info_v6()
    let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
        }
    }
    return result == 0 ? info.ri_energy_nj : nil
}

guard let arguments = Arguments(Array(CommandLine.arguments.dropFirst())) else {
    fail("usage: swift scripts/measure-process-energy.swift <pid> <seconds> <runs>", code: 64)
}

guard kill(arguments.pid, 0) == 0 else {
    fail("target pid \(arguments.pid) is not running or is not accessible", code: 66)
}

var readings: [Double] = []
readings.reserveCapacity(arguments.runs)
print("run,watts")

for run in 1...arguments.runs {
    guard let startEnergy = energyNanojoules(pid: arguments.pid) else {
        fail("could not read starting ri_energy_nj for pid \(arguments.pid)", code: 69)
    }
    let start = ContinuousClock.now
    Thread.sleep(forTimeInterval: arguments.seconds)
    let end = ContinuousClock.now
    guard let endEnergy = energyNanojoules(pid: arguments.pid), endEnergy >= startEnergy else {
        fail("could not read a monotonic ending ri_energy_nj for pid \(arguments.pid)", code: 69)
    }

    let duration = start.duration(to: end)
    let elapsed = Double(duration.components.seconds)
        + Double(duration.components.attoseconds) * 1e-18
    let watts = Double(endEnergy - startEnergy) / 1_000_000_000 / elapsed
    readings.append(watts)
    print("\(run),\(String(format: "%.6f", watts))")
}

let mean = readings.reduce(0, +) / Double(readings.count)
print("mean,\(String(format: "%.6f", mean))")
```

- [ ] **Step 4: Verify argument validation**

Run:

```bash
set +e
output=$(swift scripts/measure-process-energy.swift 2>&1)
status=$?
set -e
test "$status" -eq 64
test "$output" = "usage: swift scripts/measure-process-energy.swift <pid> <seconds> <runs>"
```

Expected: exit 0 from the shell assertions; the script itself exits 64 with the exact usage line.

- [ ] **Step 5: Verify live sampling against a controlled process**

Run:

```bash
/bin/sleep 10 &
sample_pid=$!
swift scripts/measure-process-energy.swift "$sample_pid" 1 2
wait "$sample_pid"
```

Expected: output contains the exact header `run,watts`, rows `1,<nonnegative number>` and `2,<nonnegative number>`, then `mean,<nonnegative number>`; the sampler does not terminate or mutate the target.

- [ ] **Step 6: Append an expanded-card A/B protocol without removing the general baseline**

In `docs/self-power-baseline.md`, leave the existing OPEN/CLOSED-menu/CLOSED-idle procedure and recorded-baselines table unchanged. Append this separate section after the existing content:

```markdown
## Controlled processor-power expansion A/B

Use a Release build on one Apple-Silicon Mac. Keep the power source, Low Power Mode,
menu-bar icon style/motion/speed, visible cards, panel mode, process-list limit, and
foreground apps unchanged for the whole comparison. Close Wattly Settings because its
animated icon preview is a separate renderer. Leave the popover open in Mode A and wait
60 seconds after launch before measuring.

1. Build and launch the exact commit being measured.
2. Find the Release PID with `pgrep -x Wattly` and confirm its binary path with
   `ps -p "$WATTLY_PID" -o command=`.
3. Collapse the processor-power card, wait 10 seconds, then run three consecutive
   60-second samples:
   `swift scripts/measure-process-energy.swift "$WATTLY_PID" 60 3`.
4. Expand only the processor-power card, wait until app rows appear, wait another
   10 seconds, then run the same command.
5. Compute `expansion delta = expanded mean - collapsed mean`.
6. Repeat all five steps after the optimization on the same Mac and settings.

The optimization passes when it preserves one-second processor-power polling and:

- if the pre-change expansion delta is at least 0.03 W, the post-change delta is no
  more than 80% of the pre-change delta;
- if the pre-change expansion delta is below 0.03 W, the post-change delta remains
  at or below 0.03 W because the reported 0.2–0.3 W expansion symptom did not reproduce.

## Recorded expanded-card comparisons

Each comparison records the exact date, commit, Mac model, macOS build, power source,
motion settings, collapsed runs and mean, expanded runs and mean, computed delta, and
pass/fail verdict. Do not add a comparison until all six runs were captured under the
controlled protocol above.
```

- [ ] **Step 7: Build and launch the pre-change Release app**

Run:

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Release \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/WattlyPowerBefore \
  CODE_SIGNING_ALLOWED=NO build
pkill -x Wattly 2>/dev/null || true
open /private/tmp/WattlyPowerBefore/Build/Products/Release/Wattly.app
```

Expected: `** BUILD SUCCEEDED **`; one Release Wattly process is running from `/private/tmp/WattlyPowerBefore`.

- [ ] **Step 8: Capture and record the pre-change six-run baseline**

Set Mode A, Eco/automatic polling, the intended menu-bar icon settings, and the desired process-list limit once. Close Wattly Settings. Follow the new document exactly for three collapsed and three expanded 60-second runs, then append one `before` comparison containing every emitted run, both means, and the computed expansion delta.

Expected: the document contains no blank measurement cells, and the recorded commit equals `git rev-parse HEAD`.

- [ ] **Step 9: Commit the measurement harness and baseline**

Run:

```bash
git add scripts/measure-process-energy.swift docs/self-power-baseline.md
git add docs/plans/2026-08-25-processor-power-expanded-card-efficiency.md
git commit -m "test(perf): add processor power expansion baseline"
```

Expected: one commit containing only the sampler, this implementation plan, and the evidence document; the worktree is clean afterward.

---

### Task 2: Cache icons and suppress visually unchanged process-row renders

**Files:**
- Create: `Wattly/Views/ProcessListRowsView.swift`
- Create: `WattlyTests/ProcessListRowsViewTests.swift`
- Modify: `Wattly/Views/CardExpandRegion.swift:187-241,529-573`
- Modify: `Wattly.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `[ProcessUsage]`, `[ProcessPower]`, `CardPresentation.gbText(_:)`, `CardPresentation.wattText(_:)`, `barFraction(footprint:maxBytes:)`, `wattFraction(watts:maxWatts:)`, `Tokens`, and the current card's resolved bar `Color`
- Produces: `memoryProcessRowPresentations(_:) -> [ProcessListRowPresentation]`, `powerProcessRowPresentations(_:) -> [ProcessListRowPresentation]`, `@MainActor ProcessAppIconCache.image(for:) -> NSImage`, and equatable `ProcessListRowsView`

- [ ] **Step 1: Write the failing presentation/cache tests**

Create `WattlyTests/ProcessListRowsViewTests.swift` with this complete content:

```swift
import AppKit
import SwiftUI
import Testing
@testable import Wattly

struct ProcessListRowsViewTests {
    @Test func powerRowsIgnoreChangesBelowVisiblePrecision() {
        let a = [
            ProcessPower(id: "top", name: "Top", watts: 1.0, iconPath: "/Top.app"),
            ProcessPower(id: "second", name: "Second", watts: 0.5011, iconPath: "/Second.app"),
        ]
        let b = [
            ProcessPower(id: "top", name: "Top", watts: 1.0, iconPath: "/Top.app"),
            ProcessPower(id: "second", name: "Second", watts: 0.5012, iconPath: "/Second.app"),
        ]

        #expect(powerProcessRowPresentations(a) == powerProcessRowPresentations(b))
    }

    @Test func powerRowsChangeForVisibleValueOrIdentityChange() {
        let original = [
            ProcessPower(id: "top", name: "Top", watts: 1.0, iconPath: "/Top.app"),
            ProcessPower(id: "second", name: "Second", watts: 0.501, iconPath: "/Second.app"),
        ]
        let changedValue = [
            ProcessPower(id: "top", name: "Top", watts: 1.0, iconPath: "/Top.app"),
            ProcessPower(id: "second", name: "Second", watts: 0.511, iconPath: "/Second.app"),
        ]
        let changedIdentity = [
            ProcessPower(id: "new", name: "New", watts: 1.0, iconPath: "/New.app"),
            ProcessPower(id: "second", name: "Second", watts: 0.501, iconPath: "/Second.app"),
        ]

        #expect(powerProcessRowPresentations(original) != powerProcessRowPresentations(changedValue))
        #expect(powerProcessRowPresentations(original) != powerProcessRowPresentations(changedIdentity))
    }

    @Test func memoryRowsKeepCurrentTextAndRelativeBars() {
        let gib: UInt64 = 1_073_741_824
        let rows = memoryProcessRowPresentations([
            ProcessUsage(id: "a", name: "A", footprintBytes: 2 * gib, iconPath: "/A.app"),
            ProcessUsage(id: "b", name: "B", footprintBytes: gib, iconPath: "/B.app"),
        ])

        #expect(rows.map(\.id) == ["a", "b"])
        #expect(rows.map(\.valueText) == [CardPresentation.gbText(2 * gib), CardPresentation.gbText(gib)])
        #expect(rows.map(\.fractionPermille) == [1_000, 500])
    }

    @MainActor
    @Test func iconCacheLoadsOneImagePerPath() {
        var loads = 0
        let image = NSImage(size: NSSize(width: 16, height: 16))
        let cache = ProcessAppIconCache(countLimit: 8) { _ in
            loads += 1
            return image
        }

        let first = cache.image(for: "/Applications/A.app")
        let second = cache.image(for: "/Applications/A.app")

        #expect(first === image)
        #expect(second === image)
        #expect(loads == 1)
    }

    @MainActor
    @Test func equatableRowsIncludeThemeAndBarColor() {
        let rows = [ProcessListRowPresentation(
            id: "a", name: "A", valueText: "0.50 W",
            fractionPermille: 500, iconPath: "/A.app")]
        let dark = ProcessListRowsView(rows: rows, tokens: .dark, barColor: .red)

        #expect(dark == ProcessListRowsView(rows: rows, tokens: .dark, barColor: .red))
        #expect(dark != ProcessListRowsView(rows: rows, tokens: .light, barColor: .red))
        #expect(dark != ProcessListRowsView(rows: rows, tokens: .dark, barColor: .blue))
    }
}
```

- [ ] **Step 2: Register the failing test source in the Xcode project**

Apply these exact `project.pbxproj` additions; the four IDs were checked against the current project and are unused:

```text
/* PBXBuildFile section */
A82500030000000000000003 /* ProcessListRowsViewTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = A82500040000000000000004 /* ProcessListRowsViewTests.swift */; };

/* PBXFileReference section */
A82500040000000000000004 /* ProcessListRowsViewTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ProcessListRowsViewTests.swift; sourceTree = "<group>"; };

/* WattlyTests group, after ProcessPowerTests.swift */
A82500040000000000000004 /* ProcessListRowsViewTests.swift */,

/* WattlyTests Sources phase, after ProcessPowerTests.swift in Sources */
A82500030000000000000003 /* ProcessListRowsViewTests.swift in Sources */,
```

- [ ] **Step 3: Run the full suite to verify the tests fail for missing production types**

Run:

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
```

Expected: build failure containing `cannot find 'powerProcessRowPresentations' in scope`, `cannot find 'ProcessAppIconCache' in scope`, and `cannot find 'ProcessListRowsView' in scope`. Do not use `-only-testing`; this repository's Swift Testing selectors can report zero executed tests.

- [ ] **Step 4: Create the focused process-list renderer and icon cache**

Create `Wattly/Views/ProcessListRowsView.swift` with this complete content:

```swift
import AppKit
import SwiftUI

struct ProcessListRowPresentation: Identifiable, Equatable {
    let id: String
    let name: String
    let valueText: String
    let fractionPermille: Int
    let iconPath: String?

    var fraction: Double {
        Double(fractionPermille) / 1_000
    }
}

private func processFractionPermille(_ value: Double) -> Int {
    Int((min(1, max(0, value)) * 1_000).rounded())
}

func memoryProcessRowPresentations(_ processes: [ProcessUsage]) -> [ProcessListRowPresentation] {
    let maxBytes = processes.first?.footprintBytes ?? 0
    return processes.map { process in
        ProcessListRowPresentation(
            id: process.id,
            name: process.name,
            valueText: CardPresentation.gbText(process.footprintBytes),
            fractionPermille: processFractionPermille(
                barFraction(footprint: process.footprintBytes, maxBytes: maxBytes)),
            iconPath: process.iconPath)
    }
}

func powerProcessRowPresentations(_ processes: [ProcessPower]) -> [ProcessListRowPresentation] {
    let maxWatts = processes.first?.watts ?? 0
    return processes.map { process in
        ProcessListRowPresentation(
            id: process.id,
            name: process.name,
            valueText: CardPresentation.wattText(process.watts),
            fractionPermille: processFractionPermille(
                wattFraction(watts: process.watts, maxWatts: maxWatts)),
            iconPath: process.iconPath)
    }
}

@MainActor
final class ProcessAppIconCache {
    static let shared = ProcessAppIconCache { path in
        NSWorkspace.shared.icon(forFile: path)
    }

    private let cache = NSCache<NSString, NSImage>()
    private let load: (String) -> NSImage

    init(countLimit: Int = 128, load: @escaping (String) -> NSImage) {
        cache.countLimit = countLimit
        self.load = load
    }

    func image(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = load(path)
        cache.setObject(image, forKey: key)
        return image
    }
}

@MainActor
struct ProcessListRowsView: View, Equatable {
    let rows: [ProcessListRowPresentation]
    let tokens: Tokens
    let barColor: Color

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rows == rhs.rows
            && lhs.tokens == rhs.tokens
            && lhs.barColor == rhs.barColor
    }

    var body: some View {
        ForEach(rows) { row in
            HStack(spacing: 9) {
                processIcon(row.iconPath)
                    .frame(width: 15, height: 15)
                Text(row.name)
                    .font(WattlyFont.at(11, weight: .semibold))
                    .foregroundStyle(tokens.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 74, alignment: .leading)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(tokens.sparkFill)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor)
                            .frame(width: geometry.size.width * row.fraction)
                    }
                }
                .frame(height: 6)
                Text(row.valueText)
                    .font(WattlyFont.at(10.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tokens.sub)
                    .frame(width: 46, alignment: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(row.name), \(row.valueText)")
        }
    }

    @ViewBuilder
    private func processIcon(_ path: String?) -> some View {
        if let path {
            Image(nsImage: ProcessAppIconCache.shared.image(for: path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 3).fill(tokens.sparkFill)
        }
    }
}
```

- [ ] **Step 5: Register the production source in the Xcode project**

Apply these exact `project.pbxproj` additions:

```text
/* PBXBuildFile section */
A82500010000000000000001 /* ProcessListRowsView.swift in Sources */ = {isa = PBXBuildFile; fileRef = A82500020000000000000002 /* ProcessListRowsView.swift */; };

/* PBXFileReference section */
A82500020000000000000002 /* ProcessListRowsView.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ProcessListRowsView.swift; sourceTree = "<group>"; };

/* Views group, after CardExpandRegion.swift */
A82500020000000000000002 /* ProcessListRowsView.swift */,

/* Wattly app Sources phase, after CardExpandRegion.swift in Sources */
A82500010000000000000001 /* ProcessListRowsView.swift in Sources */,
```

- [ ] **Step 6: Replace memory and power inline rows with the equatable shared renderer**

In `Wattly/Views/CardExpandRegion.swift`, remove `import AppKit`, replace `memExpand(_:)` and `powerExpand(_:)` with the following complete implementations, and delete the old `processRow`, `appIcon`, and their comments at lines 529–573:

```swift
@ViewBuilder
private func memExpand(_ sample: MemorySample) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        if sample.processes.isEmpty {
            Text(LocalizedStringKey("프로세스를 읽을 수 없음"))
                .font(WattlyFont.at(10.5, weight: .semibold))
                .foregroundStyle(t.faint)
        } else {
            ProcessListRowsView(
                rows: memoryProcessRowPresentations(sample.processes),
                tokens: t,
                barColor: sparkStroke)
            .equatable()
        }
    }
    .padding(.top, 4)
}

@ViewBuilder
private func powerExpand(_ sample: PowerSample) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        switch sample.processes {
        case .none:
            Text(LocalizedStringKey("측정 중…"))
                .font(WattlyFont.at(10.5, weight: .semibold))
                .foregroundStyle(t.faint)
        case .some(let processes) where processes.isEmpty:
            Text(LocalizedStringKey("프로세스를 읽을 수 없음"))
                .font(WattlyFont.at(10.5, weight: .semibold))
                .foregroundStyle(t.faint)
        case .some(let processes):
            ProcessListRowsView(
                rows: powerProcessRowPresentations(processes),
                tokens: t,
                barColor: sparkStroke)
            .equatable()
        }
    }
    .padding(.top, 4)
}
```

- [ ] **Step 7: Run the full suite and verify the new behavior tests pass**

Run:

```bash
set -o pipefail
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 \
  | tee /tmp/wattly-process-list-tests.log
rg 'powerRowsIgnoreChangesBelowVisiblePrecision|iconCacheLoadsOneImagePerPath|Test run with|TEST SUCCEEDED' \
  /tmp/wattly-process-list-tests.log
```

Expected: all five `ProcessListRowsViewTests` pass, the final summary reports all suites passing, and the build ends with `** TEST SUCCEEDED **`.

- [ ] **Step 8: Verify sampling/cadence files did not change**

Run:

```bash
git diff --exit-code -- \
  Wattly/Core/PollPolicy.swift \
  Wattly/Core/SystemMonitor.swift \
  Wattly/Providers/PowerProvider.swift
```

Expected: no output and exit 0, proving the one-second measurement and full-PID sampling paths are untouched.

- [ ] **Step 9: Commit the rendering optimization**

Run:

```bash
git add \
  Wattly/Views/ProcessListRowsView.swift \
  Wattly/Views/CardExpandRegion.swift \
  WattlyTests/ProcessListRowsViewTests.swift \
  Wattly.xcodeproj/project.pbxproj
git commit -m "perf(power): cache expanded process rows"
```

Expected: one implementation commit containing only the shared row renderer, integration, tests, and Xcode registration.

---

### Task 3: Validate Release energy improvement and record the result

**Files:**
- Modify: `docs/self-power-baseline.md`

**Interfaces:**
- Consumes: Task 1's pre-change collapsed/expanded means, Task 1's `measure-process-energy.swift`, and Task 2's optimized Release build
- Produces: a complete before/after comparison, computed expansion deltas, acceptance verdict, and final test/build evidence

- [ ] **Step 1: Re-run the entire automated suite from the implementation commit**

Run:

```bash
set -o pipefail
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 \
  | tee /tmp/wattly-processor-power-final-tests.log
rg 'processEnumerationRoutesByKind|autoPolicyBudgetsProvidersByVisibility|Test run with|TEST SUCCEEDED' \
  /tmp/wattly-processor-power-final-tests.log
```

Expected: the enumeration-routing test and one-second open-panel policy test pass, the full Swift Testing summary passes, and Xcode reports `** TEST SUCCEEDED **`.

- [ ] **Step 2: Build and launch the optimized Release app from a separate derived-data path**

Run:

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Release \
  -destination 'platform=macOS' -derivedDataPath /private/tmp/WattlyPowerAfter \
  CODE_SIGNING_ALLOWED=NO build
pkill -x Wattly 2>/dev/null || true
open /private/tmp/WattlyPowerAfter/Build/Products/Release/Wattly.app
```

Expected: `** BUILD SUCCEEDED **`; the running binary path is `/private/tmp/WattlyPowerAfter/Build/Products/Release/Wattly.app/Contents/MacOS/Wattly`.

- [ ] **Step 3: Restore the exact pre-change measurement conditions**

Use the same Mac, power source, Low Power Mode, Mode A, Eco/automatic polling, visible cards, menu-bar icon style/motion/speed, and process-list limit recorded in Task 1. Close Wattly Settings, leave the popover open, wait 60 seconds after launch, and confirm only the processor-power card changes between collapsed and expanded states.

Expected: `ps -p "$WATTLY_PID" -o command=` identifies the `/private/tmp/WattlyPowerAfter` binary and the recorded environmental fields match the pre-change row exactly.

- [ ] **Step 4: Capture the optimized collapsed and expanded samples**

Run the following once with the card collapsed and again after expanding it, allowing the documented 10-second settling period before each command:

```bash
WATTLY_PID=$(pgrep -x Wattly | head -n 1)
swift scripts/measure-process-energy.swift "$WATTLY_PID" 60 3
```

Expected: each state yields three nonnegative run values and one mean; all six samples come from the same PID and Release commit.

- [ ] **Step 5: Compute and enforce the acceptance gate**

Use the exact documented means:

```text
pre_delta  = pre_expanded_mean  - pre_collapsed_mean
post_delta = post_expanded_mean - post_collapsed_mean
```

Expected:

```text
if pre_delta >= 0.03 W: post_delta <= pre_delta * 0.80
if pre_delta <  0.03 W: post_delta <= 0.03 W
```

If the gate fails, do not claim the 0.2–0.3 W symptom is fixed and do not commit a passing verdict. Record the failing numbers and stop implementation for a fresh Time Profiler diagnosis; changing sampling cadence or hiding Wattly remains prohibited.

- [ ] **Step 6: Perform visual and behavioral acceptance**

With the optimized Release popover open, verify all of the following:

```text
- Collapsed processor-power card shows no per-app rows.
- First expansion shows "측정 중…" before the second sample.
- Rows appear on the next one-second sample.
- A changed Top-N identity/order/value appears without an extra delay.
- Each row keeps its app icon, two-decimal watt text, proportional bar, and VoiceOver label.
- Collapsing or closing the popover stops per-app enumeration.
- Light and dark themes recolor text, nil-path icon fallback, and bars correctly.
```

Expected: every line passes in both Mode A and an expanded Mode C processor-power hero. This is manual GUI evidence, not an automated-test claim.

- [ ] **Step 7: Append the optimized evidence and verdict**

In `docs/self-power-baseline.md`, append the `after` comparison directly below its matching `before` comparison. Include the exact date, commit, Mac model, macOS build, power source, motion settings, six run values, both means, computed post delta, percent reduction relative to pre delta, and `PASS` or `FAIL` from Step 5.

Expected: a reader can recompute every mean, delta, and percentage from the recorded values without rerunning Wattly.

- [ ] **Step 8: Run final repository checks**

Run:

```bash
git diff --check
git status --short
git diff --stat HEAD
```

Expected: `git diff --check` prints nothing; status shows only the updated evidence document; the stat contains no sampling/cadence source file.

- [ ] **Step 9: Commit the validated evidence**

Run only if Step 5 passed:

```bash
git add docs/self-power-baseline.md
git commit -m "docs(perf): record expanded power efficiency"
```

Expected: one evidence-only commit. If Step 5 failed, leave the evidence uncommitted and report the measured blocker instead of presenting the optimization as complete.

---

## Self-Review

- **Spec coverage:** Task 1 creates a repeatable physical baseline; Task 2 preserves the one-second all-PID path while caching icons and suppressing visually unchanged row work; Task 3 proves cadence, UI behavior, and Release energy improvement. No requirement depends on hiding Wattly or slowing detection.
- **Red-flag scan:** Every code-changing step contains complete code; runtime measurement fields must contain actual sampler output before a comparison is added.
- **Type consistency:** `ProcessListRowPresentation`, `memoryProcessRowPresentations`, `powerProcessRowPresentations`, `ProcessAppIconCache`, and `ProcessListRowsView` use the same names and signatures in tests, production code, and integration steps.
- **Scope:** No measurement provider, poll policy, settings schema, localization catalog, or ranking algorithm is changed.
