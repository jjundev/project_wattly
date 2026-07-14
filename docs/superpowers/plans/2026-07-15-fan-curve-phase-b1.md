# Fan Curve (Phase B-1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a user-editable CPU-temperature fan curve with a live "current CPU °C → target RPM" preview in Settings — pure model + display only, **no SMC writes** (actual fan control is the separate Phase B-2).

**Architecture:** A pure `FanCurve` value type in `Fan.swift` — fixed temperature anchors (40/60/80/95 °C) with user-editable target RPMs, piecewise-linear `evaluate(inputCelsius:)`, JSON `RawRepresentable` for `@AppStorage` (mirrors `Thresholds`). A pure `hottestCPUCelsius(_:)` helper reads the hottest CPU die sensor from the existing `TemperatureSnapshot`. The Settings window gains a fan-curve section (RPM sliders reusing the Threshold-slider idiom) plus a live preview that reads `monitor.cardState(.cpuTemp)`. The fan card and its provider are untouched.

**Tech Stack:** Swift 6, SwiftUI, `@AppStorage`, Swift Testing (`import Testing`, `@Test`, `#expect`).

## Global Constraints

- **No SMC writes, no control.** Phase B-1 is model + preview ONLY. The preview shows what a curve *would* command; nothing actuates the fan. Do not touch `FanProvider`/`SMCFanTransport`/`SMC.swift`, and add no write path.
- **Swift 6 strict concurrency.** New types are plain `Sendable, Equatable` value types; pure functions have no I/O.
- **Pure core, tested without hardware.** All curve math + aggregation live in pure free functions / value types in `Wattly/Core/Fan.swift`, tested directly (mirror how `averageRPM`/`plausibleRPM` are tested in `WattlyTests/FanTests.swift`).
- **Persistence mirrors `Thresholds`.** `FanCurve` is JSON `RawRepresentable` with an explicit `==` (the `Thresholds` lesson: a `RawRepresentable` string `==` is fragile — compare fields directly). `Defaults`/`StorageKey`/`SettingsReset` all get a `fanCurve` entry, exactly like `thresholds`.
- **Korean UI copy**, matching existing sections (section title "팬 커브", band labels "40°C" etc., preview "현재 CPU M°C → 커브 목표 N RPM", disclaimer "미리보기입니다 — 실제 팬 제어는 아직 지원되지 않습니다").
- **Fixed-band curve.** Temperature anchors are a fixed `[40, 60, 80, 95]` °C; only the four RPMs are editable. No add/remove of points (that's a deliberate scope choice for B-1).
- **Preview is Settings-only.** No change to `MetricCardView`/the fan card expand.
- **Present-gated.** The curve section renders only when a fan is present (`monitor.isPresent(.fan)`), so fanless Macs don't see a control for hardware they lack — same spirit as the fan card hiding.
- **Test framework is Swift Testing**, not XCTest.
- **Frequent commits** — one per task.

---

## File Structure

**Modified files:**
- `Wattly/Core/Fan.swift` — add `FanCurve` (value type + `evaluate` + `RawRepresentable`) and `hottestCPUCelsius(_:)`. Pure, no I/O. (`FanCurve` lives here, in the fan domain, next to `averageRPM`; only the persistence *defaults* live in `Settings.swift`, mirroring how `Thresholds` math and `Defaults.thresholds` are split.)
- `Wattly/Settings/Settings.swift` — add `Defaults.fanCurve` and `StorageKey.fanCurve`.
- `Wattly/Core/SettingsReset.swift` — add the `fanCurve` reset line (mirrors the `thresholds` line at `SettingsReset.swift:24`).
- `Wattly/Views/SettingsView.swift` — add the `fanCurveSection` (RPM sliders + live preview), present-gated, inserted after `thresholdSection`.
- `WattlyTests/FanTests.swift` — tests for `FanCurve.evaluate`, `RawRepresentable` round-trip, and `hottestCPUCelsius`.
- `WattlyTests/SettingsResetTests.swift` — assert `applyDefaults` writes `fanCurve`.

**No new files.** (So no `project.pbxproj` registration is needed — unlike Phase A.)

> **`TemperatureSnapshot` reference** (already in the tree, `Wattly/Models/MetricSample.swift`), needed by `hottestCPUCelsius`:
> `struct TemperatureSnapshot { var cpu: CategoryReading; var gpu: CategoryReading; var battery: CategoryReading }`
> `enum CategoryReading { case reading(TemperatureReading); case unavailable(TemperatureError); case notPresent(String) }`
> `struct TemperatureReading { var celsius: Double; var groups: [TemperatureGroup] = [] }`
> `struct TemperatureGroup { var name: String; var average: Double; var hottest: Double }`

---

### Task 1: FanCurve model + `evaluate` + `hottestCPUCelsius` (pure)

**Files:**
- Modify: `Wattly/Core/Fan.swift` (append the new types + helper)
- Modify: `WattlyTests/FanTests.swift` (append tests)

**Interfaces:**
- Produces:
  - `struct FanCurve: Equatable, Sendable, RawRepresentable` with `static let anchorsCelsius: [Double] = [40, 60, 80, 95]`, `var rpms: [Double]`, `init(rpms: [Double])`, `func evaluate(inputCelsius: Double) -> Double`, and JSON `init?(rawValue:)` / `var rawValue: String`.
  - `func hottestCPUCelsius(_ snapshot: TemperatureSnapshot) -> Double?`

- [ ] **Step 1: Write the failing tests**

Append to `WattlyTests/FanTests.swift` (inside the existing `struct FanTests`):

```swift
    // MARK: Fan curve (Phase B-1) — pure model

    @Test func fanCurveEvaluateFlatBelowFirstAndAboveLast() {
        let curve = FanCurve(rpms: [1200, 2500, 4500, 6000])   // anchors 40/60/80/95
        #expect(curve.evaluate(inputCelsius: 20) == 1200)      // below first anchor → first rpm
        #expect(curve.evaluate(inputCelsius: 40) == 1200)      // at first anchor
        #expect(curve.evaluate(inputCelsius: 95) == 6000)      // at last anchor
        #expect(curve.evaluate(inputCelsius: 110) == 6000)     // above last → last rpm
    }

    @Test func fanCurveEvaluateInterpolatesLinearly() {
        let curve = FanCurve(rpms: [1200, 2500, 4500, 6000])
        // Midpoint of the 60→80 segment (70 °C) between 2500 and 4500 → 3500.
        #expect(curve.evaluate(inputCelsius: 70) == 3500)
        // Quarter into the 40→60 segment (45 °C) between 1200 and 2500 → 1200 + 0.25*1300 = 1525.
        #expect(curve.evaluate(inputCelsius: 45) == 1525)
    }

    @Test func fanCurveRawValueRoundTrips() {
        let curve = FanCurve(rpms: [1000, 3000, 5000, 6500])
        #expect(FanCurve(rawValue: curve.rawValue)?.rpms == curve.rpms)
    }

    @Test func fanCurveRejectsMalformedRawValue() {
        #expect(FanCurve(rawValue: "") == nil)
        #expect(FanCurve(rawValue: "not json") == nil)
        #expect(FanCurve(rawValue: "[1,2,3]") == nil)          // wrong count (3, needs 4)
        #expect(FanCurve(rawValue: "[1,2,3,4,5]") == nil)      // wrong count (5)
    }

    @Test func hottestCPUReturnsMaxHottestAcrossGroups() {
        let snap = TemperatureSnapshot(
            cpu: .reading(TemperatureReading(celsius: 70, groups: [
                TemperatureGroup(name: "P-코어", average: 72, hottest: 88),
                TemperatureGroup(name: "E-코어", average: 60, hottest: 66),
            ])),
            gpu: .reading(TemperatureReading(celsius: 55)),
            battery: .reading(TemperatureReading(celsius: 30)))
        #expect(hottestCPUCelsius(snap) == 88)   // max of the per-group hottest values
    }

    @Test func hottestCPUNilWhenNotReadingOrNoGroups() {
        let unavailable = TemperatureSnapshot(
            cpu: .unavailable(.connectionFailed),
            gpu: .reading(TemperatureReading(celsius: 55)),
            battery: .reading(TemperatureReading(celsius: 30)))
        #expect(hottestCPUCelsius(unavailable) == nil)

        let noGroups = TemperatureSnapshot(
            cpu: .reading(TemperatureReading(celsius: 70)),   // groups defaults to []
            gpu: .reading(TemperatureReading(celsius: 55)),
            battery: .reading(TemperatureReading(celsius: 30)))
        #expect(hottestCPUCelsius(noGroups) == nil)           // empty groups → max of [] → nil
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/FanTests test 2>&1 | xcbeautify` (drop `| xcbeautify` if not installed).
Expected: FAIL to compile — `FanCurve` and `hottestCPUCelsius` don't exist.

- [ ] **Step 3: Add the model + helper**

Append to `Wattly/Core/Fan.swift`:

```swift
// MARK: - Fan curve (Phase B-1) — pure model, no I/O, no SMC writes

/// A CPU-temperature → target-RPM fan curve. **Fixed-band model**: the temperature anchors
/// are constant (`anchorsCelsius`); only the four RPMs are user-editable. `evaluate` is
/// piecewise-linear between anchors (flat below the first / above the last). Phase B-1 only
/// *displays* the evaluated target (a preview) — nothing writes to the SMC; actual fan
/// control is Phase B-2. JSON `RawRepresentable` so it persists via `@AppStorage`, exactly
/// like `Thresholds`.
struct FanCurve: Equatable, Sendable, RawRepresentable {
    /// The fixed temperature anchors (°C), ascending — the same for every curve.
    static let anchorsCelsius: [Double] = [40, 60, 80, 95]

    /// Target RPM at each anchor, parallel to `anchorsCelsius` (so `rpms.count == 4`).
    var rpms: [Double]

    init(rpms: [Double]) { self.rpms = rpms }

    /// Target RPM for an input temperature: `rpms.first` at/below the first anchor,
    /// `rpms.last` at/above the last, linearly interpolated between adjacent anchors. `0` if
    /// the curve is malformed (wrong rpm count) — a defensive default, never expected at runtime.
    func evaluate(inputCelsius c: Double) -> Double {
        let anchors = Self.anchorsCelsius
        guard rpms.count == anchors.count, let first = anchors.first, let last = anchors.last
        else { return 0 }
        if c <= first { return rpms[0] }
        if c >= last { return rpms[rpms.count - 1] }
        for i in 0..<(anchors.count - 1) where c >= anchors[i] && c < anchors[i + 1] {
            let t = (c - anchors[i]) / (anchors[i + 1] - anchors[i])
            return rpms[i] + t * (rpms[i + 1] - rpms[i])
        }
        return rpms[rpms.count - 1]
    }

    /// Explicit field-wise equality. Mirrors the `Thresholds` fix: a `RawRepresentable`
    /// type's synthesized `==` can resolve to the (fragile) `rawValue`-string comparison, so
    /// compare the stored RPMs directly.
    static func == (lhs: FanCurve, rhs: FanCurve) -> Bool { lhs.rpms == rhs.rpms }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        let values = raw.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard values.count == Self.anchorsCelsius.count else { return nil }
        self.init(rpms: values)
    }

    var rawValue: String {
        guard let data = try? JSONSerialization.data(withJSONObject: rpms),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }
}

/// The hottest CPU die sensor from a temperature snapshot (°C), or `nil` when CPU temperature
/// isn't a live reading (unavailable / no verified profile) or has no cluster groups. This is
/// the honest input for a *safety*-oriented curve — the max across the P-코어/E-코어 clusters'
/// hottest sensors, not the steadier average the card headline shows. Pure; consumes the
/// existing `TemperatureSnapshot`.
func hottestCPUCelsius(_ snapshot: TemperatureSnapshot) -> Double? {
    guard case .reading(let r) = snapshot.cpu else { return nil }
    return r.groups.map(\.hottest).max()
}
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/FanTests test 2>&1 | xcbeautify`
Expected: PASS (the 6 new tests + the existing FanTests).

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/Fan.swift WattlyTests/FanTests.swift
git commit -m "feat(fan-curve): add pure FanCurve model + hottestCPUCelsius (Phase B-1)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Persist the curve (`Defaults` / `StorageKey` / reset)

**Files:**
- Modify: `Wattly/Settings/Settings.swift` (`Defaults`, `StorageKey`)
- Modify: `Wattly/Core/SettingsReset.swift` (reset line)
- Modify: `WattlyTests/SettingsResetTests.swift` (assert reset writes it)

**Interfaces:**
- Consumes: `FanCurve` (Task 1).
- Produces: `Defaults.fanCurve: FanCurve`, `StorageKey.fanCurve: String`, and a `SettingsReset.applyDefaults` write of the fan curve.

- [ ] **Step 1: Write the failing reset test**

Append to `WattlyTests/SettingsResetTests.swift` (inside the existing test `struct`). This file already has a `makeDefaults(_ name: String)` helper that returns a clean suite (suite name + `removePersistentDomain`) — use it exactly as the other tests in the file do, passing `#function` as the name:

```swift
    @Test func resetWritesDefaultFanCurve() {
        let defaults = makeDefaults(#function)
        // Pre-dirty the key with a non-default value.
        defaults.set(FanCurve(rpms: [9, 9, 9, 9]).rawValue, forKey: StorageKey.fanCurve)

        SettingsReset.applyDefaults(into: defaults)

        let raw = defaults.string(forKey: StorageKey.fanCurve)
        #expect(raw == Defaults.fanCurve.rawValue)
        #expect(FanCurve(rawValue: raw ?? "")?.rpms == Defaults.fanCurve.rpms)
    }
```

> If the helper's name/signature differs from `makeDefaults(_:)` when you open the file, use whatever the file's other `@Test`s use to obtain a suite — keep the two `#expect` assertions identical. (The raw-string compare is safe here: `FanCurve`'s `rawValue` is a top-level array, so it is order-deterministic.)

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/SettingsResetTests test 2>&1 | xcbeautify`
Expected: FAIL to compile — `Defaults.fanCurve` and `StorageKey.fanCurve` don't exist.

- [ ] **Step 3: Add the defaults + key**

In `Wattly/Settings/Settings.swift`, inside `enum Defaults`, add after `static let thresholds = …`:

```swift
    /// Fan curve (Phase B-1): target RPMs at the fixed 40/60/80/95 °C anchors. A gentle ramp
    /// — quiet at idle, spinning up toward the fan's top end under sustained heat.
    static let fanCurve = FanCurve(rpms: [1200, 2500, 4500, 6000])
```

In `Wattly/Settings/Settings.swift`, inside `enum StorageKey`, add after `static let thresholds = "thresholds"`:

```swift
    static let fanCurve = "fanCurve"
```

- [ ] **Step 4: Add the reset line**

In `Wattly/Core/SettingsReset.swift`, inside `applyDefaults`, add immediately after the `thresholds` write (`SettingsReset.swift:24`):

```swift
        defaults.set(Defaults.fanCurve.rawValue, forKey: StorageKey.fanCurve)
```

- [ ] **Step 5: Run to verify pass**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/SettingsResetTests test 2>&1 | xcbeautify`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Wattly/Settings/Settings.swift Wattly/Core/SettingsReset.swift WattlyTests/SettingsResetTests.swift
git commit -m "feat(fan-curve): persist FanCurve via Defaults/StorageKey + reset

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Settings "팬 커브" section — RPM sliders + live preview

**Files:**
- Modify: `Wattly/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `FanCurve`, `FanCurve.anchorsCelsius`, `FanCurve.evaluate`, `hottestCPUCelsius` (Task 1); `Defaults.fanCurve`, `StorageKey.fanCurve` (Task 2). Existing: `monitor.cardState(_:)`, `monitor.isPresent(_:)`, the `SettingsSection`/`SettingsCard` components, `WattlyFont`, `t` (tokens).
- Produces: a `fanCurveSection` rendered in `body` after `thresholdSection`, present-gated on `monitor.isPresent(.fan)`.

> This is a SwiftUI view task — no unit test (the curve math + persistence are already covered by Tasks 1–2). Verify by building and by the manual check in Step 5.

- [ ] **Step 1: Add the `@AppStorage` binding + helpers**

In `Wattly/Views/SettingsView.swift`, add an `@AppStorage` property next to the existing `thresholds` one (near line 32):

```swift
    @AppStorage(StorageKey.fanCurve) private var fanCurve = Defaults.fanCurve
```

Add these helpers to the `SettingsView` struct (place them near the threshold helpers, e.g. after `thresholdBinding`):

```swift
    /// Clamping `Double` binding into one anchor's RPM; reassigns the whole `FanCurve` so the
    /// `@AppStorage` re-encodes (same idiom as `thresholdBinding`). Rounds to a whole RPM.
    private func fanCurveRpmBinding(_ index: Int) -> Binding<Double> {
        Binding(
            get: { fanCurve.rpms.indices.contains(index) ? fanCurve.rpms[index] : 0 },
            set: { newValue in
                var next = fanCurve
                if next.rpms.indices.contains(index) { next.rpms[index] = newValue.rounded() }
                fanCurve = next
            }
        )
    }

    /// The hottest live CPU sensor (°C) from the monitor, or nil when CPU temperature isn't a
    /// live reading. Read in `body` (via the preview), so the @Observable monitor re-renders it.
    private var currentHottestCPU: Double? {
        if case .value(.temperature(let s)) = monitor.cardState(.cpuTemp) { return hottestCPUCelsius(s) }
        return nil
    }
```

- [ ] **Step 2: Add the section view**

In `Wattly/Views/SettingsView.swift`, add the section + preview (place near `thresholdSection`):

```swift
    // MARK: 팬 커브 (Phase B-1 — preview only, no control)

    private var fanCurveSection: some View {
        SettingsSection(title: "팬 커브") {
            SettingsCard(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(FanCurve.anchorsCelsius.enumerated()), id: \.offset) { i, temp in
                        HStack(spacing: 9) {
                            Text("\(Int(temp))°C")
                                .font(WattlyFont.at(12, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(t.sub)
                                .frame(width: 44, alignment: .leading)
                            Slider(value: fanCurveRpmBinding(i), in: 0...8000, step: 100)
                                .tint(Tokens.accent)
                            Text("\(Int(fanCurveRpmBinding(i).wrappedValue)) RPM")
                                .font(WattlyFont.at(12, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(t.text)
                                .frame(width: 76, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Rectangle().fill(t.line).frame(height: 1)
                    fanCurvePreview
                }
            }
        }
    }

    private var fanCurvePreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let c = currentHottestCPU {
                (Text("현재 CPU \(Int(c.rounded()))°C → 커브 목표 ")
                    + Text("\(Int(fanCurve.evaluate(inputCelsius: c).rounded())) RPM")
                        .foregroundColor(t.text))
                    .font(WattlyFont.at(12, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(t.sub)
            } else {
                Text("CPU 온도를 읽을 수 없음")
                    .font(WattlyFont.at(12, weight: .regular))
                    .foregroundStyle(t.faint)
            }
            Text("미리보기입니다 — 실제 팬 제어는 아직 지원되지 않습니다")
                .font(WattlyFont.at(11.5, weight: .regular))
                .foregroundStyle(t.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
```

- [ ] **Step 3: Render it in `body`, present-gated**

In `Wattly/Views/SettingsView.swift`, in the `body`'s section `VStack`, insert the gated section immediately after `thresholdSection`:

```swift
                thresholdSection
                if monitor.isPresent(.fan) { fanCurveSection }
                menubarSection
```

- [ ] **Step 4: Build to verify it compiles + full suite green**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED.

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | xcbeautify`
Expected: TEST SUCCEEDED, all tests pass (no regressions; Tasks 1–2 tests included).

- [ ] **Step 5: Manual check (this Mac has a fan — `Mac17,2`)**

Build a Release app and open Settings:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Release build 2>&1 | tail -1
APP=$(find ~/Library/Developer/Xcode/DerivedData -path '*Build/Products/Release/Wattly.app' -print0 2>/dev/null | xargs -0 ls -td | head -1)
open "$APP"
```
Open the menubar popover → gear (Settings). Confirm: a "팬 커브" section appears after "그래프 임곗값" with four labeled RPM sliders (40/60/80/95 °C); dragging a slider updates its "N RPM" readout; the preview line reads "현재 CPU M°C → 커브 목표 N RPM" with the number changing as you drag the sliders or as CPU temp moves; the disclaimer line is present. Press "기본값으로 되돌리기" and confirm the sliders snap back to 1200/2500/4500/6000.
Expected: all of the above. (On a fanless Mac the section is absent — matches the fan card hiding.)

- [ ] **Step 6: Commit**

```bash
git add Wattly/Views/SettingsView.swift
git commit -m "feat(fan-curve): Settings fan-curve editor + live CPU-temp preview

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**1. Spec coverage** (Phase B-1 grilled design → tasks):
- Pure `FanCurve` model, JSON `RawRepresentable` like `Thresholds`, piecewise-linear `evaluate` → Task 1. ✔
- Fixed temperature bands, editable RPMs (resolved fork) → `FanCurve.anchorsCelsius` + the slider editor. ✔
- `hottestCPUCelsius` uses the max of the P/E cluster hottest sensors (the safety-oriented input, per the grill-review's precision fix) → Task 1. ✔
- Persistence + reset parity with `Thresholds` → Task 2. ✔
- Curve editor UI + live "current CPU °C → target RPM" preview, **Settings-only** (resolved fork), present-gated → Task 3. ✔
- No SMC writes / no control / fan card untouched (Phase B-1 boundary; B-2 owns the daemon + writes) → enforced by Global Constraints; no task touches `FanProvider`/`SMC.swift`/`MetricCardView`. ✔
- Honesty: an explicit "실제 팬 제어는 아직 지원되지 않습니다" disclaimer so the preview isn't mistaken for control → Task 3. ✔

**2. Placeholder scan:** No TBD/"add validation"/"similar to Task N" — every step carries complete code. ✔

**3. Type consistency:** `FanCurve(rpms:)`, `FanCurve.anchorsCelsius`, `FanCurve.evaluate(inputCelsius:)`, `hottestCPUCelsius(_:)`, `Defaults.fanCurve`, `StorageKey.fanCurve`, `fanCurveRpmBinding(_:)`, `currentHottestCPU` — used identically across Tasks 1–3. `TemperatureSnapshot`/`CategoryReading`/`TemperatureReading`/`TemperatureGroup` shapes match the reference block (verified against `Wattly/Models/MetricSample.swift`). ✔

---

## Notes for the executor

- If `xcbeautify` isn't installed, drop `| xcbeautify` from every command.
- `SettingsResetTests.swift` may build its `UserDefaults` via a file-specific helper — follow that file's existing pattern for the suite; keep the assertion identical (Task 2 Step 1 note).
- The slider range `0...8000` is a fixed display range chosen to comfortably exceed observed Mac fan maxima (~6550 RPM on the dev `Mac17,2`); it is not read from the live fan's `maxRPM` (that coupling is unnecessary for a preview and is a B-2 concern).
