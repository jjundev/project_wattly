# Zero-RPM Fan Curve Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Wattly curve command a physically verified 0 RPM on this MacBook Pro (Mac17,2 / Apple M5) through a visible Zero Fan zone, while preserving the existing automatic-release and critical-temperature safeguards.

**Architecture:** Keep the SMC write adapter unchanged because its `F<n>Tg` float writer already accepts `0`. Replace the policy's ambiguous `0` error sentinel with an optional target, then give the daemon a per-fan zero-RPM hysteresis state: a curve value of zero enters direct 0 RPM only below 48°C and remains there only until 55°C; all other curve values retain the reported `F<n>Mn…F<n>Mx` clamp. Extend the existing editor rather than add a second curve control: it must draw 48–55°C as a labelled state-hold band and Settings must explain that this band is not a single temperature-to-RPM mapping.

**Tech Stack:** Swift 6, Swift Testing, SwiftUI, IOKit/AppleSMC, Xcode/xcodebuild, macOS launchd privileged helper.

## Global Constraints

- Support macOS 14.0+ and arm64 Apple Silicon only; add no third-party dependency.
- Keep all writable AppleSMC operations inside `/Library/PrivilegedHelperTools/dev.jjundev.WattlyFanDaemon`; the app process remains read-only.
- Preserve the existing safety exits: 95°C or above commands `F<n>Mx`; unavailable CPU telemetry, SMC write failure, disabled control, sleep, process termination, and a 15-second missed heartbeat return every owned fan to automatic mode.
- A literal curve target of `0` is valid only below the direct-zero hysteresis boundary; it is not an invalid-input sentinel.
- Enter direct 0 RPM only below 48°C; while already at 0 RPM, leave it at 55°C or above by commanding at least `F<n>Mn`.
- Treat 48–55°C as a visible Zero Fan state-hold band only when the evaluated curve target is exactly `0`: a stopped fan remains stopped there; a spinning fan remains at least `F<n>Mn`. Do not represent this band as a single-valued curve result.
- Preserve a nonzero curve target exactly when it lies inside `F<n>Mn…F<n>Mx`; otherwise clamp it to that range.
- Physical acceptance is limited to this verified local machine: MacBook Pro `Mac17,2`, Apple M5, macOS 26.6.1, one fan, `F0md`, `F0Mn=2317`, `F0Mx=6550`.
- Do not run Macs Fan Control concurrently with Wattly.

---

## File Structure

| Path | Responsibility |
|---|---|
| `FanControlShared/FanControlPolicy.swift` | Pure target selection, including invalid-input distinction and 48°C/55°C direct-zero hysteresis. |
| `FanControlShared/FanControlEngine.swift` | Retains zero-state independently per fan and sends valid `0` targets through the already-existing hardware interface. |
| `WattlyTests/FanControlPolicyTests.swift` | Unit-level truth table for direct-zero entry, retention, exit, critical override, clamp, and invalid inputs. |
| `WattlyTests/FanControlEngineTests.swift` | Daemon behavior tests proving a zero target is sent and later exits to the hardware minimum. |
| `Wattly/Core/FanCurveGeometry.swift` | Pure layout constants and rectangle for the visible 48–55°C Zero Fan state-hold band. |
| `WattlyTests/FanCurveGeometryTests.swift` | Exact geometry test for the 48°C entry and 55°C exit boundaries. |
| `Wattly/Views/FanCurveEditor.swift` | Renders the shaded state-hold band and both boundary lines behind the editable curve. |
| `Wattly/Views/SettingsView.swift` | Accurate Korean explanation that makes Zero Fan policy and non-single-valued band visible to the user. |
| `docs/fan-control-local-install.md` | Installation and on-device acceptance record; replaces the obsolete universal minimum-RPM claim. |

## Decision Checkpoint

Resolved by the user's plan-revision request: use an explicit Zero Fan zone, not a hidden override. The fixed 48°C enter / 55°C exit hysteresis remains the smallest safe control mechanism because it prevents one-second target flapping near a single threshold. It requires no persisted preference or second curve, but its stateful 48–55°C behavior must be rendered and explained before implementation can call the existing editor a fan curve.

### Task 1: Make zero a valid policy target

**Files:**
- Modify: `FanControlShared/FanControlPolicy.swift:8-21`
- Modify: `FanControlShared/FanControlEngine.swift:175-182`
- Test: `WattlyTests/FanControlPolicyTests.swift:4-61`

**Interfaces:**
- Consumes: `FanCurve.evaluate(inputCelsius:) -> Double` and `FanLimits(minimum:maximum:)`.
- Produces: `FanControlPolicy.targetRPM(curve:hottestCPU:limits:wasZeroRPM:) -> Double?`, where `nil` means invalid telemetry/limits and `0` is a valid direct-zero command.

- [ ] **Step 1: Write the failing policy tests**

Replace the current `curveOnlyRaisesFloor` and invalid-input expectations with these tests, while retaining the maximum-clamp and heartbeat tests:

```swift
@Test func targetClampsToFanMaximum() {
    let aggressiveCurve = FanCurve(rpms: Array(repeating: 8000, count: 15))
    #expect(FanControlPolicy.targetRPM(curve: aggressiveCurve, hottestCPU: 90,
                                       limits: limits, wasZeroRPM: false) == 6550)
}

@Test func zeroCurveEntersAndExitsWithHysteresis() {
    let zeroCurve = FanCurve(rpms: Array(repeating: 0, count: FanCurve.anchorsCelsius.count))
    #expect(FanControlPolicy.targetRPM(curve: zeroCurve, hottestCPU: 47.9,
                                       limits: limits, wasZeroRPM: false) == 0)
    #expect(FanControlPolicy.targetRPM(curve: zeroCurve, hottestCPU: 48.0,
                                       limits: limits, wasZeroRPM: false) == 2317)
    #expect(FanControlPolicy.targetRPM(curve: zeroCurve, hottestCPU: 54.9,
                                       limits: limits, wasZeroRPM: true) == 0)
    #expect(FanControlPolicy.targetRPM(curve: zeroCurve, hottestCPU: 55.0,
                                       limits: limits, wasZeroRPM: true) == 2317)
}

@Test func nonzeroCurveStillUsesTheHardwareMinimum() {
    #expect(FanControlPolicy.targetRPM(curve: curve, hottestCPU: 40,
                                       limits: limits, wasZeroRPM: false) == 2317)
}

@Test func invalidPolicyInputsReturnNilNotAZeroCommand() {
    #expect(FanControlPolicy.targetRPM(curve: curve, hottestCPU: .nan,
                                       limits: limits, wasZeroRPM: false) == nil)
    #expect(FanControlPolicy.targetRPM(curve: curve, hottestCPU: 70,
                                       limits: .init(minimum: 0, maximum: 6550),
                                       wasZeroRPM: false) == nil)
}

@Test func malformedCurveReturnsNilNotAZeroCommand() {
    let malformedCurve = FanCurve(rpms: [])
    #expect(FanControlPolicy.targetRPM(curve: malformedCurve, hottestCPU: 40,
                                       limits: limits, wasZeroRPM: false) == nil)
}

@Test func criticalTemperatureOverridesAMalformedCurve() {
    let malformedCurve = FanCurve(rpms: [])
    #expect(FanControlPolicy.targetRPM(curve: malformedCurve, hottestCPU: 95,
                                       limits: limits, wasZeroRPM: false) == 6550)
}

@Test func criticalTemperatureOverridesAZeroCurve() {
    let zeroCurve = FanCurve(rpms: Array(repeating: 0, count: FanCurve.anchorsCelsius.count))
    #expect(FanControlPolicy.targetRPM(curve: zeroCurve, hottestCPU: 95,
                                       limits: limits, wasZeroRPM: true) == 6550)
}
```

Update the retained critical-temperature test call to the same signature:

```swift
#expect(FanControlPolicy.targetRPM(curve: curve, hottestCPU: 95,
                                   limits: limits, wasZeroRPM: false) == 6550)
```

- [ ] **Step 2: Run the suite to verify the new tests fail**

Run:

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
```

Expected: FAIL because `targetRPM` has no `wasZeroRPM` parameter and returns a non-optional `Double`.

- [ ] **Step 3: Implement the optional zero-aware policy**

Replace `targetRPM` in `FanControlShared/FanControlPolicy.swift` with this implementation and add the two constants beside `criticalCelsius`:

```swift
static let zeroRPMEnterCelsius = 48.0
static let zeroRPMExitCelsius = 55.0

static func targetRPM(curve: FanCurve,
                      hottestCPU: Double,
                      limits: FanLimits,
                      wasZeroRPM: Bool) -> Double? {
    guard hottestCPU.isFinite,
          limits.minimum.isFinite,
          limits.maximum.isFinite,
          limits.minimum > 0,
          limits.maximum >= limits.minimum else { return nil }
    if hottestCPU >= criticalCelsius { return limits.maximum }

    guard curve.rpms.count == FanCurve.anchorsCelsius.count else { return nil }

    let curveTarget = curve.evaluate(inputCelsius: hottestCPU)
    guard curveTarget.isFinite else { return nil }
    if curveTarget == 0 {
        let boundary = wasZeroRPM ? zeroRPMExitCelsius : zeroRPMEnterCelsius
        if hottestCPU < boundary { return 0 }
    }
    return min(max(curveTarget, limits.minimum), limits.maximum)
}
```

The length check is required before `evaluate`: its compatibility behavior returns `0` for a malformed in-memory curve, but malformed data must remain invalid (`nil`) rather than become a direct zero command. Put the check after the validated limits and the 95°C critical override: at or above 95°C, hardware maximum must win even when a persisted or in-memory curve is malformed. Do not add a capability database, a new preference, or a second SMC interface. An unsupported Mac can safely clamp the valid 0 target in firmware; this plan records physical acceptance only for Mac17,2.

Make the minimum, compilation-preserving caller migration in the existing engine loop in this task. It deliberately preserves the old no-zero engine behavior until Task 2 adds per-fan state:

```swift
let target = FanControlPolicy.targetRPM(curve: configuration.curve,
                                        hottestCPU: hottestCPU,
                                        limits: try hardware.limits(for: fan.index),
                                        wasZeroRPM: false)
guard let target, target.isFinite, target > 0 else {
    throw FanControlFailure.invalidTarget(fan.index)
}
```

Do not add `zeroRPMFans`, accept `target == 0`, or change the SMC write path in Task 1; those remain Task 2. This one call-site migration avoids a legacy overload that would reintroduce the old `0`-as-error ambiguity and keeps the Task 1 full suite buildable.

- [ ] **Step 4: Run the policy regression suite**

Run:

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
```

Expected: PASS; output includes `FanControlPolicyTests` with the new zero-entry, retention, exit, critical override of both valid and malformed curves, malformed-curve, and invalid-input cases.

- [ ] **Step 5: Commit the policy change**

```bash
git add FanControlShared/FanControlPolicy.swift FanControlShared/FanControlEngine.swift WattlyTests/FanControlPolicyTests.swift
git commit -m "feat(fan): allow safe zero rpm curve targets"
```

### Task 2: Carry a valid zero target through the daemon

**Files:**
- Modify: `FanControlShared/FanControlEngine.swift:36-46,175-185,208-220`
- Test: `WattlyTests/FanControlEngineTests.swift:5-220`

**Interfaces:**
- Consumes: `FanControlPolicy.targetRPM(curve:hottestCPU:limits:wasZeroRPM:) -> Double?` from Task 1 and the existing `FanControlHardware.setTarget(index:rpm:) throws`.
- Produces: per-fan direct-zero hysteresis state held only for the active manual-control session; `FanControlHardware.setTarget(index: 0, rpm: 0)` is invoked only for a valid low-temperature zero curve.

- [ ] **Step 1: Write the failing daemon transition test**

Add this test before the existing reconfiguration test in `WattlyTests/FanControlEngineTests.swift`:

```swift
@Test func zeroCurveCommandsZeroThenLeavesZeroAtTheExitBoundary() throws {
    let hw = FakeFanControlHardware(modeKey: "F0md", hasFtst: false, hottestCPU: 47,
                                    limits: FanLimits(minimum: 2317, maximum: 6550))
    let engine = FanControlEngine(hardware: hw)
    let zeroCurve = FanCurve(rpms: Array(repeating: 0, count: FanCurve.anchorsCelsius.count))

    try engine.configure(.init(enabled: true, curve: zeroCurve), now: 0)
    try engine.tick(now: 0)
    #expect(hw.writes == [.mode("F0md", 1), .target(0, 0)])

    hw.hottestCPU = 54.9
    try engine.tick(now: 1)
    #expect(hw.writes.last == .target(0, 0))

    let raisedCurve = FanCurve(rpms: Array(repeating: 3000, count: FanCurve.anchorsCelsius.count))
    try engine.configure(.init(enabled: true, curve: raisedCurve), now: 2)
    try engine.tick(now: 2)
    #expect(hw.writes.last == .target(0, 3000))

    try engine.configure(.init(enabled: true, curve: zeroCurve), now: 3)
    try engine.tick(now: 3)
    #expect(hw.writes.last == .target(0, 2317))

    hw.hottestCPU = 55
    try engine.tick(now: 4)
    #expect(hw.writes.last == .target(0, 2317))
}

@Test func invalidLimitsReleaseInsteadOfWritingZero() throws {
    let hw = FakeFanControlHardware(modeKey: "F0md", hasFtst: false, hottestCPU: 40,
                                    limits: FanLimits(minimum: 0, maximum: 6550))
    let engine = FanControlEngine(hardware: hw)
    let zeroCurve = FanCurve(rpms: Array(repeating: 0, count: FanCurve.anchorsCelsius.count))

    try engine.configure(.init(enabled: true, curve: zeroCurve), now: 0)
    #expect(throws: FanControlFailure.self) { try engine.tick(now: 0) }
    #expect(hw.writes.contains(.target(0, 0)) == false)
    #expect(hw.writes.last == .mode("F0md", 0))
}

@Test func malformedCurveReleasesInsteadOfWritingZero() throws {
    let hw = FakeFanControlHardware(modeKey: "F0md", hasFtst: false, hottestCPU: 40,
                                    limits: FanLimits(minimum: 2317, maximum: 6550))
    let engine = FanControlEngine(hardware: hw)
    let malformedCurve = FanCurve(rpms: [])

    try engine.configure(.init(enabled: true, curve: malformedCurve), now: 0)
    #expect(throws: FanControlFailure.self) { try engine.tick(now: 0) }
    #expect(hw.writes.contains(.target(0, 0)) == false)
    #expect(hw.writes.last == .mode("F0md", 0))
}

@Test func malformedCurveAtCriticalTemperatureWritesMaximum() throws {
    let hw = FakeFanControlHardware(modeKey: "F0md", hasFtst: false, hottestCPU: 95,
                                    limits: FanLimits(minimum: 2317, maximum: 6550))
    let engine = FanControlEngine(hardware: hw)

    try engine.configure(.init(enabled: true, curve: .init(rpms: [])), now: 0)
    try engine.tick(now: 0)
    #expect(hw.writes.last == .target(0, 6550))
    #expect(engine.status.mode == .controlling)
}
```

- [ ] **Step 2: Run the suite to verify the daemon tests fail**

Run:

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
```

Expected: FAIL because the current engine rejects `target == 0` and has no retained zero-RPM state.

- [ ] **Step 3: Add per-fan hysteresis state and accept valid zero targets**

Add the state beside `controlled`:

```swift
private var zeroRPMFans = Set<Int>()
```

Replace the `for fan in controlled` loop in `tick(now:)` with:

```swift
for fan in controlled {
    let target = FanControlPolicy.targetRPM(curve: configuration.curve,
                                            hottestCPU: hottestCPU,
                                            limits: try hardware.limits(for: fan.index),
                                            wasZeroRPM: zeroRPMFans.contains(fan.index))
    guard let target, target.isFinite, target >= 0 else {
        throw FanControlFailure.invalidTarget(fan.index)
    }
    if target == 0 {
        zeroRPMFans.insert(fan.index)
    } else {
        zeroRPMFans.remove(fan.index)
    }
    try hardware.setTarget(index: fan.index, rpm: target)
}
```

Clear the state at the start of `releaseAccepted(now:reason:)`:

```swift
zeroRPMFans.removeAll()
```

Also clear it at the start of `resetAllFansToAutomatic(now:)`, immediately after `configuration = nil`, so a restart cannot retain a stale zero state:

```swift
zeroRPMFans.removeAll()
```

Keep `SMCFanControlHardware.setTarget(index:rpm:)` unchanged: it already encodes any finite `Float32`, including `0`, into the `F<n>Tg` SMC key.

- [ ] **Step 4: Run all daemon and safety regressions**

Run:

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
```

Expected: PASS; existing heartbeat, sensor-unavailable, manual-mode retry, automatic-recovery, and critical-temperature tests remain green alongside the direct-zero, invalid-limits, malformed-curve automatic-release, and malformed-curve critical-maximum tests.

- [ ] **Step 5: Commit the daemon change**

```bash
git add FanControlShared/FanControlEngine.swift WattlyTests/FanControlEngineTests.swift
git commit -m "feat(fan): apply zero rpm targets with hysteresis"
```

### Task 3: Make the stateful Zero Fan zone visible in the fan-curve editor

**Files:**
- Modify: `Wattly/Core/FanCurveGeometry.swift:8-25,35-41`
- Modify: `Wattly/Views/FanCurveEditor.swift:45-80`
- Test: `WattlyTests/FanCurveGeometryTests.swift:11-52`

**Interfaces:**
- Consumes: `FanControlPolicy.zeroRPMEnterCelsius == 48.0` and `FanControlPolicy.zeroRPMExitCelsius == 55.0` from Task 1.
- Produces: `FanCurveGeometry.zeroFanHoldBand(in:) -> CGRect`, a plot-clipped rectangle from 48°C inclusive to 55°C exclusive. `FanCurveEditor` renders this band as stateful policy information, not as part of the user's configured line.

- [ ] **Step 1: Write the failing geometry test**

Add this test after `plotRectInsetsTheCanvas`:

```swift
@Test func zeroFanHoldBandUsesThePolicyEntryAndExitBoundaries() {
    let band = FanCurveGeometry.zeroFanHoldBand(in: size)
    let plot = FanCurveGeometry.plotRect(in: size)
    #expect(band.minX == FanCurveGeometry.x(forCelsius: 48, in: size))
    #expect(band.maxX == FanCurveGeometry.x(forCelsius: 55, in: size))
    #expect(band.minY == plot.minY)
    #expect(band.maxY == plot.maxY)
}
```

- [ ] **Step 2: Run the suite to verify it fails**

Run:

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
```

Expected: FAIL because `FanCurveGeometry.zeroFanHoldBand(in:)` does not exist.

- [ ] **Step 3: Add a pure policy-band layout seam**

Add these members after `rpmStep` in `Wattly/Core/FanCurveGeometry.swift`:

```swift
static let zeroFanEnterCelsius = FanControlPolicy.zeroRPMEnterCelsius
static let zeroFanExitCelsius = FanControlPolicy.zeroRPMExitCelsius

static func zeroFanHoldBand(in size: CGSize) -> CGRect {
    let plot = plotRect(in: size)
    let start = min(max(x(forCelsius: zeroFanEnterCelsius, in: size), plot.minX), plot.maxX)
    let end = min(max(x(forCelsius: zeroFanExitCelsius, in: size), plot.minX), plot.maxX)
    return CGRect(x: min(start, end), y: plot.minY,
                  width: abs(end - start), height: plot.height)
}
```

In `FanCurveEditor.canvas(_:)`, immediately after `let rpms = displayRPMs`, add the state-hold band before grid lines and before the editable curve:

```swift
let holdBand = FanCurveGeometry.zeroFanHoldBand(in: size)
ctx.fill(Path(holdBand), with: .color(Tokens.statusOrange.opacity(0.12)))

for boundary in [FanCurveGeometry.zeroFanEnterCelsius, FanCurveGeometry.zeroFanExitCelsius] {
    let x = FanCurveGeometry.x(forCelsius: boundary, in: size)
    var marker = Path()
    marker.move(to: CGPoint(x: x, y: rect.minY))
    marker.addLine(to: CGPoint(x: x, y: rect.maxY))
    ctx.stroke(marker, with: .color(Tokens.statusOrange.opacity(0.8)),
               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
}
```

Do not change the editable points, interpolation, drag gesture, or `FanCurve.evaluate`. The line continues to show the configured target; the separate orange band communicates that a literal 0 target within 48–55°C preserves the prior physical state.

- [ ] **Step 4: Run visual-geometry and full regressions**

Run:

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
```

Expected: PASS; `FanCurveGeometryTests.zeroFanHoldBandUsesThePolicyEntryAndExitBoundaries` proves that the rendered band and policy use the same values.

- [ ] **Step 5: Commit the visible Zero Fan zone**

```bash
git add Wattly/Core/FanCurveGeometry.swift Wattly/Views/FanCurveEditor.swift WattlyTests/FanCurveGeometryTests.swift
git commit -m "feat(fan): show zero fan state hold zone"
```

### Task 4: Explain the Zero Fan contract and record local acceptance

**Files:**
- Modify: `Wattly/Views/SettingsView.swift:373-404`
- Modify: `docs/fan-control-local-install.md:19-41`

**Interfaces:**
- Consumes: Task 1's 48°C entry, 55°C exit, and 95°C critical thresholds; Task 3's orange 48–55°C editor band.
- Produces: visible Korean UI copy and operational instructions that describe the stateful band, do not claim every curve target is clamped to `F<n>Mn`, and do not imply 48–55°C is a single-valued mapping.

- [ ] **Step 1: Add the Zero Fan explanation below the graph heading**

Replace the secondary text under `팬 커브 실제 적용` with:

```swift
Text("0 RPM 구역은 곡선 값이 0일 때만 적용됩니다. 48°C 미만에서는 팬을 정지시키고, 주황색 48–55°C 구간에서는 현재 상태를 유지하며, 55°C부터 기본 최소 RPM 이상으로 복귀합니다. 95°C에서는 최대 속도로 보호합니다. Macs Fan Control은 종료해야 합니다.")
```

Immediately below the `HStack` containing `Text("온도 → 팬 속도")`, add this visible legend:

```swift
HStack(spacing: 6) {
    RoundedRectangle(cornerRadius: 2)
        .fill(Tokens.statusOrange.opacity(0.12))
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Tokens.statusOrange.opacity(0.8), lineWidth: 1))
        .frame(width: 14, height: 10)
    Text("Zero Fan 상태 유지 48–55°C · 정지 중이면 0 RPM, 회전 중이면 기본 최소 RPM 이상")
        .font(WattlyFont.at(10.5, weight: .regular))
        .foregroundStyle(t.faint)
        .fixedSize(horizontal: false, vertical: true)
}
.accessibilityElement(children: .combine)
```

Keep the existing opt-in toggle and persisted `FanCurve` unchanged. Do not create a second toggle or a second stored curve: the Zero Fan policy is active only where the one visible curve evaluates to literal `0`.

- [ ] **Step 2: Update operating limits and the acceptance checklist**

Replace the first sentence of the operating-limit paragraph with:

```markdown
When enabled, a nonzero curve target is clamped to each fan's reported minimum and maximum. A literal 0 RPM curve target enters the Zero Fan zone only below 48°C; from 48°C inclusive until 55°C the helper preserves the fan's current stopped-versus-spinning state, then it resumes at least the reported minimum RPM. At 95°C or above it commands the reported maximum RPM.
```

In the `Manual M5 acceptance checklist`, replace the second checklist item with these two items:

```markdown
- [ ] With a 0 RPM curve at a CPU temperature below 48°C, verify `F0md = 1`, `F0Tg = 0`, and `F0Ac = 0` for at least two seconds.
- [ ] While the same curve remains selected, verify that 55°C or above changes `F0Tg` and `F0Ac` to at least `F0Mn`; do not deliberately heat the machine solely for this check.
```

Add this dated observation immediately below the checklist:

```markdown
### Direct-zero capability record (2026-08-15)

On MacBook Pro `Mac17,2` (Apple M5, macOS 26.6.1), a root-only bounded probe began from automatic mode at 44.0°C, entered `F0md = 1`, wrote `F0Tg = 0`, and sampled `F0Ac = 0` eight times at 250 ms intervals. The probe then wrote `F0md = 0` successfully. This confirms direct manual 0 RPM capability for this machine; it is not a cross-model guarantee.
```

- [ ] **Step 3: Build and run the full automated suite**

Run:

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test
```

Expected: both commands exit 0. The visible editor band, Settings text, policy tests, and documentation name the same 48°C, 55°C, and 95°C boundaries.

- [ ] **Step 4: Reinstall the privileged helper and perform guarded physical acceptance**

Run:

```bash
./scripts/install-fan-helper.sh
```

Expected: macOS prompts the local owner for administrator authentication; the installer rebuilds, installs, bootstraps, and prints the running `system/dev.jjundev.WattlyFanDaemon` service.

With Macs Fan Control absent, keep the CPU below 48°C, set every active low-temperature curve anchor to 0 RPM, enable Wattly's fan control, and verify the orange 48–55°C Zero Fan state-hold band is visible. Record `F0md`, `F0Tg`, `F0Ac`, `F0Mn`, `F0Mx`, CPU temperature, and daemon status. Verify at least two seconds of `F0Tg=0` and `F0Ac=0`. Disable the toggle afterward and verify `F0md=0`. Do not force a high-temperature workload; the 55°C transition is accepted only if it occurs naturally.

- [ ] **Step 5: Commit the product and operations update**

```bash
git add Wattly/Views/SettingsView.swift docs/fan-control-local-install.md
git commit -m "docs(fan): explain zero fan state hold"
```

## Self-Review

1. **Spec coverage:** Task 1 distinguishes valid 0 from invalid telemetry and malformed in-memory curves while applying 95°C maximum before curve validation; Task 2 carries direct zero through the daemon while preserving all release paths, including malformed-curve automatic recovery and malformed-curve critical maximum; Task 3 makes the resulting stateful 48–55°C behavior visible in the existing editor; Task 4 gives the same contract in Korean UI copy, reinstalls the root helper, and records the requested physical validation. No requirement is omitted.
2. **Placeholder scan:** This plan contains no incomplete-marker language, unspecified validation, or cross-task shorthand. Every source change, test, command, expected result, and commit has an exact path or code block.
3. **Type consistency:** Task 1 defines the optional `targetRPM(...wasZeroRPM:) -> Double?` signature and public `zeroRPMEnterCelsius` / `zeroRPMExitCelsius` constants; Task 2 consumes that exact signature; Task 3 consumes the constants through `FanCurveGeometry`; Task 4 refers to the same 48°C / 55°C / 95°C boundaries. `setTarget(index:rpm:)` remains unchanged.
