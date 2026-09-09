# 충전 한도 도달 시까지 잠자기 방지 (Disable Sleep until Charge Limit) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 전원 어댑터 연결 상태에서 충전 제한(예: 90%)을 켜두고 충전 중 덮개를 닫거나 유휴 잠자기에 진입하려 할 때, 목표 한도에 도달할 때까지 루트 데몬이 시스템 잠자기(`SleepDisabled`)를 일시 차단하고, 목표치 도달 시 충전 차단 후 정상 잠자기에 들게 하는 옵트인 기능을 구현한다.

**Architecture:** 잠자기 제어의 소유자는 루트 데몬 `BatteryControlCoordinator`다. 이미 검증된 `IOPMSystemSleepInhibitor`를 재사용하며, 순수 함수 `BatteryHoldSleepPolicy`가 (1) 사용자 옵트인(`sleepUntilLimitAllowed`), (2) AC 연결(`isPluggedIn`), (3) 충전 한도 미만 활성 충전(`currentSoC < clampedLimitPercentage && !isCurrentlyInhibited`), (4) 발열 보호 미발동(`!isInHeatProtection`), (5) 4시간 절대 안전 타임아웃 미만 여부를 판정한다. 기존 클램쉘 방전(`BatteryClamshellSleepPolicy`)과 `SleepDisabled`를 상호 배제적으로 공유하며, 목표 도달·어댑터 분리·발열 보호·타임아웃 시 즉시 잠자기 차단을 해제한다. 앱은 `BatteryPreferences` 단일 writer 패턴을 통해 설정을 전달한다.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Swift Testing (`import Testing`), XcodeGen, XPC (`NSXPCConnection`), IOKit 비공개 심볼 `IOPMSetSystemPowerSetting` (`@_silgen_name` 바인딩).

## Global Constraints

- **`SleepDisabled`는 데몬(루트)에서 `IOPMSetSystemPowerSetting("SleepDisabled", Bool)`로만 만진다.** 앱(비루트)은 절대 호출하지 않는다 (`12-clamshell-discharge.md:13`).
- **`AppliesOnLidClose` 어설션은 쓰지 않는다.** 루트에서도 `kIOReturnNotPrivileged`로 거부됨이 증명되었으므로 시스템 전역 `SleepDisabled`만 사용한다 (`12-clamshell-discharge.md:14`).
- **외장 디스플레이는 필수가 아니다.** 이 기능의 주 시나리오는 이동 중(카페, 사무실, 도서관) 노트북 단독 상태에서 덮개를 닫고 자리를 비우는 것이므로 외장 모니터 조건을 걸지 않는다.
- **`sleepUntilLimitAllowed`는 정책 파일에 영구 저장하지 않는다.** 데몬 단독 재시작 시 안전하게 잠자기 차단 없이 시작(`false`)하고, 앱의 60초 reconcile이 다시 실어 보낸다. 단, 데몬이 켠 시각 `sleepInhibitedAt` 마커는 정책 파일에 저장되어 데몬 비정상 종료 시에도 재시작 시 고아 플래그를 무조건 회수한다 (`BatteryPolicyPersistence.swift:22-26`).
- **4시간 절대 안전 타임아웃.** 충전기 출력 부족이나 케이블 불량으로 한도에 도달하지 못하더라도 최대 4시간 경과 시 무조건 `.expire`로 잠자기 차단을 풀고 재운다.
- **발열 보호 발동 시 즉시 영구 해제.** 덮개가 닫힌 상태에서 내부 온도가 기준치 이상으로 상승하여 발열 보호가 발동되면, 쿨다운을 기다리지 않고 즉시 잠자기 방지를 풀고 정상 잠자기에 진입시켜 기기를 식힌다.
- **어댑터 분리 시 즉시 해제.** 가방에 넣고 이동하는 도중 시스템이 켜져 있는 것을 방지하기 위해 `!isPluggedIn` 감지 즉시 잠자기 차단을 해제한다.
- **`requiredCapabilities` 불변 원칙.** 새 기능 캐퍼빌리티 `.sleepUntilLimitV1`은 토글 안에서만 확인하며, 전역 `requiredCapabilities`에는 추가하지 않는다 (구버전 헬퍼 사용자에게 불필요한 업데이트 경고 방지).
- **Swift 6 strict concurrency.** 순수 로직은 `@MainActor` 없이 작성한다.
- **파일 추가 시 반드시 xcodegen 재생성:** `/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml` (또는 `xcodegen generate`).
- **DerivedData 명시:** 워크트리 빌드/테스트 시 `-derivedDataPath .build/DerivedData` 사용.

---

## File Structure

### 공유 계층 (`FanControlShared` — 앱과 데몬 양쪽 컴파일)
| 파일 | 책임 | 변경 |
|---|---|---|
| `BatteryHoldSleepPolicy.swift` | 4h 상수 · 순수 `decide` 판정 함수 | **신규** |
| `BatteryControlProtocol.swift` | 설정 필드 `sleepUntilLimitAllowed` · `.sleepUntilLimitV1` 캐퍼빌리티 | 수정 |
| `BatteryControlCoordinator.swift` | `syncSleepInhibition`에서 방전과 충전 대기 통합 관리 | 수정 |

### 앱 계층 (`Wattly`)
| 파일 | 책임 | 변경 |
|---|---|---|
| `Settings/Settings.swift` | `Defaults`/`StorageKey`.`batterySleepUntilLimitEnabled` | 수정 |
| `Core/BatteryPreferences.swift` | `sleepUntilLimitEnabled` 읽기/쓰기 및 configuration 조립 | 수정 |
| `Core/SettingsReset.swift` | 기본값 복원 한 줄 추가 | 수정 |
| `Views/BatteryControlBridge.swift` | 설정 변경 시 `applyRequested` 즉시 push 연동 | 수정 |
| `Core/BatterySectionPresentation.swift` | 토글 활성화 조건 및 진행 배너 문구 | 수정 |
| `Views/Settings/SettingsBatterySection.swift` | "충전 한도 도달 시까지 잠자기 방지" 토글 UI 추가 | 수정 |
| `Resources/Localizable.xcstrings` | 신규 문구 등록 (한국어 및 다국어 지원) | 수정 |

### 테스트 계층 (`WattlyTests`)
| 파일 | 책임 | 변경 |
|---|---|---|
| `BatteryHoldSleepPolicyTests.swift` | 충전 잠자기 방지 순수 정책 유닛 테스트 | **신규** |
| `BatteryControlProtocolTests.swift` | 설정/캐퍼빌리티 직렬화/역직렬화 테스트 | 수정 |
| `BatteryControlCoordinatorTests.swift` | 데몬 코디네이터 연동 및 타임아웃/해제 시나리오 테스트 | 수정 |
| `BatteryPreferencesTests.swift` | 선호값 읽기/쓰기/조립 테스트 | 수정 |
| `BatterySectionPresentationTests.swift` | UI 표시 문구 및 토글 비활성화 조건 테스트 | 수정 |

### 문서
| 파일 | 책임 | 변경 |
|---|---|---|
| `docs/features/battery-management/13-sleep-until-charge-limit.md` | 기능 정의 및 실기 검증 매트릭스 문서 | **신규** |

---

### Task 1: 순수 판정 정책 (`BatteryHoldSleepPolicy`) 및 프로토콜 계약 확장

**Files:**
- Create: `FanControlShared/BatteryHoldSleepPolicy.swift`
- Modify: `FanControlShared/BatteryControlProtocol.swift:40-180`
- Create: `WattlyTests/BatteryHoldSleepPolicyTests.swift`
- Modify: `WattlyTests/BatteryControlProtocolTests.swift`

**Interfaces:**
- Produces:
  - `enum BatteryHoldSleepPolicy { static let duration: TimeInterval; static var durationHours: Int; enum Decision { none, engage, restamp(TimeInterval), disengage, expire }; static func decide(allowed:isPluggedIn:limitEnabled:currentSoC:targetLimit:isCharging:isInHeatProtection:inhibitedAt:expiredForCurrentSession:now:duration:) -> Decision }`
  - `BatteryControlConfiguration.sleepUntilLimitAllowed: Bool` (기본값 `false`)
  - `BatteryControlCapability.sleepUntilLimitV1 = "sleep-until-limit-v1"`

- [ ] **Step 1: 실패하는 정책 및 프로토콜 테스트 작성**

`WattlyTests/BatteryHoldSleepPolicyTests.swift`:
```swift
import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryHoldSleepPolicyTests {
    @Test func defaultDurationIsFourHours() {
        #expect(BatteryHoldSleepPolicy.duration == 4 * 3600)
        #expect(BatteryHoldSleepPolicy.durationHours == 4)
    }

    @Test func doesNothingWhenNotAllowed() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: false, isPluggedIn: true, limitEnabled: true,
            currentSoC: 70, targetLimit: 90, isCharging: true, isInHeatProtection: false,
            inhibitedAt: nil, expiredForCurrentSession: false, now: 1_000) == .none)
    }

    @Test func doesNothingWhenNotPluggedIn() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: false, limitEnabled: true,
            currentSoC: 70, targetLimit: 90, isCharging: true, isInHeatProtection: false,
            inhibitedAt: nil, expiredForCurrentSession: false, now: 1_000) == .none)
    }

    @Test func doesNothingWhenLimitDisabled() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: true, limitEnabled: false,
            currentSoC: 70, targetLimit: 90, isCharging: true, isInHeatProtection: false,
            inhibitedAt: nil, expiredForCurrentSession: false, now: 1_000) == .none)
    }

    @Test func doesNothingWhenAlreadyAtOrAboveTarget() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: true, limitEnabled: true,
            currentSoC: 90, targetLimit: 90, isCharging: false, isInHeatProtection: false,
            inhibitedAt: nil, expiredForCurrentSession: false, now: 1_000) == .none)
    }

    @Test func doesNothingWhenInHeatProtection() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: true, limitEnabled: true,
            currentSoC: 70, targetLimit: 90, isCharging: true, isInHeatProtection: true,
            inhibitedAt: nil, expiredForCurrentSession: false, now: 1_000) == .none)
    }

    @Test func engagesWhenAllConditionsMet() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: true, limitEnabled: true,
            currentSoC: 70, targetLimit: 90, isCharging: true, isInHeatProtection: false,
            inhibitedAt: nil, expiredForCurrentSession: false, now: 1_000) == .engage)
    }

    @Test func staysEngagedWhileConditionsHold() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: true, limitEnabled: true,
            currentSoC: 80, targetLimit: 90, isCharging: true, isInHeatProtection: false,
            inhibitedAt: 1_000, expiredForCurrentSession: false, now: 2_000) == .none)
    }

    @Test func disengagesWhenTargetReached() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: true, limitEnabled: true,
            currentSoC: 90, targetLimit: 90, isCharging: false, isInHeatProtection: false,
            inhibitedAt: 1_000, expiredForCurrentSession: false, now: 3_000) == .disengage)
    }

    @Test func disengagesWhenAdapterUnplugged() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: false, limitEnabled: true,
            currentSoC: 80, targetLimit: 90, isCharging: false, isInHeatProtection: false,
            inhibitedAt: 1_000, expiredForCurrentSession: false, now: 2_000) == .disengage)
    }

    @Test func disengagesImmediatelyWhenHeatProtectionTriggers() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: true, limitEnabled: true,
            currentSoC: 80, targetLimit: 90, isCharging: false, isInHeatProtection: true,
            inhibitedAt: 1_000, expiredForCurrentSession: false, now: 2_000) == .disengage)
    }

    @Test func expiresWhenFourHoursElapsed() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: true, limitEnabled: true,
            currentSoC: 80, targetLimit: 90, isCharging: true, isInHeatProtection: false,
            inhibitedAt: 1_000, expiredForCurrentSession: false, now: 1_000 + 4 * 3600) == .expire)
    }

    @Test func doesNotReengageAfterExpiryInSameSession() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: true, limitEnabled: true,
            currentSoC: 80, targetLimit: 90, isCharging: true, isInHeatProtection: false,
            inhibitedAt: nil, expiredForCurrentSession: true, now: 2_000) == .none)
    }

    @Test func restampsWhenClockRollsBack() {
        #expect(BatteryHoldSleepPolicy.decide(
            allowed: true, isPluggedIn: true, limitEnabled: true,
            currentSoC: 80, targetLimit: 90, isCharging: true, isInHeatProtection: false,
            inhibitedAt: 5_000, expiredForCurrentSession: false, now: 2_000) == .restamp(2_000))
    }
}
```

- [ ] **Step 2: 테스트 실행하여 실패 확인**
Run: `xcodegen generate && xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/BatteryHoldSleepPolicyTests`
Expected: 컴파일 에러 (`BatteryHoldSleepPolicy` 심볼 없음).

- [ ] **Step 3: `BatteryHoldSleepPolicy` 및 `BatteryControlProtocol` 구현**

`FanControlShared/BatteryHoldSleepPolicy.swift`:
```swift
import Foundation

public enum BatteryHoldSleepPolicy {
    public static let duration: TimeInterval = 4 * 60 * 60
    public static var durationHours: Int { Int(duration / 3600) }

    public enum Decision: Equatable, Sendable {
        case none
        case engage
        case restamp(TimeInterval)
        case disengage
        case expire
    }

    public static func decide(
        allowed: Bool,
        isPluggedIn: Bool,
        limitEnabled: Bool,
        currentSoC: Int,
        targetLimit: Int,
        isCharging: Bool,
        isInHeatProtection: Bool,
        inhibitedAt: TimeInterval?,
        expiredForCurrentSession: Bool,
        now: TimeInterval,
        duration: TimeInterval = BatteryHoldSleepPolicy.duration
    ) -> Decision {
        let shouldHold = allowed
            && isPluggedIn
            && limitEnabled
            && currentSoC < targetLimit
            && isCharging
            && !isInHeatProtection

        guard let inhibitedAt else {
            guard shouldHold, !expiredForCurrentSession else { return .none }
            return .engage
        }

        guard shouldHold else { return .disengage }
        guard now >= inhibitedAt else { return .restamp(now) }
        return now - inhibitedAt >= duration ? .expire : .none
    }
}
```

`FanControlShared/BatteryControlProtocol.swift`에 `sleepUntilLimitAllowed` 및 `.sleepUntilLimitV1` 추가:
- `BatteryControlConfiguration`: `public var sleepUntilLimitAllowed: Bool = false` 추가 (init, CodingKeys, decode, encode, normalized 전달).
- `BatteryControlCapability`: `case sleepUntilLimitV1 = "sleep-until-limit-v1"` 추가.

- [ ] **Step 4: 테스트 실행하여 성공 확인**
Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/BatteryHoldSleepPolicyTests`
Expected: **TEST SUCCEEDED**.

- [ ] **Step 5: 커밋**
```bash
git add FanControlShared/BatteryHoldSleepPolicy.swift FanControlShared/BatteryControlProtocol.swift WattlyTests/BatteryHoldSleepPolicyTests.swift WattlyTests/BatteryControlProtocolTests.swift project.yml Wattly.xcodeproj/project.pbxproj
git commit -m "feat(battery): add BatteryHoldSleepPolicy and sleepUntilLimit capability"
```

---

### Task 2: 루트 데몬 코디네이터 (`BatteryControlCoordinator`) 연동

**Files:**
- Modify: `FanControlShared/BatteryControlCoordinator.swift:30-480`
- Modify: `WattlyTests/BatteryControlCoordinatorTests.swift`

**Interfaces:**
- Consumes: `BatteryHoldSleepPolicy`, `BatteryClamshellSleepPolicy`, `SystemSleepInhibiting`.
- Produces: `BatteryControlCoordinator.syncSleepInhibition()`이 클램쉘 방전과 충전 한도 대기 양쪽을 평가하여 단일 `sleepInhibitedAt` 마커 및 `sleepInhibitor.setSleepDisabled` 관리. `capabilities`에 `.sleepUntilLimitV1` 포함.

- [ ] **Step 1: 실패하는 코디네이터 테스트 작성**

`WattlyTests/BatteryControlCoordinatorTests.swift`에 다음 테스트 추가:
- 충전 중(`currentSoC = 70 < limit = 80`) + `sleepUntilLimitAllowed = true` 상태에서 `syncSleepInhibition`이 `SleepDisabled = true`를 켜고 `status.isSystemSleepInhibited == true`를 보고하는지 확인.
- 목표치(`currentSoC = 80`) 도달 시 충전 차단과 함께 `SleepDisabled = false`로 내려가는지 확인.
- 어댑터 분리 시 즉시 `SleepDisabled = false`로 내려가는지 확인.
- 발열 보호 발동 시 즉시 `SleepDisabled = false`로 내려가는지 확인.
- 4시간 경과 후 `.expire`로 내려가고 같은 세션에서 재진입하지 않는지 확인.

- [ ] **Step 2: 테스트 실패 확인**
Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/BatteryControlCoordinatorTests`
Expected: FAIL.

- [ ] **Step 3: `BatteryControlCoordinator`의 `syncSleepInhibition` 확장 구현**

`FanControlShared/BatteryControlCoordinator.swift`:
- `private var holdSleepExpiredForCurrentSession: Bool = false` 추가.
- `public static let capabilities`에 `.sleepUntilLimitV1` 추가.
- `syncSleepInhibition()`에서:
  1. 만약 `engine.isDischargingNow == true`이면: 기존 `BatteryClamshellSleepPolicy` 평가.
  2. 만약 `engine.isDischargingNow == false`이면:
     - `clamshellExpiredForCurrentDischarge = false` 리셋.
     - `BatteryHoldSleepPolicy.decide(...)` 평가:
       - `allowed`: `engine.configuration.sleepUntilLimitAllowed`
       - `isPluggedIn`: 최근 전원 상태 어댑터 연결 여부
       - `limitEnabled`: `engine.configuration.enabled`
       - `currentSoC`: 최근 전원 상태 SoC
       - `targetLimit`: `engine.configuration.clampedLimitPercentage`
       - `isCharging`: `!engine.isChargingInhibited`
       - `isInHeatProtection`: `engine.isHeatProtectionActive`
       - `inhibitedAt`: `sleepInhibitedAt`
       - `expiredForCurrentSession`: `holdSleepExpiredForCurrentSession`
  3. `.engage`, `.disengage`, `.restamp`, `.expire`를 통합 실행:
     - `.engage`: 마커 저장 후 `setSleepDisabled(true)`
     - `.disengage`: `releaseSleepInhibition()`
     - `.expire`: `holdSleepExpiredForCurrentSession = true` 세운 뒤 `releaseSleepInhibition()`
     - `shouldHold` 조건이 해제되면 `holdSleepExpiredForCurrentSession = false` 리셋.

- [ ] **Step 4: 테스트 실행하여 성공 확인**
Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/BatteryControlCoordinatorTests`
Expected: **TEST SUCCEEDED**.

- [ ] **Step 5: 커밋**
```bash
git add FanControlShared/BatteryControlCoordinator.swift WattlyTests/BatteryControlCoordinatorTests.swift
git commit -m "feat(daemon): integrate BatteryHoldSleepPolicy into BatteryControlCoordinator"
```

---

### Task 3: 앱 레이어 선호값 및 브리지 연동 (`BatteryPreferences`, `Bridge`)

**Files:**
- Modify: `Wattly/Settings/Settings.swift:440-495`
- Modify: `Wattly/Core/BatteryPreferences.swift:10-100`
- Modify: `Wattly/Core/SettingsReset.swift:40-55`
- Modify: `Wattly/Views/BatteryControlBridge.swift:150-300`
- Test: `WattlyTests/BatteryPreferencesTests.swift`, `WattlyTests/SettingsResetTests.swift`, `WattlyTests/BatteryControlBridgeTests.swift`

**Interfaces:**
- Produces:
  - `Defaults.batterySleepUntilLimitEnabled: Bool = false`
  - `StorageKey.batterySleepUntilLimitEnabled = "batterySleepUntilLimitEnabled"`
  - `BatteryPreferences.sleepUntilLimitEnabled: Bool`
  - `BatteryPreferences.configuration(clamshellDischargeAllowed:)`에 `sleepUntilLimitAllowed: sleepUntilLimitEnabled` 연결
  - `BatteryControlBridge`의 `.onChange(of: sleepUntilLimitEnabled)` 즉시 `applyRequested` 트리거

- [ ] **Step 1: 실패하는 단위 테스트 작성**
`WattlyTests/BatteryPreferencesTests.swift` 및 `WattlyTests/SettingsResetTests.swift`에 `sleepUntilLimitEnabled` 라운드트립 및 기본값 리셋 검증 테스트 추가.

- [ ] **Step 2: 테스트 실행하여 실패 확인**
Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/BatteryPreferencesTests`
Expected: FAIL (`sleepUntilLimitEnabled` 멤버 부재).

- [ ] **Step 3: `BatteryPreferences`, `Settings`, `SettingsReset`, `Bridge` 구현**
- `Settings.swift`:
  - `Defaults.batterySleepUntilLimitEnabled = false`
  - `StorageKey.batterySleepUntilLimitEnabled = "batterySleepUntilLimitEnabled"`
- `BatteryPreferences.swift`:
  - 프로퍼티 `var sleepUntilLimitEnabled: Bool` 추가
  - `standard` 및 `init(defaults:)` 및 `write(to:)`에 매핑 추가
  - `configuration(clamshellDischargeAllowed:)` 생성 시 `sleepUntilLimitAllowed: sleepUntilLimitEnabled` 전달
- `SettingsReset.swift`:
  - `defaults.set(Defaults.batterySleepUntilLimitEnabled, forKey: StorageKey.batterySleepUntilLimitEnabled)` 추가
- `BatteryControlBridge.swift`:
  - `@AppStorage(StorageKey.batterySleepUntilLimitEnabled)` 바인딩 추가
  - `.onChange(of: sleepUntilLimitEnabled) { ... applyRequested(...) }` 추가

- [ ] **Step 4: 테스트 실행하여 통과 확인**
Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/BatteryPreferencesTests -only-testing:WattlyTests/SettingsResetTests`
Expected: **TEST SUCCEEDED**.

- [ ] **Step 5: 커밋**
```bash
git add Wattly/Settings/Settings.swift Wattly/Core/BatteryPreferences.swift Wattly/Core/SettingsReset.swift Wattly/Views/BatteryControlBridge.swift WattlyTests/BatteryPreferencesTests.swift WattlyTests/SettingsResetTests.swift
git commit -m "feat(app): add sleepUntilLimitEnabled preference and bridge routing"
```

---

### Task 4: UI 표시, 설정 토글 및 로컬라이제이션

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift:800-835`
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift:115-160`
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Create: `docs/features/battery-management/13-sleep-until-charge-limit.md`
- Test: `WattlyTests/BatterySectionPresentationTests.swift`, `WattlyTests/LocalizationTests.swift`

**Interfaces:**
- Produces:
  - `BatterySectionPresentation.isSleepUntilLimitToggleEnabled(limitEnabled:capabilities:) -> Bool`
  - `BatterySectionPresentation.sleepUntilLimitHoldingText(locale:) -> String`
  - `SettingsBatterySection` 내 "충전 한도 도달 시까지 잠자기 방지" 토글 행
  - 메뉴바/팝오버 충전 대기 중 배너 문구 ("잠자기 차단 중 (충전 완료 후 자동으로 잠듭니다)")

- [ ] **Step 1: 실패하는 프레젠테이션 테스트 작성**
`WattlyTests/BatterySectionPresentationTests.swift`에 `sleepUntilLimitHoldingText` 및 토글 활성화/비활성화 가드 테스트 추가.

- [ ] **Step 2: 테스트 실행하여 실패 확인**
Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/BatterySectionPresentationTests`
Expected: FAIL.

- [ ] **Step 3: `BatterySectionPresentation`, `SettingsBatterySection`, `Localizable.xcstrings` 구현**
- `BatterySectionPresentation.swift`:
  ```swift
  static func sleepUntilLimitHoldingText(locale: Locale = Locale(identifier: "ko")) -> String {
      String(localized: "잠자기 차단 중 (충전 완료 후 자동으로 잠듭니다)", locale: locale)
  }

  static func isSleepUntilLimitToggleEnabled(limitEnabled: Bool, capabilities: [BatteryControlCapability]?) -> Bool {
      guard limitEnabled else { return false }
      guard let capabilities else { return false }
      return capabilities.contains(.sleepUntilLimitV1)
  }
  ```
- `SettingsBatterySection.swift`:
  - `최대 충전 한도` 슬라이더/세그먼트 바로 아래에 `SettingsToggleRow` 추가:
    - 타이틀: "충전 한도 도달 시까지 잠자기 방지"
    - 서브타이틀: "충전 중 덮개를 닫아도 목표 한도에 도달할 때까지 잠들지 않고 충전을 마칩니다. 도달 시 자동으로 잠자기에 들어갑니다."
    - 바인딩: `$batterySleepUntilLimitEnabled`
    - `isEnabled`: `BatterySectionPresentation.isSleepUntilLimitToggleEnabled`
- `Localizable.xcstrings`: 신규 문자열 등록.
- `docs/features/battery-management/13-sleep-until-charge-limit.md`: 기능 사양 및 실기 검증 매트릭스 작성.

- [ ] **Step 4: 전체 테스트 스위트 및 데몬 빌드 검증**
Run:
```bash
xcodegen generate
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test
xcodebuild -project Wattly.xcodeproj -scheme WattlyFanDaemon -configuration Debug -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build
```
Expected: **TEST SUCCEEDED** 및 **BUILD SUCCEEDED**.

- [ ] **Step 5: 커밋**
```bash
git add Wattly/Core/BatterySectionPresentation.swift Wattly/Views/Settings/SettingsBatterySection.swift Wattly/Resources/Localizable.xcstrings docs/features/battery-management/13-sleep-until-charge-limit.md WattlyTests/BatterySectionPresentationTests.swift
git commit -m "feat(ui): add sleep-until-limit toggle in settings and status presentation"
```

---

## Plan Self-Review Checklist
1. **Spec Coverage:**
   - 덮개 닫힘 잠자기 차단 (`SleepDisabled`) -> Task 1, 2
   - 목표 도달 시 자동 해제 -> Task 1, 2
   - 어댑터 분리 시 즉시 해제 -> Task 1, 2
   - 발열 보호 시 즉시 해제 -> Task 1, 2
   - 4시간 안전 타임아웃 -> Task 1, 2
   - 설정 토글 및 UI 안내 문구 -> Task 3, 4
2. **No Placeholders:** 모든 단계에 구체적인 파일명, 코드 조각, 테스트 명령 및 기대 결과 명시 완료.
3. **Type Consistency:** `sleepUntilLimitAllowed`, `sleepUntilLimitEnabled`, `.sleepUntilLimitV1`, `BatteryHoldSleepPolicy.decide` 네이밍 전 태스크 일치.
