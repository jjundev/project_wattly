# Battery Heat Protection Threshold Presets Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update the Battery Heat Protection threshold presets to `[32°C, 35°C, 38°C, 40°C]` with the new industry-standard default of `35°C` (aligned with Apple battery operating guidelines and AlDente Pro).

**Architecture:** Update the shared default threshold and preset definitions across `FanControlShared` protocol/codec/status reasoning, `Wattly` settings defaults, client convenience signatures, presentation presets, and test suites.

**Tech Stack:** Swift 5.9+, SwiftUI, XCTest / Swift Testing (`Testing`).

## Global Constraints

- Target macOS 14.0 and later on Apple Silicon arm64; no Intel path.
- Add no third-party dependencies.
- Preserve backward and forward compatibility across the privileged XPC interface for older helpers and app versions.
- Leniently decode `BatteryControlStatusReason`, `BatteryControlActivity`, and `BatteryControlConfiguration` without throwing on unknown or malformed tokens.
- The full validation gate is `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData` and `xcodebuild build -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData`.

---

### Task 1: Update Default Threshold to 35°C in Protocol, Status Reasoning & Client

**Files:**
- Modify: `FanControlShared/BatteryControlProtocol.swift:15-50`
- Modify: `FanControlShared/BatteryControlStatusReason.swift:150-155`
- Modify: `Wattly/Settings/Settings.swift:40-60`
- Modify: `Wattly/Control/BatteryControlClient.swift:70-190`
- Modify: `Wattly/Core/BatteryStatusText.swift:75-80`
- Test: `WattlyTests/BatteryControlProtocolTests.swift`
- Test: `WattlyTests/SettingsResetTests.swift`
- Test: `WattlyTests/BatteryControlClientTests.swift`

**Interfaces:**
- Consumes: `BatteryControlConfiguration`
- Produces: `Defaults.batteryHeatProtectionThreshold == 35`, `BatteryControlConfiguration.heatProtectionThresholdCelsius == 35` by default, fallback resume temperature `33°C` (`35 - 2 = 33`).

- [ ] **Step 1: Write the failing tests**

In `WattlyTests/BatteryControlProtocolTests.swift`:
```swift
    @Test func configurationDefaultHeatProtectionThresholdIs35() {
        let config = BatteryControlConfiguration()
        #expect(config.heatProtectionThresholdCelsius == 35)
    }

    @Test func decodingConfigurationWithoutThresholdDefaultsTo35() throws {
        let json = "{\"enabled\":true,\"limitPercentage\":80,\"lowerHysteresisDelta\":5,\"heatProtectionEnabled\":true}".data(using: .utf8)!
        let config = try BatteryControlCodec.decode(BatteryControlConfiguration.self, from: json)
        #expect(config.heatProtectionThresholdCelsius == 35)
    }
```

In `WattlyTests/SettingsResetTests.swift`:
```swift
    @Test func resetRestoresHeatProtectionThresholdTo35() {
        #expect(Defaults.batteryHeatProtectionThreshold == 35)
    }
```

In `WattlyTests/BatteryControlClientTests.swift`:
```swift
    @Test func clientApplyUsesDefaultThreshold35() async {
        var recordedRequest: BatteryControlClientRequest?
        let client = BatteryControlClient(requestHandler: { request in
            recordedRequest = request
            let status = BatteryControlServiceStatus(
                mode: .charging, currentPercentage: 50, isPowerAdapterConnected: true,
                detail: "ok", updatedAt: 100
            )
            return (try? BatteryControlCodec.encode(status), nil)
        })
        await client.apply(enabled: true, limitPercentage: 80, lowerHysteresisDelta: 5, heatProtectionEnabled: true)
        if case .configure(let data) = recordedRequest,
           let decoded = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data) {
            #expect(decoded.configuration.heatProtectionThresholdCelsius == 35)
        } else {
            Issue.record("Expected configure request with decoded config")
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing:WattlyTests/BatteryControlProtocolTests/configurationDefaultHeatProtectionThresholdIs35`
Expected: FAIL with `36 != 35`

- [ ] **Step 3: Update protocol, status reasoning, settings default, and client signatures**

In `FanControlShared/BatteryControlProtocol.swift`:
- Change default parameter `heatProtectionThresholdCelsius: Int = 35` in `init(...)` and fallback decoding default `?? 35`.

In `FanControlShared/BatteryControlStatusReason.swift:153`:
- Update fallback `resumeTemperatureCelsius ?? 33`.

In `Wattly/Settings/Settings.swift`:
- `public static let batteryHeatProtectionThreshold = 35`

In `Wattly/Control/BatteryControlClient.swift`:
- Change default parameter `heatProtectionThresholdCelsius: Int = 35` in `apply`, `disableAndConfirm`, `reconcile`, `installAndApply`.
- In `prepareForRemoval` (line 121), pass `heatProtectionThresholdCelsius: 35`.

In `Wattly/Core/BatteryStatusText.swift:77`:
- Update fallback `resumeTemperatureCelsius ?? 33`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing:WattlyTests/BatteryControlProtocolTests -only-testing:WattlyTests/SettingsResetTests -only-testing:WattlyTests/BatteryControlClientTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
GIT_CONFIG_GLOBAL=/dev/null git add FanControlShared/BatteryControlProtocol.swift FanControlShared/BatteryControlStatusReason.swift Wattly/Settings/Settings.swift Wattly/Control/BatteryControlClient.swift Wattly/Core/BatteryStatusText.swift WattlyTests/BatteryControlProtocolTests.swift WattlyTests/SettingsResetTests.swift WattlyTests/BatteryControlClientTests.swift
GIT_CONFIG_GLOBAL=/dev/null git commit -m "feat(battery): update default heat protection threshold to 35C"
```

---

### Task 2: Update Presentation Presets to [32°C, 35°C, 38°C, 40°C] & UI Integration

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift:250-255`
- Test: `WattlyTests/BatterySectionPresentationTests.swift`
- Test: `WattlyTests/SettingsBatterySectionTests.swift`

**Interfaces:**
- Consumes: `BatterySectionPresentation.heatProtectionThresholdPresets`
- Produces: `BatterySectionPresentation.heatProtectionThresholdPresets == [32, 35, 38, 40]`

- [ ] **Step 1: Write the failing tests**

In `WattlyTests/BatterySectionPresentationTests.swift:631`:
```swift
    @Test func heatProtectionThresholdPresetsAreValid() {
        #expect(BatterySectionPresentation.heatProtectionThresholdPresets == [32, 35, 38, 40])
    }
```

In `WattlyTests/SettingsBatterySectionTests.swift`:
```swift
    @Test func heatProtectionPresetsMatchExpectedValues() {
        #expect(BatterySectionPresentation.heatProtectionThresholdPresets == [32, 35, 38, 40])
    }

    @Test func batteryHeatProtectionDefaultsAreConsistent() {
        #expect(Defaults.batteryHeatProtectionEnabled == false)
        #expect(Defaults.batteryHeatProtectionThreshold == 35)
        #expect(StorageKey.batteryHeatProtectionEnabled == "batteryHeatProtectionEnabled")
        #expect(StorageKey.batteryHeatProtectionThreshold == "batteryHeatProtectionThreshold")
    }

    @Test func batteryHeatProtectionThresholdCanBePersisted() {
        let defaults = UserDefaults(suiteName: "SettingsBatterySectionTests")!
        let presets = [32, 35, 38, 40]
        for preset in presets {
            defaults.set(preset, forKey: StorageKey.batteryHeatProtectionThreshold)
            #expect(defaults.integer(forKey: StorageKey.batteryHeatProtectionThreshold) == preset)
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing:WattlyTests/BatterySectionPresentationTests/heatProtectionThresholdPresetsAreValid`
Expected: FAIL with `[34, 36, 38, 40] != [32, 35, 38, 40]`

- [ ] **Step 3: Update BatterySectionPresentation presets**

In `Wattly/Core/BatterySectionPresentation.swift`:
```swift
    public static let heatProtectionThresholdPresets = [32, 35, 38, 40]
```

- [ ] **Step 4: Run full test suite and build**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData`
Run: `xcodebuild build -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData`
Expected: ALL 891+ tests PASS, BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
GIT_CONFIG_GLOBAL=/dev/null git add Wattly/Core/BatterySectionPresentation.swift WattlyTests/SettingsBatterySectionTests.swift WattlyTests/BatterySectionPresentationTests.swift
GIT_CONFIG_GLOBAL=/dev/null git commit -m "feat(ui): update heat protection presets to [32C, 35C, 38C, 40C]"
```
