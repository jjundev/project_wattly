# BatteryPreferences + 브리지 단일 쓰기 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 배터리 설정 9개를 읽고·기본값을 채우고·데몬 설정으로 바꾸는 규칙을 `BatteryPreferences` 한 곳에 두고, 데몬으로 밀어 넣는 주체를 `BatteryControlBridge` 하나로 만든다. 그 결과 이중 쓰기 경합, 스케줄 알림 기본값 불일치(true인데 false로 읽힘), Sailing 폭 0→1 전송, wake 직후 스케줄 2회 실행이 함께 사라진다.

**Architecture:** `BatteryPreferences`는 값 타입이다. `init(defaults:)`가 존재 여부를 가드해 읽고(`integer(forKey:)`의 0 함정 제거), `configuration(clamshellDischargeAllowed:)`가 유일한 조립 규칙이며, `write(to:)`는 바뀐 키만 쓴다. `BatteryControlBridge`는 아홉 개 `.onChange` 대신 `.onChange(of: preferences)` 하나로 관찰하고 250 ms 디바운스 후 `apply` 또는 `disable`을 결정한다(순수 `pushAction`). 설정 뷰·스케줄·인텐트·캘리브레이션·재설치 경로는 `BatteryPreferences`를 통해서만 설정을 만든다. 설정 뷰의 직접 `apply` 호출은 도우미 설치 분기 하나만 남긴다.

**Tech Stack:** Swift 6, SwiftUI `@AppStorage`, Swift Testing.

**Spec:** 감사 보고서 §2 High("배터리 설정마다 쓰기 주체가 둘"), High("새 설치에서 스케줄 알림이 절대 오지 않는다"), Medium("Sailing 폭이 1로 전송"), Medium("깨어난 뒤 스케줄이 두 번"), §3 "#1 심화 기회", "Pass-through" — https://claude.ai/code/artifact/20a3c5b7-ad33-4ec3-ae78-288a0259454d

## Global Constraints

- `BatteryControlClient.apply(enabled:limitPercentage:…)`의 기존 시그니처는 **유지**한다(테스트 40여 곳이 부른다). 새 `apply(_ configuration:isCalibrationWrite:)`를 추가하고 기존 것은 그리로 전달한다.
- `revivedConfiguration`(클라이언트 길목)의 규칙은 건드리지 않는다. 브리지의 `preservingActivity`도 그대로다.
- Shortcuts 인텐트는 결과를 반환해야 하므로 자기 `apply`를 유지한다. 인텐트가 설정 키를 쓰면 브리지가 같은 설정을 한 번 더 밀어 넣는다(2회 쓰기). 이건 받아들인다 — 데몬 `configure`는 멱등이고 인텐트는 분 단위 이벤트다.
- `SettingsReset.applyDefaults`가 모든 `StorageKey`를 덮는 계약은 유지된다(키를 추가하지 않는다).
- Swift 6 strict concurrency, macOS 14.0.

---

## 파일 구조

| 파일 | 책임 |
|------|------|
| `Wattly/Core/BatteryPreferences.swift` (신규) | 값 타입 + `UserDefaults` 존재-가드 읽기 확장. |
| `Wattly/Control/BatteryControlClient.swift` (수정) | `apply(_:isCalibrationWrite:)`, `installAndApply(_:transferringOwnership:window:)`, `startTopUp/cancelTopUp/startManualDischarge/stopManualDischarge(preferences:)` 추가. |
| `Wattly/Views/BatteryControlBridge.swift` (재작성) | 단일 관찰 + 디바운스 + `pushAction`. |
| `Wattly/Views/Settings/SettingsBatterySection.swift:252-425` (수정) | 설치 분기만 남김. |
| `Wattly/Views/Settings/SettingsBatteryDischargeSection.swift:173-206` (수정) | `.onChange→apply` 2개 삭제. |
| `Wattly/Core/BatteryScheduleCoordinator.swift` (수정) | `BatteryPreferences` 사용, 같은 분 재실행 방지, 알림 기본값. |
| `Wattly/Core/BatteryCalibrationCoordinator.swift:377-395` (수정) | `currentSnapshot` 위임. |
| `Wattly/Intents/BatteryIntentBridge.swift` (재작성) | 34개 존재-가드 → `BatteryPreferences`. |
| `Wattly/Views/CardExpandRegion.swift:428-452, 511-538`, `Wattly/Views/SettingsView.swift:435-452`, `Wattly/Views/Settings/SettingsBatteryCalibrationSection.swift:504-540` (수정) | 호출부. |
| `WattlyTests/BatteryPreferencesTests.swift` (신규), `BatteryControlBridgeTests.swift`, `BatteryScheduleCoordinatorTests.swift`, `BatteryIntentBridgeTests.swift` (수정) | |

---

### Task 1: `BatteryPreferences` 값 타입

**Files:**
- Create: `Wattly/Core/BatteryPreferences.swift`
- Create: `WattlyTests/BatteryPreferencesTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct BatteryPreferences: Equatable, Sendable {
      var limitEnabled: Bool; var limitPercentage: Int
      var sailingEnabled: Bool; var sailingDelta: Int
      var heatProtectionEnabled: Bool; var heatProtectionThresholdCelsius: Int
      var autoDischargeEnabled: Bool; var manualDischargeTarget: Int
      var clamshellDischargeEnabled: Bool
      static let standard: BatteryPreferences
      init(limitEnabled:limitPercentage:sailingEnabled:sailingDelta:heatProtectionEnabled:heatProtectionThresholdCelsius:autoDischargeEnabled:manualDischargeTarget:clamshellDischargeEnabled:)
      init(defaults: UserDefaults)
      func write(to defaults: UserDefaults)
      var effectiveHysteresisDelta: Int
      func configuration(clamshellDischargeAllowed: Bool) -> BatteryControlConfiguration
      var calibrationSnapshot: CalibrationSnapshot
  }
  extension UserDefaults {
      func wattlyBool(_ key: String, default fallback: Bool) -> Bool
      func wattlyInt(_ key: String, default fallback: Int) -> Int
  }
  ```
- Consumes: `Defaults.*`, `StorageKey.*`, `BatterySectionPresentation.clampedManualDischargeTarget`, `CalibrationSnapshot`.

- [ ] **Step 1: 실패하는 테스트**

```swift
// WattlyTests/BatteryPreferencesTests.swift
import Testing
import Foundation
@testable import Wattly

@Suite struct BatteryPreferencesTests {
    private func freshDefaults() -> UserDefaults {
        let name = "BatteryPreferencesTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// `integer(forKey:)`는 없는 키에 0을 준다. 감사에서 잡힌 두 버그(알림 false, Sailing 0→1)가 이 줄에서 죽는다.
    @Test func absentKeysReadAsTheDeclaredDefaults() {
        let prefs = BatteryPreferences(defaults: freshDefaults())
        #expect(prefs == .standard)
        #expect(prefs.sailingDelta == 5)
        #expect(prefs.manualDischargeTarget == 80)
        #expect(prefs.heatProtectionThresholdCelsius == 35)
        #expect(freshDefaults().wattlyBool(StorageKey.batteryScheduleNotificationsEnabled,
                                           default: Defaults.batteryScheduleNotificationsEnabled) == true)
    }

    @Test func writeThenReadRoundTripsEveryField() {
        let d = freshDefaults()
        var prefs = BatteryPreferences.standard
        prefs.limitEnabled = true; prefs.limitPercentage = 85
        prefs.sailingEnabled = true; prefs.sailingDelta = 4
        prefs.heatProtectionEnabled = true; prefs.heatProtectionThresholdCelsius = 38
        prefs.autoDischargeEnabled = true; prefs.manualDischargeTarget = 70
        prefs.clamshellDischargeEnabled = true
        prefs.write(to: d)
        #expect(BatteryPreferences(defaults: d) == prefs)
    }

    @Test func writeOnlyTouchesChangedKeys() {
        let d = freshDefaults()
        BatteryPreferences.standard.write(to: d)
        // 기본값과 같은 값은 쓰지 않는다 — 키가 여전히 없다.
        #expect(d.object(forKey: StorageKey.batteryLimitPercentage) == nil)
        var changed = BatteryPreferences.standard
        changed.limitPercentage = 90
        changed.write(to: d)
        #expect(d.object(forKey: StorageKey.batteryLimitPercentage) as? Int == 90)
        #expect(d.object(forKey: StorageKey.batterySailingDelta) == nil)
    }

    @Test func configurationAppliesTheSailingAndClampRules() {
        var prefs = BatteryPreferences.standard
        prefs.limitEnabled = true; prefs.limitPercentage = 85
        prefs.sailingEnabled = false; prefs.sailingDelta = 5
        prefs.manualDischargeTarget = 100
        let off = prefs.configuration(clamshellDischargeAllowed: true)
        #expect(off.lowerHysteresisDelta == 2)
        #expect(off.manualDischargeTarget == BatterySectionPresentation.manualDischargeTargetRange.upperBound)
        #expect(off.clamshellDischargeAllowed == true)
        #expect(off.topUpActive == false && off.manualDischargeActive == false && off.calibrationActive == false)

        prefs.sailingEnabled = true
        #expect(prefs.configuration(clamshellDischargeAllowed: false).lowerHysteresisDelta == 5)
    }

    @Test func calibrationSnapshotCarriesTheRawStoredValues() {
        var prefs = BatteryPreferences.standard
        prefs.sailingEnabled = true; prefs.sailingDelta = 3; prefs.manualDischargeTarget = 100
        let snap = prefs.calibrationSnapshot
        #expect(snap.sailingEnabled == true && snap.sailingDelta == 3)
        // 스냅샷은 원복용 원값이다. 클램프는 전송 시점(`configuration`)에만 한다.
        #expect(snap.manualDischargeTarget == 100)
    }

    /// 브리지가 `.onChange(of: preferences)` 하나로 관찰하므로, 모든 필드가 동등성에 참여해야 한다.
    @Test func everyFieldParticipatesInEquality() {
        let base = BatteryPreferences.standard
        var variants: [BatteryPreferences] = []
        var v = base; v.limitEnabled.toggle(); variants.append(v)
        v = base; v.limitPercentage += 1; variants.append(v)
        v = base; v.sailingEnabled.toggle(); variants.append(v)
        v = base; v.sailingDelta += 1; variants.append(v)
        v = base; v.heatProtectionEnabled.toggle(); variants.append(v)
        v = base; v.heatProtectionThresholdCelsius += 1; variants.append(v)
        v = base; v.autoDischargeEnabled.toggle(); variants.append(v)
        v = base; v.manualDischargeTarget += 1; variants.append(v)
        v = base; v.clamshellDischargeEnabled.toggle(); variants.append(v)
        #expect(variants.count == 9)
        for variant in variants { #expect(variant != base) }
    }
}
```

- [ ] **Step 2: 실패 확인** — Run: `… -only-testing:WattlyTests/BatteryPreferencesTests` — Expected: 컴파일 실패.

- [ ] **Step 3: 구현**

```swift
// Wattly/Core/BatteryPreferences.swift
import Foundation

/// 사용자가 저장한 배터리 제어 선호값 전부. 읽기(존재 가드 + 기본값), 쓰기(바뀐 키만),
/// 데몬 설정으로의 변환(Sailing 규칙, 방전 목표 클램프)이 여기 한 곳에만 있다.
/// 브리지·스케줄·Shortcuts·캘리브레이션·재설치는 모두 이 타입을 지나 `BatteryControlConfiguration`을 만든다.
struct BatteryPreferences: Equatable, Sendable {
    var limitEnabled: Bool
    var limitPercentage: Int
    var sailingEnabled: Bool
    var sailingDelta: Int
    var heatProtectionEnabled: Bool
    var heatProtectionThresholdCelsius: Int
    var autoDischargeEnabled: Bool
    var manualDischargeTarget: Int
    var clamshellDischargeEnabled: Bool

    static let standard = BatteryPreferences(
        limitEnabled: Defaults.batteryLimitEnabled,
        limitPercentage: Defaults.batteryLimitPercentage,
        sailingEnabled: Defaults.batterySailingEnabled,
        sailingDelta: Defaults.batterySailingDelta,
        heatProtectionEnabled: Defaults.batteryHeatProtectionEnabled,
        heatProtectionThresholdCelsius: Defaults.batteryHeatProtectionThreshold,
        autoDischargeEnabled: Defaults.batteryAutoDischargeEnabled,
        manualDischargeTarget: Defaults.batteryManualDischargeTarget,
        clamshellDischargeEnabled: Defaults.batteryClamshellDischargeEnabled)

    init(
        limitEnabled: Bool, limitPercentage: Int,
        sailingEnabled: Bool, sailingDelta: Int,
        heatProtectionEnabled: Bool, heatProtectionThresholdCelsius: Int,
        autoDischargeEnabled: Bool, manualDischargeTarget: Int,
        clamshellDischargeEnabled: Bool
    ) {
        self.limitEnabled = limitEnabled
        self.limitPercentage = limitPercentage
        self.sailingEnabled = sailingEnabled
        self.sailingDelta = sailingDelta
        self.heatProtectionEnabled = heatProtectionEnabled
        self.heatProtectionThresholdCelsius = heatProtectionThresholdCelsius
        self.autoDischargeEnabled = autoDischargeEnabled
        self.manualDischargeTarget = manualDischargeTarget
        self.clamshellDischargeEnabled = clamshellDischargeEnabled
    }

    /// `@AppStorage`는 기본값을 저장하지 않으므로 없는 키는 `Defaults`로 읽는다.
    init(defaults: UserDefaults) {
        let d = Self.standard
        limitEnabled = defaults.wattlyBool(StorageKey.batteryLimitEnabled, default: d.limitEnabled)
        limitPercentage = defaults.wattlyInt(StorageKey.batteryLimitPercentage, default: d.limitPercentage)
        sailingEnabled = defaults.wattlyBool(StorageKey.batterySailingEnabled, default: d.sailingEnabled)
        sailingDelta = defaults.wattlyInt(StorageKey.batterySailingDelta, default: d.sailingDelta)
        heatProtectionEnabled = defaults.wattlyBool(StorageKey.batteryHeatProtectionEnabled, default: d.heatProtectionEnabled)
        heatProtectionThresholdCelsius = defaults.wattlyInt(StorageKey.batteryHeatProtectionThreshold, default: d.heatProtectionThresholdCelsius)
        autoDischargeEnabled = defaults.wattlyBool(StorageKey.batteryAutoDischargeEnabled, default: d.autoDischargeEnabled)
        manualDischargeTarget = defaults.wattlyInt(StorageKey.batteryManualDischargeTarget, default: d.manualDischargeTarget)
        clamshellDischargeEnabled = defaults.wattlyBool(StorageKey.batteryClamshellDischargeEnabled, default: d.clamshellDischargeEnabled)
    }

    /// 바뀐 키만 쓴다. 안 바뀐 키까지 쓰면 `@AppStorage` 관찰자들이 헛되이 깨어난다.
    func write(to defaults: UserDefaults) {
        let current = BatteryPreferences(defaults: defaults)
        func put<T: Equatable>(_ new: T, _ old: T, _ key: String) {
            if new != old { defaults.set(new, forKey: key) }
        }
        put(limitEnabled, current.limitEnabled, StorageKey.batteryLimitEnabled)
        put(limitPercentage, current.limitPercentage, StorageKey.batteryLimitPercentage)
        put(sailingEnabled, current.sailingEnabled, StorageKey.batterySailingEnabled)
        put(sailingDelta, current.sailingDelta, StorageKey.batterySailingDelta)
        put(heatProtectionEnabled, current.heatProtectionEnabled, StorageKey.batteryHeatProtectionEnabled)
        put(heatProtectionThresholdCelsius, current.heatProtectionThresholdCelsius, StorageKey.batteryHeatProtectionThreshold)
        put(autoDischargeEnabled, current.autoDischargeEnabled, StorageKey.batteryAutoDischargeEnabled)
        put(manualDischargeTarget, current.manualDischargeTarget, StorageKey.batteryManualDischargeTarget)
        put(clamshellDischargeEnabled, current.clamshellDischargeEnabled, StorageKey.batteryClamshellDischargeEnabled)
    }

    /// Sailing이 꺼져 있으면 데몬 기본 2포인트 히스테리시스.
    var effectiveHysteresisDelta: Int { sailingEnabled ? sailingDelta : 2 }

    /// 데몬으로 나가는 유일한 조립 규칙. 활동 플래그(topUp/manualDischarge/calibration)는 여기서 세우지 않는다 —
    /// 그건 데몬 상태에서 `preservingActivity`/`revivedConfiguration`이 되살린다.
    func configuration(clamshellDischargeAllowed: Bool) -> BatteryControlConfiguration {
        BatteryControlConfiguration(
            enabled: limitEnabled,
            limitPercentage: limitPercentage,
            lowerHysteresisDelta: effectiveHysteresisDelta,
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
            autoDischargeEnabled: autoDischargeEnabled,
            manualDischargeTarget: BatterySectionPresentation.clampedManualDischargeTarget(manualDischargeTarget),
            clamshellDischargeAllowed: clamshellDischargeAllowed)
    }

    /// 캘리브레이션 원복용 원값. 클램프하지 않는다.
    var calibrationSnapshot: CalibrationSnapshot {
        CalibrationSnapshot(
            limitEnabled: limitEnabled,
            limitPercentage: limitPercentage,
            sailingEnabled: sailingEnabled,
            sailingDelta: sailingDelta,
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
            autoDischargeEnabled: autoDischargeEnabled,
            manualDischargeTarget: manualDischargeTarget)
    }
}

extension UserDefaults {
    /// `bool(forKey:)`는 없는 키에 false를 준다. 기본값이 true인 키에는 반드시 이걸 쓴다.
    func wattlyBool(_ key: String, default fallback: Bool) -> Bool {
        object(forKey: key) != nil ? bool(forKey: key) : fallback
    }

    /// `integer(forKey:)`는 없는 키에 0을 준다. 0이 유효값이 아닌 모든 키에 이걸 쓴다.
    func wattlyInt(_ key: String, default fallback: Int) -> Int {
        object(forKey: key) != nil ? integer(forKey: key) : fallback
    }
}
```

- [ ] **Step 4: 통과 확인** — Expected: 6개 PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/BatteryPreferences.swift WattlyTests/BatteryPreferencesTests.swift
git commit -m "feat(battery): add BatteryPreferences as the single source of stored-preference rules"
```

---

### Task 2: `BatteryControlClient` — 설정 값 타입을 받는 진입점

**Files:**
- Modify: `Wattly/Control/BatteryControlClient.swift:80-127` (`apply`), `:205-330` (래퍼들), `:432-500` (`installAndApply`)
- Test: `WattlyTests/BatteryControlClientTests.swift` (테스트 2개 추가)

**Interfaces:**
- Produces:
  - `func apply(_ configuration: BatteryControlConfiguration, isCalibrationWrite: Bool = false) async -> BatteryControlServiceStatus?`
  - `func installAndApply(_ configuration: BatteryControlConfiguration, transferringOwnership: Bool = false, window: NSWindow?) async -> InstallFailure?`
  - `func startTopUp(preferences: BatteryPreferences)`, `cancelTopUp(preferences:)`, `startManualDischarge(preferences:)`, `stopManualDischarge(preferences:)` — 모두 `async -> BatteryControlServiceStatus?`.

- [ ] **Step 1: 실패하는 테스트** — `BatteryControlClientTests`에 추가:

```swift
    @MainActor @Test func applyWithConfigurationSendsItThroughTheSameChokepoint() async throws {
        let receiver = RequestReceiver()   // 파일 안에 이미 있는 리시버 액터를 쓴다; 없으면 아래 정의를 추가한다.
        let client = BatteryControlClient(requestHandler: { request in
            await receiver.set(request)
            let status = BatteryControlServiceStatus(mode: .charging, currentPercentage: 50,
                                                     isPowerAdapterConnected: true, detail: "OK", updatedAt: 1)
            return (try? BatteryControlCodec.encode(status), nil)
        }, clamshellAllowance: { true })
        var prefs = BatteryPreferences.standard
        prefs.limitEnabled = true; prefs.limitPercentage = 85; prefs.manualDischargeTarget = 100
        _ = await client.apply(prefs.configuration(clamshellDischargeAllowed: false))
        guard case .configure(let data) = await receiver.request else { Issue.record("expected configure"); return }
        let sent = try BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data).configuration
        #expect(sent.limitPercentage == 85)
        #expect(sent.manualDischargeTarget == BatterySectionPresentation.manualDischargeTargetRange.upperBound)
        // 클램쉘 허용값은 호출자가 아니라 길목이 정한다.
        #expect(sent.clamshellDischargeAllowed == true)
    }

    @MainActor @Test func startTopUpFromPreferencesSetsTopUpActive() async throws {
        let receiver = RequestReceiver()
        let client = BatteryControlClient(requestHandler: { request in
            await receiver.set(request)
            let status = BatteryControlServiceStatus(mode: .charging, currentPercentage: 50,
                                                     isPowerAdapterConnected: true, detail: "OK", updatedAt: 1)
            return (try? BatteryControlCodec.encode(status), nil)
        })
        var prefs = BatteryPreferences.standard
        prefs.sailingEnabled = true; prefs.sailingDelta = 4
        _ = await client.startTopUp(preferences: prefs)
        guard case .configure(let data) = await receiver.request else { Issue.record("expected configure"); return }
        let sent = try BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data).configuration
        #expect(sent.topUpActive == true && sent.enabled == true && sent.lowerHysteresisDelta == 4)
    }
```

`RequestReceiver`가 파일에 없으면 상단에 추가:

```swift
private actor RequestReceiver {
    var request: BatteryControlClient.BatteryControlClientRequest?
    func set(_ r: BatteryControlClient.BatteryControlClientRequest) { request = r }
}
```

- [ ] **Step 2: 실패 확인** — Expected: 컴파일 실패.

- [ ] **Step 3: 구현** — 기존 `apply(enabled:…)`의 본문을 다음으로 바꾼다(문서 주석은 유지):

```swift
    @discardableResult
    public func apply(
        enabled: Bool,
        limitPercentage: Int,
        lowerHysteresisDelta: Int = 2,
        heatProtectionEnabled: Bool = false,
        heatProtectionThresholdCelsius: Int = 35,
        topUpActive: Bool = false,
        autoDischargeEnabled: Bool = false,
        manualDischargeActive: Bool = false,
        manualDischargeTarget: Int = 80,
        calibrationActive: Bool = false,
        calibrationTargetPercentage: Int = BatteryCalibration.floorPercentage,
        isCalibrationWrite: Bool = false
    ) async -> BatteryControlServiceStatus? {
        await apply(
            BatteryControlConfiguration(
                enabled: enabled,
                limitPercentage: limitPercentage,
                lowerHysteresisDelta: lowerHysteresisDelta,
                heatProtectionEnabled: heatProtectionEnabled,
                heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
                topUpActive: topUpActive,
                autoDischargeEnabled: autoDischargeEnabled,
                manualDischargeActive: manualDischargeActive,
                manualDischargeTarget: manualDischargeTarget,
                calibrationActive: calibrationActive,
                calibrationTargetPercentage: calibrationTargetPercentage),
            isCalibrationWrite: isCalibrationWrite)
    }

    /// 설정 값 타입을 그대로 받는 진입점. 위 파라미터 버전은 이리로 전달한다.
    @discardableResult
    public func apply(
        _ configuration: BatteryControlConfiguration,
        isCalibrationWrite: Bool = false
    ) async -> BatteryControlServiceStatus? {
        commandGeneration &+= 1
        let config = await revivedConfiguration(configuration, isCalibrationWrite: isCalibrationWrite)
        let request = BatteryControlConfigurationRequest(configuration: config, generation: commandGeneration)
        guard let data = try? BatteryControlCodec.encode(request) else {
            updateUnavailable("충전 제한 설정을 인코딩할 수 없음")
            return nil
        }
        return await send(.configure(data))
    }
```

`stopManualDischarge` 아래에 추가:

```swift
    // MARK: - BatteryPreferences 진입점

    @discardableResult
    public func startTopUp(preferences p: BatteryPreferences) async -> BatteryControlServiceStatus? {
        BatteryNotificationManager.requestAuthorization()
        var config = p.configuration(clamshellDischargeAllowed: false)
        config.enabled = true
        config.topUpActive = true
        return await apply(config)
    }

    @discardableResult
    public func cancelTopUp(preferences p: BatteryPreferences) async -> BatteryControlServiceStatus? {
        var config = p.configuration(clamshellDischargeAllowed: false)
        config.enabled = true
        config.topUpActive = false
        return await apply(config)
    }

    @discardableResult
    public func startManualDischarge(preferences p: BatteryPreferences) async -> BatteryControlServiceStatus? {
        BatteryNotificationManager.requestAuthorization()
        var config = p.configuration(clamshellDischargeAllowed: false)
        config.enabled = true
        config.manualDischargeActive = true
        return await apply(config)
    }

    @discardableResult
    public func stopManualDischarge(preferences p: BatteryPreferences) async -> BatteryControlServiceStatus? {
        var config = p.configuration(clamshellDischargeAllowed: false)
        config.enabled = true
        config.manualDischargeActive = false
        return await apply(config)
    }
```

`installAndApply(enabled:…)` 위에 추가하고, 기존 함수는 본문을 아래 새 함수 호출로 바꾼다:

```swift
    /// 설정 값 타입을 받는 설치 경로. 설치 → 밀어 넣기 → 수락 확인까지 한 번에.
    public func installAndApply(
        _ configuration: BatteryControlConfiguration,
        transferringOwnership: Bool = false,
        window: NSWindow?
    ) async -> InstallFailure? {
        isInstallingHelper = true
        defer { isInstallingHelper = false }
        if let failure = await installHandler(window, transferringOwnership, {
            await self.apply(configuration)
        }) {
            return .install(failure)
        }
        let revived = await revivedConfiguration(configuration, isCalibrationWrite: false)
        guard BatteryControlPolicy.accepted(configuration: revived, by: status) else {
            return .configureRejected(reason: status.detailReason, detail: status.detail)
        }
        return nil
    }
```

기존 `installAndApply(enabled:limitPercentage:…window:)`의 본문:

```swift
        await installAndApply(
            BatteryControlConfiguration(
                enabled: enabled,
                limitPercentage: limitPercentage,
                lowerHysteresisDelta: lowerHysteresisDelta,
                heatProtectionEnabled: heatProtectionEnabled,
                heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
                topUpActive: false,
                autoDischargeEnabled: autoDischargeEnabled,
                manualDischargeActive: manualDischargeActive,
                manualDischargeTarget: manualDischargeTarget),
            transferringOwnership: transferringOwnership,
            window: window)
```

- [ ] **Step 4: 통과 확인** — Run: `… -only-testing:WattlyTests/BatteryControlClientTests` — Expected: 기존 + 2개 PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Control/BatteryControlClient.swift WattlyTests/BatteryControlClientTests.swift
git commit -m "feat(battery): accept BatteryControlConfiguration and BatteryPreferences at the client chokepoint"
```

---

### Task 3: `BatteryControlBridge` — 단일 관찰, 디바운스, `pushAction`

**Files:**
- Rewrite: `Wattly/Views/BatteryControlBridge.swift`
- Modify: `WattlyTests/BatteryControlBridgeTests.swift` (`makeConfiguration`/`effectiveDelta`/`reconcileTaskID` 테스트 → `pushAction` 테스트로 교체)

**Interfaces:**
- Produces:
  - `enum BatteryControlBridge.PushAction: Equatable { case none, apply, disable }`
  - `static func pushAction(from old: BatteryPreferences, to new: BatteryPreferences, hasExternalDisplay: Bool) -> PushAction`
  - `static let pushDebounceMilliseconds = 250`
  - `preservingActivity`, `unsupportedStreak`, `wakeAction`, `shouldAnnounceTopUpExpiry`는 그대로.
- 삭제: `makeConfiguration`, `effectiveDelta`, `reconcileTaskID`.

- [ ] **Step 1: 실패하는 테스트** — `BatteryControlBridgeTests.swift`에서 `configurationCarriesEveryStoredPreference`, `sailingOffUsesTheFixedTwoPointDelta`, `reconcileTaskIDChangesWithEveryStoredPreference`, `makeConfigurationForwardsTheClamshellAllowance`를 삭제하고 다음을 추가한다(`autoDischargeMismatchIsWhatTriggeredTheReapply`, `clamshellAllowanceMismatch…`가 `makeConfiguration`을 쓰면 `BatteryPreferences(...).configuration(clamshellDischargeAllowed:)`로 바꾼다):

```swift
    // MARK: - pushAction

    private var on: BatteryPreferences {
        var p = BatteryPreferences.standard; p.limitEnabled = true; p.limitPercentage = 80; return p
    }

    @Test func unchangedConfigurationIsNotPushed() {
        var new = on; new.sailingDelta = 7                      // sailing off → delta는 설정에 안 실린다
        #expect(BatteryControlBridge.pushAction(from: on, to: new, hasExternalDisplay: false) == .none)
        #expect(BatteryControlBridge.pushAction(from: on, to: on, hasExternalDisplay: false) == .none)
    }

    @Test func activeLimitOrHeatProtectionAlwaysApplies() {
        var new = on; new.limitPercentage = 85
        #expect(BatteryControlBridge.pushAction(from: on, to: new, hasExternalDisplay: false) == .apply)
        var heatOnly = BatteryPreferences.standard; heatOnly.heatProtectionEnabled = true
        #expect(BatteryControlBridge.pushAction(from: .standard, to: heatOnly, hasExternalDisplay: false) == .apply)
    }

    @Test func turningEverythingOffDisables() {
        var off = on; off.limitEnabled = false
        #expect(BatteryControlBridge.pushAction(from: on, to: off, hasExternalDisplay: false) == .disable)
    }

    /// 한도가 꺼진 채로도 수동 방전은 돌 수 있다. 방전 쪽 토글만 바뀌면 `disable`이 아니라 활동을
    /// 보존하는 `apply`로 가야 방전이 취소되지 않는다(예전 `applyRequested` 직행 경로와 같다).
    @Test func dischargeSideChangesWhileLimitOffStillApply() {
        var a = BatteryPreferences.standard; a.autoDischargeEnabled = true
        #expect(BatteryControlBridge.pushAction(from: .standard, to: a, hasExternalDisplay: false) == .apply)
        var c = BatteryPreferences.standard; c.clamshellDischargeEnabled = true
        #expect(BatteryControlBridge.pushAction(from: .standard, to: c, hasExternalDisplay: true) == .apply)
        // 외장 디스플레이가 없으면 클램쉘 옵트인은 설정값을 바꾸지 않는다 → none
        #expect(BatteryControlBridge.pushAction(from: .standard, to: c, hasExternalDisplay: false) == .none)
        var t = BatteryPreferences.standard; t.manualDischargeTarget = 70
        #expect(BatteryControlBridge.pushAction(from: .standard, to: t, hasExternalDisplay: false) == .apply)
    }
```

- [ ] **Step 2: 실패 확인** — Expected: 컴파일 실패.

- [ ] **Step 3: 브리지 재작성** — 파일 전체를 다음으로 교체한다. `preservingActivity`, `unsupportedStreak`, `wakeAction`, `shouldAnnounceTopUpExpiry`, `handleInitialTask`, `handleWake`, `handleReconcileLoop`, `applyRequested`, `disableRequested`, `syncMonitorTarget`, 상태 `.onChange(of: client.status)`·wake·시계 변경·디스플레이 변경 핸들러의 본문은 기존 파일에서 **그대로** 옮긴다(아래에는 바뀐 부분만 전부 적는다).

```swift
import SwiftUI
import AppKit

struct BatteryControlBridge: View {
    enum WakeAction: Equatable { case refreshStatus, apply, disableAndConfirm }
    enum PushAction: Equatable { case none, apply, disable }

    /// 슬라이더 드래그 한 번이 XPC 쓰기 수십 번이 되지 않게 하는 간격. 마지막 변경 후 이만큼 조용하면 한 번 민다.
    static let pushDebounceMilliseconds = 250

    let client: BatteryControlClient
    var monitor: SystemMonitor? = nil
    var scheduleCoordinator: BatteryScheduleCoordinator? = nil

    @AppStorage(StorageKey.batteryLimitEnabled) private var enabled = Defaults.batteryLimitEnabled
    @AppStorage(StorageKey.batteryLimitPercentage) private var limit = Defaults.batteryLimitPercentage
    @AppStorage(StorageKey.batterySailingEnabled) private var sailingEnabled = Defaults.batterySailingEnabled
    @AppStorage(StorageKey.batterySailingDelta) private var sailingDelta = Defaults.batterySailingDelta
    @AppStorage(StorageKey.batteryHeatProtectionEnabled) private var heatProtectionEnabled = Defaults.batteryHeatProtectionEnabled
    @AppStorage(StorageKey.batteryHeatProtectionThreshold) private var heatProtectionThreshold = Defaults.batteryHeatProtectionThreshold
    @AppStorage(StorageKey.batteryAutoDischargeEnabled) private var autoDischargeEnabled = Defaults.batteryAutoDischargeEnabled
    @AppStorage(StorageKey.batteryManualDischargeTarget) private var manualDischargeTarget = Defaults.batteryManualDischargeTarget
    @AppStorage(StorageKey.batteryClamshellDischargeEnabled) private var clamshellDischargeEnabled = Defaults.batteryClamshellDischargeEnabled
    @State private var hasExternalDisplay = false
    @State private var pushTask: Task<Void, Never>?

    @State private var topUpDetector = BatteryTopUpTransitionDetector()
    @State private var topUpExpiryDetector = BatteryTopUpExpiryDetector()
    @State private var dischargeDetector = BatteryDischargeTransitionDetector()

    /// 아홉 개 `@AppStorage`를 하나의 값으로. `.onChange(of:)`와 `.task(id:)`가 이 값 하나만 본다.
    private var preferences: BatteryPreferences {
        BatteryPreferences(
            limitEnabled: enabled, limitPercentage: limit,
            sailingEnabled: sailingEnabled, sailingDelta: sailingDelta,
            heatProtectionEnabled: heatProtectionEnabled, heatProtectionThresholdCelsius: heatProtectionThreshold,
            autoDischargeEnabled: autoDischargeEnabled, manualDischargeTarget: manualDischargeTarget,
            clamshellDischargeEnabled: clamshellDischargeEnabled)
    }

    private var clamshellDischargeAllowed: Bool { clamshellDischargeEnabled && hasExternalDisplay }

    private var configuration: BatteryControlConfiguration {
        preferences.configuration(clamshellDischargeAllowed: clamshellDischargeAllowed)
    }

    /// 어떤 변경이 어떤 쓰기가 되는지. 순수라서 테스트가 경계를 고정한다.
    /// - 설정으로 변환했을 때 같으면 아무것도 안 한다(Sailing 꺼진 채 delta만 바뀐 경우 등).
    /// - 한도나 열 보호가 켜져 있으면 `apply`.
    /// - 둘 다 꺼졌더라도 방전 쪽(자동 방전·클램쉘·수동 목표)만 바뀐 것이면 `apply` — 진행 중인 수동 방전을
    ///   `disable`로 취소하지 않기 위해서다(예전 `applyRequested` 직행 경로).
    /// - 그 외(한도를 껐다)는 `disable`.
    static func pushAction(
        from old: BatteryPreferences, to new: BatteryPreferences, hasExternalDisplay: Bool
    ) -> PushAction {
        let oldConfig = old.configuration(clamshellDischargeAllowed: old.clamshellDischargeEnabled && hasExternalDisplay)
        let newConfig = new.configuration(clamshellDischargeAllowed: new.clamshellDischargeEnabled && hasExternalDisplay)
        guard oldConfig != newConfig else { return .none }
        if new.limitEnabled || new.heatProtectionEnabled { return .apply }
        var dischargeSideOnly = old
        dischargeSideOnly.autoDischargeEnabled = new.autoDischargeEnabled
        dischargeSideOnly.clamshellDischargeEnabled = new.clamshellDischargeEnabled
        dischargeSideOnly.manualDischargeTarget = new.manualDischargeTarget
        return dischargeSideOnly == new ? .apply : .disable
    }

    // preservingActivity / unsupportedStreak / wakeAction / shouldAnnounceTopUpExpiry — 기존 그대로

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task { await handleInitialTask() }
            .onChange(of: preferences) { old, new in
                syncMonitorTarget()
                schedulePush(from: old, to: new)
            }
            // 디스플레이 변경·wake·시계 변경·client.status 핸들러 — 기존 그대로
            .task(id: preferences) { await handleReconcileLoop() }
            // .onChange(of: client.status) — 기존 그대로
    }

    /// 디바운스된 단일 쓰기 경로. 마지막 변경 시점의 `configuration`을 다시 읽어 보내므로 드래그 도중 값은 버려진다.
    private func schedulePush(from old: BatteryPreferences, to new: BatteryPreferences) {
        let action = Self.pushAction(from: old, to: new, hasExternalDisplay: hasExternalDisplay)
        guard action != .none else { return }
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .milliseconds(Self.pushDebounceMilliseconds))
            guard !Task.isCancelled else { return }
            let requested = configuration
            switch action {
            case .apply:
                await applyRequested(requested, reason: "preference-change")
                // 이 Mac에 충전 레지스터가 없다고 도우미가 답했으면 방금 켠 옵트인을 되돌린다 —
                // 아니면 스위치가 ON인 채로 스스로 비활성화돼 되돌릴 길이 없다(예전 SettingsBatterySection의 규칙).
                if client.status.isHardwareSupported == false {
                    if enabled { enabled = false }
                    if heatProtectionEnabled { heatProtectionEnabled = false }
                }
            case .disable:
                await disableRequested(requested, reason: "preference-change")
            case .none:
                break
            }
        }
    }

    // handleInitialTask / handleWake / handleReconcileLoop / applyRequested / disableRequested / syncMonitorTarget — 기존 그대로
}
```

`handleConfigChange`는 삭제한다. 디스플레이 변경 핸들러 안의 `Self.makeConfiguration(... clamshellDischargeAllowed: detected)` 호출은 `preferences.configuration(clamshellDischargeAllowed: detected)`로 바꾼다.

- [ ] **Step 4: 통과 확인** — Run: `… -only-testing:WattlyTests/BatteryControlBridgeTests` — Expected: PASS. 전체 빌드도 통과해야 한다(`makeConfiguration` 참조가 남아 있으면 컴파일러가 알려 준다).

- [ ] **Step 5: Commit**

```bash
git add Wattly/Views/BatteryControlBridge.swift WattlyTests/BatteryControlBridgeTests.swift
git commit -m "refactor(battery): observe one BatteryPreferences value and debounce pushes in the bridge"
```

---

### Task 4: 설정 뷰에서 직접 `apply` 제거 — 설치 분기만 남기기

**Files:**
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift:252-425`
- Modify: `Wattly/Views/Settings/SettingsBatteryDischargeSection.swift:173-206`
- Modify: `Wattly/Views/Settings/SettingsBatteryCalibrationSection.swift:504-540`
- Modify: `Wattly/Views/SettingsView.swift:435-452`

- [ ] **Step 1: `SettingsBatterySection`의 다섯 `.onChange`를 다음 둘로 교체**

```swift
            // 밀어 넣기는 BatteryControlBridge 한 곳이 한다. 여기 남은 일은 도우미가 없을 때 설치를 띄우는 것뿐이다.
            .onChange(of: batteryLimitEnabled) { _, isEnabled in
                guard isEnabled, !batteryControl.isInstallingHelper else { return }
                installHelperIfMissing(revertOnFailure: { batteryLimitEnabled = false })
            }
            .onChange(of: batteryHeatProtectionEnabled) { _, isEnabled in
                guard isEnabled, !batteryControl.isInstallingHelper else { return }
                installHelperIfMissing(revertOnFailure: { batteryHeatProtectionEnabled = false })
            }
```

그리고 `body` 아래 private 함수로:

```swift
    /// 도우미가 없을 때만 관리자 인증 → 설치 → 현재 설정 밀어 넣기. 도우미가 있으면 브리지가 이미 밀어 넣었다.
    private func installHelperIfMissing(revertOnFailure: @escaping @MainActor () -> Void) {
        let window = NSApp.keyWindow
        Task {
            guard BatteryControlPolicy.shouldRunInstaller(mode: batteryControl.status.mode) else { return }
            let refreshedMode = await batteryControl.refreshStatus()?.mode ?? .unavailable
            guard BatteryControlPolicy.shouldRunInstaller(mode: refreshedMode) else { return }
            let configuration = BatteryPreferences(defaults: .standard).configuration(clamshellDischargeAllowed: false)
            if let failure = await batteryControl.installAndApply(configuration, window: window) {
                installErrorMessage = Self.message(for: failure, locale: locale)
                isInstallFailedAlertPresented = true
                revertOnFailure()
            }
        }
    }
```

`installCurrentConfiguration(transferringOwnership:)`(소유권 이전 alert가 부른다)의 `installAndApply(enabled: …, window:)` 호출도 `installAndApply(BatteryPreferences(defaults: .standard).configuration(clamshellDischargeAllowed: false), transferringOwnership: transferringOwnership, window: window)`로 바꾼다. 더 이상 쓰이지 않는 `effectiveDelta`/`dischargeTarget`/`heatProtectionThreshold` private 계산 프로퍼티는 컴파일러 경고를 보고 지운다(뷰 표시에 쓰이면 남긴다).

- [ ] **Step 2: `SettingsBatteryDischargeSection`** — `.onChange(of: autoDischargeEnabled) { … setAutoDischarge … }`와 `.onChange(of: manualDischargeTarget) { … reconcile … }` 두 블록을 통째로 삭제한다. (브리지의 `pushAction`이 두 키 모두 `.apply`로 처리한다.)

- [ ] **Step 3: `SettingsBatteryCalibrationSection.updateHelper()`** — 본문의 `int(...)` 헬퍼와 `installAndApply(enabled: …)` 블록을 다음으로 교체:

```swift
    private func updateHelper() {
        let window = NSApp.keyWindow
        Task {
            let configuration = BatteryPreferences(defaults: .standard).configuration(clamshellDischargeAllowed: false)
            if let failure = await batteryControl.installAndApply(configuration, window: window) {
                installErrorMessage = SettingsBatterySection.message(for: failure, locale: locale)
                isInstallFailedAlertPresented = true
            }
            await batteryControl.refreshStatus()
        }
    }
```

- [ ] **Step 4: `SettingsView.reapplyAllSettingsAfterHelperReinstall()`**

```swift
    @MainActor
    private func reapplyAllSettingsAfterHelperReinstall() async {
        await batteryControl.apply(
            BatteryPreferences(defaults: .standard).configuration(clamshellDischargeAllowed: false))
        if fanControlEnabled {
            await fanControl.apply(enabled: true, curve: fanCurve)
        }
    }
```

- [ ] **Step 5: 빌드 + `SettingsBatterySectionTests`**

Run: `… -only-testing:WattlyTests/SettingsBatterySectionTests` 및 전체 빌드
Expected: PASS / BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add Wattly/Views/Settings/SettingsBatterySection.swift Wattly/Views/Settings/SettingsBatteryDischargeSection.swift Wattly/Views/Settings/SettingsBatteryCalibrationSection.swift Wattly/Views/SettingsView.swift
git commit -m "refactor(settings): make BatteryControlBridge the only writer; views keep only the install branch"
```

---

### Task 5: 스케줄 코디네이터 — `BatteryPreferences`, 같은 분 재실행 방지, 알림 기본값

**Files:**
- Modify: `Wattly/Core/BatteryScheduleCoordinator.swift:97-126` (`evaluateSchedules`), `:181-214` (`effective*` 삭제), `:216-300` (`execute`)
- Test: `WattlyTests/BatteryScheduleCoordinatorTests.swift`

**Interfaces:**
- Produces: `static func alreadyTriggered(_ schedule: BatteryChargingSchedule, at date: Date, calendar: Calendar) -> Bool`

- [ ] **Step 1: 실패하는 테스트** — 파일 상단 `MockBatteryState`에 `var applyCount = 0`을 추가하고 `applyConfig`에서 `applyCount += 1`. 스위트에 추가:

```swift
    @Test @MainActor func matchingScheduleFiresOnceEvenIfEvaluatedTwiceInTheSameMinute() async {
        let state = MockBatteryState()
        let defaults = makeIsolatedDefaults()
        let coordinator = BatteryScheduleCoordinator(batteryControl: makeMockClient(state: state), defaults: defaults)
        coordinator.addSchedule(BatteryChargingSchedule(
            name: "8시 80%", time: ScheduleTime(hour: 8, minute: 0),
            repeatRule: .daily, action: .setLimit(percentage: 80)))
        var comps = DateComponents(); comps.year = 2026; comps.month = 9; comps.day = 8; comps.hour = 8; comps.minute = 0
        let eight = Calendar.current.date(from: comps)!
        await coordinator.evaluateSchedules(at: eight, isWake: false)
        await coordinator.evaluateSchedules(at: eight.addingTimeInterval(20), isWake: false)
        #expect(await state.applyCount == 1)
    }

    /// 감사 버그: sailing on + delta 키 없음 → 0 → 데몬 클램프 1. 이제는 기본값 5가 실린다.
    @Test @MainActor func scheduleSendsTheDefaultSailingDeltaWhenTheKeyIsAbsent() async {
        let state = MockBatteryState()
        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: StorageKey.batterySailingEnabled)
        let coordinator = BatteryScheduleCoordinator(batteryControl: makeMockClient(state: state), defaults: defaults)
        coordinator.addSchedule(BatteryChargingSchedule(
            name: "x", time: ScheduleTime(hour: 9, minute: 30), action: .setLimit(percentage: 90)))
        var comps = DateComponents(); comps.year = 2026; comps.month = 9; comps.day = 8; comps.hour = 9; comps.minute = 30
        await coordinator.evaluateSchedules(at: Calendar.current.date(from: comps)!, isWake: false)
        #expect(await state.lastAppliedConfig?.lowerHysteresisDelta == Defaults.batterySailingDelta)
    }
```

(`BatteryChargingSchedule.init`의 인자 순서는 `name:` → `time:` → `repeatRule:`(기본 `.daily`) → `action:`이다. 두 번째 테스트는 기본값 `.daily`를 쓴다.)

- [ ] **Step 2: 실패 확인** — Expected: 첫 테스트 `applyCount == 2`로 FAIL, 두 번째 `== 1`로 FAIL.

- [ ] **Step 3: 구현**

`evaluateSchedules`의 비-wake 분기:

```swift
            for schedule in active {
                if schedule.time.hour == hour && schedule.time.minute == minute
                    && schedule.repeatRule.matches(date: date, calendar: calendar)
                    && !Self.alreadyTriggered(schedule, at: date, calendar: calendar) {
                    matching.append(schedule)
                }
            }
```

`// MARK: - Evaluation & Execution` 아래에 추가:

```swift
    /// wake 직후에는 분 타이머·`handleWake`·시계 변경 알림 셋이 같은 분에 겹쳐 온다. 같은 분에 이미 실행한
    /// 스케줄은 두 번째 호출에서 건너뛴다. wake 경로의 `shouldCatchUp`은 자기 검사를 따로 한다.
    static func alreadyTriggered(_ schedule: BatteryChargingSchedule, at date: Date, calendar: Calendar) -> Bool {
        guard let last = schedule.lastTriggeredAt else { return false }
        return calendar.isDate(last, equalTo: date, toGranularity: .minute)
    }
```

`effectiveManualDischargeTarget`, `effectiveHeatProtectionThreshold`, `effectiveLimitPercentage` 세 프로퍼티와 그 주석을 삭제하고 `execute`를 다음으로 교체:

```swift
    private func execute(schedule: BatteryChargingSchedule, at date: Date) async {
        let isPluggedIn = batteryControl.status.isPowerAdapterConnected
        var prefs = BatteryPreferences(defaults: defaults)

        switch schedule.action {
        case .setLimit(let pct):
            prefs.limitEnabled = true
            prefs.limitPercentage = pct
            prefs.write(to: defaults)
            let status = await batteryControl.apply(prefs.configuration(clamshellDischargeAllowed: false))
            recordOutcome(schedule: schedule, status: status, at: date)

        case .startTopUp:
            if !isPluggedIn {
                recordLog(schedule: schedule, status: .skipped(reason: .adapterDisconnected), timestamp: date)
            } else {
                let status = await batteryControl.startTopUp(preferences: prefs)
                recordOutcome(schedule: schedule, status: status, at: date)
            }

        case .pauseCharging:
            prefs.limitEnabled = true
            prefs.limitPercentage = Self.pauseChargingLimitPercentage
            prefs.write(to: defaults)
            var config = prefs.configuration(clamshellDischargeAllowed: false)
            config.lowerHysteresisDelta = 2
            let status = await batteryControl.apply(config)
            recordOutcome(schedule: schedule, status: status, at: date)
        }

        if case .once = schedule.repeatRule {
            toggleSchedule(id: schedule.id, isEnabled: false)
        }
        if let idx = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[idx].lastTriggeredAt = date
            saveSchedules()
        }

        // 기본값 true인 키 — `bool(forKey:)`로 읽으면 새 설치에서 영원히 false다.
        if defaults.wattlyBool(StorageKey.batteryScheduleNotificationsEnabled,
                               default: Defaults.batteryScheduleNotificationsEnabled) {
            let locale = activeLocale
            BatteryNotificationManager.postScheduleTriggeredNotification(
                scheduleName: schedule.name,
                actionSummary: schedule.action.summary(locale: locale),
                locale: locale,
                note: Self.autoDischargeWarning(
                    action: schedule.action,
                    isAutoDischargeEnabled: prefs.autoDischargeEnabled,
                    locale: locale))
        }
    }

    private func recordOutcome(schedule: BatteryChargingSchedule, status: BatteryControlServiceStatus?, at date: Date) {
        if let status, status.mode != .unavailable {
            recordLog(schedule: schedule, status: .success, timestamp: date)
        } else {
            recordLog(schedule: schedule, status: .failed(reason: String(localized: "도우미 연결 실패")), timestamp: date)
        }
    }
```

- [ ] **Step 4: 통과 확인** — Run: `… -only-testing:WattlyTests/BatteryScheduleCoordinatorTests` — Expected: 전부 PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/BatteryScheduleCoordinator.swift WattlyTests/BatteryScheduleCoordinatorTests.swift
git commit -m "fix(schedule): read preferences through BatteryPreferences; fire once per minute; honor the notifications default"
```

---

### Task 6: 캘리브레이션 스냅샷과 `BatteryIntentBridge`

**Files:**
- Modify: `Wattly/Core/BatteryCalibrationCoordinator.swift:377-395`
- Rewrite: `Wattly/Intents/BatteryIntentBridge.swift`
- Test: `WattlyTests/BatteryIntentBridgeTests.swift` (기존 테스트가 그대로 통과해야 한다), `WattlyTests/BatteryCalibrationCoordinatorTests.swift`(변경 없음)

- [ ] **Step 1: `currentSnapshot` 위임**

```swift
    /// 시작 시점의 사용자 설정. 존재 가드·기본값은 `BatteryPreferences`가 책임진다.
    public func currentSnapshot() -> CalibrationSnapshot {
        BatteryPreferences(defaults: defaults).calibrationSnapshot
    }
```

- [ ] **Step 2: `BatteryIntentBridge` 재작성** — `fetchBatteryState()`는 그대로 두고 나머지 네 메서드를 교체:

```swift
    public func fetchLimitConfig() async throws -> BatteryLimitConfigEntity {
        let prefs = BatteryPreferences(defaults: userDefaults)
        let client = await clientProvider()
        let status = await client.refreshStatus()
        let isTopUp = status?.desiredConfiguration?.topUpActive == true || status?.activity == .topUp
        return BatteryLimitConfigEntity(
            isEnabled: prefs.limitEnabled,
            limitPercentage: prefs.limitPercentage,
            isSailingEnabled: prefs.sailingEnabled,
            sailingDelta: prefs.sailingDelta,
            isHeatProtectionEnabled: prefs.heatProtectionEnabled,
            isTopUpActive: isTopUp)
    }

    @discardableResult
    public func applyLimit(enabled: Bool? = nil, limitPercentage: Int? = nil) async throws -> BatteryControlServiceStatus {
        var prefs = BatteryPreferences(defaults: userDefaults)
        if let enabled { prefs.limitEnabled = enabled }
        if let limitPercentage { prefs.limitPercentage = limitPercentage }
        return try await push(prefs)
    }

    @discardableResult
    public func applySailing(enabled: Bool, delta: Int? = nil) async throws -> BatteryControlServiceStatus {
        var prefs = BatteryPreferences(defaults: userDefaults)
        prefs.sailingEnabled = enabled
        if let delta { prefs.sailingDelta = delta }
        return try await push(prefs)
    }

    @discardableResult
    public func applyTopUp(start: Bool) async throws -> BatteryControlServiceStatus {
        let prefs = BatteryPreferences(defaults: userDefaults)
        let client = await clientProvider()
        let status = start
            ? await client.startTopUp(preferences: prefs)
            : await client.cancelTopUp(preferences: prefs)
        return try Self.checked(status)
    }

    @discardableResult
    public func applyHeatProtection(enabled: Bool, thresholdCelsius: Int? = nil) async throws -> BatteryControlServiceStatus {
        var prefs = BatteryPreferences(defaults: userDefaults)
        prefs.heatProtectionEnabled = enabled
        if let thresholdCelsius { prefs.heatProtectionThresholdCelsius = thresholdCelsius }
        return try await push(prefs)
    }

    /// 설정 → 데몬 → 저장. 데몬이 거부하면 저장하지 않는다(예전 동작과 같다). 저장은 브리지를 깨워
    /// 같은 설정을 한 번 더 밀게 하지만, 데몬 `configure`는 멱등이고 인텐트는 분 단위 이벤트라 받아들인다.
    private func push(_ prefs: BatteryPreferences) async throws -> BatteryControlServiceStatus {
        let client = await clientProvider()
        let status = try Self.checked(await client.apply(prefs.configuration(clamshellDischargeAllowed: false)))
        prefs.write(to: userDefaults)
        return status
    }

    private static func checked(_ status: BatteryControlServiceStatus?) throws -> BatteryControlServiceStatus {
        guard let status else { throw BatteryIntentError.helperNotInstalled }
        if status.mode == .unsupported || status.isHardwareSupported == false {
            throw BatteryIntentError.hardwareUnsupported
        }
        return status
    }
```

- [ ] **Step 3: 테스트 실행**

Run: `… -only-testing:WattlyTests/BatteryIntentBridgeTests`, `… -only-testing:WattlyTests/BatteryCalibrationCoordinatorTests`, `… -only-testing:WattlyTests/SetBatteryLimitIntentsTests`, `… -only-testing:WattlyTests/SpecialBatteryIntentsTests`
Expected: 전부 PASS. (`applySailing`이 delta 미지정 시 저장값을 안 바꾸는 단정이 있다면 `write(to:)`가 바뀐 키만 쓰므로 그대로 통과한다.)

- [ ] **Step 4: Commit**

```bash
git add Wattly/Core/BatteryCalibrationCoordinator.swift Wattly/Intents/BatteryIntentBridge.swift
git commit -m "refactor(battery): route calibration snapshot and Shortcuts through BatteryPreferences"
```

---

### Task 7: 카드 확장 영역의 Top Up / 수동 방전 버튼

**Files:**
- Modify: `Wattly/Views/CardExpandRegion.swift:428-452`, `:511-538`

- [ ] **Step 1: Top Up 버튼 액션 교체**

```swift
            Button {
                let prefs = BatteryPreferences(defaults: .standard)
                Task {
                    if isTopUp {
                        await batteryControl.cancelTopUp(preferences: prefs)
                    } else {
                        await batteryControl.startTopUp(preferences: prefs)
                    }
                }
            } label: {
```

- [ ] **Step 2: 수동 방전 버튼 액션 교체**

```swift
                Button {
                    let prefs = BatteryPreferences(defaults: .standard)
                    Task {
                        if isDischarging {
                            await batteryControl.stopManualDischarge(preferences: prefs)
                        } else {
                            await batteryControl.startManualDischarge(preferences: prefs)
                        }
                    }
                } label: {
```

`dischargeTarget`(표시용 클램프 값)이 슬라이더/텍스트에 아직 쓰이면 남긴다. `startManualDischarge(preferences:)`는 `configuration(...)`에서 같은 클램프를 적용한다.

- [ ] **Step 3: 전체 테스트**

Run: 전체 `xcodebuild … test`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: 실기 확인(1회)** — 설정 창을 열어 둔 채 팝오버에서 Top Up을 켜고, 설정의 충전 한도 슬라이더를 움직인다. Top Up 표시가 유지되어야 한다(예전엔 취소될 수 있었다). `log stream --predicate 'subsystem == "dev.jjundev.Wattly"' --info`에서 `applyRequested push: reason=preference-change`가 슬라이더를 놓은 뒤 **한 번**만 찍히는지 본다.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Views/CardExpandRegion.swift
git commit -m "refactor(popover): build Top Up and discharge requests from BatteryPreferences"
```

---

## Self-Review

- **Spec coverage:** 이중 쓰기 → Task 3·4 ✔. 알림 기본값 → Task 1 `wattlyBool` + Task 5 ✔. Sailing 0→1 → Task 1 `wattlyInt` + Task 5 테스트 ✔. wake 2회 실행 → Task 5 `alreadyTriggered` ✔. 36곳 조립 → Task 1·4·5·6·7 ✔. `BatteryIntentBridge` pass-through 축소 → Task 6 ✔. 설정 뷰 `.onChange→apply` 삭제 → Task 4 ✔.
- **Placeholder scan:** 없음. "기존 그대로"로 표시한 브리지 메서드들은 파일에 이미 존재하는 코드이며 옮기기만 한다.
- **Type consistency:** `BatteryPreferences.configuration(clamshellDischargeAllowed:)` 전 태스크 동일. `client.apply(_:)`·`installAndApply(_:transferringOwnership:window:)`·`startTopUp(preferences:)` 등 Task 2 정의와 Task 4·5·6·7 호출 라벨 일치. `pushAction(from:to:hasExternalDisplay:)` Task 3 정의·테스트 일치 ✔.
