# Battery Stack-Mode Display Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In the "스택 행" (stack-row, mode A) popover layout, hide the battery card's voltage/current from the collapsed view (visible only when the card is expanded), and make the "1분 평균" (1-minute average) sub-line item carry the charge/discharge sign.

**Architecture:** `CardPresentation.subText` is the single pure function that renders the battery card's sub-line; it currently always includes `mA · V · 충전/방전 중 · 1분 평균 W`. We (1) fix the 1-minute average to carry its own +/− sign (it can point the opposite direction from the instantaneous state — e.g. the average was net-discharging for most of the last minute even though the battery is charging right now), (2) drop the voltage/current segment from `subText` entirely and expose it instead through two new pure formatters (`batteryCurrentText`/`batteryVoltageText`), and (3) make the battery card `isExpandable` — the same mechanism `power`/`cpu`/`mem`/`cpuTemp`/`fan` already use for their chevron + tap-to-expand — with a new `batteryExpand` region in `MetricCardView` that renders those two formatters as 전류/전압 rows. `MetricCardView` (and the `isExpandable`/expand-region wiring in `PopoverContentView`) is used ONLY by mode A, so the new expand-to-reveal behavior is scoped to "스택 행" mode.

`subText` itself, however, is shared beyond mode A: mode B (`PopoverGridView`) never renders it (unaffected either way) and mode C's compact list rows use `compactRowText` (value+unit only, also unaffected) — but mode C's **hero** tile (`PopoverHeroView.valueBody`, line 144) renders `d.subText` directly, with no expand mechanism of its own. So Task 2's `subText` change has one accepted side effect outside the literal "스택 행" scope: if the user has picked 배터리 as the mode-C hero metric, its sub-line also loses `mA`/`V` (keeping only `충전/방전 중 · 1분 평균 ±X.X W`). This is judged acceptable — the hero has nowhere to put an expand-only detail anyway, and a shorter, sign-correct sub-line there is a reasonable byproduct of the shared pure function — but it is a real, deliberate, out-of-literal-scope consequence, not something to describe as "unaffected."

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Swift Testing (`import Testing`, `@Test`, `#expect`).

## Global Constraints

- Swift 6 language mode; deployment target macOS 14.0; arm64 only. (`project.yml`)
- Korean copy lives in `CardPresentation`/`Accessibility` (localization is a separate concern) — any new user-facing string goes there, nowhere else.
- The displayed minus sign is **U+2212** (MINUS SIGN), not an ASCII hyphen — reuse `CardPresentation.batterySign`, never hand-roll a new `"-"`.
- `BatterySample.milliamps` is always non-negative (the provider stores `abs(...)`); the sign is prepended separately by the view/formatter layer, never baked into the stored field.
- `BatterySample.average1mW`'s sign convention matches `netW`: `> 0` = net discharging over the window, `< 0` = net charging. It is NOT derived from the instantaneous `charging` flag.
- One-decimal formatting via `CardPresentation.f1` for watts/volts (matches "12.7 V", "10.4 W").
- Pure display/formatting logic lives in `CardPresentation` (no SwiftUI, no I/O) — `MetricCardView` stays a thin renderer over it, per the existing `cpuExpand`/`memExpand`/`tempExpand`/`fanExpand` pattern.
- No new files are created in this plan — every change edits an existing file, so **xcodegen does NOT need to be re-run**.
- Build: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
- Test: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test`
  - Filter one suite: append `-only-testing:WattlyTests/CardPresentationTests`

---

### Task 1: 1-minute average carries its own +/− sign

**Files:**
- Modify: `Wattly/Core/CardPresentation.swift:163-168` (`subText`'s `.battery` case)
- Test: `WattlyTests/CardPresentationTests.swift:24-41` (`batteryValueAndSub`) + a new test

**Interfaces:**
- Consumes: `CardPresentation.batterySign(netW: Double, charging: Bool) -> String` (existing, unchanged signature).
- Produces: `CardPresentation.subText(_ state: MetricState) -> String?` — same signature, new behavior for the battery case's `1분 평균` segment.

- [ ] **Step 1: Write the failing tests**

In `WattlyTests/CardPresentationTests.swift`, update the existing `batteryValueAndSub` test's discharging-case assertion (the average text now carries a sign) and add a new test proving the sign follows the average's OWN direction, not the instantaneous `charging` flag:

```swift
    @Test func batteryValueAndSub() {
        let charging = MetricState.value(.battery(BatterySample(
            netW: -30.0, milliamps: 2362, volts: 12.7, charging: true, externalConnected: true)))
        #expect(CardPresentation.valueText(.battery, charging) == "+30.0")
        #expect(CardPresentation.unitText(.battery, charging) == "W")
        #expect(CardPresentation.subText(charging) == "+2362 mA · 12.7 V · 충전 중")

        let discharging = MetricState.value(.battery(BatterySample(
            netW: 12.0, milliamps: 944, volts: 12.7, charging: false, externalConnected: false,
            average1mW: 10.4)))
        #expect(CardPresentation.valueText(.battery, discharging) == "\(minus)12.0")
        #expect(CardPresentation.subText(discharging) == "−944 mA · 12.7 V · 방전 중 · 1분 평균 \(minus)10.4 W")

        let zero = MetricState.value(.battery(BatterySample(
            netW: 0.0, milliamps: 0, volts: 12.7, charging: false, externalConnected: true)))
        #expect(CardPresentation.valueText(.battery, zero) == "0.0")
        #expect(CardPresentation.subText(zero) == "0 mA · 12.7 V · 방전 중")
    }

    @Test func batteryAverageSignFollowsItsOwnDirection() {
        // Average trending to charge (negative) while the instantaneous state is discharging —
        // the sign must follow the average's own direction, not `charging`.
        let trendingCharge = MetricState.value(.battery(BatterySample(
            netW: 12.0, milliamps: 944, volts: 12.7, charging: false, externalConnected: false,
            average1mW: -3.0)))
        #expect(CardPresentation.subText(trendingCharge) == "−944 mA · 12.7 V · 방전 중 · 1분 평균 +3.0 W")

        // Average trending to discharge (positive) while the instantaneous state is charging.
        let trendingDischarge = MetricState.value(.battery(BatterySample(
            netW: -5.0, milliamps: 400, volts: 12.7, charging: true, externalConnected: true,
            average1mW: 2.0)))
        #expect(CardPresentation.subText(trendingDischarge) == "+400 mA · 12.7 V · 충전 중 · 1분 평균 \(minus)2.0 W")

        // Near-zero average magnitude (< 0.05) drops the sign, matching the headline rule (#17).
        let flatAverage = MetricState.value(.battery(BatterySample(
            netW: 12.0, milliamps: 944, volts: 12.7, charging: false, externalConnected: false,
            average1mW: 0.02)))
        #expect(CardPresentation.subText(flatAverage) == "−944 mA · 12.7 V · 방전 중 · 1분 평균 0.0 W")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/CardPresentationTests/batteryValueAndSub -only-testing:WattlyTests/CardPresentationTests/batteryAverageSignFollowsItsOwnDirection`
Expected: FAIL — `batteryValueAndSub`'s discharging assertion mismatches (current code emits `"1분 평균 10.4 W"`, no sign), and `batteryAverageSignFollowsItsOwnDirection` doesn't compile-fail (the test itself is valid Swift) but its `#expect`s fail because the average text has no sign at all yet.

- [ ] **Step 3: Implement the sign**

In `Wattly/Core/CardPresentation.swift`, replace the `.battery` case of `subText`:

```swift
        case .battery(let s):
            // #17: same zero-magnitude → no-sign rule as the value (keeps mA in step).
            let sign = batterySign(netW: s.netW, charging: s.charging)
            let base = "\(sign)\(s.milliamps) mA · \(f1(s.volts)) V · \(s.charging ? "충전 중" : "방전 중")"
            guard let average = s.average1mW else { return base }
            // The average's OWN sign — not `s.charging` — since the 1-minute trend can point
            // the opposite way from the instantaneous state (e.g. just plugged in after a
            // minute of discharge).
            let avgSign = batterySign(netW: average, charging: average < 0)
            return "\(base) · 1분 평균 \(avgSign)\(f1(abs(average))) W"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/CardPresentationTests`
Expected: PASS (all `CardPresentationTests` cases, including the two touched above)

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/CardPresentation.swift WattlyTests/CardPresentationTests.swift
git commit -m "fix(battery): 1-minute average sub-line carries its own +/- sign"
```

---

### Task 2: Drop voltage/current from the collapsed sub-line; add pure expand-row formatters

**Files:**
- Modify: `Wattly/Core/CardPresentation.swift` (`subText`'s `.battery` case again; add two new static funcs near `batterySign`)
- Test: `WattlyTests/CardPresentationTests.swift` (update `batteryValueAndSub` + `batteryAverageSignFollowsItsOwnDirection`; add a new test)

**Interfaces:**
- Consumes: `CardPresentation.batterySign(netW:charging:) -> String`, `CardPresentation.f1(_:) -> String` (existing).
- Produces: `CardPresentation.batteryCurrentText(_ s: BatterySample) -> String` and `CardPresentation.batteryVoltageText(_ s: BatterySample) -> String` — new, consumed by Task 3's `MetricCardView.batteryExpand`.

- [ ] **Step 1: Write the failing tests**

In `WattlyTests/CardPresentationTests.swift`, update `batteryValueAndSub` and `batteryAverageSignFollowsItsOwnDirection` to drop the `mA · V ·` prefix from every `subText` expectation, and add a new test for the two formatters:

```swift
    @Test func batteryValueAndSub() {
        let charging = MetricState.value(.battery(BatterySample(
            netW: -30.0, milliamps: 2362, volts: 12.7, charging: true, externalConnected: true)))
        #expect(CardPresentation.valueText(.battery, charging) == "+30.0")
        #expect(CardPresentation.unitText(.battery, charging) == "W")
        #expect(CardPresentation.subText(charging) == "충전 중")

        let discharging = MetricState.value(.battery(BatterySample(
            netW: 12.0, milliamps: 944, volts: 12.7, charging: false, externalConnected: false,
            average1mW: 10.4)))
        #expect(CardPresentation.valueText(.battery, discharging) == "\(minus)12.0")
        #expect(CardPresentation.subText(discharging) == "방전 중 · 1분 평균 \(minus)10.4 W")

        let zero = MetricState.value(.battery(BatterySample(
            netW: 0.0, milliamps: 0, volts: 12.7, charging: false, externalConnected: true)))
        #expect(CardPresentation.valueText(.battery, zero) == "0.0")
        #expect(CardPresentation.subText(zero) == "방전 중")
    }

    @Test func batteryAverageSignFollowsItsOwnDirection() {
        let trendingCharge = MetricState.value(.battery(BatterySample(
            netW: 12.0, milliamps: 944, volts: 12.7, charging: false, externalConnected: false,
            average1mW: -3.0)))
        #expect(CardPresentation.subText(trendingCharge) == "방전 중 · 1분 평균 +3.0 W")

        let trendingDischarge = MetricState.value(.battery(BatterySample(
            netW: -5.0, milliamps: 400, volts: 12.7, charging: true, externalConnected: true,
            average1mW: 2.0)))
        #expect(CardPresentation.subText(trendingDischarge) == "충전 중 · 1분 평균 \(minus)2.0 W")

        let flatAverage = MetricState.value(.battery(BatterySample(
            netW: 12.0, milliamps: 944, volts: 12.7, charging: false, externalConnected: false,
            average1mW: 0.02)))
        #expect(CardPresentation.subText(flatAverage) == "방전 중 · 1분 평균 0.0 W")
    }

    @Test func batteryCurrentAndVoltageTextForExpand() {
        let discharging = BatterySample(netW: 12.0, milliamps: 944, volts: 12.7,
                                         charging: false, externalConnected: false)
        #expect(CardPresentation.batteryCurrentText(discharging) == "\(minus)944 mA")
        #expect(CardPresentation.batteryVoltageText(discharging) == "12.7 V")

        let charging = BatterySample(netW: -30.0, milliamps: 2362, volts: 12.7,
                                      charging: true, externalConnected: true)
        #expect(CardPresentation.batteryCurrentText(charging) == "+2362 mA")
        #expect(CardPresentation.batteryVoltageText(charging) == "12.7 V")

        let zero = BatterySample(netW: 0.0, milliamps: 0, volts: 12.7,
                                  charging: false, externalConnected: true)
        #expect(CardPresentation.batteryCurrentText(zero) == "0 mA")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/CardPresentationTests`
Expected: FAIL — the updated `subText` expectations still see `mA`/`V` in the string, and `batteryCurrentAndVoltageTextForExpand` fails to build (`batteryCurrentText`/`batteryVoltageText` don't exist yet).

- [ ] **Step 3: Implement**

In `Wattly/Core/CardPresentation.swift`, replace the `.battery` case of `subText` (from Task 1) with:

```swift
        case .battery(let s):
            let base = s.charging ? "충전 중" : "방전 중"
            guard let average = s.average1mW else { return base }
            // The average's OWN sign — not `s.charging` — since the 1-minute trend can point
            // the opposite way from the instantaneous state (e.g. just plugged in after a
            // minute of discharge).
            let avgSign = batterySign(netW: average, charging: average < 0)
            return "\(base) · 1분 평균 \(avgSign)\(f1(abs(average))) W"
```

Then add two new static funcs directly below `batterySign` (still inside `enum CardPresentation`):

```swift
    /// Battery current text for the expand-only 전류 row (plan: battery stack-mode display) —
    /// sign + magnitude, the mA the collapsed sub-line used to show inline.
    static func batteryCurrentText(_ s: BatterySample) -> String {
        "\(batterySign(netW: s.netW, charging: s.charging))\(s.milliamps) mA"
    }

    /// Battery voltage text for the expand-only 전압 row (plan: battery stack-mode display).
    static func batteryVoltageText(_ s: BatterySample) -> String {
        "\(f1(s.volts)) V"
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/CardPresentationTests`
Expected: PASS (all `CardPresentationTests` cases)

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/CardPresentation.swift WattlyTests/CardPresentationTests.swift
git commit -m "refactor(battery): drop voltage/current from the collapsed sub-line, add expand-row formatters"
```

---

### Task 3: Make the battery card expandable in mode A, with a 전류/전압 expand region

**Files:**
- Modify: `Wattly/Models/CardKind.swift:28-30` (`isExpandable`)
- Modify: `Wattly/Views/MetricCardView.swift:108-152` (`expandRegion` switch) and `:200-235` (new `batteryExpand`/`batteryDetailRow` funcs, placed after `powerExpand`)
- Test: `WattlyTests/CardPresentationTests.swift:186-190` (`cardKindStructuralFlags`)

**Interfaces:**
- Consumes: `CardPresentation.batteryCurrentText(_:) -> String`, `CardPresentation.batteryVoltageText(_:) -> String` (Task 2).
- Produces: `CardKind.isExpandable` now includes `.battery`; `MetricCardView`'s existing `onToggleExpand`/chevron/`.accessibilityAction` wiring (already generic over `card.isExpandable` in both `MetricCardView.swift` and `PopoverContentView.swift:383`) picks this up with no further changes.

- [ ] **Step 1: Write the failing test**

In `WattlyTests/CardPresentationTests.swift`, update `cardKindStructuralFlags`:

```swift
    @Test func cardKindStructuralFlags() {
        #expect(CardKind.allCases.filter(\.isExpandable) == [.power, .battery, .cpu, .mem, .cpuTemp, .fan])
        #expect(CardKind.allCases.filter(\.hasSparkArea) == [.power, .cpu, .mem, .cpuTemp, .gpuTemp, .batTemp, .fan])
        #expect(CardKind.allCases.filter(\.isAccented) == [.power])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/CardPresentationTests/cardKindStructuralFlags`
Expected: FAIL — `CardKind.allCases.filter(\.isExpandable)` is still `[.power, .cpu, .mem, .cpuTemp, .fan]` (no `.battery`).

- [ ] **Step 3: Implement `isExpandable`**

In `Wattly/Models/CardKind.swift`, replace:

```swift
    /// Cards with an expand region + chevron (processor-power per-app Top-3, CPU per-core,
    /// memory Top-3, CPU-temp clusters). Drives both the chevron and whether a tap toggles.
    var isExpandable: Bool { self == .power || self == .cpu || self == .mem || self == .cpuTemp || self == .fan }
```

with:

```swift
    /// Cards with an expand region + chevron (processor-power per-app Top-3, battery
    /// voltage/current, CPU per-core, memory Top-3, CPU-temp clusters). Drives both the
    /// chevron and whether a tap toggles.
    var isExpandable: Bool {
        self == .power || self == .battery || self == .cpu || self == .mem || self == .cpuTemp || self == .fan
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/CardPresentationTests/cardKindStructuralFlags`
Expected: PASS

- [ ] **Step 5: Add the battery expand region to `MetricCardView`**

In `Wattly/Views/MetricCardView.swift`, add a `.battery` branch to `expandRegion` (right after the `.power` branch, matching `CardKind`'s declaration order):

```swift
    @ViewBuilder
    private var expandRegion: some View {
        if card == .power, case .value(.power(let s)) = state {
            powerExpand(s)
        } else if card == .battery, case .value(.battery(let s)) = state {
            batteryExpand(s)
        } else if card == .cpu, case .value(.cpu(let s)) = state {
            cpuExpand(s)
        } else if card == .mem, case .value(.memory(let s)) = state {
            memExpand(s)
        } else if card == .cpuTemp, case .value(.temperature(let s)) = state, case .reading(let r) = s.cpu {
            tempExpand(r.groups)
        } else if card == .fan, case .value(.fan(let s)) = state {
            fanExpand(s)
        }
    }
```

Then add the `batteryExpand`/`batteryDetailRow` funcs right after `powerExpand` (i.e. immediately before the `// Process row, pixel-matched...` comment that precedes `processRow`):

```swift
    // MARK: Battery expand — voltage/current (plan: battery stack-mode display)

    /// Voltage + current, hidden from the collapsed sub-line (moved here so "스택 행" mode
    /// only shows them once the card is tapped open) — mirrors the other cards' expand-
    /// reveals-detail pattern (`cpuExpand`'s per-core, `memExpand`'s Top-3). There's no
    /// natural 0–100 scale to bar-fill for volts/mA, so this is a plain label/value pair,
    /// unlike `tempGroupRow`/`fanRow`.
    private func batteryExpand(_ s: BatterySample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            batteryDetailRow(label: "전류", value: CardPresentation.batteryCurrentText(s))
            batteryDetailRow(label: "전압", value: CardPresentation.batteryVoltageText(s))
        }
        .padding(.top, 8)
    }

    private func batteryDetailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(WattlyFont.at(10.5, weight: .semibold))
                .foregroundStyle(t.faint)
            Spacer(minLength: 8)
            Text(value)
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.sub)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
    }
```

- [ ] **Step 6: Build to verify it compiles**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Run the full test suite**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test`
Expected: `** TEST SUCCEEDED **` (every suite, not just `CardPresentationTests`)

- [ ] **Step 8: Manual on-device check**

Run: `open <DerivedData>/Build/Products/Debug/Wattly.app --args -WattlyScenario laptop` (substitute the actual DerivedData path from Step 6's build output)

Verify in the popover (mode A / "스택 행", the default panel mode — confirm via 설정 if it was changed):
- The 배터리 card's collapsed sub-line reads `충전 중` / `방전 중` (optionally `· 1분 평균 ±X.X W`), with NO `mA`/`V` visible, and shows a chevron next to the "배터리" label.
- Tapping the card expands it, revealing `전류` and `전압` rows below the sparkline.
- Tapping again collapses it, hiding those rows.
- Switch 설정 → 패널 레이아웃 to B and confirm the battery tile there is unaffected (`PopoverGridView` never renders `subText`, so nothing changed).
- Switch to C: the battery **list row** (when battery is NOT the hero) still reads as a plain "±X.X W" via `compactRowText` — unaffected. If you set 배터리 as the **hero** metric, its sub-line now reads `충전/방전 중 · 1분 평균 ±X.X W` with no `mA`/`V` either (accepted side effect of the shared `subText`, per the Architecture section — not a bug).

- [ ] **Step 9: Commit**

```bash
git add Wattly/Models/CardKind.swift Wattly/Views/MetricCardView.swift WattlyTests/CardPresentationTests.swift
git commit -m "feat(battery): expand-to-reveal voltage/current in stack-row mode"
```
