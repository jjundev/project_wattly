# Fan Curve Graph Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fan-curve settings' four RPM sliders with an interactive temperature→fan-speed graph whose 13 anchor points (40–100 °C, 5° steps) are adjusted by dragging.

**Architecture:** The fixed-anchor `FanCurve` model widens from 4 anchors to 13. A new SwiftUI-free `FanCurveGeometry` holds all plot math (mirrors the existing `Sparkline` helper) so it is unit-tested without a render host. A thin `FanCurveEditor` view draws the curve in a `Canvas` and edits the nearest anchor's RPM from a `DragGesture`; a per-anchor focusable overlay gives VoiceOver-adjustable + arrow-key parity with the old sliders. `SettingsView.fanCurveSection` swaps its sliders/preview for the graph plus a section-local "기본값" reset button.

**Tech Stack:** Swift 6, SwiftUI (`Canvas`, `DragGesture`, `@FocusState`, `.accessibilityAdjustableAction`, `.onKeyPress`), Swift Testing (`import Testing` / `@Test` / `#expect`), Xcode project (manual `project.pbxproj` registration for new files).

## Global Constraints

- **Swift 6 language mode**, **macOS deployment target 14.0** — every API used must exist on 14.0 (`Canvas`, `.onKeyPress`, `.accessibilityAdjustableAction`, `@FocusState`, `.focusable()` all qualify).
- **UI copy is Korean.** New strings: section header `온도 → 팬 속도`, reset button `기본값`, VoiceOver anchor label `<n>°C 팬 속도`, anchor value `<rpm> RPM`.
- **Fonts** come only from `WattlyFont.at(size, weight:)` (Pretendard). **Colors** come only from the `@Environment(\.tokens)` set (`t.text`, `t.sub`, `t.faint`, `t.line`, `t.rowBg`, `t.cardBg`, `t.rowBorder`) plus the theme-independent `Tokens.accent` / `Tokens.statusOrange`. No hard-coded hex in Swift.
- **Tests use Swift Testing**, not XCTest. Test structs mirror the existing files' style.
- **Build:** `xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
- **Test:** `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test`
- **New `.swift` files must be registered in `Wattly.xcodeproj/project.pbxproj`** — the project uses explicit references (no synchronized groups). Each file needs 4 entries modeled on an existing sibling (source files → model on `Sparkline.swift`, test files → model on `SparklineTests.swift`).
- **Helper reinstall note (not a task):** the fan-control daemon (`WattlyFanDaemon`) embeds `FanCurve` from `FanControlShared`. After Task 1 changes the anchor count, a *previously installed* helper is compiled against 4 anchors and will reject a 13-RPM configuration over XPC. Anyone with the helper installed must re-run `scripts/install-fan-helper.sh`. Fan control is opt-in/gated, so this does not block the UI work; call it out in the PR description.

---

## File Structure

**Model (shared):**
- `FanControlShared/FanCurve.swift` — MODIFY: widen `anchorsCelsius` to the 13 values `stride(40…100, by: 5)`. All validation (`init?(rawValue:)`, `Codable`) already keys off `Self.anchorsCelsius.count`, so it adapts automatically — only the anchor literal and its doc comment change.
- `Wattly/Settings/Settings.swift` — MODIFY: `Defaults.fanCurve` becomes a 13-element ramp; update the comment.

**Pure geometry (app target, `Core` group):**
- `Wattly/Core/FanCurveGeometry.swift` — CREATE: value-only plot math (plot rect, temp→x, rpm→y, y→rpm inverse w/ clamp+step-round, handle points, nearest-anchor). No SwiftUI import. Mirrors `Sparkline`.

**View (app target, `Views` group):**
- `Wattly/Views/FanCurveEditor.swift` — CREATE: `Canvas` drawing + `DragGesture` editing + per-anchor accessibility/keyboard overlay. Binds `Binding<FanCurve>`.
- `Wattly/Views/SettingsView.swift` — MODIFY: rewrite `fanCurveSection` (drop sliders + `fanCurvePreview` + `fanControlStatusText`; add header + 기본값 button + `FanCurveEditor`); delete the now-dead `fanCurveRpmBinding` / `fanCurvePreview` / `fanControlStatusText`; add `fanControlProblemText`.

**Accessibility copy (app target, `Core` group):**
- `Wattly/Core/Accessibility.swift` — MODIFY: add pure `fanAnchorLabel(celsius:)` / `fanAnchorValue(rpm:)`.

**Tests:**
- `WattlyTests/FanTests.swift` — MODIFY: the fan-curve model cases (4-anchor → 13-anchor).
- `WattlyTests/FanControlPolicyTests.swift` — MODIFY: 13-anchor curves + recomputed expectations.
- `WattlyTests/FanControlProtocolTests.swift` — MODIFY: 13-anchor curves.
- `WattlyTests/SettingsResetTests.swift` — MODIFY: 13-element pre-dirty value.
- `WattlyTests/FanCurveGeometryTests.swift` — CREATE (test target): geometry unit tests.
- `WattlyTests/AccessibilityTests.swift` — MODIFY: cases for the two new pure helpers.

---

## Task 1: Widen `FanCurve` to 13 anchors (40–100 °C, 5° steps)

**Files:**
- Modify: `FanControlShared/FanCurve.swift:7` (the `anchorsCelsius` literal + doc)
- Modify: `Wattly/Settings/Settings.swift:256-258` (`Defaults.fanCurve` + comment)
- Test: `WattlyTests/FanTests.swift` (fan-curve model cases, ~lines 89-137)
- Test: `WattlyTests/FanControlPolicyTests.swift:5,10,14`
- Test: `WattlyTests/FanControlProtocolTests.swift:8,15`
- Test: `WattlyTests/SettingsResetTests.swift:86`

**Interfaces:**
- Consumes: nothing new.
- Produces: `FanCurve.anchorsCelsius == [40,45,50,55,60,65,70,75,80,85,90,95,100]` (13 `Double`s); `Defaults.fanCurve.rpms == [1000,1200,1500,1900,2400,3000,3600,4200,4800,5500,6200,6800,7400]`. `FanCurve(rpms:)`, `.evaluate(inputCelsius:)`, `init?(rawValue:)`, `.rawValue`, `Codable` signatures are unchanged.

- [ ] **Step 1: Update the model tests to expect 13 anchors (red)**

In `WattlyTests/FanTests.swift`, replace the whole `// MARK: Fan curve (Phase B-1) — pure model` block (the six `fanCurve*` tests, currently lines ~87-137) with:

```swift
    // MARK: Fan curve — pure model (13 anchors, 40–100 °C, 5° steps)

    /// The full default ramp, reused across the model cases.
    private static let ramp: [Double] =
        [1000, 1200, 1500, 1900, 2400, 3000, 3600, 4200, 4800, 5500, 6200, 6800, 7400]

    @Test func fanCurveEvaluateFlatBelowFirstAndAboveLast() {
        let curve = FanCurve(rpms: Self.ramp)               // anchors 40…100 step 5
        #expect(curve.evaluate(inputCelsius: 20) == 1000)   // below first anchor → first rpm
        #expect(curve.evaluate(inputCelsius: 40) == 1000)   // at first anchor
        #expect(curve.evaluate(inputCelsius: 100) == 7400)  // at last anchor
        #expect(curve.evaluate(inputCelsius: 120) == 7400)  // above last → last rpm
    }

    @Test func fanCurveEvaluateInterpolatesLinearly() {
        let curve = FanCurve(rpms: Self.ramp)
        // Midpoint of the 70→75 segment (72.5 °C) between 3600 and 4200 → 3900.
        #expect(curve.evaluate(inputCelsius: 72.5) == 3900)
        // 0.2 into the 40→45 segment (41 °C) between 1000 and 1200 → 1000 + 0.2*200 = 1040.
        #expect(curve.evaluate(inputCelsius: 41) == 1040)
    }

    @Test func fanCurveRawValueRoundTrips() {
        let curve = FanCurve(rpms: [1000,1500,2000,2500,3000,3500,4000,4500,5000,5500,6000,6500,7000])
        #expect(FanCurve(rawValue: curve.rawValue)?.rpms == curve.rpms)
    }

    @Test func fanCurveRejectsMalformedRawValue() {
        #expect(FanCurve(rawValue: "") == nil)
        #expect(FanCurve(rawValue: "not json") == nil)
        #expect(FanCurve(rawValue: "[1,2,3]") == nil)        // wrong count (3, needs 13)
        #expect(FanCurve(rawValue: "[1200,2500,4500,6000]") == nil)  // the OLD 4-length is now rejected
    }

    @Test func fanCurveRejectsOutOfRangeRawValue() {
        // A huge finite value would TRAP the `Int(...)` render sites — reject the whole curve so
        // `@AppStorage` falls back to `Defaults.fanCurve`.
        #expect(FanCurve(rawValue: "[1000,1200,1500,1900,2400,3000,3600,4200,4800,5500,6200,6800,1e19]") == nil)
        #expect(FanCurve(rawValue: "[-1,1200,1500,1900,2400,3000,3600,4200,4800,5500,6200,6800,7400]") == nil)
        #expect(FanCurve(rawValue: "[1000,1200,1500,1900,2400,3000,3600,4200,4800,5500,6200,6800,8000]")?.rpms
                == [1000,1200,1500,1900,2400,3000,3600,4200,4800,5500,6200,6800,8000])
    }

    @Test func fanCurveCodableRejectsOutOfRangeCurve() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                FanCurve.self,
                from: Data("[1000,1200,1500,1900,2400,3000,3600,4200,4800,5500,6200,6800,20001]".utf8))
        }
    }

    @Test func fanCurveCodableRejectsWrongLengthCurve() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(FanCurve.self, from: Data("[1200,2500,4500]".utf8))  // 3 ≠ 13
        }
    }
```

- [ ] **Step 2: Update the policy + protocol + reset tests to 13-anchor curves (red)**

In `WattlyTests/FanControlPolicyTests.swift`, change the two curve literals and the one recomputed expectation:

```swift
    let curve = FanCurve(rpms: [1000,1200,1500,1900,2400,3000,3600,4200,4800,5500,6200,6800,7400])
    let limits = FanLimits(minimum: 2317, maximum: 6550)

    @Test func curveOnlyRaisesFloor() {
        #expect(FanControlPolicy.targetRPM(curve: curve, hottestCPU: 40, limits: limits) == 2317)
        #expect(FanControlPolicy.targetRPM(curve: curve, hottestCPU: 70, limits: limits) == 3600)  // evaluate(70)=3600
    }

    @Test func targetClampsToFanMaximum() {
        let aggressiveCurve = FanCurve(rpms: Array(repeating: 8000, count: 13))
        #expect(FanControlPolicy.targetRPM(curve: aggressiveCurve, hottestCPU: 90, limits: limits) == 6550)
    }
```

(Leave `criticalTemperatureForcesMaximum` unchanged: at `hottestCPU == 95` the policy's `hottestCPU >= criticalCelsius` branch short-circuits to `limits.maximum` (6550) *before* `curve.evaluate` is ever called (`FanControlPolicy.swift:19`), so the curve's anchor count is irrelevant to it. Every degenerate-limits case returns the safe `0` regardless. No other edits in this file.)

In `WattlyTests/FanControlProtocolTests.swift`, replace both `FanCurve(rpms: [1200, 2500, 4500, 6000])` occurrences (lines 8 and 15) with:

```swift
FanCurve(rpms: [1000,1200,1500,1900,2400,3000,3600,4200,4800,5500,6200,6800,7400])
```

In `WattlyTests/SettingsResetTests.swift:86`, replace the pre-dirty line with a 13-element non-default:

```swift
        defaults.set(FanCurve(rpms: Array(repeating: 3000, count: 13)).rawValue, forKey: StorageKey.fanCurve)
```

- [ ] **Step 3: Run the model/policy tests to verify they fail**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/FanTests -only-testing:WattlyTests/FanControlPolicyTests 2>&1 | tail -25`
Expected: FAIL — e.g. `fanCurveEvaluateFlatBelowFirstAndAboveLast` sees `evaluate` return `0` (the 13-length `ramp` is a malformed in-memory curve against the still-4 `anchorsCelsius`), and `fanCurveRejectsMalformedRawValue` fails because `[1200,2500,4500,6000]` still decodes.

- [ ] **Step 4: Widen the anchors in the model**

In `FanControlShared/FanCurve.swift`, replace lines 6-7:

```swift
    /// The fixed temperature anchors (°C), ascending — the same for every curve. 40…100 in 5°
    /// steps (13 anchors): a fine-grained curve the graph editor exposes as draggable points.
    static let anchorsCelsius: [Double] = Array(stride(from: 40.0, through: 100.0, by: 5.0))
```

- [ ] **Step 5: Update the default curve**

In `Wattly/Settings/Settings.swift`, replace lines 256-258:

```swift
    /// Fan curve: target RPMs at the fixed 40…100 °C anchors (5° steps). A gentle ramp — quiet
    /// at idle, spinning up toward the fan's top end under sustained heat.
    static let fanCurve = FanCurve(rpms: [1000, 1200, 1500, 1900, 2400, 3000, 3600, 4200, 4800, 5500, 6200, 6800, 7400])
```

- [ ] **Step 6: Run the full suite to verify green**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: PASS — all tests green (FanTests, FanControlPolicyTests, FanControlProtocolTests, SettingsResetTests included). The app still builds with the old 13 sliders rendering (they iterate `FanCurve.anchorsCelsius`, so they simply show 13 rows now).

- [ ] **Step 7: Commit**

```bash
git add FanControlShared/FanCurve.swift Wattly/Settings/Settings.swift \
        WattlyTests/FanTests.swift WattlyTests/FanControlPolicyTests.swift \
        WattlyTests/FanControlProtocolTests.swift WattlyTests/SettingsResetTests.swift
git commit -m "feat(fan): widen fan curve to 13 anchors (40-100C, 5-degree steps)"
```

---

## Task 2: Pure `FanCurveGeometry` helper

**Files:**
- Create: `Wattly/Core/FanCurveGeometry.swift`
- Create + Test: `WattlyTests/FanCurveGeometryTests.swift`
- Modify: `Wattly.xcodeproj/project.pbxproj` (register both new files)

**Interfaces:**
- Consumes: `FanCurve.anchorsCelsius` (from Task 1).
- Produces (all `static`, on `enum FanCurveGeometry`):
  - `anchorsCelsius: [Double]`, `celsiusMin: Double`, `celsiusMax: Double`
  - `rpmMin: Double` (0), `rpmMax: Double` (8000), `rpmStep: Double` (100)
  - `plotRect(in size: CGSize) -> CGRect`
  - `x(forCelsius: Double, in: CGSize) -> CGFloat`
  - `y(forRPM: Double, in: CGSize) -> CGFloat`
  - `rpm(forY: CGFloat, in: CGSize) -> Double` (inverse; clamped `rpmMin…rpmMax`, rounded to `rpmStep`)
  - `handlePoints(_ rpms: [Double], in: CGSize) -> [CGPoint]`
  - `nearestAnchorIndex(toX: CGFloat, in: CGSize) -> Int`

- [ ] **Step 1: Register the two new files in `project.pbxproj`**

The project has no synchronized groups, so both files need explicit entries. For **each** file, generate one unique 24-char uppercase-hex id for the build-file entry and one for the file reference:

```bash
openssl rand -hex 12 | tr 'a-z' 'A-Z'   # run 4× total: 2 ids per file
```

**`FanCurveGeometry.swift` (app target, `Core` group)** — model on `Sparkline.swift`. Add 4 lines, each next to the corresponding `Sparkline.swift` line (use Edit to insert after each anchor line):

- After `Wattly.xcodeproj/project.pbxproj:86` (PBXBuildFile section):
  `		<BUILDID_GEO> /* FanCurveGeometry.swift in Sources */ = {isa = PBXBuildFile; fileRef = <FILEID_GEO> /* FanCurveGeometry.swift */; };`
- After line 211 (PBXFileReference section):
  `		<FILEID_GEO> /* FanCurveGeometry.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FanCurveGeometry.swift; sourceTree = "<group>"; };`
- After line 264 (the `Core` group's children — the line holding `Sparkline.swift`):
  `				<FILEID_GEO> /* FanCurveGeometry.swift */,`
- After line 663 (the app target's `Sources` build phase — the line holding `Sparkline.swift in Sources`):
  `				<BUILDID_GEO> /* FanCurveGeometry.swift in Sources */,`

**`FanCurveGeometryTests.swift` (test target, `WattlyTests` group)** — model on `SparklineTests.swift`. Add 4 lines next to the corresponding `SparklineTests.swift` lines:

- After line 37 (PBXBuildFile):
  `		<BUILDID_GEOTEST> /* FanCurveGeometryTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = <FILEID_GEOTEST> /* FanCurveGeometryTests.swift */; };`
- After line 190 (PBXFileReference):
  `		<FILEID_GEOTEST> /* FanCurveGeometryTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FanCurveGeometryTests.swift; sourceTree = "<group>"; };`
- After line 361 (the `WattlyTests` group children — line holding `SparklineTests.swift`):
  `				<FILEID_GEOTEST> /* FanCurveGeometryTests.swift */,`
- After line 582 (the test target's `Sources` phase — line holding `SparklineTests.swift in Sources`):
  `				<BUILDID_GEOTEST> /* FanCurveGeometryTests.swift in Sources */,`

Note: line numbers drift as you insert — re-`grep -n "Sparkline"` / `grep -n "SparklineTests"` in the pbxproj between insertions to re-anchor, or insert bottom-up. Each id must be unique across the whole file (`grep` the generated id first to confirm zero hits).

- [ ] **Step 2: Create `FanCurveGeometry.swift` with placeholder returns (compiles, tests will fail on values)**

Create `Wattly/Core/FanCurveGeometry.swift`:

```swift
import CoreGraphics

/// Pure geometry for the fan-curve editor — the deterministic core, mirroring `Sparkline`:
/// value-only (no SwiftUI), so it is unit-testable without a render host. Maps the fixed
/// temperature anchors × the editable RPMs into a `Canvas` of a given size, and inverts a
/// drag's y back into a stepped, clamped RPM.
enum FanCurveGeometry {
    /// The temperature domain = the model's fixed anchors (40…100 °C, 5° steps).
    static let anchorsCelsius = FanCurve.anchorsCelsius
    static var celsiusMin: Double { anchorsCelsius.first ?? 40 }
    static var celsiusMax: Double { anchorsCelsius.last ?? 100 }

    /// The editable RPM axis. `rpmMax` is the plot ceiling (the old slider's `0…8000`); the
    /// model's own rawValue validation still permits up to 20000, so a stored curve above 8000
    /// just pins to the top of the plot.
    static let rpmMin: Double = 0
    static let rpmMax: Double = 8000
    static let rpmStep: Double = 100

    /// Plot insets inside the Canvas — room for the y labels (left) and x labels (bottom).
    static let padLeft: CGFloat = 34
    static let padRight: CGFloat = 12
    static let padTop: CGFloat = 12
    static let padBottom: CGFloat = 24   // matches the prototype's PAD.b

    static func plotRect(in size: CGSize) -> CGRect {
        CGRect(x: padLeft, y: padTop,
               width: max(0, size.width - padLeft - padRight),
               height: max(0, size.height - padTop - padBottom))
    }

    static func x(forCelsius c: Double, in size: CGSize) -> CGFloat { 0 }        // placeholder
    static func y(forRPM rpm: Double, in size: CGSize) -> CGFloat { 0 }          // placeholder
    static func rpm(forY yPix: CGFloat, in size: CGSize) -> Double { 0 }         // placeholder
    static func handlePoints(_ rpms: [Double], in size: CGSize) -> [CGPoint] { [] }  // placeholder
    static func nearestAnchorIndex(toX xPix: CGFloat, in size: CGSize) -> Int { 0 }  // placeholder
}
```

- [ ] **Step 3: Write the geometry tests (red)**

Create `WattlyTests/FanCurveGeometryTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import Wattly

struct FanCurveGeometryTests {
    // A fixed render size → plotRect = (34, 12, 266, 154): minX 34, maxX 300, minY 12, maxY 166.
    private let size = CGSize(width: 312, height: 190)
    private let ramp: [Double] =
        [1000, 1200, 1500, 1900, 2400, 3000, 3600, 4200, 4800, 5500, 6200, 6800, 7400]

    @Test func plotRectInsetsTheCanvas() {
        let r = FanCurveGeometry.plotRect(in: size)
        #expect(r.minX == 34);  #expect(r.maxX == 300)
        #expect(r.minY == 12);  #expect(r.maxY == 166)
    }

    @Test func handlePointsSpanPlotWidthMonotonically() {
        let pts = FanCurveGeometry.handlePoints(ramp, in: size)
        #expect(pts.count == 13)
        #expect(pts.first!.x == 34)     // first anchor at plot left
        #expect(pts.last!.x == 300)     // last anchor at plot right
        #expect(zip(pts, pts.dropFirst()).allSatisfy { $0.x < $1.x })  // strictly increasing x
    }

    @Test func yMapsRPMAxisToPlotHeightInverted() {
        #expect(FanCurveGeometry.y(forRPM: 8000, in: size) == 12)   // max rpm → plot top
        #expect(FanCurveGeometry.y(forRPM: 0, in: size) == 166)     // min rpm → plot bottom
    }

    @Test func rpmForYRoundTripsOnStepBoundary() {
        let y = FanCurveGeometry.y(forRPM: 3000, in: size)
        #expect(FanCurveGeometry.rpm(forY: y, in: size) == 3000)
    }

    @Test func rpmForYClampsOutsidePlot() {
        #expect(FanCurveGeometry.rpm(forY: -50, in: size) == 8000)   // above the top → max
        #expect(FanCurveGeometry.rpm(forY: 999, in: size) == 0)      // below the bottom → min
    }

    @Test func rpmForYRoundsToStep() {
        // Any y inside the plot must resolve to a whole multiple of the 100-RPM step.
        for y in stride(from: CGFloat(12), through: 166, by: 7) {
            #expect(FanCurveGeometry.rpm(forY: y, in: size).truncatingRemainder(dividingBy: 100) == 0)
        }
    }

    @Test func nearestAnchorIndexPicksClosestColumn() {
        let x70 = FanCurveGeometry.x(forCelsius: 70, in: size)
        #expect(FanCurveGeometry.nearestAnchorIndex(toX: x70, in: size) == 6)  // 70 °C is anchor 6
        #expect(FanCurveGeometry.nearestAnchorIndex(toX: -100, in: size) == 0) // far left → first
        #expect(FanCurveGeometry.nearestAnchorIndex(toX: 9999, in: size) == 12)// far right → last
    }
}
```

- [ ] **Step 4: Run the geometry tests to verify they fail**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/FanCurveGeometryTests 2>&1 | tail -25`
Expected: FAIL — placeholder returns give wrong values (e.g. `handlePointsSpanPlotWidthMonotonically` sees `pts.count == 0`). If instead it fails to *compile* with "cannot find FanCurveGeometry", the pbxproj registration in Step 1 is wrong — fix that first.

- [ ] **Step 5: Implement the real geometry**

In `Wattly/Core/FanCurveGeometry.swift`, replace the five placeholder methods:

```swift
    static func x(forCelsius c: Double, in size: CGSize) -> CGFloat {
        let r = plotRect(in: size)
        let span = celsiusMax - celsiusMin
        guard span > 0 else { return r.minX }
        return r.minX + CGFloat((c - celsiusMin) / span) * r.width
    }

    static func y(forRPM rpm: Double, in size: CGSize) -> CGFloat {
        let r = plotRect(in: size)
        let span = rpmMax - rpmMin
        guard span > 0 else { return r.maxY }
        return r.maxY - CGFloat((rpm - rpmMin) / span) * r.height
    }

    /// Inverse of `y(forRPM:)`, clamped to `rpmMin…rpmMax` and rounded to `rpmStep`.
    static func rpm(forY yPix: CGFloat, in size: CGSize) -> Double {
        let r = plotRect(in: size)
        guard r.height > 0 else { return rpmMin }
        let frac = Double((r.maxY - yPix) / r.height)
        let raw = rpmMin + frac * (rpmMax - rpmMin)
        let stepped = (raw / rpmStep).rounded() * rpmStep
        return min(max(stepped, rpmMin), rpmMax)
    }

    static func handlePoints(_ rpms: [Double], in size: CGSize) -> [CGPoint] {
        zip(anchorsCelsius, rpms).map { c, rpm in
            CGPoint(x: x(forCelsius: c, in: size), y: y(forRPM: rpm, in: size))
        }
    }

    /// Index of the anchor whose column is nearest `xPix` — the anchor a drag at `xPix` edits.
    static func nearestAnchorIndex(toX xPix: CGFloat, in size: CGSize) -> Int {
        anchorsCelsius.indices.min(by: {
            abs(x(forCelsius: anchorsCelsius[$0], in: size) - xPix)
                < abs(x(forCelsius: anchorsCelsius[$1], in: size) - xPix)
        }) ?? 0
    }
```

- [ ] **Step 6: Run the geometry tests to verify they pass**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/FanCurveGeometryTests 2>&1 | tail -15`
Expected: PASS (7 tests).

- [ ] **Step 7: Commit**

```bash
git add Wattly/Core/FanCurveGeometry.swift WattlyTests/FanCurveGeometryTests.swift Wattly.xcodeproj/project.pbxproj
git commit -m "feat(fan): add pure FanCurveGeometry plot helper"
```

---

## Task 3: `FanCurveEditor` view + wire into settings (drag + draw)

**Files:**
- Create: `Wattly/Views/FanCurveEditor.swift`
- Modify: `Wattly/Views/SettingsView.swift` (`fanCurveSection` ~241-278; delete `fanCurvePreview` ~281-300, `fanControlStatusText` ~302-315, `fanCurveRpmBinding` ~408-417)
- Modify: `Wattly.xcodeproj/project.pbxproj` (register `FanCurveEditor.swift`)

**Interfaces:**
- Consumes: `FanCurveGeometry.*` (Task 2), `FanCurve` binding, `Tokens`/`WattlyFont`.
- Produces: `FanCurveEditor(curve: Binding<FanCurve>, currentCPU: Double?)`. `SettingsView.fanControlProblemText: String?`.
- Note: `Accessibility.fanAnchorLabel` / `fanAnchorValue` are referenced here but **land in Task 4** — this task's `FanCurveEditor` does NOT yet include the accessibility overlay, so it must not reference them. The overlay is added in Task 4.

- [ ] **Step 1: Register `FanCurveEditor.swift` in `project.pbxproj`**

App target, `Views` group — model on `Sparkline.swift`'s 4 entries exactly as in Task 2 Step 1, but put the group-children line under the **`Views`** group. Generate 2 fresh unique ids (`openssl rand -hex 12 | tr 'a-z' 'A-Z'`).

- After the PBXBuildFile block (near line 86):
  `		<BUILDID_ED> /* FanCurveEditor.swift in Sources */ = {isa = PBXBuildFile; fileRef = <FILEID_ED> /* FanCurveEditor.swift */; };`
- After the PBXFileReference block (near line 211):
  `		<FILEID_ED> /* FanCurveEditor.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FanCurveEditor.swift; sourceTree = "<group>"; };`
- Inside the **`Views`** group children (the group whose `path = Views`; `grep -n "path = Views" project.pbxproj`, then find its `children = (` list just above and add):
  `				<FILEID_ED> /* FanCurveEditor.swift */,`
- In the **app** target's Sources phase (the phase containing `Sparkline.swift in Sources`, near line 663):
  `				<BUILDID_ED> /* FanCurveEditor.swift in Sources */,`

- [ ] **Step 2: Create `FanCurveEditor.swift` (drawing + drag only)**

Create `Wattly/Views/FanCurveEditor.swift`:

```swift
import SwiftUI

/// The interactive fan-curve editor — replaces the four RPM sliders. A `Canvas` draws the grid,
/// the piecewise-linear curve + area fill, the per-anchor handles, and the live-CPU marker; a
/// `DragGesture` moves the nearest anchor's RPM. All plot math lives in the pure (tested)
/// `FanCurveGeometry`; this view only renders it and wires the gesture. VoiceOver + keyboard
/// adjustment of each anchor is layered on in the accessibility overlay (added separately).
struct FanCurveEditor: View {
    @Binding var curve: FanCurve
    var currentCPU: Double?
    @Environment(\.tokens) private var t

    @State private var dragIndex: Int?

    private static let viewHeight: CGFloat = 150

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            canvas(size)
                .contentShape(Rectangle())
                .gesture(drag(in: size))
        }
        .frame(height: Self.viewHeight)
    }

    // MARK: Drawing

    private func canvas(_ size: CGSize) -> some View {
        Canvas { ctx, _ in
            let rect = FanCurveGeometry.plotRect(in: size)

            // horizontal grid + y labels (0…8k every 2k)
            for rpm in stride(from: 0.0, through: FanCurveGeometry.rpmMax, by: 2000) {
                let y = FanCurveGeometry.y(forRPM: rpm, in: size)
                var g = Path(); g.move(to: CGPoint(x: rect.minX, y: y)); g.addLine(to: CGPoint(x: rect.maxX, y: y))
                ctx.stroke(g, with: .color(t.line), lineWidth: 1)
                ctx.draw(Text("\(Int(rpm / 1000))k").font(WattlyFont.at(9.5, weight: .medium)).foregroundColor(t.faint),
                         at: CGPoint(x: rect.minX - 6, y: y), anchor: .trailing)
            }

            // vertical gridline at every anchor; label only every 10°
            for c in FanCurveGeometry.anchorsCelsius {
                let x = FanCurveGeometry.x(forCelsius: c, in: size)
                let isMajor = c.truncatingRemainder(dividingBy: 10) == 0
                var g = Path(); g.move(to: CGPoint(x: x, y: rect.minY)); g.addLine(to: CGPoint(x: x, y: rect.maxY))
                ctx.stroke(g, with: .color(t.line.opacity(isMajor ? 1 : 0.55)), lineWidth: 1)
                if isMajor {
                    ctx.draw(Text("\(Int(c))°").font(WattlyFont.at(9.5, weight: .medium)).foregroundColor(t.faint),
                             at: CGPoint(x: x, y: rect.maxY + 12), anchor: .center)
                }
            }

            let pts = FanCurveGeometry.handlePoints(curve.rpms, in: size)
            guard pts.count == FanCurveGeometry.anchorsCelsius.count else { return }

            // area fill under the curve
            var area = Path()
            area.move(to: CGPoint(x: pts[0].x, y: rect.maxY))
            for p in pts { area.addLine(to: p) }
            area.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: rect.maxY))
            area.closeSubpath()
            ctx.fill(area, with: .color(Tokens.accent.opacity(0.14)))

            // the curve polyline
            var line = Path(); line.addLines(pts)
            ctx.stroke(line, with: .color(Tokens.accent), style: StrokeStyle(lineWidth: 2, lineJoin: .round))

            // live-CPU marker (dashed vertical + dot on the curve + label)
            if let cpu = currentCPU, cpu >= FanCurveGeometry.celsiusMin, cpu <= FanCurveGeometry.celsiusMax {
                let x = FanCurveGeometry.x(forCelsius: cpu, in: size)
                let yv = FanCurveGeometry.y(forRPM: curve.evaluate(inputCelsius: cpu), in: size)
                var m = Path(); m.move(to: CGPoint(x: x, y: rect.minY)); m.addLine(to: CGPoint(x: x, y: rect.maxY))
                ctx.stroke(m, with: .color(Tokens.statusOrange), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                ctx.fill(Path(ellipseIn: CGRect(x: x - 3, y: yv - 3, width: 6, height: 6)), with: .color(Tokens.statusOrange))
                ctx.draw(Text("\(Int(cpu.rounded()))°C").font(WattlyFont.at(9.5, weight: .bold)).foregroundColor(Tokens.statusOrange),
                         at: CGPoint(x: x + 5, y: rect.minY + 2), anchor: .topLeading)
            }

            // handle dots (filled when the anchor is being dragged)
            for (i, p) in pts.enumerated() {
                let box = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
                ctx.fill(Path(ellipseIn: box), with: .color(i == dragIndex ? Tokens.accent : t.rowBg))
                ctx.stroke(Path(ellipseIn: box), with: .color(Tokens.accent), lineWidth: 2.5)
            }
        }
    }

    // MARK: Editing

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let i = dragIndex ?? FanCurveGeometry.nearestAnchorIndex(toX: value.startLocation.x, in: size)
                dragIndex = i
                setRPM(FanCurveGeometry.rpm(forY: value.location.y, in: size), at: i)
            }
            .onEnded { _ in dragIndex = nil }
    }

    private func setRPM(_ rpm: Double, at index: Int) {
        guard curve.rpms.indices.contains(index) else { return }
        var next = curve
        next.rpms[index] = rpm
        curve = next
    }
}

#Preview {
    struct Harness: View {
        @State var curve = FanCurve(rpms: [1000,1200,1500,1900,2400,3000,3600,4200,4800,5500,6200,6800,7400])
        var body: some View {
            FanCurveEditor(curve: $curve, currentCPU: 62)
                .padding()
                .environment(\.tokens, .dark)
                .frame(width: 320)
        }
    }
    return Harness()
}
```

- [ ] **Step 3: Rewrite `fanCurveSection` in `SettingsView.swift`**

Replace the `fanCurveSection` computed property (lines ~241-278) with:

```swift
    private var fanCurveSection: some View {
        SettingsSection(title: "팬 커브") {
            SettingsCard(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsToggleRow(isOn: $fanControlEnabled, divider: true) {
                        VStack(alignment: .leading, spacing: 2) {
                            rowTitle("팬 커브 실제 적용")
                            Text("Wattly가 macOS 기본 최소 RPM 이상으로만 팬을 제어합니다. Macs Fan Control은 종료해야 합니다.")
                                .font(WattlyFont.at(11.5, weight: .regular))
                                .foregroundStyle(t.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let problem = fanControlProblemText {
                        Text(problem)
                            .font(WattlyFont.at(11.5, weight: .regular))
                            .foregroundStyle(t.faint)
                    }
                    HStack {
                        Text("온도 → 팬 속도")
                            .font(WattlyFont.at(12, weight: .semibold))
                            .foregroundStyle(t.sub)
                        Spacer()
                        Button { fanCurve = Defaults.fanCurve } label: {
                            Text("기본값")
                                .font(WattlyFont.at(11, weight: .semibold))
                                .foregroundStyle(t.sub)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6).fill(t.cardBg))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(t.rowBorder, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("팬 커브 기본값으로 되돌리기")
                    }
                    FanCurveEditor(curve: $fanCurve, currentCPU: currentHottestCPU)
                }
            }
        }
    }

    /// Only the *actionable* fan-control states get a line under the toggle. The persistent
    /// "적용 중"/"자동 제어" copy was dropped (graph redesign 2026-07-15), but a missing helper or
    /// a control failure still needs to surface — so those (and the transient 연결 중) show, and
    /// the two nominal states show nothing.
    private var fanControlProblemText: String? {
        switch fanControl.status.mode {
        case .unavailable: return "도우미 미설치 — scripts/install-fan-helper.sh 실행"
        case .engaging:    return "수동 제어 연결 중"
        case .failed:      return "제어 실패 — macOS 자동 제어로 복귀"
        case .automatic, .controlling: return nil
        }
    }
```

- [ ] **Step 4: Delete the now-dead helpers in `SettingsView.swift`**

Remove these three members entirely (they are no longer referenced):
- `private var fanCurvePreview: some View { … }` (the old preview block, ~lines 281-300)
- `private var fanControlStatusText: String { … }` (the old always-on status, ~lines 302-315)
- `private func fanCurveRpmBinding(_ index: Int) -> Binding<Double> { … }` (the old per-slider binding, ~lines 406-417)

Keep `currentHottestCPU` — the editor consumes it.

- [ ] **Step 5: Build and run to verify the graph works**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`. If it fails to find `FanCurveEditor`, re-check the Task 3 Step 1 pbxproj entries.

Then launch and drive the UI:
```bash
open "$(xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/Wattly.app"
```
Open the menubar popover → Settings (gear) → 팬 커브 section. Verify by observation:
- The graph renders: 0–8k y grid, 40/50/…/100 x labels, blue curve + fill, 13 handle dots, orange dashed CPU marker (if CPU temp is live).
- Dragging a handle up/down changes its RPM and re-shapes the curve; the dragged dot fills solid.
- Clicking **기본값** snaps the curve back to the default ramp.
- Toggling **팬 커브 실제 적용** off/on works; no persistent "적용 중" line appears in the nominal state.

- [ ] **Step 6: Commit**

```bash
git add Wattly/Views/FanCurveEditor.swift Wattly/Views/SettingsView.swift Wattly.xcodeproj/project.pbxproj
git commit -m "feat(fan): replace fan-curve sliders with draggable graph editor"
```

---

## Task 4: VoiceOver + keyboard adjustment for each anchor

**Files:**
- Modify: `Wattly/Core/Accessibility.swift` (add two pure helpers)
- Test: `WattlyTests/AccessibilityTests.swift` (cases for the two helpers)
- Modify: `Wattly/Views/FanCurveEditor.swift` (add the focusable per-anchor overlay + keyboard + adjustable actions)

**Interfaces:**
- Consumes: `FanCurveGeometry.handlePoints/rpmStep/rpmMin/rpmMax` (Task 2), the `curve` binding (Task 3).
- Produces: `Accessibility.fanAnchorLabel(celsius: Double) -> String`, `Accessibility.fanAnchorValue(rpm: Double) -> String`.

- [ ] **Step 1: Write the accessibility-copy tests (red)**

In `WattlyTests/AccessibilityTests.swift`, add these cases (inside the `AccessibilityTests` struct):

```swift
    // MARK: Fan-curve anchor copy

    @Test func fanAnchorLabelSpeaksTempAndRole() {
        #expect(Accessibility.fanAnchorLabel(celsius: 40) == "40°C 팬 속도")
        #expect(Accessibility.fanAnchorLabel(celsius: 100) == "100°C 팬 속도")
    }

    @Test func fanAnchorValueSpeaksWholeRPM() {
        #expect(Accessibility.fanAnchorValue(rpm: 1200) == "1200 RPM")
        #expect(Accessibility.fanAnchorValue(rpm: 3049.6) == "3050 RPM")  // rounds defensively
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/AccessibilityTests 2>&1 | tail -20`
Expected: FAIL to compile — "cannot find 'fanAnchorLabel'/'fanAnchorValue' in scope".

- [ ] **Step 3: Add the pure helpers to `Accessibility.swift`**

In `Wattly/Core/Accessibility.swift`, add to the `Accessibility` enum (near the other `static func`s):

```swift
    /// Fan-curve editor: the spoken label for one temperature anchor's handle ("40°C 팬 속도")
    /// and its value ("1200 RPM"). Pure so the copy is table-tested (issue 15), matching the
    /// symbol-based unit style of the rest of this file.
    static func fanAnchorLabel(celsius: Double) -> String { "\(Int(celsius))°C 팬 속도" }
    static func fanAnchorValue(rpm: Double) -> String { "\(Int(rpm.rounded())) RPM" }
```

- [ ] **Step 4: Run to verify they pass**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/AccessibilityTests 2>&1 | tail -15`
Expected: PASS (existing cases + 2 new).

- [ ] **Step 5: Add the focusable per-anchor overlay to `FanCurveEditor.swift`**

Add a `@FocusState` and the overlay, and reflect keyboard focus in the handle fill. Make three edits:

(a) Add the focus state below `@State private var dragIndex`:

```swift
    @FocusState private var focusedAnchor: Int?
```

(b) In `body`, wrap the canvas + overlay in a `ZStack` so the accessibility handles sit on top. Replace the `GeometryReader` body:

```swift
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                canvas(size)
                anchorControls(size)
            }
            .contentShape(Rectangle())
            .gesture(drag(in: size))
        }
        .frame(height: Self.viewHeight)
```

(c) Add the overlay + nudge helper (and let the handle dot also fill when keyboard-focused). Append these methods to the struct:

```swift
    // MARK: Accessibility + keyboard

    /// One invisible focusable control per anchor, positioned on its handle. Gives VoiceOver an
    /// adjustable action (up/down = ±`rpmStep`) and hardware arrow keys the same effect when the
    /// handle is focused — restoring the parity the sliders had (issue 15). Pointer drags still
    /// go to the container gesture; these clear views carry no gesture of their own.
    private func anchorControls(_ size: CGSize) -> some View {
        let pts = FanCurveGeometry.handlePoints(curve.rpms, in: size)
        return ForEach(Array(FanCurveGeometry.anchorsCelsius.enumerated()), id: \.offset) { i, c in
            Color.clear
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .position(pts.indices.contains(i) ? pts[i] : .zero)
                .focusable()
                .focused($focusedAnchor, equals: i)
                .accessibilityElement()
                .accessibilityLabel(Accessibility.fanAnchorLabel(celsius: c))
                .accessibilityValue(Accessibility.fanAnchorValue(rpm: curve.rpms.indices.contains(i) ? curve.rpms[i] : 0))
                .accessibilityAdjustableAction { direction in
                    nudge(direction == .increment ? FanCurveGeometry.rpmStep : -FanCurveGeometry.rpmStep, at: i)
                }
                .onKeyPress(.upArrow)   { nudge(FanCurveGeometry.rpmStep, at: i); return .handled }
                .onKeyPress(.downArrow) { nudge(-FanCurveGeometry.rpmStep, at: i); return .handled }
        }
    }

    private func nudge(_ delta: Double, at index: Int) {
        guard curve.rpms.indices.contains(index) else { return }
        let clamped = min(max(curve.rpms[index] + delta, FanCurveGeometry.rpmMin), FanCurveGeometry.rpmMax)
        setRPM(clamped, at: index)
    }
```

(d) In `canvas(_:)`, make the handle also fill when keyboard-focused — change the handle-dots loop's fill test from `i == dragIndex` to:

```swift
                ctx.fill(Path(ellipseIn: box), with: .color(i == dragIndex || i == focusedAnchor ? Tokens.accent : t.rowBg))
```

- [ ] **Step 6: Build, run the full suite, and verify a11y interactively**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: PASS — full suite green.

Then build+launch (same commands as Task 3 Step 5) and verify in the 팬 커브 section:
- **Pointer:** dragging a handle still moves it (the overlay did not steal the drag). If a drag over a handle no longer works, the focusable overlay is intercepting — see the note below.
- **Keyboard:** Tab into the graph; each press moves focus to the next anchor (its dot fills). ↑/↓ change that anchor's RPM by 100 and re-shape the curve.
- **VoiceOver** (⌘F5): focusing a handle announces e.g. "40°C 팬 속도, 1200 RPM, 조정 가능"; VO up/down (⌃⌥⇧↑/↓) changes the value.

Note if pointer drag regresses: give the container gesture priority so the clear controls never swallow a drag — change `.gesture(drag(in: size))` on the `ZStack` to `.highPriorityGesture(drag(in: size))`. Re-verify all three input modes.

- [ ] **Step 7: Commit**

```bash
git add Wattly/Core/Accessibility.swift WattlyTests/AccessibilityTests.swift Wattly/Views/FanCurveEditor.swift
git commit -m "feat(fan): add VoiceOver + keyboard adjustment to fan-curve editor"
```

---

## Self-Review

**Spec coverage** (the four prototype-settled requirements + the accessibility decision):
- *Sliders → draggable graph, x=temp / y=fan* → Task 3 (`FanCurveEditor` Canvas + `DragGesture`), geometry in Task 2.
- *5° steps, 40–100 °C (13 anchors)* → Task 1 (`anchorsCelsius = stride(40…100, 5)`), default + all tests updated.
- *Remove the status / preview text* → Task 3 Step 4 deletes `fanCurvePreview` + `fanControlStatusText`; Step 3 keeps only actionable problem states via `fanControlProblemText`.
- *"기본값" reset button replacing the drag hint* → Task 3 Step 3 (`Button { fanCurve = Defaults.fanCurve }`).
- *Full VoiceOver + keyboard (chosen at checkpoint)* → Task 4 (adjustable action + `.onKeyPress` + focus).

**Placeholder scan:** every code step carries complete code; the only intentional placeholders are the `FanCurveGeometry` method stubs in Task 2 Step 2, which exist to make the red test compile and are fully replaced in Step 5. No "TBD"/"add error handling"/"similar to" left.

**Type consistency:** `FanCurveGeometry` method names/signatures in the Task 2 Interfaces block match their call sites in Task 3 (`plotRect`, `x(forCelsius:in:)`, `y(forRPM:in:)`, `rpm(forY:in:)`, `handlePoints(_:in:)`, `nearestAnchorIndex(toX:in:)`) and Task 4 (`rpmStep`, `rpmMin`, `rpmMax`, `handlePoints`). `Accessibility.fanAnchorLabel(celsius:)` / `fanAnchorValue(rpm:)` defined in Task 4 Step 3 match their Task 4 Step 5 call sites. `setRPM(_:at:)` defined in Task 3 is reused by `nudge` in Task 4. `Defaults.fanCurve` (13 elements) from Task 1 is what the 기본값 button and reset test assert.

**Ordering:** Task 1 leaves a green, buildable app (old sliders now render 13 rows). Task 2 adds tested geometry with no UI change. Task 3 swaps in the graph. Task 4 layers accessibility on the working graph. Each task ends independently testable/committable.
