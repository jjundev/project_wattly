# Fan Speed Card Threshold Warning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Color the 팬 속도 card orange (주의) / red (위험) when fan speed climbs toward the hardware ceiling, using a user-adjustable 주의/위험 threshold pair expressed as a percentage of each fan's own maximum RPM.

**Architecture:** Fan load is normalized to a machine-independent percentage by a new pure `FanSample.loadPercent` (mean of every fan's clamped `actualRPM / maxRPM`, ×100), so one default threshold pair works on every Mac regardless of its 4 000–7 000 RPM ceiling. `Thresholds` gains a **non-optional** `fan: ThresholdPair` (default 70/90 — the fan warning ships ON, like CPU and temperature, unlike the opt-in GPU pair), and `CardPresentation.thresholdLevel` grows a `.fan` case. Every sparkline surface — `MetricCardView`, `PopoverGridView`, `PopoverHeroView` — and the VoiceOver `Accessibility.stateWord` already read that one function, so no view code changes. Settings reuses the existing `thresholdBlock` helper for the new sliders, shown only on Macs that actually have a fan.

**Tech Stack:** Swift 6.0 (strict concurrency), SwiftUI, Swift Testing (`import Testing`, `@Test`, `#expect`), Xcode String Catalog (`Localizable.xcstrings`), XcodeGen.

## Global Constraints

- **Platform:** macOS 14.0+ (Apple Silicon arm64 only).
- **Language Mode:** Swift 6 with strict concurrency (`Sendable` value types across actor boundaries).
- **Testing Framework:** Swift Testing (`import Testing`, `@Test`, `#expect(...)`, `struct SuiteName`), matching the rest of `WattlyTests`. No XCTest.
- **Comparison basis (decided):** percentage of maximum RPM, **not** absolute RPM.
- **Default state (decided):** fan warnings are ON by default — `fan: ThresholdPair` is non-optional, no enable/disable toggle.
- **Ship defaults:** 주의 = 70 %, 위험 = 90 % of max RPM.
- **Source-language copy:** Korean is the source language of `Localizable.xcstrings` (`"sourceLanguage": "ko"`). Every new user-facing string must be added to the catalog with all 30 localizations.
- **`%` placement rule:** in every localized value the `%` character must be immediately followed by `)` (never by a letter), matching the existing safe keys `"CPU 사용률 (%)"` / `"GPU 사용률 (%)"`, so the String Catalog never reads it as a format specifier.
- **No new files:** every change lands in an existing file, so `xcodegen generate` is **not** required for this plan.
- **Zero Placeholders:** full, working code and tests in every task.
- **TDD:** pure derivations covered by unit tests before the implementation.

**Build / test commands** (from the repo root):

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
```

---

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `Wattly/Core/Fan.swift` | Pure fan-domain math (no IOKit). Gains `FanSample.loadPercent` — the % -of-ceiling figure the threshold compares. | Modify |
| `Wattly/Settings/Settings.swift` | `Thresholds` value type (JSON `RawRepresentable` for `@AppStorage`) + `Defaults`. Gains the non-optional `fan` pair, its decode fallback, encode, equality, and ship default. | Modify |
| `Wattly/Core/CardPresentation.swift` | Pure card presentation. `thresholdLevel` gains the `.fan` case — the single seam every view and VoiceOver reads. | Modify |
| `Wattly/Views/Settings/SettingsThresholdSection.swift` | 상태 경고 기준 settings UI. Gains a fan block reusing the existing `thresholdBlock` helper, plus a `showsFan` gate. | Modify |
| `Wattly/Views/SettingsView.swift` | Owns the `SystemMonitor`; passes `monitor.isPresent(.fan)` into the threshold section. | Modify |
| `Wattly/Resources/Localizable.xcstrings` | String Catalog. Gains one key with 30 localizations. | Modify |
| `WattlyTests/FanTests.swift` | Pure fan-helper tests. Covers `loadPercent`. | Modify |
| `WattlyTests/ThresholdTests.swift` | Threshold model + routing tests. Covers fan routing, defaults, serialization, legacy decode. | Modify |
| `WattlyTests/CardPresentationTests.swift` | Card presentation tests. The stale `fanHasNoThresholdColor` test is replaced. | Modify |
| `WattlyTests/AccessibilityTests.swift` | VoiceOver copy tests. Covers the fan card's 주의/위험 state word. | Modify |
| `WattlyTests/LocalizationTests.swift` | String Catalog translation tests. Covers the new settings key. | Modify |

Not modified, and deliberately so: `MetricCardView.swift`, `CardExpandRegion.swift`, `PopoverGridView.swift`, `PopoverHeroView.swift`, `Accessibility.swift`, `SettingsReset.swift`, `SystemMonitor.swift`. All of them already route through `CardPresentation.thresholdLevel` / `Defaults.thresholds`, so the fan color and its VoiceOver word appear on all four popover surfaces and reset correctly with no edit.

---

### Task 1: Pure fan load percentage (`FanSample.loadPercent`)

The threshold input. Each fan is scored against **its own** ceiling (multi-fan Macs can have different per-fan maxima), the ratios are averaged to match the card headline's average-RPM semantics, and fans with an unreadable ceiling (`maxRPM <= 0`) are skipped entirely rather than counted as 0 %.

**Files:**
- Modify: `Wattly/Core/Fan.swift:22-29`
- Test: `WattlyTests/FanTests.swift`

**Interfaces:**
- Consumes: `FanReading` (`index`, `actualRPM`, `minRPM`, `maxRPM`, `targetRPM`), `CardPresentation.fanBarFraction(actual:max:) -> Double` (existing, clamps to `0...1`, returns `0` when `max <= 0`).
- Produces: `FanSample.loadPercent: Double?` — mean per-fan load as a percentage in `0...100`, or `nil` when no fan has a readable ceiling.

- [ ] **Step 1: Write the failing test**

Append these tests inside `struct FanTests` in `WattlyTests/FanTests.swift`, immediately after the existing `fanBarFractionScalesAndClamps` test (around line 27):

```swift
    // MARK: - FanSample.loadPercent (threshold input — % of each fan's own ceiling)

    @Test func loadPercentEmptySampleIsNil() {
        #expect(FanSample(fans: []).loadPercent == nil)
    }

    @Test func loadPercentAveragesPerFanRatios() {
        // Fan 0 sits at 50 % of its own 6000 ceiling, fan 1 at 100 % of its 4000 ceiling.
        let s = FanSample(fans: [
            FanReading(index: 0, actualRPM: 3000, minRPM: 1200, maxRPM: 6000, targetRPM: 3000),
            FanReading(index: 1, actualRPM: 4000, minRPM: 1200, maxRPM: 4000, targetRPM: 4000),
        ])
        #expect(s.loadPercent == 75)   // (50 + 100) / 2
    }

    @Test func loadPercentSkipsFansWithoutAReadableCeiling() {
        // A fan reporting max 0 is unreadable, NOT idle — averaging it in as 0 % would
        // dilute a genuinely spinning fan below its warn threshold.
        let s = FanSample(fans: [
            FanReading(index: 0, actualRPM: 4800, minRPM: 1200, maxRPM: 6000, targetRPM: 4800),
            FanReading(index: 1, actualRPM: 0, minRPM: 0, maxRPM: 0, targetRPM: 0),
        ])
        #expect(s.loadPercent == 80)   // fan 1 skipped entirely, not averaged as 0
    }

    @Test func loadPercentIsNilWhenNoFanHasACeiling() {
        let s = FanSample(fans: [
            FanReading(index: 0, actualRPM: 2000, minRPM: 0, maxRPM: 0, targetRPM: 0),
        ])
        #expect(s.loadPercent == nil)
    }

    @Test func loadPercentClampsOvershootToOneHundred() {
        // SMC can briefly report an actual above the advertised max; the band must not
        // exceed 100 % (and must never go negative on a garbage decode).
        let over = FanSample(fans: [
            FanReading(index: 0, actualRPM: 7200, minRPM: 1200, maxRPM: 6000, targetRPM: 6000),
        ])
        #expect(over.loadPercent == 100)

        let under = FanSample(fans: [
            FanReading(index: 0, actualRPM: -50, minRPM: 0, maxRPM: 6000, targetRPM: 0),
        ])
        #expect(under.loadPercent == 0)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/FanTests
```

Expected: **BUILD FAILED**, with `error: value of type 'FanSample' has no member 'loadPercent'` on each of the five new tests.

- [ ] **Step 3: Write the minimal implementation**

In `Wattly/Core/Fan.swift`, add `loadPercent` to the `FanSample` struct body, directly below `maxFanRPM` (line 26-28), so the struct becomes:

```swift
struct FanSample: Sendable, Equatable {
    var fans: [FanReading]

    /// Maximum RPM across all physical fans (e.g. 6550), or nil if no fans exist.
    var maxFanRPM: Double? {
        fans.map(\.maxRPM).filter { $0 > 0 }.max()
    }

    /// Mean fan load as a percentage of each fan's **own** ceiling (0…100), or `nil` when no
    /// fan reports a readable `maxRPM`. This is the threshold input (the warning band is
    /// defined against the ceiling, not against raw RPM, so one default pair is correct on
    /// every Mac — ceilings range roughly 4 000–7 000 RPM by model, and multi-fan Macs can
    /// differ per fan). Averaging the per-fan ratios mirrors the card headline, which averages
    /// actual RPM. Fans with `maxRPM <= 0` are *skipped*, not counted as 0 %: an unreadable
    /// ceiling is missing data, and diluting the mean with it would mask a spinning fan.
    /// Reuses `fanBarFraction` so the band and the expand-region bars share one clamp.
    var loadPercent: Double? {
        let ratios = fans
            .filter { $0.maxRPM > 0 }
            .map { CardPresentation.fanBarFraction(actual: $0.actualRPM, max: $0.maxRPM) }
        guard !ratios.isEmpty else { return nil }
        return ratios.reduce(0, +) / Double(ratios.count) * 100
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/FanTests
```

Expected: **TEST SUCCEEDED** — every `FanTests` case passes, including the five new ones.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/Fan.swift WattlyTests/FanTests.swift
git commit -m "feat(fan): add FanSample.loadPercent, the %-of-ceiling threshold input"
```

---

### Task 2: Fan threshold pair + `.fan` case in `thresholdLevel`

This is the task that makes the warning visible. `Thresholds` gains a non-optional `fan` pair (default 70/90); `CardPresentation.thresholdLevel` routes `.fan` through `loadPercent`. Because `MetricCardView`, `PopoverGridView`, `PopoverHeroView` and `Accessibility.stateWord` all read that one function, the card sparkline, the grid and hero surfaces, and VoiceOver all light up from this single change.

Note the ordering constraint in the decoder: a pre-existing persisted `thresholds` JSON has **no** `"fan"` key, so decoding must fall back to the ship default rather than fail — otherwise every existing user's whole threshold settings blob would be discarded.

**Files:**
- Modify: `Wattly/Settings/Settings.swift:106-155` (the `Thresholds` struct) and `Wattly/Settings/Settings.swift:400-403` (`Defaults.thresholds`)
- Modify: `Wattly/Core/CardPresentation.swift:95-109` (`thresholdLevel`)
- Test: `WattlyTests/ThresholdTests.swift`
- Test: `WattlyTests/CardPresentationTests.swift:525-529` (replaces the stale `fanHasNoThresholdColor`)
- Test: `WattlyTests/AccessibilityTests.swift`

**Interfaces:**
- Consumes: `FanSample.loadPercent: Double?` (Task 1); `ThresholdPair.level(_:) -> ThresholdLevel`; `ThresholdLevel.stateWord: String?`.
- Produces:
  - `Thresholds.defaultFan: ThresholdPair` — `ThresholdPair(warn: 70, crit: 90)`, the one home for the ship default and the legacy-decode fallback.
  - `Thresholds.fan: ThresholdPair` — non-optional stored property.
  - `Thresholds.init(cpu:temp:gpu:fan:)` — `gpu` defaults to `nil`, `fan` defaults to `Thresholds.defaultFan`, so every existing call site keeps compiling unchanged.
  - `CardPresentation.thresholdLevel(.fan, state, thresholds) -> ThresholdLevel?`.

- [ ] **Step 1: Write the failing tests**

**(a)** In `WattlyTests/ThresholdTests.swift`, add these tests inside `struct ThresholdTests`, immediately after the existing `gpuThresholdOptionalSerialization` test (which ends around line 87):

```swift
    // MARK: fan — % of each fan's own ceiling, ON by default (no opt-in toggle)

    @Test func fanComparesLoadPercentAgainstItsOwnPair() {
        let th = Defaults.thresholds        // fan 70/90 (% of max RPM)
        #expect(CardPresentation.thresholdLevel(.fan, fan(actual: 1800, max: 6000), th) == .normal)  // 30 %
        #expect(CardPresentation.thresholdLevel(.fan, fan(actual: 4500, max: 6000), th) == .warn)    // 75 %
        #expect(CardPresentation.thresholdLevel(.fan, fan(actual: 5700, max: 6000), th) == .crit)    // 95 %
    }

    @Test func fanBoundariesAreInclusiveOnThePercentage() {
        let th = Defaults.thresholds        // fan 70/90
        #expect(CardPresentation.thresholdLevel(.fan, fan(actual: 4200, max: 6000), th) == .warn)    // exactly 70 %
        #expect(CardPresentation.thresholdLevel(.fan, fan(actual: 5400, max: 6000), th) == .crit)    // exactly 90 %
    }

    @Test func fanWithoutAReadableCeilingIsNil() {
        // No ceiling → no percentage → no band. The card stays neutral rather than
        // guessing, matching the memory card's behavior when kernel pressure is missing.
        let th = Defaults.thresholds
        let noCeiling = MetricState.value(.fan(FanSample(fans: [
            FanReading(index: 0, actualRPM: 3000, minRPM: 0, maxRPM: 0, targetRPM: 0)])))
        #expect(CardPresentation.thresholdLevel(.fan, noCeiling, th) == nil)
        #expect(CardPresentation.thresholdLevel(.fan, .value(.fan(FanSample(fans: []))), th) == nil)
        #expect(CardPresentation.thresholdLevel(.fan, .loading, th) == nil)
    }

    @Test func fanThresholdIsOnByDefault() {
        // Unlike the opt-in GPU pair, the fan pair is non-optional and ships enabled.
        #expect(Defaults.thresholds.fan == ThresholdPair(warn: 70, crit: 90))
    }

    @Test func fanThresholdSurvivesSerializationRoundTrip() {
        var t = Defaults.thresholds
        t.fan = ThresholdPair(warn: 55, crit: 80)
        let restored = Thresholds(rawValue: t.rawValue)
        #expect(restored?.fan == ThresholdPair(warn: 55, crit: 80))
        #expect(restored == t)
    }

    @Test func legacyPayloadWithoutFanDecodesToTheDefaultPair() {
        // Regression: every already-installed copy has a persisted blob with no "fan" key.
        // It must decode (keeping the user's cpu/temp/gpu edits) with the fan default filled
        // in — NOT fail the decode and silently reset every threshold.
        let legacy = #"{"cpu":{"warn":60,"crit":85},"temp":{"warn":72,"crit":95},"gpu":{"warn":85,"crit":95}}"#
        let decoded = Thresholds(rawValue: legacy)
        #expect(decoded?.cpu == ThresholdPair(warn: 60, crit: 85))
        #expect(decoded?.temp == ThresholdPair(warn: 72, crit: 95))
        #expect(decoded?.gpu == ThresholdPair(warn: 85, crit: 95))
        #expect(decoded?.fan == ThresholdPair(warn: 70, crit: 90))
    }

    @Test func fanDifferenceRegistersAsUnequal() {
        // The memberwise `==` must include the new field, or a fan-only edit would compare
        // equal and the settings UI would not re-render.
        var changed = Defaults.thresholds
        changed.fan.crit -= 5
        #expect(changed != Defaults.thresholds)
    }
```

Then add this helper to the `// MARK: helpers` block at the bottom of `struct ThresholdTests`, next to the existing `cpu` / `mem` helpers:

```swift
    private func fan(actual: Double, max: Double) -> MetricState {
        .value(.fan(FanSample(fans: [
            FanReading(index: 0, actualRPM: actual, minRPM: 0, maxRPM: max, targetRPM: actual)])))
    }
```

**(b)** In `WattlyTests/CardPresentationTests.swift`, **replace** the now-wrong `fanHasNoThresholdColor` test at lines 525-529:

```swift
    @Test func fanHasNoThresholdColor() {
        let state = MetricState.value(.fan(FanSample(fans: [
            FanReading(index: 0, actualRPM: 9000, minRPM: 0, maxRPM: 9000, targetRPM: 9000)])))
        #expect(CardPresentation.thresholdLevel(.fan, state, Defaults.thresholds) == nil)
    }
```

with:

```swift
    @Test func fanColorsByPercentageOfItsCeiling() {
        // A fan pinned at its own ceiling is 100 % → 위험, regardless of the absolute RPM
        // (this same 9000 RPM sample used to be color-free).
        let pinned = MetricState.value(.fan(FanSample(fans: [
            FanReading(index: 0, actualRPM: 9000, minRPM: 0, maxRPM: 9000, targetRPM: 9000)])))
        #expect(CardPresentation.thresholdLevel(.fan, pinned, Defaults.thresholds) == .crit)

        let idle = MetricState.value(.fan(FanSample(fans: [
            FanReading(index: 0, actualRPM: 1200, minRPM: 1200, maxRPM: 9000, targetRPM: 1200)])))
        #expect(CardPresentation.thresholdLevel(.fan, idle, Defaults.thresholds) == .normal)
    }
```

**(c)** In `WattlyTests/AccessibilityTests.swift`, add this test right after the existing `gpuStateWordCritWarnNormal` test (which ends around line 131), before `powerCardHasNoStateWord`:

```swift
    @Test func fanStateWordCritWarnNormal() {
        let th = Defaults.thresholds   // fan warn 70 % / crit 90 % of max RPM
        func fanState(_ actual: Double) -> MetricState {
            .value(.fan(FanSample(fans: [
                FanReading(index: 0, actualRPM: actual, minRPM: 1200, maxRPM: 6000, targetRPM: actual)])))
        }
        #expect(Accessibility.stateWord(.fan, fanState(5700), th) == "위험")   // 95 %
        #expect(Accessibility.stateWord(.fan, fanState(4500), th) == "주의")   // 75 %
        #expect(Accessibility.stateWord(.fan, fanState(1800), th) == nil)      // 30 %
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/ThresholdTests -only-testing:WattlyTests/AccessibilityTests -only-testing:WattlyTests/CardPresentationTests
```

Expected: **BUILD FAILED**, with `error: value of type 'Thresholds' has no member 'fan'` in `ThresholdTests`. (The `CardPresentationTests` / `AccessibilityTests` cases compile but would fail at runtime with `nil` — the build error comes first.)

- [ ] **Step 3: Write the implementation**

**(a)** In `Wattly/Settings/Settings.swift`, replace the whole `Thresholds` struct (lines 106-155) with:

```swift
struct Thresholds: Equatable, Sendable, RawRepresentable {
    /// The ship default for the fan pair, and the fallback used when decoding a payload
    /// persisted before the fan pair existed. One home so the two can't drift.
    static let defaultFan = ThresholdPair(warn: 70, crit: 90)

    var cpu: ThresholdPair
    var temp: ThresholdPair
    var gpu: ThresholdPair?
    /// Fan warning band, compared against `FanSample.loadPercent` (% of each fan's own max
    /// RPM), NOT against absolute RPM — ceilings vary by model, so a percentage keeps one
    /// default correct everywhere. Non-optional: unlike the opt-in GPU pair, the fan warning
    /// ships on, like CPU and temperature.
    var fan: ThresholdPair

    init(cpu: ThresholdPair, temp: ThresholdPair, gpu: ThresholdPair? = nil,
         fan: ThresholdPair = Thresholds.defaultFan) {
        self.cpu = cpu
        self.temp = temp
        self.gpu = gpu
        self.fan = fan
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cpuObject = object["cpu"] as? [String: Double],
              let tempObject = object["temp"] as? [String: Double],
              let cpuWarn = cpuObject["warn"], let cpuCrit = cpuObject["crit"],
              let tempWarn = tempObject["warn"], let tempCrit = tempObject["crit"]
        else { return nil }

        self.cpu = ThresholdPair(warn: cpuWarn, crit: cpuCrit)
        self.temp = ThresholdPair(warn: tempWarn, crit: tempCrit)

        if let gpuObject = object["gpu"] as? [String: Double],
           let gpuWarn = gpuObject["warn"], let gpuCrit = gpuObject["crit"] {
            self.gpu = ThresholdPair(warn: gpuWarn, crit: gpuCrit)
        } else {
            self.gpu = nil
        }

        // Payloads persisted before the fan pair existed carry no "fan" key — fall back to
        // the default instead of failing the decode (which would reset every threshold).
        if let fanObject = object["fan"] as? [String: Double],
           let fanWarn = fanObject["warn"], let fanCrit = fanObject["crit"] {
            self.fan = ThresholdPair(warn: fanWarn, crit: fanCrit)
        } else {
            self.fan = Self.defaultFan
        }
    }

    var rawValue: String {
        var dict: [String: Any] = [
            "cpu": ["warn": cpu.warn, "crit": cpu.crit],
            "temp": ["warn": temp.warn, "crit": temp.crit],
            "fan": ["warn": fan.warn, "crit": fan.crit]
        ]
        if let g = gpu {
            dict["gpu"] = ["warn": g.warn, "crit": g.crit]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: data, encoding: .utf8)
        else { return "" }
        return string
    }

    /// Memberwise equality — NOT JSON string equality (#L12).
    static func == (lhs: Thresholds, rhs: Thresholds) -> Bool {
        lhs.cpu == rhs.cpu && lhs.temp == rhs.temp && lhs.gpu == rhs.gpu && lhs.fan == rhs.fan
    }
}
```

**(b)** In `Wattly/Settings/Settings.swift`, replace `Defaults.thresholds` (lines 400-403) with:

```swift
    static let thresholds = Thresholds(
        cpu: ThresholdPair(warn: 70, crit: 90),
        temp: ThresholdPair(warn: 70, crit: 90),
        gpu: nil,
        fan: Thresholds.defaultFan       // 70 / 90 % of max RPM — on by default
    )
```

**(c)** In `Wattly/Core/CardPresentation.swift`, add the `.fan` case to `thresholdLevel` — insert it after the `.gpuTemp` case (line 107), so the switch reads:

```swift
        case (.cpu, .cpu(let s)):
            return thresholds.cpu.level(s.overall)
        case (.gpu, .gpu(let s)):
            return thresholds.gpu?.level(s.overall)
        case (.mem, .memory(let sample)):
            return sample.pressure?.thresholdLevel
        case (.cpuTemp, .temperature(let s)): return tempLevel(s.cpu, thresholds.temp)
        case (.gpuTemp, .temperature(let s)): return tempLevel(s.gpu, thresholds.temp)
        case (.fan, .fan(let s)):
            // % of each fan's own ceiling, not raw RPM — see `FanSample.loadPercent`.
            // No readable ceiling → nil → the card stays neutral.
            return s.loadPercent.map { thresholds.fan.level($0) }
        default: return nil   // power/battery (fixed) + any state/sample mismatch
        }
```

Also extend the doc comment above `thresholdLevel` by appending this paragraph after the temperature paragraph:

```swift
    /// The fan card compares `FanSample.loadPercent` — the mean of each fan's own
    /// `actual / max` ratio as a percentage — against `thresholds.fan`, so one default pair
    /// is correct across every RPM ceiling. A sample with no readable ceiling yields `nil`
    /// and the card stays neutral.
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
```

Expected: **TEST SUCCEEDED** — the full suite, including the new `ThresholdTests`, the rewritten `CardPresentationTests.fanColorsByPercentageOfItsCeiling`, `AccessibilityTests.fanStateWordCritWarnNormal`, and the untouched `SettingsResetTests` round-trip assertion (`Thresholds(rawValue:) == Defaults.thresholds`), which now exercises the fan field for free.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Settings/Settings.swift Wattly/Core/CardPresentation.swift WattlyTests/ThresholdTests.swift WattlyTests/CardPresentationTests.swift WattlyTests/AccessibilityTests.swift
git commit -m "feat(fan): color the fan card by % of max RPM against a 70/90 threshold pair"
```

---

### Task 3: Settings sliders + localization

Expose 주의/위험 for the fan card in 설정 → 고급 → 상태 경고 기준, reusing the existing `thresholdBlock` helper (which already carries the colored dot, the clamped slider pair, and the `ThresholdPair.setting` warn ≤ crit drag rule). The block is hidden on fanless Macs, mirroring how `SettingsView.advancedGroup` already hides the fan-curve section.

**Files:**
- Modify: `Wattly/Views/Settings/SettingsThresholdSection.swift:4-22`
- Modify: `Wattly/Views/SettingsView.swift:351-359`
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Test: `WattlyTests/LocalizationTests.swift:63-78`

**Interfaces:**
- Consumes: `Thresholds.fan` (Task 2); the existing private `thresholdBlock(title:keyPath:warnRange:critRange:suffix:)` and `thresholdDivider` in `SettingsThresholdSection`; `SystemMonitor.isPresent(_:) -> Bool`.
- Produces: `SettingsThresholdSection(showsFan: Bool)` — the memberwise init gains one label; the only call site is `SettingsView.advancedGroup`.

- [ ] **Step 1: Write the failing test**

In `WattlyTests/LocalizationTests.swift`, add these two lines to `menuMetricChipsAndThresholdTranslations`, right after the existing `"GPU 사용률 (%)"` expectation (line 73):

```swift
        #expect(String(localized: "팬 속도 (최대 RPM 대비 %)", locale: Locale(identifier: "ja")) == "ファン回転数 最大比 (%)")
        #expect(String(localized: "팬 속도 (최대 RPM 대비 %)", locale: Locale(identifier: "en")) == "Fan Speed vs. Max RPM (%)")
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/LocalizationTests
```

Expected: **TEST FAILED** — `menuMetricChipsAndThresholdTranslations` fails, because an unknown key falls back to the key itself: the expectation compares `"팬 속도 (최대 RPM 대비 %)"` against `"ファン回転数 最大比 (%)"`.

- [ ] **Step 3: Add the string to the String Catalog**

Run this script from the repo root. It appends one entry with all 30 localizations and re-serializes with the exact formatting Xcode uses (verified round-trip identical: `indent=2`, `ensure_ascii=False`, trailing newline, insertion order preserved), so the diff is the appended block only.

```bash
python3 - <<'PY'
import json, collections
path = 'Wattly/Resources/Localizable.xcstrings'
with open(path) as f:
    doc = json.load(f, object_pairs_hook=collections.OrderedDict)

key = "팬 속도 (최대 RPM 대비 %)"
values = collections.OrderedDict([
    ("ko", "팬 속도 (최대 RPM 대비 %)"),
    ("en", "Fan Speed vs. Max RPM (%)"),
    ("ja", "ファン回転数 最大比 (%)"),
    ("zh-Hans", "风扇转速 占最大值 (%)"),
    ("zh-Hant", "風扇轉速 佔最大值 (%)"),
    ("de", "Lüfterdrehzahl zur max. Drehzahl (%)"),
    ("fr", "Vitesse du ventilateur vs régime max (%)"),
    ("es", "Velocidad del ventilador respecto al máximo (%)"),
    ("it", "Velocità ventola rispetto al massimo (%)"),
    ("pt-BR", "Velocidade da ventoinha em relação ao máximo (%)"),
    ("pt-PT", "Velocidade da ventoinha em relação ao máximo (%)"),
    ("nl", "Ventilatorsnelheid t.o.v. maximum (%)"),
    ("ru", "Скорость вентилятора от максимума (%)"),
    ("pl", "Prędkość wentylatora względem maks. (%)"),
    ("tr", "Fan hızı maks. değere oranı (%)"),
    ("sv", "Fläkthastighet av max (%)"),
    ("da", "Blæserhastighed af maks. (%)"),
    ("nb", "Viftehastighet av maks. (%)"),
    ("fi", "Tuulettimen nopeus maksimista (%)"),
    ("cs", "Otáčky ventilátoru vůči max. (%)"),
    ("hu", "Ventilátor fordulatszáma a maximumhoz (%)"),
    ("ro", "Viteza ventilatorului față de maxim (%)"),
    ("el", "Ταχύτητα ανεμιστήρα ως προς το μέγιστο (%)"),
    ("uk", "Швидкість вентилятора від максимуму (%)"),
    ("he", "מהירות המאוורר מתוך המרבי (%)"),
    ("ar", "سرعة المروحة من الحد الأقصى (%)"),
    ("hi", "फैन स्पीड अधिकतम की तुलना में (%)"),
    ("th", "ความเร็วพัดลมเทียบกับสูงสุด (%)"),
    ("id", "Kecepatan kipas terhadap maks. (%)"),
    ("vi", "Tốc độ quạt so với tối đa (%)"),
])

entry = collections.OrderedDict()
entry["extractionState"] = "manual"
entry["localizations"] = collections.OrderedDict(
    (lang, collections.OrderedDict([
        ("stringUnit", collections.OrderedDict([("state", "translated"), ("value", v)]))
    ]))
    for lang, v in values.items()
)
doc["strings"][key] = entry

with open(path, 'w') as f:
    f.write(json.dumps(doc, ensure_ascii=False, indent=2) + "\n")

reloaded = json.load(open(path))
assert len(reloaded["strings"][key]["localizations"]) == 30, "expected 30 localizations"
print("added:", key, "->", len(reloaded["strings"]), "keys total")
PY
```

Expected output: `added: 팬 속도 (최대 RPM 대비 %) -> 196 keys total`

- [ ] **Step 4: Add the settings block**

In `Wattly/Views/Settings/SettingsThresholdSection.swift`, replace the type declaration and `body` (lines 3-22) with:

```swift
/// Threshold settings section: CPU/GPU utilization, CPU/GPU temperature, and fan-speed
/// warning/critical sliders. `showsFan` is false on fanless Macs (the fan block would edit a
/// threshold nothing can ever cross), mirroring the fan-curve section's own gate.
struct SettingsThresholdSection: View {
    let showsFan: Bool

    @Environment(\.tokens) private var t
    @AppStorage(StorageKey.thresholds) private var thresholds = Defaults.thresholds

    var body: some View {
        SettingsSection(title: "상태 경고 기준") {
            SettingsCard(padding: Tokens.cardPadding) {
                VStack(alignment: .leading, spacing: 16) {
                    thresholdBlock(title: "CPU 사용률 (%)", keyPath: \.cpu,
                                   warnRange: 10...95, critRange: 20...100, suffix: "%")
                    thresholdDivider
                    gpuThresholdBlock
                    thresholdDivider
                    thresholdBlock(title: "CPU · GPU 온도 (°C)", keyPath: \.temp,
                                   warnRange: 40...100, critRange: 50...110, suffix: "°")
                    if showsFan {
                        thresholdDivider
                        // % of the fan's own ceiling, so one pair is meaningful on every
                        // model — see `FanSample.loadPercent`.
                        thresholdBlock(title: "팬 속도 (최대 RPM 대비 %)", keyPath: \.fan,
                                       warnRange: 30...95, critRange: 40...100, suffix: "%")
                    }
                }
            }
        }
    }
```

Leave the rest of the file (`gpuThresholdBlock`, `thresholdDivider`, `thresholdBlock`, `thresholdRow`, `thresholdBinding`) untouched.

In `Wattly/Views/SettingsView.swift`, update `advancedGroup` (lines 351-359) to pass the gate:

```swift
    private var advancedGroup: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroupHeader(title: "고급")
            SettingsThresholdSection(showsFan: monitor.isPresent(.fan))
            if monitor.isPresent(.fan) {
                SettingsFanCurveSection(monitor: monitor, fanControl: fanControl)
            }
        }
    }
```

- [ ] **Step 5: Run the full test suite to verify it passes**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
```

Expected: **TEST SUCCEEDED** — `LocalizationTests.menuMetricChipsAndThresholdTranslations` now passes along with every suite from Tasks 1-2.

- [ ] **Step 6: Build and eyeball the app on-device**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: **BUILD SUCCEEDED**. Then launch the built app, and check three things:
1. 설정 → 고급 → 상태 경고 기준 shows the new **팬 속도 (최대 RPM 대비 %)** block with 주의 / 위험 sliders under the temperature block (a fanless Mac shows no fan block and no fan-curve section — both gates agree).
2. Dragging 주의 down below the current fan load turns the 팬 속도 card's **sparkline** orange, and dragging 위험 below it turns it red — on the stack (mode A), grid (mode B) and hero (mode C) layouts alike. The per-fan bars in the expand region stay neutral (`t.spark`, hardcoded at `CardExpandRegion.swift:390`) — same as the temperature expand bars; only the mem/power *process* bars follow the threshold color.
3. Dragging 주의 above 위험 pushes 위험 up with it (the existing clamp), and the value readouts stay whole numbers.
4. At idle (below 주의) the fan sparkline is now **green**, where it used to be neutral gray — `ThresholdLevel.normal.stroke` is `Tokens.statusGreen`, so this is the same idle appearance the CPU and temperature cards already have. Confirm that reads as intended. (On a Mac whose fan ceiling is unreadable there is no percentage, so that card's spark stays gray.)

- [ ] **Step 7: Commit**

```bash
git add Wattly/Views/Settings/SettingsThresholdSection.swift Wattly/Views/SettingsView.swift Wattly/Resources/Localizable.xcstrings WattlyTests/LocalizationTests.swift
git commit -m "feat(settings): add fan-speed warning thresholds with 30-language copy"
```

---

## Verification checklist

- [ ] `FanSample.loadPercent` skips fans with an unreadable ceiling instead of averaging them as 0 %.
- [ ] A pre-existing persisted `thresholds` blob (no `"fan"` key) decodes with cpu/temp/gpu preserved and fan filled from `Thresholds.defaultFan`.
- [ ] `Thresholds.==` includes `fan` (a fan-only edit compares unequal).
- [ ] 기본값으로 되돌리기 restores the fan pair — `SettingsReset` writes `Defaults.thresholds.rawValue`, so this needs no code change but the round-trip is asserted by `SettingsResetTests`.
- [ ] The fan color appears on every sparkline surface (stack card, grid, hero) with no view-layer edits. The expand region's per-fan bars are deliberately NOT colored — they use `t.spark` like the temperature bars.
- [ ] VoiceOver announces 주의 / 위험 on the fan card.
- [ ] The fan block is hidden in Settings on a fanless Mac.
