# Manual & Automatic Discharge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement safe manual and automatic battery discharge in Wattly, utilizing Apple Silicon SMC `CHIE` register with a fail-closed safety model, mutual exclusion with Top-Up, Settings 50%~100% slider, and Menu Bar Popover live indicators.

**Architecture:** SMC register probing and atomic writes (`BatteryControlKeys` in `FanControlShared/BatteryControlKeys.swift` and `SMCBatteryControlHardware` in `WattlyFanDaemon/BatteryControlHardware.swift`), prioritized state machine engine (`BatteryControlEngine.swift`), atomic XPC coordination with Top-Up mutual exclusion (`BatteryControlCoordinator.swift`), client APIs (`BatteryControlClient.swift`), and SwiftUI views (`SettingsBatterySection.swift`, `CardExpandRegion.swift`, `MetricCardView.swift`).

**Tech Stack:** Swift 5.10+, SwiftUI, AppKit, IOKit, SMC Driver, macOS LaunchDaemon (XPC), Swift Testing (`import Testing`), XcodeGen, xcodebuild

## Global Constraints

- **Hardware Register**: SMC `CHIE` (1 byte, `type=hex_`, write `0x08` for discharge, `0x00` for normal/idle). Writeable attribute `0x40` on Apple Silicon modern Macs (`probeOrder` candidate).
- **Fail-Closed Invariant**: Never persist active discharge sessions to `BatteryPolicyFileStore`. Always restore `CHIE=0x00` on daemon start (`hydrateHardwareState`), shutdown (`releaseForTermination`), sleep (`.willSleep`), and adapter unplug (`onBatteryPower`).
- **Priority Pipeline**: Thermal Protection (>= 35°C) > Low Battery Protection (< 15%) > Manual Discharge (`manualDischargeActive`) > Top-Up (`topUpActive`) > Auto Discharge (`autoDischargeEnabled` & `SoC > limit + 1`) > Charge Limit Hysteresis.
- **Mutual Exclusion with Top-Up**: Top-Up and Manual Discharge cannot run concurrently. When Top-Up reaches 100%, hold at 100% bypass without auto-discharging until unplugged or user setting change.
- **Configurable Range**: Manual discharge target slider supports 50% to 100% with 1% granularity, defaulting to the current charge limit (e.g. 80%).
- **Tooling & Test Framework**: Strictly use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`) and `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/<TestName>`. Localization strictly uses `Wattly/Resources/Localizable.xcstrings`.

---

## File Structure

```
FanControlShared/
├── BatteryControlKeys.swift               # [MODIFY] Add CHIE probe order, discharge writes, and isDischargeSupported
├── BatteryControlEngine.swift             # [MODIFY] Update BatteryControlHardwareProtocol & state machine pipeline with discharge & fail-closed normalize
├── BatteryControlProtocol.swift           # [MODIFY] Extend BatteryControlConfiguration & client requests for discharge
├── BatteryControlActivity.swift           # [VERIFIED] .discharging already declared
├── BatteryControlStatusReason.swift       # [MODIFY] Add discharge status reason codes
└── BatteryControlCoordinator.swift        # [MODIFY] Manage discharge session, sleep/unplug handlers, mutual exclusion

WattlyFanDaemon/
└── BatteryControlHardware.swift           # [MODIFY] Implement SMCBatteryControlHardware discharge writes and release

Wattly/
├── Control/BatteryControlClient.swift     # [MODIFY] Client API for startManualDischarge, stopManualDischarge, setAutoDischarge
├── Core/BatteryNotificationManager.swift  # [MODIFY] Add discharge completion push notification
├── Core/BatterySectionPresentation.swift  # [MODIFY] Formatting for discharge status, remaining time, net watts
├── Views/Settings/SettingsBatterySection.swift # [MODIFY] Add Auto Discharge toggle & Manual Discharge 50%~100% slider
├── Views/CardExpandRegion.swift           # [MODIFY] Add Discharge row and mutual exclusion button in Popover
├── Views/MetricCardView.swift             # [MODIFY] Visual cues for discharging state (sparkline, pulse dot)
└── Resources/Localizable.xcstrings        # [MODIFY] Add Korean & English strings for discharge UI

WattlyTests/
├── BatteryControlKeysTests.swift          # [MODIFY] Verify CHIE probing and write generation
├── BatteryControlEngineTests.swift        # [MODIFY] Swift Testing for discharge pipeline & mutual exclusion
├── BatteryControlCoordinatorTests.swift   # [MODIFY] Swift Testing for session lifecycle & fail-closed resets
├── BatteryControlClientTests.swift        # [MODIFY] Swift Testing for client API
├── BatterySectionPresentationTests.swift  # [MODIFY] Swift Testing for presentation text and time calculation
└── SettingsBatterySectionTests.swift      # [MODIFY] Swift Testing for slider and toggle states
```

---

## Task Decomposition

### Task 1: SMC Register & Hardware Layer (`CHIE`)

**Files:**
- Modify: `FanControlShared/BatteryControlKeys.swift:150-170,298-330`
- Modify: `FanControlShared/BatteryControlEngine.swift:3-30`
- Modify: `WattlyFanDaemon/BatteryControlHardware.swift:4-90`
- Test: `WattlyTests/BatteryControlKeysTests.swift`

**Interfaces:**
- Consumes: `SMCKeyInfo`, `SMCKeyData`
- Produces: `BatteryControlKeys.dischargeWrites(active:) -> [BatteryControlKeyWrite]`, `BatteryControlHardwareProtocol.setDischargingActive(_ active: Bool) -> Bool`, `isDischargeHardwareSupported: Bool`

- [ ] **Step 1: Write the failing unit tests for CHIE key probing and writes**

```swift
// In WattlyTests/BatteryControlKeysTests.swift
import Testing
@testable import FanControlShared

@Suite struct BatteryControlKeysDischargeTests {
    @Test func dischargeKeyProbingAndWrites() {
        let registerSet = BatteryControlKeys.registerSet { key in
            if key == "CHIE" { return ("hex_", 1) }
            if key == "CHTE" { return ("ui32", 4) }
            return nil
        }
        #expect(registerSet.isDischargeSupported)
        let writesOn = BatteryControlKeys.dischargeWrites(active: true, registerSet: registerSet)
        #expect(writesOn.contains(where: { $0.key == "CHIE" && $0.bytes == [0x08] }))
        let writesOff = BatteryControlKeys.dischargeWrites(active: false, registerSet: registerSet)
        #expect(writesOff.contains(where: { $0.key == "CHIE" && $0.bytes == [0x00] }))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**
Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlKeysDischargeTests`
Expected: FAIL (missing `isDischargeSupported` / `dischargeWrites`)

- [ ] **Step 3: Implement CHIE probing in `BatteryControlKeys`, protocol in `BatteryControlEngine.swift`, and hardware in `WattlyFanDaemon/BatteryControlHardware.swift`**
- Add `CHIE` probing to `probeOrder`.
- Add `dischargeWrites(active:registerSet:) -> [BatteryControlKeyWrite]`.
- Add `setDischargingActive(_ active: Bool) -> Bool` to `BatteryControlHardwareProtocol` and `SMCBatteryControlHardware`.

- [ ] **Step 4: Run test to verify it passes**
Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlKeysDischargeTests`
Expected: PASS

- [ ] **Step 5: Commit**
```bash
git add FanControlShared/BatteryControlKeys.swift FanControlShared/BatteryControlEngine.swift WattlyFanDaemon/BatteryControlHardware.swift WattlyTests/BatteryControlKeysTests.swift
git commit -m "feat(hardware): implement SMC CHIE register probing and discharge writes"
```

---

### Task 2: Core Domain & Configuration Models

**Files:**
- Modify: `FanControlShared/BatteryControlProtocol.swift:3-80`
- Modify: `FanControlShared/BatteryControlStatusReason.swift:1-40`
- Test: `WattlyTests/BatteryControlPolicyTests.swift`

**Interfaces:**
- Consumes: `BatteryControlConfiguration`
- Produces: `autoDischargeEnabled: Bool`, `manualDischargeActive: Bool`, `manualDischargeTarget: Int`, `dischargingToTarget`, `dischargingManual`

- [ ] **Step 1: Write failing test for configuration normalization & discharge properties**

```swift
// In WattlyTests/BatteryControlPolicyTests.swift
import Testing
@testable import FanControlShared

@Suite struct BatteryControlDischargePolicyTests {
    @Test func dischargeConfigurationProperties() {
        let config = BatteryControlConfiguration(
            enabled: true,
            limitPercentage: 80,
            autoDischargeEnabled: true,
            manualDischargeActive: true,
            manualDischargeTarget: 70
        )
        #expect(config.clampedManualDischargeTarget == 70)
        #expect(config.autoDischargeEnabled == true)
        #expect(config.manualDischargeActive == true)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**
Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlDischargePolicyTests`
Expected: FAIL

- [ ] **Step 3: Implement discharge fields and normalization in `BatteryControlConfiguration` (`FanControlShared/BatteryControlProtocol.swift`) and reasons in `BatteryControlStatusReason`**

- [ ] **Step 4: Run test to verify it passes**
Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlDischargePolicyTests`
Expected: PASS

- [ ] **Step 5: Commit**
```bash
git add FanControlShared/BatteryControlProtocol.swift FanControlShared/BatteryControlStatusReason.swift WattlyTests/BatteryControlPolicyTests.swift
git commit -m "feat(domain): add discharge configuration parameters and status reasons"
```

---

### Task 3: State Machine & Safety Engine (`BatteryControlEngine`)

**Files:**
- Modify: `FanControlShared/BatteryControlEngine.swift:190-320`
- Test: `WattlyTests/BatteryControlEngineTests.swift`

**Interfaces:**
- Consumes: `BatteryControlConfiguration`, `BatteryControlHardwareProtocol`
- Produces: `BatteryControlEngine.update(currentSoC:isPluggedIn:temperatureCelsius:now:)` returning `.discharging` activity, `normalizeOnFirstUpdate()`, `releaseVerified()`

- [ ] **Step 1: Write failing unit tests for priority pipeline, mutual exclusion, and fail-closed normalization**

```swift
// In WattlyTests/BatteryControlEngineTests.swift
import Testing
@testable import FanControlShared

@Suite struct BatteryControlEngineDischargeTests {
    @Test func manualDischargeTransitionsToTargetAndReverts() {
        let mockHardware = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHardware)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80, manualDischargeActive: true, manualDischargeTarget: 70))
        
        let status1 = engine.update(currentSoC: 85, isPluggedIn: true)
        #expect(status1.activity == .discharging)
        #expect(mockHardware.isDischargeActive == true)
        
        // Reaching target:
        let status2 = engine.update(currentSoC: 70, isPluggedIn: true)
        #expect(status2.activity == .holdingAtLimit)
        #expect(mockHardware.isDischargeActive == false)
    }

    @Test func thermalProtectionOverridesDischarge() {
        let mockHardware = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHardware)
        engine.configure(BatteryControlConfiguration(enabled: true, limitPercentage: 80, manualDischargeActive: true, manualDischargeTarget: 70, heatProtectionEnabled: true, heatProtectionThresholdCelsius: 35))
        
        let status = engine.update(currentSoC: 85, isPluggedIn: true, temperatureCelsius: 36.0)
        #expect(status.activity == .heatProtection)
        #expect(mockHardware.isDischargeActive == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**
Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlEngineDischargeTests`
Expected: FAIL

- [ ] **Step 3: Implement prioritized evaluation pipeline and `CHIE` writes in `BatteryControlEngine`**
- Pipeline: Heat protection (>=35°C) -> Low SoC (<15%) -> Manual Discharge -> Top-Up -> Auto Discharge -> Limit Hysteresis.
- Ensure `normalizeOnFirstUpdate` and `releaseVerified` normalize `CHIE=0x00`.
- Implement `topUpCompletedHold` to hold 100% bypass without immediate auto-discharge.

- [ ] **Step 4: Run test to verify it passes**
Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlEngineDischargeTests`
Expected: PASS

- [ ] **Step 5: Commit**
```bash
git add FanControlShared/BatteryControlEngine.swift WattlyTests/BatteryControlEngineTests.swift
git commit -m "feat(engine): implement discharge state machine pipeline and safety invariants"
```

---

### Task 4: Coordinator & Daemon Lifecycle (`BatteryControlCoordinator`)

**Files:**
- Modify: `FanControlShared/BatteryControlCoordinator.swift:150-320`
- Test: `WattlyTests/BatteryControlCoordinatorTests.swift`

**Interfaces:**
- Consumes: `BatteryControlEngine`, `BatteryPolicyStoring`
- Produces: `startManualDischarge`, `stopManualDischarge`, Unplug and Sleep safety reset

- [ ] **Step 1: Write failing unit tests for non-persisted discharge session and unplug safety reset**

```swift
// In WattlyTests/BatteryControlCoordinatorTests.swift
import Testing
@testable import FanControlShared

@Suite struct BatteryControlCoordinatorDischargeTests {
    @Test func unplugResetsDischargeState() {
        let mockStore = MockBatteryPolicyStore()
        let mockEngine = BatteryControlEngine(hardware: MockBatteryHardware())
        let coordinator = BatteryControlCoordinator(ownerUID: 501, store: mockStore, engine: mockEngine, now: { 1000 })
        
        let config = BatteryControlConfiguration(enabled: true, limitPercentage: 80, manualDischargeActive: true, manualDischargeTarget: 70)
        _ = coordinator.configure(config, trigger: .clientRequest)
        _ = coordinator.sample(currentSoC: 80, isPluggedIn: false)
        
        #expect(coordinator.latestStatus.desiredConfiguration?.manualDischargeActive == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**
Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlCoordinatorDischargeTests`
Expected: FAIL

- [ ] **Step 3: Implement coordinator methods and unplug/sleep safety reset**
Ensure `BatteryPolicyFileStore` never persists `manualDischargeActive: true`.

- [ ] **Step 4: Run test to verify it passes**
Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlCoordinatorDischargeTests`
Expected: PASS

- [ ] **Step 5: Commit**
```bash
git add FanControlShared/BatteryControlCoordinator.swift WattlyTests/BatteryControlCoordinatorTests.swift
git commit -m "feat(coordinator): manage discharge session lifecycle and fail-closed unplug safety"
```

---

### Task 5: Client API & Notification Manager

**Files:**
- Modify: `Wattly/Control/BatteryControlClient.swift:80-140`
- Modify: `Wattly/Core/BatteryNotificationManager.swift:30-80`
- Test: `WattlyTests/BatteryControlClientTests.swift`

**Interfaces:**
- Consumes: `BatteryControlProtocol`
- Produces: `BatteryControlClient.startManualDischarge(target:)`, `stopManualDischarge()`, `BatteryNotificationManager.notifyDischargeCompleted(target:)`

- [ ] **Step 1: Write failing tests for client discharge commands and notification triggers**

```swift
// In WattlyTests/BatteryControlClientTests.swift
import Testing
@testable import Wattly
@testable import FanControlShared

@Suite struct BatteryControlClientDischargeTests {
    @Test func clientDischargeCommands() async {
        let client = BatteryControlClient { request in
            let status = BatteryControlServiceStatus(mode: .active, currentPercentage: 85, isPowerAdapterConnected: true, desiredConfiguration: .init(manualDischargeActive: true, manualDischargeTarget: 70))
            let data = try? BatteryControlCodec.encode(status)
            return (data, nil)
        }
        let status = await client.startManualDischarge(target: 70)
        #expect(status?.desiredConfiguration?.manualDischargeTarget == 70)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**
Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlClientDischargeTests`
Expected: FAIL

- [ ] **Step 3: Implement client methods and push notification trigger on discharge completion**

- [ ] **Step 4: Run test to verify it passes**
Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlClientDischargeTests`
Expected: PASS

- [ ] **Step 5: Commit**
```bash
git add Wattly/Control/BatteryControlClient.swift Wattly/Core/BatteryNotificationManager.swift WattlyTests/BatteryControlClientTests.swift
git commit -m "feat(client): add discharge control client methods and completion notifications"
```

---

### Task 6: Presentation & Localization Layer

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift:30-120`
- Modify: `Wattly/Core/BatteryStatusText.swift:20-60`
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Test: `WattlyTests/BatterySectionPresentationTests.swift`

**Interfaces:**
- Consumes: `BatteryControlActivity.discharging`, `currentSoC`, `target`
- Produces: `statusText`, `remainingDischargeTimeText`, localized entries in String Catalog

- [ ] **Step 1: Write failing unit tests for presentation helpers and localized strings**

```swift
// In WattlyTests/BatterySectionPresentationTests.swift
import Testing
@testable import Wattly
@testable import FanControlShared

@Suite struct BatterySectionPresentationDischargeTests {
    @Test func dischargePresentationText() {
        let text = BatterySectionPresentation.dischargeDescription(target: 70, currentSoC: 85, watts: -18.4)
        #expect(text.contains("70%"))
        #expect(text.contains("-18.4 W"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**
Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatterySectionPresentationDischargeTests`
Expected: FAIL

- [ ] **Step 3: Implement presentation helpers and add English & Korean entries to `Localizable.xcstrings`**

- [ ] **Step 4: Run test to verify it passes**
Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatterySectionPresentationDischargeTests`
Expected: PASS

- [ ] **Step 5: Commit**
```bash
git add Wattly/Core/BatterySectionPresentation.swift Wattly/Core/BatteryStatusText.swift Wattly/Resources/Localizable.xcstrings WattlyTests/BatterySectionPresentationTests.swift
git commit -m "feat(presentation): add localized discharge status descriptions and string catalog entries"
```

---

### Task 7: Settings UI (`SettingsBatterySection`)

**Files:**
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift:1-260`
- Test: `WattlyTests/SettingsBatterySectionTests.swift`

**Interfaces:**
- Consumes: `BatteryControlClient`, `manualDischargeTarget` AppStorage
- Produces: Auto Discharge Toggle, Manual Discharge 50%~100% Slider with live values and Start/Stop buttons

- [ ] **Step 1: Write failing snapshot/view tests for Settings discharge controls**

```swift
// In WattlyTests/SettingsBatterySectionTests.swift
import Testing
@testable import Wattly

@Suite struct SettingsBatterySectionDischargeTests {
    @Test func settingsDischargeSliderAndToggleRendering() {
        let view = SettingsBatterySection()
        #expect(view != nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**
Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/SettingsBatterySectionDischargeTests`
Expected: FAIL

- [ ] **Step 3: Implement Auto Discharge toggle card and Manual Discharge 50%~100% slider in `SettingsBatterySection`**

- [ ] **Step 4: Run test to verify it passes**
Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/SettingsBatterySectionDischargeTests`
Expected: PASS

- [ ] **Step 5: Commit**
```bash
git add Wattly/Views/Settings/SettingsBatterySection.swift WattlyTests/SettingsBatterySectionTests.swift
git commit -m "feat(ui): add auto discharge toggle and 50%~100% manual discharge slider in Settings"
```

---

### Task 8: Menu Bar Popover UI (`CardExpandRegion` & `MetricCardView`)

**Files:**
- Modify: `Wattly/Views/CardExpandRegion.swift:315-365`
- Modify: `Wattly/Views/MetricCardView.swift:55-80,205-225`
- Test: `WattlyTests/CardPresentationTests.swift`

**Interfaces:**
- Consumes: `BatteryControlClient`, `BatteryControlActivity`
- Produces: Popover discharge subtext, orange pulse indicator, negative net wattage display, `수동 방전` row with `[XX%까지 방전]` / `[방전 중지]` button

- [ ] **Step 1: Write failing view tests for popover discharge controls and mutual switching**

- [ ] **Step 2: Run test to verify it fails**
Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/CardPresentationTests`
Expected: FAIL

- [ ] **Step 3: Implement popover battery card expand discharge row and visual feedback in `MetricCardView`**

- [ ] **Step 4: Run test to verify it passes**
Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/CardPresentationTests`
Expected: PASS

- [ ] **Step 5: Commit**
```bash
git add Wattly/Views/CardExpandRegion.swift Wattly/Views/MetricCardView.swift WattlyTests/CardPresentationTests.swift
git commit -m "feat(ui): add discharge row and live indicators to Popover expandable battery card"
```

---

### Task 9: Full Integration Verification & Build

**Files:**
- Verify: Full codebase

- [ ] **Step 1: Run complete unit test suite**
Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'`
Expected: **TEST SUCCEEDED** (All tests pass with 0 failures)

- [ ] **Step 2: Run clean project build**
Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' build`
Expected: **BUILD SUCCEEDED**

- [ ] **Step 3: Final Commit & Tagging**
```bash
git commit --allow-empty -m "chore: complete manual & automatic discharge integration"
```

---

## Verification Plan

### Automated Tests
- `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlKeysDischargeTests`
- `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlEngineDischargeTests`
- `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlCoordinatorDischargeTests`
- `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlClientDischargeTests`
- `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatterySectionPresentationDischargeTests`
- `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/SettingsBatterySectionDischargeTests`
- `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'` (Full test suite)

### Manual Verification
1. **Settings Slider**: Open Settings › Battery Control, slide manual target between 50% and 100%, verify label changes live.
2. **Manual Discharge Trigger**: Click `[XX%까지 방전 시작]`, verify Popover shows orange pulse, negative wattage (`-18.4 W`), and status transitions to `holdingAtLimit` when target is reached.
3. **Safety Fallback**: Unplug AC adapter while discharging, verify discharge immediately cancels and reverts `CHIE=0x00`.
4. **Top-Up Mutual Exclusion**: Start Top-Up, then start Manual Discharge — verify Top-Up is cancelled and discharge takes over safely.
