# Memory Card — Real RAM Pressure Percentage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the actual macOS RAM pressure as a live percentage on the 메모리 (memory) card — the same 0–100% number Activity Monitor's "메모리 압력" graph reports.

**Architecture:** The kernel's exact free-memory percentage is only available through the undocumented XNU syscall `memorystatus_get_level` (#453) — the same one `/usr/bin/memory_pressure` and the open-source *Stats* app use. `MemoryProvider` (the actor doing all memory I/O) reads that syscall each poll, converts it to a pressure percent via a pure, table-tested helper (`memoryPressurePercent`, `100 − free`, clamped), and carries it on `MemorySample.pressurePercent`. `CardPresentation.subText` prepends a `압력 NN%` segment to the memory card's always-visible sub-line, reusing the exact pattern by which `스왑` (swap) was added (`docs/superpowers/plans/2026-07-13-memory-swap-line.md`). The kernel *level* enum that already colors the card (`MemorySample.pressure`, plan 17) is untouched — this adds the numeric readout beside it.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`import Testing`), XcodeGen project. macOS 14.0 deploy target. No new entitlements, no App Store constraint (personal / open-source menubar app).

## Global Constraints

- **Swift 6 language mode**, deploy target macOS **14.0** — everything must compile clean under `-swift-version 6`.
- **Private-API choice is deliberate and approved:** `memorystatus_get_level` is an undocumented syscall. It is fine for this personal/open-source app but would risk Mac App Store rejection — do NOT swap it for the `host_statistics64` occupancy approximation, which does **not** match Activity Monitor (the naive `free+inactive+speculative` ratio diverges from the kernel's real number). This was chosen over the alternatives at the plan's decision checkpoint.
- **Graceful degradation:** every kernel read may fail. A failed syscall → `nil` pressure percent → the sub-line silently omits the `압력` segment (never a crash, never a fake `0%`). This mirrors the existing `pressure`/`swapUsedBytes` nil handling in `MemoryProvider`.
- **No new files.** Every change edits an existing file, so **XcodeGen does NOT need regenerating**. (Only re-run xcodegen if you add/remove a file — you won't here.)
- **Korean copy** lives in `CardPresentation` (pure), consistent with `고정`/`압축`/`스왑`. The pressure segment label is exactly `압력` and the format is `압력 <int>%` (no decimal, no space before `%`).
- **Verified facts (do not re-derive):** on this Mac, `memorystatus_get_level(&free)` returns `rc == 0` with `free` = the free-memory percent; `100 − free` matches `/usr/bin/memory_pressure`'s "System-wide memory free percentage" inversion and Activity Monitor. The `@_silgen_name` binding with a distinct Swift name compiles and links under Swift 6 (verified 2026-07-16).

**Build / test commands** (from project memory; run from the worktree root):

```bash
# Build (ad-hoc, no signing needed):
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

# Test (ad-hoc signs the test host):
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
```

To run a single Swift Testing case, filter by name:

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  test -only-testing:WattlyTests/MemoryUsageTests/pressurePercentInvertsAndClamps
```

---

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `Wattly/Core/MemoryUsage.swift` | Pure memory derivations | **Add** `memoryPressurePercent(freeLevel:)` pure helper; **add** `pressurePercent` param to `memorySample(...)` |
| `Wattly/Models/MetricSample.swift` | The Sendable sample types | **Add** `MemorySample.pressurePercent: Int?` field |
| `Wattly/Providers/MemoryProvider.swift` | Real memory I/O (actor) | **Add** `@_silgen_name` syscall binding + `pressurePercent()` reader; wire it into `read(...)` |
| `Wattly/Core/CardPresentation.swift` | Pure display copy/formatting | **Modify** the `.memory` case of `subText(_:)` to prepend `압력 NN%` |
| `Wattly/Providers/FakeProvider.swift` | Dev/preview synthetic samples | **Add** a synthetic `pressurePercent` so the fake harness demos the readout |
| `WattlyTests/MemoryUsageTests.swift` | Pure-fn tests | **Add** cases for `memoryPressurePercent` + `memorySample` carrying the percent |
| `WattlyTests/CardPresentationTests.swift` | Presentation tests | **Add** case for the `압력` sub-line segment |
| `WattlyTests/AccessibilityTests.swift` | VoiceOver-label tests | **Add** case: the folded card label includes the pressure segment |

---

## Task 1: Model + pure pressure-percent helper

Adds the data channel end-to-end at the pure/model layer: a table-tested `100 − free` (clamped) function and the `MemorySample` field that carries it. No I/O yet.

**Files:**
- Modify: `Wattly/Core/MemoryUsage.swift` (add pure fn after `MemoryPressure`, ~line 36; extend `memorySample`, lines 47–60)
- Modify: `Wattly/Models/MetricSample.swift` (add field to `MemorySample`, after line 51)
- Test: `WattlyTests/MemoryUsageTests.swift`

**Interfaces:**
- Produces: `func memoryPressurePercent(freeLevel: UInt32) -> Int` — returns `100 − freeLevel`, clamped to `0...100`.
- Produces: `MemorySample.pressurePercent: Int?` — the kernel RAM-pressure percent (0–100), or `nil` when the syscall was unavailable this poll. Default `nil` (so every existing `MemorySample(...)` construction stays valid).
- Produces: `memorySample(..., pressurePercent: Int? = nil, ...)` — new trailing-defaulted parameter threaded onto the field.
- Consumes: nothing (leaf of the dependency chain).

- [ ] **Step 1: Write the failing tests**

Add to `WattlyTests/MemoryUsageTests.swift`, inside `struct MemoryUsageTests`, right after the `MemoryPressure` section (after `memorySampleCarriesPressureWhenGiven`, ~line 86):

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  test -only-testing:WattlyTests/MemoryUsageTests 2>&1 | tail -20
```
Expected: FAIL — compile error, `cannot find 'memoryPressurePercent' in scope` and `extra argument 'pressurePercent'`.

- [ ] **Step 3: Add the `pressurePercent` field to `MemorySample`**

In `Wattly/Models/MetricSample.swift`, inside `struct MemorySample`, add after the `pressure` field (after line 51, `var pressure: MemoryPressure? = nil`):

```swift
    /// The kernel's RAM-pressure percentage (0–100), from `memorystatus_get_level` — the
    /// same number Activity Monitor's "메모리 압력" graph shows (`100 − free%`). Distinct from
    /// `pressure` (the coarse NORMAL/WARN/CRITICAL band that colors the card): this is the
    /// precise readout the sub-line prints. `nil` = the syscall was unavailable this poll →
    /// the sub-line drops the 압력 segment (never a fake 0%).
    var pressurePercent: Int? = nil
```

- [ ] **Step 4: Add the pure helper + the `memorySample` parameter**

In `Wattly/Core/MemoryUsage.swift`, add the pure helper immediately after the `MemoryPressure` enum's closing brace (after line 36):

```swift
/// Kernel free-memory percent → RAM-pressure percent. `memorystatus_get_level` (XNU
/// syscall #453) reports the FREE percentage, so pressure is its inverse. Clamped to
/// 0…100 so a corrupt kernel read can never produce a negative or >100 value. Pure and
/// table-tested (issue 18) — the provider does the syscall I/O and hands the raw free%
/// here, mirroring `MemoryPressure(fromSysctl:)`.
func memoryPressurePercent(freeLevel: UInt32) -> Int {
    max(0, min(100, 100 - Int(freeLevel)))
}
```

Then extend `memorySample(...)` (lines 47–60). Add the `pressurePercent` parameter (trailing-defaulted, placed next to `pressure`) and thread it onto the returned sample:

```swift
func memorySample(active: UInt64, wire: UInt64, compressor: UInt64,
                  pageSize: UInt64, memsize: UInt64,
                  processes: [ProcessUsage],
                  pressure: MemoryPressure? = nil,
                  pressurePercent: Int? = nil,
                  swapUsedBytes: UInt64 = 0) -> MemorySample {
    MemorySample(
        usedGB: Double(usedBytes(active: active, wire: wire, compressor: compressor, pageSize: pageSize)) / bytesPerGiB,
        totalGB: Double(memsize) / bytesPerGiB,
        wiredGB: Double(wire * pageSize) / bytesPerGiB,
        compressedGB: Double(compressor * pageSize) / bytesPerGiB,
        swapUsedGB: Double(swapUsedBytes) / bytesPerGiB,
        processes: topProcesses(processes),
        pressure: pressure,
        pressurePercent: pressurePercent)
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  test -only-testing:WattlyTests/MemoryUsageTests 2>&1 | tail -20
```
Expected: PASS — all `MemoryUsageTests` green (the two new cases plus the pre-existing ones).

- [ ] **Step 6: Commit**

```bash
git add Wattly/Core/MemoryUsage.swift Wattly/Models/MetricSample.swift WattlyTests/MemoryUsageTests.swift
git commit -m "feat(memory): add pure RAM-pressure-percent helper + MemorySample.pressurePercent"
```

---

## Task 2: Provider reads the `memorystatus_get_level` syscall

Wires the real kernel read into `MemoryProvider.read`. The syscall itself is I/O (like the existing `sysctlInt32`/`swapUsedBytes` reads) so it is not unit-tested; the pure conversion it feeds is already covered by Task 1, and correctness is confirmed on-device against Activity Monitor.

**Files:**
- Modify: `Wattly/Providers/MemoryProvider.swift` (add the `@_silgen_name` binding at file scope; add a static `pressurePercent()` reader; call it in `read(...)`)

**Interfaces:**
- Consumes: `memoryPressurePercent(freeLevel:)` and the `memorySample(..., pressurePercent:)` parameter from Task 1.
- Produces: `MemoryProvider.read(...)` now populates `MemorySample.pressurePercent` on every poll (nil only when the syscall fails).

- [ ] **Step 1: Add the syscall binding at file scope**

In `Wattly/Providers/MemoryProvider.swift`, add this **at file scope, immediately after the file's doc-comment block (after line 8) and directly before the `actor MemoryProvider` declaration (line 9)** — keep it below the existing header comment for readability, not jammed under `import Foundation`:

```swift
/// Private XNU syscall #453 — the exact call `/usr/bin/memory_pressure` and the
/// open-source *Stats* app use to read the free-memory percentage that backs Activity
/// Monitor's "메모리 압력" graph. There is no public API for this number (Apple DTS
/// explicitly discourages any free-memory statistic), and the `host_statistics64`
/// occupancy ratio does NOT match the kernel's figure — so we bind the syscall directly.
/// Distinct Swift name via `@_silgen_name` so it never shadows a future SDK import.
@_silgen_name("memorystatus_get_level")
private func wattly_memorystatus_get_level(_ level: UnsafeMutablePointer<UInt32>) -> Int32
```

- [ ] **Step 2: Add the static reader method**

In `Wattly/Providers/MemoryProvider.swift`, add this static method inside `actor MemoryProvider`, next to the other sysctl helpers — e.g. immediately after `swapUsedBytes()` (after line 85):

```swift
    /// Kernel RAM-pressure percent (0–100) via `memorystatus_get_level` (#453). The syscall
    /// fills a free-memory percentage; `memoryPressurePercent` inverts it. nil on failure →
    /// the card omits the 압력 segment rather than showing a wrong number. A cheap scalar
    /// read every poll (no gating), like `kern.memorystatus_vm_pressure_level`.
    private static func pressurePercent() -> Int? {
        var free: UInt32 = 0
        guard wattly_memorystatus_get_level(&free) == 0 else { return nil }
        return memoryPressurePercent(freeLevel: free)
    }
```

- [ ] **Step 3: Wire it into `read(...)`**

In `Wattly/Providers/MemoryProvider.swift`, in `read(at:)`, add the read next to the existing `pressure` line (after line 28) and pass it to `memorySample`. The `pressure` block becomes:

```swift
        // Kernel memory-pressure verdict — cheap scalar read every poll (no gating). nil on
        // failure → the card falls back to the used% band (CardPresentation).
        let pressure = Self.sysctlInt32("kern.memorystatus_vm_pressure_level").map(MemoryPressure.init(fromSysctl:))
        // Exact RAM-pressure percentage (Activity Monitor "메모리 압력") — the sub-line readout.
        let pressurePercent = Self.pressurePercent()
        return .value(.memory(memorySample(
            active: UInt64(vm.active_count),
            wire: UInt64(vm.wire_count),
            compressor: UInt64(vm.compressor_page_count),
            pageSize: pageSize == 0 ? 16384 : pageSize,
            memsize: memsize,
            processes: procs,
            pressure: pressure,
            pressurePercent: pressurePercent,
            swapUsedBytes: Self.swapUsedBytes())))
```

- [ ] **Step 4: Build to verify it compiles and links**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -15
```
Expected: `** BUILD SUCCEEDED **`. (The `@_silgen_name` symbol resolves at link time — a link error here would mean the symbol name is wrong; it is verified correct on this SDK.)

- [ ] **Step 5: Run the full test suite to confirm nothing regressed**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | tail -20
```
Expected: PASS — all tests still green (this task adds no tests; it must not break any).

- [ ] **Step 6: On-device sanity check (manual, one-time)**

Compare the syscall's value against the OS tool, then eyeball the running app in Step 6 of Task 3. From the worktree root:

```bash
# The kernel's own numbers — the app's 압력 % should track (100 − this free%):
/usr/bin/memory_pressure | tail -1     # e.g. "System-wide memory free percentage: 54%"  → 압력 ≈ 46%
```
Expected: the last line prints a free percentage; `100 −` that value is what the memory card should show once Task 3 renders it. (Full visual confirmation happens after Task 3.)

- [ ] **Step 7: Commit**

```bash
git add Wattly/Providers/MemoryProvider.swift
git commit -m "feat(memory): read real RAM pressure via memorystatus_get_level syscall"
```

---

## Task 3: Show `압력 NN%` on the memory card sub-line + VoiceOver

Surfaces the number in the always-visible memory sub-line, prepended before `고정 · 압축 · 스왑` — the same slot `스왑` was added to. Because `Accessibility.cardLabel` folds `CardPresentation.subText` into the spoken label, VoiceOver picks the readout up for free; we add a test to lock that in.

**Files:**
- Modify: `Wattly/Core/CardPresentation.swift` (the `.memory` case of `subText`, lines 197–198)
- Test: `WattlyTests/CardPresentationTests.swift`
- Test: `WattlyTests/AccessibilityTests.swift`

**Interfaces:**
- Consumes: `MemorySample.pressurePercent` from Task 1.
- Produces: `CardPresentation.subText(.value(.memory(s)))` returns `"압력 <p>% · 고정 … · 압축 … · 스왑 …"` when `s.pressurePercent != nil`, else the unchanged `"고정 … · 압축 … · 스왑 …"`.

- [ ] **Step 1: Write the failing tests**

In `WattlyTests/CardPresentationTests.swift`, add after `memorySubShowsSwapSize` (~line 140):

```swift
    @Test func memorySubShowsPressurePercent() {
        // When the syscall supplied a pressure %, it leads the sub-line as its own segment.
        let st = MetricState.value(.memory(MemorySample(
            usedGB: 8.37, totalGB: 16, wiredGB: 3.21, compressedGB: 1.05,
            swapUsedGB: 0.0, pressurePercent: 46)))
        #expect(CardPresentation.subText(st) == "압력 46% · 고정 3.2 GB · 압축 1.1 GB · 스왑 0.0 GB")
    }

    @Test func memorySubOmitsPressureWhenUnavailable() {
        // No pressure % (syscall failed / not set) → the sub-line is exactly as before.
        let st = MetricState.value(.memory(MemorySample(
            usedGB: 8.37, totalGB: 16, wiredGB: 3.21, compressedGB: 1.05)))
        #expect(CardPresentation.subText(st) == "고정 3.2 GB · 압축 1.1 GB · 스왑 0.0 GB")
    }
```

In `WattlyTests/AccessibilityTests.swift`, add after `memoryUsesGBSymbolAndFoldsDetail` (~line 64):

```swift
    @Test func memoryFoldsPressurePercentIntoLabel() {
        let st = MetricState.value(.memory(MemorySample(
            usedGB: 9.18, totalGB: 16, wiredGB: 1, compressedGB: 0.5, pressurePercent: 46)))
        #expect(Accessibility.cardLabel(.mem, st)
                == "메모리, 9.2 GB, 압력 46% · 고정 1.0 GB · 압축 0.5 GB · 스왑 0.0 GB")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  test -only-testing:WattlyTests/CardPresentationTests/memorySubShowsPressurePercent \
  -only-testing:WattlyTests/AccessibilityTests/memoryFoldsPressurePercentIntoLabel 2>&1 | tail -20
```
Expected: FAIL — the sub-line still starts with `고정`, missing the `압력 46% · ` prefix.

- [ ] **Step 3: Prepend the pressure segment in `subText`**

In `Wattly/Core/CardPresentation.swift`, replace the `.memory` case of `subText(_:)` (lines 197–198):

```swift
        case .memory(let s):
            return "고정 \(f1(s.wiredGB)) GB · 압축 \(f1(s.compressedGB)) GB · 스왑 \(f1(s.swapUsedGB)) GB"
```

with:

```swift
        case .memory(let s):
            let detail = "고정 \(f1(s.wiredGB)) GB · 압축 \(f1(s.compressedGB)) GB · 스왑 \(f1(s.swapUsedGB)) GB"
            // Lead with the exact RAM-pressure % (Activity Monitor "메모리 압력") when the kernel
            // syscall supplied it; drop the segment entirely when it's unavailable (never "0%").
            guard let p = s.pressurePercent else { return detail }
            return "압력 \(p)% · \(detail)"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  test -only-testing:WattlyTests/CardPresentationTests \
  -only-testing:WattlyTests/AccessibilityTests 2>&1 | tail -20
```
Expected: PASS — the two new cases plus every pre-existing `CardPresentationTests`/`AccessibilityTests` case (the memory sub-line cases that don't set `pressurePercent` still read the old string).

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/CardPresentation.swift WattlyTests/CardPresentationTests.swift WattlyTests/AccessibilityTests.swift
git commit -m "feat(memory): show 압력 NN% on the memory card sub-line (+ VoiceOver)"
```

- [ ] **Step 6: On-device visual verification (manual, one-time)**

Build and launch the app, open the popover, and read the 메모리 card's sub-line:

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -3
# Launch the built .app (path printed by the build, under DerivedData/…/Build/Products/Debug/Wattly.app),
# click the menubar icon, and confirm the 메모리 card sub-line reads e.g. "압력 46% · 고정 … · 압축 … · 스왑 …".
# Cross-check the number against Activity Monitor's 메모리 압력 graph (they should agree within ~1–2%,
# since both poll independently) and against `/usr/bin/memory_pressure | tail -1` (100 − free%).
```
Expected: the sub-line shows a live `압력 NN%` that tracks Activity Monitor. Note: the card *color* (plan 17, driven by the coarse `pressure` band) is unchanged — only the new numeric readout appears.

---

## Task 4: FakeProvider demos the pressure percent

Keeps the dev/preview harness representative: the fake memory sample now carries a synthetic `pressurePercent` derived from its occupancy fraction, so SwiftUI previews and any fake-driven path show the readout. (The real provider drives it at runtime; the fake never runs on-device for memory — plan 05 routes `.memory` to the real provider.)

**Files:**
- Modify: `Wattly/Providers/FakeProvider.swift` (the `.memory` case, lines 99–119)

**Interfaces:**
- Consumes: `MemorySample.pressurePercent` from Task 1.
- Produces: fake `.memory` samples now populate `pressurePercent`.

- [ ] **Step 1: Add a synthetic pressure percent to the fake memory sample**

In `Wattly/Providers/FakeProvider.swift`, in the `.memory` case, locate the existing synthetic-pressure lines (around lines 111–114):

```swift
            // Synthesise pressure from the occupancy ratio so the fake/dev harness still
            // demos the pressure-colored card (the real sysctl drives it at runtime).
            let frac = total > 0 ? used / total : 0
            let pressure: MemoryPressure = frac > 0.85 ? .critical : (frac > 0.70 ? .warn : .normal)
```

Immediately after that `let pressure` line, add:

```swift
            // Synthetic exact-percent readout for the sub-line (the real syscall drives it at
            // runtime). Roughly tracks occupancy so the demo number looks plausible beside the band.
            let pressurePercent = Int((frac * 100).rounded())
```

Then update the returned sample (lines 118–119) to pass it:

```swift
            return .memory(MemorySample(usedGB: used, totalGB: total, wiredGB: 2.4, compressedGB: 1.1,
                                        swapUsedGB: swap, processes: procs,
                                        pressure: pressure, pressurePercent: pressurePercent))
```

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the full suite to confirm green**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | tail -20
```
Expected: PASS — every test green.

- [ ] **Step 4: Commit**

```bash
git add Wattly/Providers/FakeProvider.swift
git commit -m "chore(fake): populate synthetic RAM-pressure percent for previews"
```

---

## Self-Review

**1. Spec coverage** — the request is "메모리 카드에서 실제 램 압력을 %로 확인할 수 있도록": (a) *실제* (real, not occupancy approximation) → Task 2 reads the kernel syscall that Activity Monitor uses; (b) *%로* (as a percentage) → `memoryPressurePercent` produces 0–100; (c) *메모리 카드에서 확인* (visible on the memory card) → Task 3 renders it on the always-visible sub-line + VoiceOver. Covered.

**2. Placeholder scan** — every step has concrete code, exact file/line anchors, exact commands, and expected output. No TBD/TODO/"handle edge cases". The one non-automated verification (on-device number match) is explicit and unavoidable — the syscall can't be exercised in a headless unit test, and this matches how plans 05/07/08 verified provider I/O.

**3. Type consistency** — `memoryPressurePercent(freeLevel: UInt32) -> Int` is defined in Task 1 and consumed by the same name in Task 2. `MemorySample.pressurePercent: Int?` is defined in Task 1 and read by the same name in Tasks 2/3/4. `memorySample(..., pressurePercent: Int? = nil, ...)` — the parameter name matches at every call site (Task 1 definition, Task 2 provider call). The `@_silgen_name` Swift identifier `wattly_memorystatus_get_level` is declared and called only in Task 2. No drift.

**Backward-compatibility note:** `pressurePercent` and the `memorySample` parameter both default to `nil`, so all three pre-existing memory sub-line assertions (`CardPresentationTests:131,139`, `AccessibilityTests:63`) and the structural `MemorySample(...)` constructions in tests remain valid and green — they exercise the "pressure unavailable" branch.
