# Battery Control Activity Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a backward-compatible, shared battery-control activity model and use it to render trustworthy, icon-and-text status in the battery settings row without implementing Sailing, Heat Protection, or Top Up behavior yet.

**Architecture:** Keep `BatteryControlServiceMode` as the low-level helper/hardware mode used by installer, polling, and recovery policy. Add a separate optional `BatteryControlActivity` to `BatteryControlServiceStatus`; the daemon reports the activity it has actually verified, while old helpers omit the field and the app derives only the four existing base activities from `BatteryControlStatusReason`. `BatterySectionPresentation` remains the deep app-side module: it owns precedence, freshness, semantic indicator selection, localization, and the SF Symbol name so SwiftUI only renders its result.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, Codable JSON over privileged XPC, XcodeGen, macOS 14+, Apple Silicon arm64

## Global Constraints

- Support macOS 14.0 and later on Apple Silicon arm64; do not add an Intel path.
- Add no third-party dependencies.
- Preserve the existing meanings of `BatteryControlServiceMode`, `BatteryControlStatusReason`, `detail`, `detailReason`, `appliedLimitPercentage`, and `isHardwareSupported`.
- `BatteryControlActivity` describes helper-verified activity, never a UI request or an optimistic client-side command.
- The new `activity` XPC field must be optional so a current app can decode an older installed helper.
- Unknown or malformed future activity tokens must degrade to `.unrecognized` without failing the entire `BatteryControlServiceStatus` decode.
- Keep `detail` and `detailReason` as the text/backward-compatibility channel; activity selects presentation semantics but does not replace diagnostics.
- Presentation precedence is installation → helper/hardware error or unavailable → stale → verified activity → legacy/local fallback.
- A status older than 15 seconds is not presented as current; while refreshing, reuse the already-localized `확인 중...` catalog key.
- Use both an SF Symbol and localized text; color alone must never carry state.
- Do not implement Sailing, Heat Protection, Top Up, Discharge, Calibration, scheduling, menu-bar icon changes, or state history in this PR.
- Do not change charge-limit thresholds, SMC writes, retry budgets, polling cadence, or hardware behavior.
- A new source file requires `xcodegen generate` and the regenerated `Wattly.xcodeproj/project.pbxproj` in the same commit.
- The full validation gate is `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'`, followed by `xcodebuild build -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'`.
- Keep the 11 files under `docs/features/battery-management/` out of this implementation PR; they belong to the separate documentation PR.

---

## Scope and settled decisions

Primary specification:

- `docs/features/battery-management/03-charge-status-indicators.md`

Future-state vocabulary references:

- `docs/features/battery-management/01-sailing-mode.md`
- `docs/features/battery-management/02-top-up.md`
- `docs/features/battery-management/05-heat-protection.md`

Decisions fixed for this PR:

1. `BatteryControlServiceMode` remains the recovery/transport-facing mode. It is not expanded with product activities.
2. `BatteryControlActivity` is one authoritative activity, chosen by the helper. Future policy precedence belongs in the helper, not in SwiftUI.
3. Current helper behavior emits only `.inactive`, `.chargingToLimit`, `.holdingAtLimit`, and `.onBatteryPower`; future cases are protocol vocabulary and presentation coverage only.
4. The settings status row changes from a colored circle to an SF Symbol plus text. The main menu-bar icon is outside this PR.
5. No status history is stored. `updatedAt` is used only to avoid presenting an old sample as current.
6. Stale means strictly more than 15 seconds old. Exactly 15 seconds remains current, preventing flicker at the three-poll boundary.
7. Unsupported hardware keeps the settings status row visible with a dedicated warning indicator; only the limit picker and advisory controls are hidden.

## File structure

### Create

- `FanControlShared/BatteryControlActivity.swift` — shared, leniently Codable activity vocabulary plus legacy-reason inference and explicit-activity resolution.
- `WattlyTests/BatteryControlActivityTests.swift` — direct tests for tokens, malformed input, inference, and precedence.

### Modify

- `FanControlShared/BatteryControlProtocol.swift` — optional `activity` field on `BatteryControlServiceStatus`.
- `FanControlShared/BatteryControlEngine.swift` — reports one verified base activity with each normal status.
- `Wattly/Core/BatterySectionPresentation.swift` — semantic indicator model, activity precedence, stale handling, icon names, and tones.
- `Wattly/Views/Settings/SettingsBatterySection.swift` — renders the semantic SF Symbol and text returned by the presentation module.
- `WattlyTests/BatteryControlProtocolTests.swift` — XPC backward/forward compatibility for the optional activity.
- `WattlyTests/BatteryControlEngineTests.swift` — actual engine state to activity mapping and failure behavior.
- `WattlyTests/BatterySectionPresentationTests.swift` — indicator mapping, precedence, freshness, and existing behavior preservation.
- `Wattly.xcodeproj/project.pbxproj` — regenerated by XcodeGen because two Swift files are added.

### Explicitly unchanged

- `FanControlShared/BatteryControlStatusReason.swift` — existing reason tokens and legacy Korean strings remain stable.
- `Wattly/Core/BatteryStatusText.swift` — continues to own localized status text.
- `Wattly/Resources/Localizable.xcstrings` — no new copy is required; stale rendering reuses `확인 중...`.
- `WattlyFanDaemon/BatteryControlHardware.swift` and SMC transport — no hardware behavior changes.

## Execution preflight

This checkout is currently detached at `origin/main`. Before Task 1 changes any file, create the implementation branch and confirm that the already-created feature-definition documents remain untracked:

```bash
git switch -c codex/battery-control-activity-status
git status --short --branch
```

Expected: the first line is `## codex/battery-control-activity-status`; `docs/features/` and this plan may be untracked, and no source file is modified. Do not stage `docs/features/battery-management/` in any implementation commit.

---

### Task 1: Add the shared activity vocabulary and optional XPC field

**Files:**

- Create: `WattlyTests/BatteryControlActivityTests.swift`
- Create: `FanControlShared/BatteryControlActivity.swift`
- Modify: `WattlyTests/BatteryControlProtocolTests.swift:147-153`
- Modify: `FanControlShared/BatteryControlProtocol.swift:53-96`
- Modify: `Wattly.xcodeproj/project.pbxproj` through `xcodegen generate`

**Interfaces:**

- Consumes: `BatteryControlStatusReason`, `BatteryControlCodec`, and `BatteryControlServiceStatus`.
- Produces: `BatteryControlActivity`, `BatteryControlActivity.inferred(from:)`, `BatteryControlActivity.resolved(explicit:reason:)`, and `BatteryControlServiceStatus.activity: BatteryControlActivity?`.

- [ ] **Step 1: Write the failing activity-model tests**

Create `WattlyTests/BatteryControlActivityTests.swift` with exactly:

```swift
import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryControlActivityTests {
    @Test func roundTripsEveryKnownToken() throws {
        for activity in BatteryControlActivity.allCases where activity != .unrecognized {
            let data = try BatteryControlCodec.encode(activity)
            let decoded = try BatteryControlCodec.decode(BatteryControlActivity.self, from: data)
            #expect(decoded == activity)
        }
    }

    @Test func unknownAndMalformedTokensBecomeUnrecognized() throws {
        let future = try BatteryControlCodec.decode(
            BatteryControlActivity.self,
            from: Data("\"futureActivity\"".utf8))
        let malformed = try BatteryControlCodec.decode(
            BatteryControlActivity.self,
            from: Data("42".utf8))

        #expect(future == .unrecognized)
        #expect(malformed == .unrecognized)
    }

    @Test func existingReasonsInferOnlyVerifiedBaseActivities() {
        #expect(BatteryControlActivity.inferred(from: .init(kind: .limitDisabled)) == .inactive)
        #expect(BatteryControlActivity.inferred(
            from: .init(kind: .chargingToTarget, limitPercentage: 80)) == .chargingToLimit)
        #expect(BatteryControlActivity.inferred(
            from: .init(kind: .inhibitedAtLimit, limitPercentage: 80)) == .holdingAtLimit)
        #expect(BatteryControlActivity.inferred(from: .init(kind: .onBatteryPower)) == .onBatteryPower)

        #expect(BatteryControlActivity.inferred(from: .init(kind: .initializing)) == nil)
        #expect(BatteryControlActivity.inferred(from: .init(kind: .applyFailed)) == nil)
        #expect(BatteryControlActivity.inferred(from: .init(kind: .releaseFailed)) == nil)
        #expect(BatteryControlActivity.inferred(from: nil) == nil)
    }

    @Test func explicitKnownActivityWinsAndUnrecognizedFallsBack() {
        let reason = BatteryControlStatusReason(kind: .chargingToTarget, limitPercentage: 80)

        #expect(BatteryControlActivity.resolved(explicit: .heatProtection, reason: reason)
                == .heatProtection)
        #expect(BatteryControlActivity.resolved(explicit: .unrecognized, reason: reason)
                == .chargingToLimit)
        #expect(BatteryControlActivity.resolved(explicit: nil, reason: reason)
                == .chargingToLimit)
    }
}
```

- [ ] **Step 2: Add failing protocol-compatibility tests**

Append these tests inside `BatteryControlProtocolTests` in `WattlyTests/BatteryControlProtocolTests.swift`:

```swift
    @Test func statusFromOlderHelperLeavesActivityUnknown() throws {
        let legacy = Data(#"{"mode":"charging","currentPercentage":70,"isPowerAdapterConnected":true,"detail":"충전 중","updatedAt":1.0}"#.utf8)
        let decoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: legacy)
        #expect(decoded.activity == nil)
    }

    @Test func statusRoundTripsAnActivity() throws {
        let status = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 80,
            isPowerAdapterConnected: true,
            detail: "충전 제한 80% 도달 (전원 어댑터 바이패스 구동)",
            updatedAt: 12.0,
            appliedLimitPercentage: 80,
            isHardwareSupported: true,
            detailReason: .init(kind: .inhibitedAtLimit, limitPercentage: 80),
            activity: .holdingAtLimit)

        let decoded = try BatteryControlCodec.decode(
            BatteryControlServiceStatus.self,
            from: BatteryControlCodec.encode(status))

        #expect(decoded == status)
        #expect(decoded.activity == .holdingAtLimit)
    }

    @Test func statusSurvivesUnknownAndMalformedActivityTokens() throws {
        let future = Data(#"{"mode":"charging","currentPercentage":70,"isPowerAdapterConnected":true,"detail":"충전 중","updatedAt":1.0,"activity":"futureActivity"}"#.utf8)
        let malformed = Data(#"{"mode":"charging","currentPercentage":70,"isPowerAdapterConnected":true,"detail":"충전 중","updatedAt":1.0,"activity":42}"#.utf8)

        let futureDecoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: future)
        let malformedDecoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: malformed)

        #expect(futureDecoded.activity == .unrecognized)
        #expect(malformedDecoded.activity == .unrecognized)
        #expect(futureDecoded.currentPercentage == 70)
        #expect(malformedDecoded.currentPercentage == 70)
    }
```

- [ ] **Step 3: Generate the project and run the tests to verify they fail**

Run:

```bash
xcodegen generate
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  -only-testing:WattlyTests/BatteryControlActivityTests \
  -only-testing:WattlyTests/BatteryControlProtocolTests
```

Expected: compilation fails because `BatteryControlActivity` and `BatteryControlServiceStatus.activity` do not exist.

- [ ] **Step 4: Implement the shared activity module**

Create `FanControlShared/BatteryControlActivity.swift` with exactly:

```swift
import Foundation

/// The user-facing battery policy the helper has actually verified.
///
/// This is deliberately separate from `BatteryControlServiceMode`: service mode describes whether
/// the helper is reachable and whether the charge gate is physically open or closed; activity says
/// which product policy owns that state. Future policy engines choose one authoritative activity.
public enum BatteryControlActivity: String, Codable, Equatable, Sendable, CaseIterable {
    case inactive
    case chargingToLimit
    case holdingAtLimit
    case onBatteryPower
    case sailing
    case heatProtection
    case topUp
    case discharging
    case calibration

    /// A newer helper sent an activity token this app does not know. Never emitted locally.
    case unrecognized

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? ""
        self = Self(rawValue: raw) ?? .unrecognized
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Compatibility path for an older helper that has `detailReason` but no activity field.
    /// Only reasons that prove a normal base activity are inferred; diagnostics stay `nil`.
    public static func inferred(from reason: BatteryControlStatusReason?) -> Self? {
        switch reason?.kind {
        case .some(.limitDisabled): return .inactive
        case .some(.chargingToTarget): return .chargingToLimit
        case .some(.inhibitedAtLimit): return .holdingAtLimit
        case .some(.onBatteryPower): return .onBatteryPower
        case .some(.initializing), .some(.powerSourceUnreadable),
             .some(.hardwareUnsupported), .some(.releaseFailed),
             .some(.applyFailed), .some(.unrecognized), .none:
            return nil
        }
    }

    /// Prefer the helper's explicit verified activity. Unknown future tokens fall back to the
    /// reason understood by this app, preserving useful status after an incremental update.
    public static func resolved(explicit: Self?, reason: BatteryControlStatusReason?) -> Self? {
        if let explicit, explicit != .unrecognized { return explicit }
        return inferred(from: reason)
    }
}
```

- [ ] **Step 5: Add the optional activity to the XPC status**

In `FanControlShared/BatteryControlProtocol.swift`, add this property immediately after `detailReason`:

```swift
    /// The product policy the helper has actually verified. Optional for an older installed helper;
    /// `nil` means unknown, not inactive. `detailReason` remains the diagnostic/text channel.
    public var activity: BatteryControlActivity?
```

Replace the `BatteryControlServiceStatus` initializer with:

```swift
    public init(
        mode: BatteryControlServiceMode,
        currentPercentage: Int,
        isPowerAdapterConnected: Bool,
        detail: String,
        updatedAt: TimeInterval,
        appliedLimitPercentage: Int? = nil,
        isHardwareSupported: Bool? = nil,
        detailReason: BatteryControlStatusReason? = nil,
        activity: BatteryControlActivity? = nil
    ) {
        self.mode = mode
        self.currentPercentage = currentPercentage
        self.isPowerAdapterConnected = isPowerAdapterConnected
        self.detail = detail
        self.updatedAt = updatedAt
        self.appliedLimitPercentage = appliedLimitPercentage
        self.isHardwareSupported = isHardwareSupported
        self.detailReason = detailReason
        self.activity = activity
    }
```

The synthesized `Codable` implementation remains valid: an absent optional field decodes as `nil`, and the activity's lenient decoder absorbs an unknown or non-string token.

- [ ] **Step 6: Regenerate and run the focused tests**

Run:

```bash
xcodegen generate
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  -only-testing:WattlyTests/BatteryControlActivityTests \
  -only-testing:WattlyTests/BatteryControlProtocolTests
```

Expected: `TEST SUCCEEDED`; every known token round-trips, older payloads produce `nil`, and unknown/malformed activity values preserve the rest of the status.

- [ ] **Step 7: Commit the shared protocol slice**

```bash
git add FanControlShared/BatteryControlActivity.swift \
  FanControlShared/BatteryControlProtocol.swift \
  WattlyTests/BatteryControlActivityTests.swift \
  WattlyTests/BatteryControlProtocolTests.swift \
  docs/plans/2026-08-23-battery-control-activity-status.md \
  Wattly.xcodeproj/project.pbxproj
git commit -m "feat(battery): add shared activity status"
```

---

### Task 2: Make the helper report verified base activities

**Files:**

- Modify: `WattlyTests/BatteryControlEngineTests.swift:520-559`
- Modify: `FanControlShared/BatteryControlEngine.swift:212-237`

**Interfaces:**

- Consumes: `BatteryControlActivity.inferred(from:)` from Task 1 and the existing authoritative `BatteryControlStatusReason` created by `detailReason(isPluggedIn:target:)`.
- Produces: non-optional normal activities on statuses emitted by `BatteryControlEngine`; failures and unsupported hardware continue to emit `activity == nil`.

- [ ] **Step 1: Write failing engine activity tests**

Append these tests inside `BatteryControlEngineTests`:

```swift
    @Test func normalStatesReportVerifiedBaseActivities() {
        let mockHW = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHW)

        let inactive = engine.update(currentSoC: 70, isPluggedIn: true)
        #expect(inactive.activity == .inactive)

        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80))
        let charging = engine.update(currentSoC: 70, isPluggedIn: true)
        #expect(charging.activity == .chargingToLimit)

        let holding = engine.update(currentSoC: 80, isPluggedIn: true)
        #expect(holding.activity == .holdingAtLimit)

        let unplugged = engine.update(currentSoC: 79, isPluggedIn: false)
        #expect(unplugged.activity == .onBatteryPower)
    }

    @Test func failuresAndUnsupportedHardwareDoNotClaimANormalActivity() {
        let unsupportedHardware = MockBatteryHardware()
        unsupportedHardware.registerSet = .unsupported
        let unsupportedEngine = BatteryControlEngine(hardware: unsupportedHardware)
        unsupportedEngine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80))
        #expect(unsupportedEngine.update(currentSoC: 70, isPluggedIn: true).activity == nil)

        let failingHardware = MockBatteryHardware()
        failingHardware.writeShouldFail = true
        let failingEngine = BatteryControlEngine(hardware: failingHardware)
        failingEngine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80))
        #expect(failingEngine.update(currentSoC: 70, isPluggedIn: true).activity == nil)
    }
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  -only-testing:WattlyTests/BatteryControlEngineTests
```

Expected: the new assertions fail because engine-created statuses still use the initializer's default `activity == nil`.

- [ ] **Step 3: Populate activity from the same reason that owns legacy text**

In `BatteryControlEngine.status(currentSoC:isPluggedIn:target:)`, replace the final two initializer arguments:

```swift
            isHardwareSupported: isHardwareSupported,
            detailReason: reason
```

with:

```swift
            isHardwareSupported: isHardwareSupported,
            detailReason: reason,
            // The reason is already the single authoritative decision for this sample. Deriving
            // activity here keeps the new app, the legacy sentence, and the hardware mode aligned.
            activity: BatteryControlActivity.inferred(from: reason)
```

Do not add activity to `FanControlDaemon`'s `.powerSourceUnreadable` status at `WattlyFanDaemon/FanControlDaemon.swift:182-194`; an unreadable power source cannot verify a normal activity and must remain `nil`.

- [ ] **Step 4: Run engine and daemon-facing tests**

Run:

```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  -only-testing:WattlyTests/BatteryControlEngineTests \
  -only-testing:WattlyTests/BatteryControlClientTests \
  -only-testing:WattlyTests/BatteryControlPolicyTests
```

Expected: `TEST SUCCEEDED`; base activities match reasons, failures remain activity-free, and reconcile/installer behavior is unchanged because it still reads `mode` and `appliedLimitPercentage`.

- [ ] **Step 5: Commit verified activity reporting**

```bash
git add FanControlShared/BatteryControlEngine.swift WattlyTests/BatteryControlEngineTests.swift
git commit -m "feat(battery): report verified control activity"
```

---

### Task 3: Render semantic status icons and stale-state feedback

**Files:**

- Modify: `WattlyTests/BatterySectionPresentationTests.swift:36-201`
- Modify: `Wattly/Core/BatterySectionPresentation.swift:10-129`
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift:27-73,133-177,192-217,233-241`

**Interfaces:**

- Consumes: `BatteryControlServiceMode`, `BatteryControlActivity.resolved(explicit:reason:)`, `BatteryControlStatusReason`, `updatedAt`, the existing localized `확인 중...` key, and `Tokens.statusGreen/statusOrange/statusRed`.
- Produces: `BatterySectionPresentation.Status(indicator:text:)`, `BatterySectionPresentation.Indicator.symbolName`, `BatterySectionPresentation.Indicator.tone`, and the icon-and-text settings status row.

- [ ] **Step 1: Replace presentation expectations with semantic indicators**

In `WattlyTests/BatterySectionPresentationTests.swift`, keep the exposure, picker, install-button, polling, and localization sections, but change every status expectation to the semantic indicator shown here:

```swift
// Replace the two existing detail-visibility tests. Configuration controls hide on explicit
// unsupported hardware, but Task 3 Step 6 keeps the status row itself outside that conditional.
@Test func configurationControlsAreVisibleWhenSupportIsTrueOrUnknown() {
    #expect(BatterySectionPresentation.showsConfigurationControls(isHardwareSupported: true))
    #expect(BatterySectionPresentation.showsConfigurationControls(isHardwareSupported: nil))
}

@Test func configurationControlsHideOnlyOnExplicitlyUnsupportedHardware() {
    #expect(!BatterySectionPresentation.showsConfigurationControls(isHardwareSupported: false))
}

// installingOutranksEverything
#expect(s == .init(indicator: .installing, text: "도우미 설치 중…"))

// offAndUnavailableStillReportsTheConnectionFailure
#expect(s == .init(indicator: .unavailable, text: "무시되어야 하는 문구"))

// offAndChargingPassesTheDaemonsDetailThrough
#expect(s == .init(indicator: .inactive, text: "충전 제한 비활성화됨"))

// offAndUnsupportedSurfacesTheActionableFailure
#expect(s == .init(indicator: .failure,
                   text: "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)"))

// offAndInhibitedSurfacesTheVerifiedHardwareState
let s = BatterySectionPresentation.status(
    isLimitOn: false, isInstalling: false, mode: .inhibited,
    reason: .init(kind: .inhibitedAtLimit, limitPercentage: 80),
    detail: "충전 제한 80% 도달 (전원 어댑터 바이패스 구동)",
    locale: ko)
#expect(s == .init(indicator: .holdingAtLimit,
                   text: "충전 제한 80% 도달 (전원 어댑터 바이패스 구동)"))

// onStateMapsModeToDotAndPassesDetailThrough: replace the cases table
let cases: [(BatteryControlServiceMode, BatterySectionPresentation.Indicator)] = [
    (.inhibited, .holdingAtLimit),
    (.charging, .chargingToLimit),
    (.unavailable, .unavailable),
    (.unsupported, .failure),
]
for (mode, indicator) in cases {
    let s = BatterySectionPresentation.status(isLimitOn: true, isInstalling: false,
                                             mode: mode,
                                             reason: nil, detail: "데몬 문구",
                                             locale: ko)
    #expect(s == .init(indicator: indicator, text: "데몬 문구"))
}

// statusTextFollowsTheLocale
#expect(s == .init(indicator: .chargingToLimit, text: "Charging to 80%"))

// installingTextIsLocalized
#expect(s == .init(indicator: .installing, text: "Installing helper…"))

// disabledSubstituteTextIsLocalized keeps testing disabledStatusText directly; the status call
// with `.unavailable` now preserves the connection failure instead of replacing it.
#expect(BatterySectionPresentation.disabledStatusText(locale: en) == "Charge limit off")

// stuckAfterTurningOffStaysLoudAndTranslated
#expect(s == .init(indicator: .failure,
                   text: "Could not resume charging (try reconnecting the power adapter)"))
```

Rename `offAndUnavailableShowsTheFaintConstant` to `offAndUnavailableStillReportsTheConnectionFailure`,
`offAndInhibitedSurfacesTheDaemonsDetail` to `offAndInhibitedSurfacesTheVerifiedHardwareState`, and
`onStateMapsModeToDotAndPassesDetailThrough` to `onStateMapsModeToFallbackIndicatorAndPassesDetailThrough`.
Use the implementations and expectations above.

- [ ] **Step 2: Add failing activity, precedence, icon, and freshness tests**

Append these tests inside `BatterySectionPresentationTests`:

```swift
    @Test func everyActivityHasAStableSemanticIndicator() {
        let cases: [(BatteryControlActivity, BatterySectionPresentation.Indicator)] = [
            (.inactive, .inactive),
            (.chargingToLimit, .chargingToLimit),
            (.holdingAtLimit, .holdingAtLimit),
            (.onBatteryPower, .onBatteryPower),
            (.sailing, .sailing),
            (.heatProtection, .heatProtection),
            (.topUp, .topUp),
            (.discharging, .discharging),
            (.calibration, .calibration),
        ]

        for (activity, indicator) in cases {
            let status = BatterySectionPresentation.status(
                isLimitOn: true,
                isInstalling: false,
                mode: .charging,
                // Future helpers keep `detail` for an app that knows this activity token but does
                // not yet know their newer reason token. The indicator and prose stay independent.
                reason: .init(kind: .unrecognized),
                detail: "상태 문구",
                locale: ko,
                activity: activity)
            #expect(status == .init(indicator: indicator, text: "상태 문구"))
        }
    }

    @Test func helperErrorsOutrankToggleActivityAndFreshness() {
        let unavailable = BatterySectionPresentation.status(
            isLimitOn: false, isInstalling: false, mode: .unavailable,
            reason: nil, detail: "도우미에 연결되지 않음", locale: ko,
            activity: .topUp, updatedAt: 100, now: 200)
        let failed = BatterySectionPresentation.status(
            isLimitOn: false, isInstalling: false, mode: .unsupported,
            reason: .init(kind: .applyFailed), detail: "이 Mac에서 충전 제어를 적용하지 못했습니다",
            locale: ko, activity: .topUp, updatedAt: 100, now: 200)

        #expect(unavailable.indicator == .unavailable)
        #expect(failed.indicator == .failure)
    }

    @Test func hardwareUnsupportedHasItsOwnReachableIndicator() {
        let status = BatterySectionPresentation.status(
            isLimitOn: false, isInstalling: false, mode: .unsupported,
            reason: .init(kind: .hardwareUnsupported),
            detail: "이 Mac은 충전 제어를 지원하지 않습니다",
            locale: ko, activity: nil)

        #expect(status == .init(indicator: .hardwareUnsupported,
                               text: "이 Mac은 충전 제어를 지원하지 않습니다"))
        #expect(BatterySectionPresentation.showsConfigurationControls(
            isHardwareSupported: false) == false)
    }

    @Test func explicitActivityWinsAndOlderHelperFallsBackToReason() {
        let explicit = BatterySectionPresentation.status(
            isLimitOn: false, isInstalling: false, mode: .inhibited,
            reason: .init(kind: .inhibitedAtLimit, limitPercentage: 80), detail: "상태 문구",
            locale: ko, activity: .heatProtection)
        let fallback = BatterySectionPresentation.status(
            isLimitOn: false, isInstalling: false, mode: .inhibited,
            reason: .init(kind: .inhibitedAtLimit, limitPercentage: 80), detail: "상태 문구",
            locale: ko, activity: nil)

        #expect(explicit.indicator == .heatProtection)
        #expect(fallback.indicator == .holdingAtLimit)
    }

    @Test func verifiedInactiveActivityOutranksAnOptimisticLocalToggle() {
        let status = BatterySectionPresentation.status(
            isLimitOn: true, isInstalling: false, mode: .charging,
            reason: .init(kind: .limitDisabled), detail: "충전 제한 비활성화됨",
            locale: ko, activity: .inactive)

        #expect(status == .init(indicator: .inactive, text: "충전 제한 비활성화됨"))
    }

    @Test func statusBecomesStaleOnlyAfterThreePollIntervals() {
        let atBoundary = BatterySectionPresentation.status(
            isLimitOn: true, isInstalling: false, mode: .charging,
            reason: .init(kind: .chargingToTarget, limitPercentage: 80), detail: "상태 문구",
            locale: ko, activity: .chargingToLimit, updatedAt: 100, now: 115)
        let stale = BatterySectionPresentation.status(
            isLimitOn: true, isInstalling: false, mode: .charging,
            reason: .init(kind: .chargingToTarget, limitPercentage: 80), detail: "상태 문구",
            locale: ko, activity: .chargingToLimit, updatedAt: 100, now: 115.001)

        #expect(atBoundary.indicator == .chargingToLimit)
        #expect(atBoundary.text == "목표치(80%)까지 충전 중")
        #expect(stale == .init(indicator: .stale, text: "확인 중..."))
    }

    @Test func unavailableAndInstallingAreNeverRelabeledAsStale() {
        let unavailable = BatterySectionPresentation.status(
            isLimitOn: true, isInstalling: false, mode: .unavailable,
            reason: nil, detail: "도우미에 연결되지 않음", locale: ko,
            activity: nil, updatedAt: 100, now: 200)
        let installing = BatterySectionPresentation.status(
            isLimitOn: true, isInstalling: true, mode: .charging,
            reason: nil, detail: "상태 문구", locale: ko,
            activity: .chargingToLimit, updatedAt: 100, now: 200)

        #expect(unavailable.indicator == .unavailable)
        #expect(installing.indicator == .installing)
    }

    @Test func indicatorsExposeStableSymbolsAndNonColorMeaning() {
        #expect(BatterySectionPresentation.Indicator.chargingToLimit.symbolName == "bolt.circle.fill")
        #expect(BatterySectionPresentation.Indicator.holdingAtLimit.symbolName == "pause.circle.fill")
        #expect(BatterySectionPresentation.Indicator.heatProtection.symbolName == "thermometer")
        #expect(BatterySectionPresentation.Indicator.failure.symbolName == "exclamationmark.triangle.fill")
        #expect(BatterySectionPresentation.Indicator.hardwareUnsupported.symbolName == "nosign")
        #expect(BatterySectionPresentation.Indicator.stale.symbolName == "clock.fill")

        #expect(BatterySectionPresentation.Indicator.chargingToLimit.tone == .green)
        #expect(BatterySectionPresentation.Indicator.failure.tone == .orange)
        #expect(BatterySectionPresentation.Indicator.unavailable.tone == .red)
        #expect(BatterySectionPresentation.Indicator.hardwareUnsupported.tone == .red)
        #expect(BatterySectionPresentation.Indicator.inactive.tone == .faint)
    }

    @Test func everyIndicatorSymbolExistsOnTheRunningMacOS() {
        for indicator in BatterySectionPresentation.Indicator.allCases {
            #expect(NSImage(systemSymbolName: indicator.symbolName,
                            accessibilityDescription: nil) != nil,
                    "Missing SF Symbol: \(indicator.symbolName)")
        }
    }
```

Add `import AppKit` beside the existing `Foundation` import at the top of
`WattlyTests/BatterySectionPresentationTests.swift` for the symbol-existence test.

- [ ] **Step 3: Run presentation tests to verify they fail**

Run:

```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  -only-testing:WattlyTests/BatterySectionPresentationTests
```

Expected: compilation fails because `Indicator`, `Tone`, `Status.indicator`, activity parameters, and freshness parameters do not exist.

- [ ] **Step 4: Replace the presentation result types with semantic indicators**

In `Wattly/Core/BatterySectionPresentation.swift`, replace `Dot` and `Status` with:

```swift
    enum Tone: String, Equatable {
        case green, orange, red, faint
    }

    enum Indicator: String, Equatable, CaseIterable {
        case installing
        case stale
        case inactive
        case chargingToLimit
        case holdingAtLimit
        case onBatteryPower
        case sailing
        case heatProtection
        case topUp
        case discharging
        case calibration
        case unavailable
        case hardwareUnsupported
        case failure

        var symbolName: String {
            switch self {
            case .installing: return "arrow.down.circle.fill"
            case .stale: return "clock.fill"
            case .inactive, .holdingAtLimit: return "pause.circle.fill"
            case .chargingToLimit: return "bolt.circle.fill"
            case .onBatteryPower: return "battery.100"
            case .sailing: return "arrow.left.and.right.circle.fill"
            case .heatProtection: return "thermometer"
            case .topUp: return "arrow.up.circle.fill"
            case .discharging: return "arrow.down.circle.fill"
            case .calibration: return "arrow.triangle.2.circlepath"
            case .hardwareUnsupported: return "nosign"
            case .unavailable, .failure: return "exclamationmark.triangle.fill"
            }
        }

        var tone: Tone {
            switch self {
            case .inactive, .stale: return .faint
            case .chargingToLimit, .onBatteryPower, .topUp: return .green
            case .installing, .holdingAtLimit, .sailing, .heatProtection,
                 .discharging, .calibration, .failure:
                return .orange
            case .unavailable, .hardwareUnsupported: return .red
            }
        }
    }

    struct Status: Equatable {
        let indicator: Indicator
        let text: String
    }

    static let staleAfter = 15.0
```

- [ ] **Step 5: Replace the status resolver with activity and freshness precedence**

Replace `BatterySectionPresentation.status` with:

```swift
    static func status(isLimitOn: Bool,
                       isInstalling: Bool,
                       mode: BatteryControlServiceMode,
                       reason: BatteryControlStatusReason?,
                       detail: String,
                       locale: Locale,
                       activity: BatteryControlActivity? = nil,
                       updatedAt: TimeInterval = 0,
                       now: TimeInterval = 0) -> Status {
        let resolvedText = BatteryStatusText.text(reason: reason, detail: detail, locale: locale)

        if isInstalling {
            return Status(indicator: .installing,
                          text: String(localized: "도우미 설치 중…", locale: locale))
        }

        // Connection and hardware errors outrank freshness, verified activity, and the local
        // toggle. `.unavailable` is a current local connection result, not an old remote sample.
        switch mode {
        case .unavailable:
            return Status(indicator: .unavailable, text: resolvedText)
        case .unsupported:
            let resolvedReason = BatteryStatusText.resolve(reason: reason, detail: detail)
            return Status(indicator: resolvedReason?.kind == .hardwareUnsupported
                          ? .hardwareUnsupported : .failure,
                          text: resolvedText)
        case .charging, .inhibited:
            break
        }

        // A zero timestamp is the client's initial state and means "no remote sample". Exactly
        // three polling intervals stays current; only a strictly older sample becomes stale.
        if updatedAt > 0,
           now >= updatedAt,
           now - updatedAt > staleAfter {
            return Status(indicator: .stale,
                          text: String(localized: "확인 중...", locale: locale))
        }

        if let resolvedActivity = BatteryControlActivity.resolved(explicit: activity, reason: reason) {
            return Status(indicator: indicator(for: resolvedActivity), text: resolvedText)
        }

        // The local toggle is the least authoritative input. It is used only when an old helper
        // sent neither activity nor a recognized reason and the mode carries no finer meaning.
        if !isLimitOn {
            return Status(indicator: .inactive, text: disabledStatusText(locale: locale))
        }

        return Status(indicator: mode == .inhibited ? .holdingAtLimit : .chargingToLimit,
                      text: resolvedText)
    }

    private static func indicator(for activity: BatteryControlActivity) -> Indicator {
        switch activity {
        case .inactive: return .inactive
        case .chargingToLimit: return .chargingToLimit
        case .holdingAtLimit: return .holdingAtLimit
        case .onBatteryPower: return .onBatteryPower
        case .sailing: return .sailing
        case .heatProtection: return .heatProtection
        case .topUp: return .topUp
        case .discharging: return .discharging
        case .calibration: return .calibration
        case .unrecognized:
            // `BatteryControlActivity.resolved` never returns this. Keep a total switch so a future
            // caller cannot turn an unknown token into a confident normal activity.
            return .failure
        }
    }
```

Replace `areDetailsVisible(isHardwareSupported:)` with the narrowly named helper below. It controls
only the picker and advisory; Step 6 keeps the status row visible regardless of this result.

```swift
    static func showsConfigurationControls(isHardwareSupported: Bool?) -> Bool {
        isHardwareSupported != false
    }
```

Leave the picker helpers, install-button logic, and polling logic unchanged.

- [ ] **Step 6: Render the semantic SF Symbol in settings**

In the `SettingsToggleRow` call, replace `divider: areDetailsVisible` with `divider: true`. Then
replace the existing `if areDetailsVisible { ... }` block immediately after the toggle row with:

```swift
                VStack(alignment: .leading, spacing: 12) {
                    if showsConfigurationControls {
                        HStack {
                            Text("최대 충전 한도")
                                .font(WattlyFont.at(12, weight: .medium))
                                .foregroundStyle(t.text)
                            Spacer()
                            Text("\(batteryLimitPercentage)%")
                                .font(WattlyFont.at(12, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(t.text)
                        }
                        .opacity(isLimitPickerEnabled ? 1 : 0.5)

                        WattlySegment(
                            selection: $batteryLimitPercentage,
                            options: presetLimits.map { ($0, "\($0)%") },
                            pillVPadding: 6,
                            isEnabled: isLimitPickerEnabled,
                            disabledReason: BatterySectionPresentation
                                .limitPickerDisabledReason(isLimitOn: batteryLimitEnabled)
                        )
                    }

                    // Always visible: unsupported hardware must explain itself with the same
                    // icon-and-text status interface instead of making the entire status row vanish.
                    batteryStatusIndicator

                    if showsConfigurationControls {
                        advisoryBanner
                    }
                }
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
```

Replace the existing `isHardwareUnsupported` and `areDetailsVisible` computed properties with:

```swift
    private var isHardwareUnsupported: Bool {
        batteryControl.status.isHardwareSupported == false
    }

    private var showsConfigurationControls: Bool {
        BatterySectionPresentation.showsConfigurationControls(
            isHardwareSupported: batteryControl.status.isHardwareSupported)
    }
```

In `Wattly/Views/Settings/SettingsBatterySection.swift`, replace `batteryStatusIndicator` with:

```swift
    private var batteryStatusIndicator: some View {
        let resolved = resolvedStatus
        return HStack(spacing: 8) {
            Image(systemName: resolved.indicator.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusColor(for: resolved.indicator.tone))
                // The localized status text carries the meaning; hiding the decorative symbol
                // prevents VoiceOver from reading an English SF Symbol name before it.
                .accessibilityHidden(true)
            Text(verbatim: resolved.text)
                .font(WattlyFont.at(11, weight: .regular))
                .foregroundStyle(t.sub)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if BatterySectionPresentation.isInstallButtonVisible(isLimitOn: batteryLimitEnabled,
                                                                 mode: batteryControl.status.mode) {
                Button {
                    let window = NSApp.keyWindow
                    let limit = batteryLimitPercentage
                    Task {
                        if let failure = await batteryControl.installAndApply(
                            enabled: batteryLimitEnabled,
                            limitPercentage: limit,
                            window: window) {
                            installErrorMessage = Self.message(for: failure, locale: locale)
                            isInstallFailedAlertPresented = true
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if batteryControl.isInstallingHelper {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 10, height: 10)
                        }
                        Text("도우미 설치")
                            .font(WattlyFont.at(11.5, weight: .medium))
                            .foregroundStyle(t.text)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rowBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(batteryControl.isInstallingHelper)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
```

Replace `resolvedStatus` with:

```swift
    private var resolvedStatus: BatterySectionPresentation.Status {
        BatterySectionPresentation.status(
            isLimitOn: batteryLimitEnabled,
            isInstalling: batteryControl.isInstallingHelper,
            mode: batteryControl.status.mode,
            reason: batteryControl.status.detailReason,
            detail: batteryControl.status.detail,
            locale: locale,
            activity: batteryControl.status.activity,
            updatedAt: batteryControl.status.updatedAt,
            now: Date().timeIntervalSince1970)
    }
```

Replace `dotColor(for:)` with:

```swift
    private func statusColor(for tone: BatterySectionPresentation.Tone) -> Color {
        switch tone {
        case .green: return Tokens.statusGreen
        case .orange: return Tokens.statusOrange
        case .red: return Tokens.statusRed
        case .faint: return t.faint
        }
    }
```

- [ ] **Step 7: Run the focused presentation and localization tests**

Run:

```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' \
  -only-testing:WattlyTests/BatterySectionPresentationTests \
  -only-testing:WattlyTests/BatteryStatusTextTests \
  -only-testing:WattlyTests/SettingsBatterySectionTests \
  -only-testing:WattlyTests/LocalizationTests
```

Expected: `TEST SUCCEEDED`; every activity has a stable semantic indicator, stale data renders `확인 중...`, errors outrank activities, and existing localized status text remains unchanged.

- [ ] **Step 8: Run the full automated gate**

Run:

```bash
xcodegen generate
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'
xcodebuild build -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'
git diff --check
```

Expected: both Xcode commands finish with `TEST SUCCEEDED` / `BUILD SUCCEEDED`, and `git diff --check` prints nothing.

- [ ] **Step 9: Perform the settings-row acceptance check**

Run the app with the installed helper and verify these exact states:

1. Limit OFF: pause-circle icon, faint tone, localized `충전 제한 비활성화됨`.
2. Limit ON below target while plugged in: bolt-circle icon, green tone, localized charging-to-target text.
3. Limit reached: pause-circle icon, orange tone, localized adapter-bypass text.
4. Adapter unplugged: battery icon, green tone, localized on-battery text.
5. Helper unavailable while limit is ON: red warning-triangle icon, localized helper error, install button visible.
6. Hardware unsupported: limit picker and advisory hidden, red `nosign` indicator and localized unsupported text still visible.
7. VoiceOver reads the localized status sentence once and does not announce the SF Symbol's English name.
8. On a macOS 14 test Mac or VM, open the same settings row and confirm all indicators render instead of leaving blank symbol space. The automated `NSImage` loop catches typos on the current runner; this acceptance step verifies the deployment floor specifically.

Expected: the icon, tone, and text agree in all eight checks; unsupported hardware retains its explanation, and no Sailing, Heat Protection, or Top Up control appears.

- [ ] **Step 10: Commit the status indicator slice**

```bash
git add Wattly/Core/BatterySectionPresentation.swift \
  Wattly/Views/Settings/SettingsBatterySection.swift \
  WattlyTests/BatterySectionPresentationTests.swift
git commit -m "feat(battery): show semantic control status icons"
```

---

## Final verification and PR scope

Before opening the implementation PR, run:

```bash
git status --short
git log --oneline --decorate -3
git diff origin/main...HEAD -- \
  FanControlShared/BatteryControlActivity.swift \
  FanControlShared/BatteryControlProtocol.swift \
  FanControlShared/BatteryControlEngine.swift \
  Wattly/Core/BatterySectionPresentation.swift \
  Wattly/Views/Settings/SettingsBatterySection.swift \
  WattlyTests/BatteryControlActivityTests.swift \
  WattlyTests/BatteryControlProtocolTests.swift \
  WattlyTests/BatteryControlEngineTests.swift \
  WattlyTests/BatterySectionPresentationTests.swift \
  docs/plans/2026-08-23-battery-control-activity-status.md \
  Wattly.xcodeproj/project.pbxproj
```

Expected PR contents:

- One optional, backward-compatible XPC field.
- Four base activities emitted by current behavior.
- Future activity vocabulary with no future control behavior.
- Semantic SF Symbol plus localized text in the existing settings status row.
- Stale-state feedback after 15 seconds.
- No SMC, polling, configuration, scheduling, or menu-bar behavior changes.

Do not stage `docs/features/battery-management/` into this PR. Those 11 feature definitions remain the separate documentation PR agreed with the user.
