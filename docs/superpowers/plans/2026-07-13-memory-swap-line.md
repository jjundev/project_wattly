# Memory Swap Sub-line Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add swapped-memory size ("스왑 X.X GB") to the memory card's sub-line so it's visible in the stack-row (mode A) layout.

**Architecture:** The memory sub-line is produced purely by `CardPresentation.subText`, driven by `MemorySample`. We add a `swapUsedGB` field to `MemorySample`, plumb it through the pure `memorySample(...)` factory, read `vm.swapusage` (the kernel swap counter Activity Monitor uses) in `MemoryProvider`, and append a "· 스왑 X.X GB" segment to the existing "고정 … · 압축 …" sub-line. Because the sub-line is shared, the segment naturally also appears wherever `subText` renders (the mode-C hero card and the VoiceOver label) — consistent, same data.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Swift Testing (`import Testing`, `@Test`, `#expect`), Darwin `sysctlbyname("vm.swapusage")` → `xsw_usage`.

## Global Constraints

- Swift 6 language mode; deployment target macOS 14.0; arm64 only. (`project.yml`)
- Korean copy lives in `CardPresentation` (localization is a separate concern) — copy any user-facing string there, nowhere else.
- All memory "GB" values are **GiB** (÷ 1024³, `bytesPerGiB` in `MemoryUsage.swift`) for internal consistency with used/total/wired/compressed — NOT decimal GB.
- One-decimal formatting via `CardPresentation.f1` (so "5.0 GB", matching "고정 3.2 GB").
- No new files are created in this plan — every change edits an existing file, so **xcodegen does NOT need to be re-run**. (Only adding/removing files under `Wattly/`/`WattlyTests/` requires `xcodegen generate`.)
- Build: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
- Test: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test`
  - Filter one suite: append `-only-testing:WattlyTests/MemoryUsageTests` (replace suite name as needed).

---

### Task 1: `MemorySample.swapUsedGB` + `memorySample(...)` plumbing

**Files:**
- Modify: `Wattly/Models/MetricSample.swift:30-45` (add `swapUsedGB` field to `MemorySample`)
- Modify: `Wattly/Core/MemoryUsage.swift:47-58` (add `swapUsedBytes` param to `memorySample`)
- Test: `WattlyTests/MemoryUsageTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `MemorySample.swapUsedGB: Double` — swap used, GiB. Defaults to `0` (so every existing `MemorySample(...)` literal in tests/`FakeProvider` compiles unchanged).
  - `memorySample(active:wire:compressor:pageSize:memsize:processes:pressure:swapUsedBytes:) -> MemorySample` — new trailing `swapUsedBytes: UInt64 = 0` param, converted to GiB into `swapUsedGB`.

- [ ] **Step 1: Write the failing test**

Add these two tests to `WattlyTests/MemoryUsageTests.swift`, immediately after the `memorySampleWiredAndCompressed` test (currently ends at line 43):

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/MemoryUsageTests`
Expected: FAIL to compile — `extra argument 'swapUsedBytes' in call` and `value of type 'MemorySample' has no member 'swapUsedGB'`.

- [ ] **Step 3: Write minimal implementation**

In `Wattly/Models/MetricSample.swift`, add the field to `MemorySample` right after `compressedGB` (line 34). Change:

```swift
struct MemorySample: Sendable, Equatable {
    var usedGB: Double
    var totalGB: Double
    var wiredGB: Double
    var compressedGB: Double
```

to:

```swift
struct MemorySample: Sendable, Equatable {
    var usedGB: Double
    var totalGB: Double
    var wiredGB: Double
    var compressedGB: Double
    /// Swap used, GiB (macOS `vm.swapusage` `xsu_used` — the number Activity Monitor's
    /// "사용된 스왑 공간" shows). 0 when there's no swap OR the sysctl was unavailable.
    var swapUsedGB: Double = 0
```

In `Wattly/Core/MemoryUsage.swift`, change the `memorySample` signature + body (lines 47-58). Change:

```swift
func memorySample(active: UInt64, wire: UInt64, compressor: UInt64,
                  pageSize: UInt64, memsize: UInt64,
                  processes: [ProcessUsage],
                  pressure: MemoryPressure? = nil) -> MemorySample {
    MemorySample(
        usedGB: Double(usedBytes(active: active, wire: wire, compressor: compressor, pageSize: pageSize)) / bytesPerGiB,
        totalGB: Double(memsize) / bytesPerGiB,
        wiredGB: Double(wire * pageSize) / bytesPerGiB,
        compressedGB: Double(compressor * pageSize) / bytesPerGiB,
        processes: topProcesses(processes),
        pressure: pressure)
}
```

to:

```swift
func memorySample(active: UInt64, wire: UInt64, compressor: UInt64,
                  pageSize: UInt64, memsize: UInt64,
                  processes: [ProcessUsage],
                  pressure: MemoryPressure? = nil,
                  swapUsedBytes: UInt64 = 0) -> MemorySample {
    MemorySample(
        usedGB: Double(usedBytes(active: active, wire: wire, compressor: compressor, pageSize: pageSize)) / bytesPerGiB,
        totalGB: Double(memsize) / bytesPerGiB,
        wiredGB: Double(wire * pageSize) / bytesPerGiB,
        compressedGB: Double(compressor * pageSize) / bytesPerGiB,
        swapUsedGB: Double(swapUsedBytes) / bytesPerGiB,
        processes: topProcesses(processes),
        pressure: pressure)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/MemoryUsageTests`
Expected: PASS (all `MemoryUsageTests`, including the two new cases).

- [ ] **Step 5: Commit**

```bash
git add Wattly/Models/MetricSample.swift Wattly/Core/MemoryUsage.swift WattlyTests/MemoryUsageTests.swift
git commit -m "feat: add swapUsedGB to MemorySample + memorySample plumbing"
```

---

### Task 2: Memory sub-line shows "· 스왑 X.X GB"

**Files:**
- Modify: `Wattly/Core/CardPresentation.swift:175-176` (memory `subText` case)
- Test: `WattlyTests/CardPresentationTests.swift:67-74` (update) + new swap test
- Test: `WattlyTests/AccessibilityTests.swift:61-64` (update — the a11y label folds `subText`)

**Interfaces:**
- Consumes: `MemorySample.swapUsedGB` (Task 1).
- Produces: memory `subText` now ends with ` · 스왑 <f1(swapUsedGB)> GB`. This string is reused by `Accessibility.cardLabel` (folded into the VoiceOver label) and by the mode-C hero card (`PopoverHeroView` reads `d.subText`) — both pick up the swap segment automatically. No signature change.

- [ ] **Step 1: Write the failing test**

In `WattlyTests/CardPresentationTests.swift`, update the existing `subText` assertion (line 72) inside `memoryValueUnitSub`. Change:

```swift
        #expect(CardPresentation.subText(st) == "고정 3.2 GB · 압축 1.1 GB")
```

to:

```swift
        #expect(CardPresentation.subText(st) == "고정 3.2 GB · 압축 1.1 GB · 스왑 0.0 GB")
```

Then add a new test right after `memoryValueUnitSub` closes (after line 74):

```swift
    @Test func memorySubShowsSwapSize() {
        // The swap segment reflects swapUsedGB and uses the same one-decimal GB format.
        let st = MetricState.value(.memory(MemorySample(
            usedGB: 12.0, totalGB: 16, wiredGB: 3.21, compressedGB: 1.05, swapUsedGB: 5.0)))
        #expect(CardPresentation.subText(st) == "고정 3.2 GB · 압축 1.1 GB · 스왑 5.0 GB")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/CardPresentationTests`
Expected: FAIL — `memoryValueUnitSub` and `memorySubShowsSwapSize` mismatch (actual sub-line still ends at "압축 1.1 GB", missing the swap segment).

- [ ] **Step 3: Write minimal implementation**

In `Wattly/Core/CardPresentation.swift`, update the memory case of `subText` (line 176). Change:

```swift
        case .memory(let s):
            return "고정 \(f1(s.wiredGB)) GB · 압축 \(f1(s.compressedGB)) GB"
```

to:

```swift
        case .memory(let s):
            return "고정 \(f1(s.wiredGB)) GB · 압축 \(f1(s.compressedGB)) GB · 스왑 \(f1(s.swapUsedGB)) GB"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/CardPresentationTests`
Expected: PASS (all `CardPresentationTests`, including `memorySubShowsSwapSize`).

- [ ] **Step 5: Update the accessibility-label expectation (subText is folded into it)**

The VoiceOver label folds the whole sub-line (`Accessibility.cardLabel` → `CardPresentation.subText`), so it now inherits the swap segment. In `WattlyTests/AccessibilityTests.swift`, update `memoryUsesGBSymbolAndFoldsDetail` (line 62-63). Change:

```swift
        #expect(Accessibility.cardLabel(.mem, mem(9.18))
                == "메모리, 9.2 GB, 고정 1.0 GB · 압축 0.5 GB")
```

to:

```swift
        #expect(Accessibility.cardLabel(.mem, mem(9.18))
                == "메모리, 9.2 GB, 고정 1.0 GB · 압축 0.5 GB · 스왑 0.0 GB")
```

(The `mem(...)` helper builds a `MemorySample` with no swap, so `swapUsedGB` defaults to 0 → "스왑 0.0 GB".)

- [ ] **Step 6: Run both affected suites to verify green**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/CardPresentationTests -only-testing:WattlyTests/AccessibilityTests`
Expected: PASS (both suites).

- [ ] **Step 7: Commit**

```bash
git add Wattly/Core/CardPresentation.swift WattlyTests/CardPresentationTests.swift WattlyTests/AccessibilityTests.swift
git commit -m "feat: show swap size in memory card sub-line"
```

---

### Task 3: `MemoryProvider` reads `vm.swapusage`

**Files:**
- Modify: `Wattly/Providers/MemoryProvider.swift:21-37` (`read`) + add a `swapUsedBytes()` helper near the other sysctl helpers (after line 74)

**Interfaces:**
- Consumes: `memorySample(..., swapUsedBytes:)` (Task 1).
- Produces: at runtime, every memory poll now carries real `swapUsedGB`. No API change.

This task is I/O against the live kernel, so it has no unit test (matching the repo convention — providers are exercised by running the app; the pure derivations are what's unit-tested). It is verified by building and eyeballing the running app. The `xsw_usage` struct and `xsu_used` field are confirmed available from Darwin (a standalone `swiftc` check returns `rc=0` with a populated `xsu_used`).

- [ ] **Step 1: Add the swap-read helper**

In `Wattly/Providers/MemoryProvider.swift`, add this static helper immediately after `sysctlInt32(_:)` (which ends at line 74), before the `// MARK: Top processes` comment:

```swift
    /// Swap used in bytes from `vm.swapusage` (`xsw_usage.xsu_used`) — the counter macOS
    /// Activity Monitor labels "사용된 스왑 공간". A struct-valued sysctl (not a scalar), so it
    /// gets its own helper. 0 on failure → the card shows "스왑 0.0 GB" rather than a wrong number.
    private static func swapUsedBytes() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }
```

- [ ] **Step 2: Wire the swap read into `read(at:)`**

In `Wattly/Providers/MemoryProvider.swift`, update the `memorySample(...)` call in `read(at:)` (lines 29-36). Change:

```swift
        return .value(.memory(memorySample(
            active: UInt64(vm.active_count),
            wire: UInt64(vm.wire_count),
            compressor: UInt64(vm.compressor_page_count),
            pageSize: pageSize == 0 ? 16384 : pageSize,
            memsize: memsize,
            processes: procs,
            pressure: pressure)))
```

to:

```swift
        return .value(.memory(memorySample(
            active: UInt64(vm.active_count),
            wire: UInt64(vm.wire_count),
            compressor: UInt64(vm.compressor_page_count),
            pageSize: pageSize == 0 ? 16384 : pageSize,
            memsize: memsize,
            processes: procs,
            pressure: pressure,
            swapUsedBytes: Self.swapUsedBytes())))
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run the real app and verify the sub-line**

Launch the built app (real `MemoryProvider` drives `.memory` regardless of scenario), open the menubar popover, and read the 메모리 card's sub-line.

```bash
open "$(xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/Wattly.app"
```

Expected: the 메모리 card sub-line reads `고정 X.X GB · 압축 X.X GB · 스왑 X.X GB`, and the swap number matches the terminal's `sysctl vm.swapusage` "used" value converted to GiB (e.g. on a machine reporting `used = 3742826496` bytes → ≈ `스왑 3.5 GB`). Cross-check with `sysctl vm.swapusage`. Also confirm the now-3-segment sub-line stays on **one line** at the card's width (the mode-A `Text` has no `.lineLimit`; the power card already renders a 3-segment sub-line here without wrapping, so this is expected to be fine — just verify). Quit the app afterward.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Providers/MemoryProvider.swift
git commit -m "feat: read vm.swapusage in MemoryProvider for the swap sub-line"
```

---

### Task 4: `FakeProvider` synthetic swap (dev-harness demo)

**Files:**
- Modify: `Wattly/Providers/FakeProvider.swift:112-114` (the `.memory` synthetic sample)

**Interfaces:**
- Consumes: `MemorySample.swapUsedGB` (Task 1).
- Produces: the fake/dev scenarios now demo a non-zero swap segment (instead of always "스왑 0.0 GB"), so the UI can be eyeballed without real swap pressure. Runtime is unaffected — the app routes `.memory` to the real provider.

- [ ] **Step 1: Add a synthetic swap to the fake memory sample**

In `Wattly/Providers/FakeProvider.swift`, the `.memory` case computes `frac` (line 111) just above the return. Update the `return` (lines 113-114). Change:

```swift
            return .memory(MemorySample(usedGB: used, totalGB: total, wiredGB: 2.4, compressedGB: 1.1,
                                        processes: procs, pressure: pressure))
```

to:

```swift
            // Synthetic swap so the dev harness demos the "스왑" sub-line segment: none when
            // roomy, a little under pressure, more when critical (the real sysctl drives it at runtime).
            let swap = frac > 0.85 ? 5.0 : (frac > 0.70 ? 1.5 : 0.0)
            return .memory(MemorySample(usedGB: used, totalGB: total, wiredGB: 2.4, compressedGB: 1.1,
                                        swapUsedGB: swap, processes: procs, pressure: pressure))
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Wattly/Providers/FakeProvider.swift
git commit -m "feat: synthetic swap in FakeProvider for dev-harness demo"
```

---

### Final verification

- [ ] **Run the full test suite**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test`
Expected: all suites PASS (no regressions in `MemoryUsageTests`, `CardPresentationTests`, `AccessibilityTests`, `PanelPresentationTests`, `MenuBarTextTests`, `ThresholdTests`, or the rest).
