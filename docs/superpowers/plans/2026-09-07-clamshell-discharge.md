# 클램쉘 방전(뚜껑 닫힘 잠자기 차단) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 강제 방전(CHIE) 중 뚜껑을 닫아도 Mac이 잠들지 않도록, 루트 데몬이 방전 중에만 시스템 전역 `SleepDisabled`를 켜고 방전 종료·어댑터 분리·발열 보호·12시간 만료·데몬 시작/종료/삭제에서 되돌리는 옵트인 기능을 구현한다.

**Architecture:** 플래그의 소유자는 데몬 `BatteryControlCoordinator`다. 켜는 조건은 세 가지가 동시에 참일 때뿐이다 — (1) 앱이 보낸 `clamshellDischargeAllowed`(= 사용자 옵트인 && 외장 디스플레이 존재), (2) 엔진의 `isDischargingNow`(CHIE가 실제로 걸림; 수동·자동·캘리브레이션 전부), (3) 12시간 만료 래치가 서 있지 않음. 판정은 순수 함수 `BatteryClamshellSleepPolicy.decide`에, 실제 호출은 `SystemSleepInhibiting` 프로토콜 뒤에 있어 테스트는 스파이로 한다. 앱은 `BatteryControlClient.revivedConfiguration`(데몬으로 나가는 유일한 길목)에서 값을 계산해 실어 보내므로 Shortcuts·스케줄 등 어떤 호출부도 손대지 않는다.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Swift Testing (`import Testing`), XcodeGen, XPC(NSXPCConnection), IOKit 비공개 심볼 `IOPMSetSystemPowerSetting` / `IOPMCopySystemPowerSettings`(`@_silgen_name` 바인딩), AppKit `NSScreen` + CoreGraphics `CGDisplayIsBuiltin`.

## Global Constraints

- **`SleepDisabled`는 데몬(루트)에서 `IOPMSetSystemPowerSetting("SleepDisabled", Bool)`로만 만진다.** 앱은 절대 호출하지 않는다(비루트는 `0xE00002C1` 거부, 2026-09-07 실측). 루트에서는 직접 호출이 성공하고 1.5초 안에 `pmset -g`에 반영된다(실측) — `pmset` 서브프로세스 폴백은 없다. (결정 #1, #19)
- **`AppliesOnLidClose` 어설션은 쓰지 않는다.** 루트에서도 `kIOReturnNotPrivileged`(실측). `SleepAssertion`(idle sleep용)은 그대로 둔다. (결정 #18)
- **켜는 트리거는 엔진 `isDischargingNow` 하나.** 방전 출처(수동·자동·캘리브레이션)로 구분하지 않는다. 어댑터 분리·발열 보호·15% 하한 가드는 모두 이 값을 통해 자동 상속된다. (결정 #3, #20)
- **`clamshellDischargeAllowed`는 정책 파일에 저장하지 않는다.** `persistPolicy`가 `manualDischargeActive`처럼 `false`로 기록한다. 데몬만 재시작하면 앱의 60초 reconcile이 다시 보낸다. (결정 #6)
- **12시간 절대 만료.** 켠 시각 `sleepInhibitedAt`은 `PersistedBatteryPolicy`에 저장(소유 마커 겸용). 만료 후에는 같은 방전 세션 동안 다시 켜지 않는다. 만료는 잠자기 차단만 풀고 방전은 건드리지 않는다. (결정 #10, #11, #23)
- **마커를 먼저 저장하고 플래그를 켠다.** 그 사이에 크래시가 나도 재시작 시 마커만 보고 정리한다. 데몬 `restore`·`restoreWithoutPowerReading`·`releaseForTermination`·`--verify-battery-release`는 마커가 있으면 무조건 `SleepDisabled=0`. (결정 #14)
- **사용자가 직접 켜둔 `disablesleep 1`은 소유하지 않는다.** 켜기 전 현재값이 이미 `true`면 마커를 남기지 않고, 따라서 해제도 하지 않는다. (결정 #15)
- **외장 디스플레이 판정은 앱만 한다.** 루트 데몬은 WindowServer 없이 CG를 못 부른다. (결정 #7)
- **`BatterySectionPresentation.maintenanceStatus`·`HelperHealthStatus`의 전역 `requiredCapabilities`는 불변.** `.clamshellDischargeV1` 게이팅은 토글 안에서만. (결정 #16)
- 새 사용자 노출 문자열은 한국어 키 + 30개 로케일 전체를 `scripts/i18n_additions/*.json` → `python3 scripts/add_localizations.py`로 등록한다.
- Swift 6 strict concurrency. 순수 로직은 `@MainActor` 없이.
- `Wattly/`·`FanControlShared/`·`WattlyFanDaemon/`·`WattlyTests/` 아래 **파일을 추가하면 반드시 xcodegen 재생성**: `/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml`
- 빌드/테스트는 워크트리에서 DerivedData를 명시한다(에셋 카탈로그 권한 문제): `-derivedDataPath .build/DerivedData`
  - 테스트 전체: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test 2>&1 | tail -30`
  - 특정 스위트만: `... test -only-testing:WattlyTests/BatteryClamshellSleepPolicyTests`
  - 데몬만 빌드: `xcodebuild -project Wattly.xcodeproj -scheme WattlyFanDaemon -configuration Debug -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build 2>&1 | tail -5`
    (`-target`는 쓸 수 없다 — 이 툴체인은 `-derivedDataPath`와 함께 쓰면 "The flag -scheme, -testProductsPath, or -xctestrun is required when specifying -derivedDataPath"로 거부한다. 실측 확인.)

---

## File Structure

### 공유 계층 (`FanControlShared` — 앱과 데몬 양쪽에 컴파일됨)

| 파일 | 책임 | 변경 |
|---|---|---|
| `SystemSleepInhibiting.swift` | 잠자기 억제기 프로토콜 + `NoopSystemSleepInhibitor` | **신규** |
| `BatteryClamshellSleepPolicy.swift` | 12h 상수 · 순수 `decide` | **신규** |
| `BatteryControlProtocol.swift` | 설정 필드 `clamshellDischargeAllowed` · 상태 필드 `isSystemSleepInhibited` · `.clamshellDischargeV1` | 수정 |
| `BatteryPolicyPersistence.swift` | `sleepInhibitedAt` 마커 | 수정 |
| `BatteryControlEngine.swift` | `isDischargingNow` 노출 | 수정 |
| `BatteryControlCoordinator.swift` | 억제기 주입 · `syncSleepInhibition` · 마커 저장/복구/정리 | 수정 |

### 데몬 (`WattlyFanDaemon`)

| 파일 | 책임 | 변경 |
|---|---|---|
| `IOPMSystemSleepInhibitor.swift` | `@_silgen_name` 바인딩으로 `SleepDisabled` 읽기/쓰기 | **신규** |
| `main.swift` | 억제기 주입 · verifier 경로의 고아 플래그 정리 | 수정 |

### 앱 (`Wattly`)

| 파일 | 책임 | 변경 |
|---|---|---|
| `Settings/Settings.swift` | `Defaults`/`StorageKey`.`batteryClamshellDischargeEnabled` | 수정 |
| `Core/SettingsReset.swift` | 기본값 복원 한 줄 | 수정 |
| `Core/ExternalDisplayDetector.swift` | 외장 디스플레이 존재 판정(순수 코어 + `NSScreen` 래퍼) | **신규** |
| `Control/BatteryControlClient.swift` | `clamshellAllowance` 주입 · `revivedConfiguration`/`reconcile`에서 값 계산 | 수정 |
| `Views/BatteryControlBridge.swift` | 설정·디스플레이 변화 → push · `reconcileTaskID` | 수정 |
| `Core/BatterySectionPresentation.swift` | 토글 게이팅 · 상태 문구 | 수정 |
| `Views/Settings/SettingsBatteryDischargeSection.swift` | 토글 행 · 진행 배너의 "잠자기 차단 중" 줄 | 수정 |
| `Views/Settings/SettingsBatteryCalibrationSection.swift` | preflight 안내 조건부 문구 | 수정 |
| `Resources/Localizable.xcstrings` | 신규 키 6개 × 30 로케일 | 수정(스크립트) |

### 테스트 (`WattlyTests`)

| 파일 | 변경 |
|---|---|
| `BatteryClamshellSleepPolicyTests.swift` | **신규** |
| `ExternalDisplayDetectorTests.swift` | **신규** |
| `BatteryControlProtocolTests.swift` · `BatteryControlCoordinatorTests.swift` · `BatteryControlClientTests.swift` · `BatteryControlBridgeTests.swift` · `BatterySectionPresentationTests.swift` · `SettingsResetTests.swift` | 수정 |

### 문서

| 파일 | 변경 |
|---|---|
| `docs/features/battery-management/12-clamshell-discharge.md` | **신규** |

---

### Task 1: 잠자기 억제기 프로토콜 + 순수 판정 정책

**Files:**
- Create: `FanControlShared/SystemSleepInhibiting.swift`
- Create: `FanControlShared/BatteryClamshellSleepPolicy.swift`
- Test: `WattlyTests/BatteryClamshellSleepPolicyTests.swift`

**Interfaces:**
- Produces: `protocol SystemSleepInhibiting: Sendable { func readSleepDisabled() -> Bool?; func setSleepDisabled(_ disabled: Bool) -> Bool }`, `struct NoopSystemSleepInhibitor`, `enum BatteryClamshellSleepPolicy { static let duration: TimeInterval; enum Decision { none, engage, restamp(TimeInterval), disengage, expire }; static func decide(allowed:isDischarging:inhibitedAt:expiredForCurrentDischarge:now:duration:) -> Decision }`

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/BatteryClamshellSleepPolicyTests.swift`:

```swift
import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryClamshellSleepPolicyTests {
    @Test func defaultDurationIsTwelveHours() {
        #expect(BatteryClamshellSleepPolicy.duration == 12 * 3600)
        #expect(BatteryClamshellSleepPolicy.durationHours == 12)
    }

    /// 옵트인이 없으면 방전 중이어도 아무것도 하지 않는다.
    @Test func doesNothingWhenNotAllowed() {
        #expect(BatteryClamshellSleepPolicy.decide(
            allowed: false, isDischarging: true, inhibitedAt: nil,
            expiredForCurrentDischarge: false, now: 1_000) == .none)
    }

    /// 옵트인이 있어도 CHIE가 걸려 있지 않으면 켜지 않는다.
    @Test func doesNothingWhileNotDischarging() {
        #expect(BatteryClamshellSleepPolicy.decide(
            allowed: true, isDischarging: false, inhibitedAt: nil,
            expiredForCurrentDischarge: false, now: 1_000) == .none)
    }

    @Test func engagesWhenAllowedAndDischarging() {
        #expect(BatteryClamshellSleepPolicy.decide(
            allowed: true, isDischarging: true, inhibitedAt: nil,
            expiredForCurrentDischarge: false, now: 1_000) == .engage)
    }

    /// 같은 방전 세션에서 이미 12시간을 다 쓴 뒤에는 다시 켜지 않는다 — 앱의 60초 reconcile이
    /// `allowed=true`를 매분 되밀어도 만료가 무력화되면 안 된다.
    @Test func doesNotReengageAfterExpiryWithinTheSameDischarge() {
        #expect(BatteryClamshellSleepPolicy.decide(
            allowed: true, isDischarging: true, inhibitedAt: nil,
            expiredForCurrentDischarge: true, now: 1_000) == .none)
    }

    @Test func staysEngagedWhileConditionsHold() {
        #expect(BatteryClamshellSleepPolicy.decide(
            allowed: true, isDischarging: true, inhibitedAt: 1_000,
            expiredForCurrentDischarge: false, now: 1_000 + 3_600) == .none)
    }

    /// 방전이 끝나면(목표 도달·어댑터 분리·발열 보호·사용자 중지) 즉시 되돌린다.
    @Test func disengagesWhenDischargeStops() {
        #expect(BatteryClamshellSleepPolicy.decide(
            allowed: true, isDischarging: false, inhibitedAt: 1_000,
            expiredForCurrentDischarge: false, now: 2_000) == .disengage)
    }

    /// 사용자가 옵트인을 끄거나 외장 디스플레이를 뽑으면(앱이 allowed=false를 보냄) 되돌린다.
    @Test func disengagesWhenAllowanceIsWithdrawn() {
        #expect(BatteryClamshellSleepPolicy.decide(
            allowed: false, isDischarging: true, inhibitedAt: 1_000,
            expiredForCurrentDischarge: false, now: 2_000) == .disengage)
    }

    @Test func expiresAfterTheDuration() {
        #expect(BatteryClamshellSleepPolicy.decide(
            allowed: true, isDischarging: true, inhibitedAt: 1_000,
            expiredForCurrentDischarge: false,
            now: 1_000 + BatteryClamshellSleepPolicy.duration) == .expire)
        #expect(BatteryClamshellSleepPolicy.decide(
            allowed: true, isDischarging: true, inhibitedAt: 1_000,
            expiredForCurrentDischarge: false,
            now: 1_000 + BatteryClamshellSleepPolicy.duration - 1) == .none)
    }

    /// 시계가 뒤로 점프해 스탬프가 미래에 남으면 만료가 영원히 오지 않는다. Top Up과 같은
    /// 규칙으로 현재 시각에 재고정한다 — 손해는 최대 한 주기 연장뿐이다.
    @Test func restampsWhenTheClockWentBackwards() {
        #expect(BatteryClamshellSleepPolicy.decide(
            allowed: true, isDischarging: true, inhibitedAt: 5_000,
            expiredForCurrentDischarge: false, now: 4_000) == .restamp(4_000))
    }

    /// 만료·해제 판정은 스탬프가 있을 때 allowed/discharging보다 우선하지 않는다 —
    /// 방전이 이미 끝났으면 `.disengage`가 맞고, `.expire`로 래치를 세우면 다음 방전이
    /// 클램쉘을 못 쓴다.
    @Test func disengagePrecedesExpiryWhenDischargeAlreadyStopped() {
        #expect(BatteryClamshellSleepPolicy.decide(
            allowed: true, isDischarging: false, inhibitedAt: 0,
            expiredForCurrentDischarge: false,
            now: BatteryClamshellSleepPolicy.duration * 2) == .disengage)
    }
}
```

- [ ] **Step 2: 파일 생성 후 xcodegen 재생성, 테스트가 컴파일 실패하는지 확인**

Run:
```bash
/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml && xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/BatteryClamshellSleepPolicyTests 2>&1 | grep -E 'error:|Testing failed|TEST' | head
```
Expected: `error: cannot find 'BatteryClamshellSleepPolicy' in scope`

- [ ] **Step 3: 프로토콜과 정책 구현**

`FanControlShared/SystemSleepInhibiting.swift`:

```swift
import Foundation

/// 시스템 전역 잠자기 억제(`pmset disablesleep`과 같은 `SleepDisabled` 설정)의 읽기·쓰기.
///
/// 실제 구현은 루트 데몬에만 있다(`IOPMSystemSleepInhibitor`). 앱은 비루트라 호출 자체가
/// `kIOReturnNotPrivileged`로 거부되므로 이 프로토콜을 구현하지 않는다. 코디네이터는 이 뒤에서
/// 판정만 하고, 테스트는 스파이로 대체한다.
public protocol SystemSleepInhibiting: Sendable {
    /// 현재 값. 읽기 자체가 실패하면 `nil` — "꺼져 있음"으로 오해하면 사용자가 직접 켜둔
    /// 값을 Wattly가 소유해 버리므로, 호출자는 `nil`을 `false`와 다르게 다뤄야 한다.
    func readSleepDisabled() -> Bool?
    /// 쓰기 성공 여부.
    func setSleepDisabled(_ disabled: Bool) -> Bool
}

/// 아무것도 하지 않는 기본 구현. 코디네이터 생성자의 기본값이라 기존 호출부·테스트가 그대로
/// 컴파일되고, 잠자기 억제와 무관한 테스트는 스파이를 만들 필요가 없다.
public struct NoopSystemSleepInhibitor: SystemSleepInhibiting {
    public init() {}
    public func readSleepDisabled() -> Bool? { false }
    public func setSleepDisabled(_ disabled: Bool) -> Bool { true }
}
```

`FanControlShared/BatteryClamshellSleepPolicy.swift`:

```swift
import Foundation

/// 클램쉘 방전의 잠자기 차단을 "지금 켜야 하는가 / 꺼야 하는가"에 대한 **유일한** 판정.
///
/// 배경: CHIE 강제 방전 중에는 macOS가 배터리 구동으로 보고, powerd는 `DesktopMode && AC`가
/// 아니면 뚜껑 닫힘에 잠자기를 건다. 잠들면 방전은 정지한다(602초에 −0.01%p, 실측).
/// `PreventUserIdleSystemSleep`·`caffeinate`·`AppliesOnLidClose` 어설션은 이 OS에서 통하지
/// 않아(마지막 것은 루트에서도 거부) 시스템 전역 `SleepDisabled`를 쓴다. 그 설정은 재부팅을
/// 넘어 남으므로, 켜는 조건은 좁고 끄는 경로는 여러 겹이어야 한다.
///
/// 순수 함수로 떼어 둔 이유는 `BatteryTopUpExpiry`와 같다 — 시간이 얽힌 전이를 실제 대기 없이
/// 테이블 테스트하고, 만료 예외를 넣을 자리를 한 곳으로 고정한다.
public enum BatteryClamshellSleepPolicy {
    /// 켠 뒤 이만큼 지나면 무조건 해제한다. Top Up 만료와 같은 12시간 — 실측 방전 속도
    /// 0.11~0.33 %p/분이면 수동 100→50%가 최대 약 8시간, 캘리브레이션 100→20%가 약 7시간이다.
    public static let duration: TimeInterval = 12 * 60 * 60

    /// 사용자에게 보여 줄 시간 수. 문구가 상수와 갈라지지 않도록 문자열에 12를 직접 쓰지 않는다.
    public static var durationHours: Int { Int(duration / 3600) }

    public enum Decision: Equatable, Sendable {
        case none
        /// 마커를 저장하고 `SleepDisabled`를 켠다.
        case engage
        /// 스탬프가 미래에 있다(시계 역행). 이 시각으로 재고정한다.
        case restamp(TimeInterval)
        /// `SleepDisabled`를 끄고 마커를 지운다.
        case disengage
        /// `.disengage` + 같은 방전 세션 동안 재개 금지 래치.
        case expire
    }

    /// - Parameters:
    ///   - allowed: 앱이 보낸 `clamshellDischargeAllowed`(옵트인 && 외장 디스플레이).
    ///   - isDischarging: 엔진의 `isDischargingNow` — CHIE가 실제로 걸려 있는지.
    ///   - inhibitedAt: Wattly가 켠 시각(소유 마커). 우리가 켜지 않았으면 `nil`.
    ///   - expiredForCurrentDischarge: 이번 방전 세션에서 이미 만료됐는지. 코디네이터가
    ///     `isDischarging`이 거짓이 되는 순간 리셋한다.
    ///   - now: 벽시계. 잠자기 동안에도 진행해야 하므로 단조 시계를 쓰면 안 된다.
    public static func decide(
        allowed: Bool,
        isDischarging: Bool,
        inhibitedAt: TimeInterval?,
        expiredForCurrentDischarge: Bool,
        now: TimeInterval,
        duration: TimeInterval = BatteryClamshellSleepPolicy.duration
    ) -> Decision {
        guard let inhibitedAt else {
            guard allowed, isDischarging, !expiredForCurrentDischarge else { return .none }
            return .engage
        }
        // 소유 중. 조건이 하나라도 깨지면 만료보다 먼저 해제한다 — 방전이 끝난 뒤 `.expire`로
        // 래치를 세우면 다음 방전이 클램쉘을 못 쓴다.
        guard allowed, isDischarging else { return .disengage }
        guard now >= inhibitedAt else { return .restamp(now) }
        return now - inhibitedAt >= duration ? .expire : .none
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/BatteryClamshellSleepPolicyTests 2>&1 | grep -E 'Test Suite|passed|failed' | tail -5
```
Expected: `Test Suite 'BatteryClamshellSleepPolicyTests' passed` (11 tests)

- [ ] **Step 5: Commit**

```bash
git add FanControlShared/SystemSleepInhibiting.swift FanControlShared/BatteryClamshellSleepPolicy.swift WattlyTests/BatteryClamshellSleepPolicyTests.swift Wattly.xcodeproj/project.pbxproj
git commit -m "feat(battery): add clamshell sleep-inhibition policy and inhibitor seam

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: 프로토콜 필드 — 설정·상태·capability·저장 마커

**Files:**
- Modify: `FanControlShared/BatteryControlProtocol.swift:3-100` (설정), `:139-145` (capability), `:296-360` (status)
- Modify: `FanControlShared/BatteryPolicyPersistence.swift:4-36`, `:107-112`
- Test: `WattlyTests/BatteryControlProtocolTests.swift`

**Interfaces:**
- Produces: `BatteryControlConfiguration.clamshellDischargeAllowed: Bool`(기본 false, memberwise init 마지막 인자), `BatteryControlServiceStatus.isSystemSleepInhibited: Bool?`(init 마지막 인자), `BatteryControlCapability.clamshellDischargeV1 = "clamshell-discharge-v1"`, `PersistedBatteryPolicy.sleepInhibitedAt: TimeInterval?`(init 마지막 인자)

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/BatteryControlProtocolTests.swift` 끝(마지막 `}` 앞)에 추가:

```swift
    // MARK: - 클램쉘 방전

    /// 필드를 모르는 구버전 페이로드(구버전 앱 → 새 데몬, 새 앱 → 구버전 데몬 양쪽).
    @Test func clamshellDischargeFieldDefaultsOffAndDecodesLeniently() throws {
        let legacy = #"{"enabled":true,"limitPercentage":80,"lowerHysteresisDelta":2}"#
        let decoded = try BatteryControlCodec.decode(
            BatteryControlConfiguration.self, from: Data(legacy.utf8))
        #expect(decoded.clamshellDischargeAllowed == false)
    }

    @Test func clamshellDischargeFieldRoundTrips() throws {
        let config = BatteryControlConfiguration(enabled: true, clamshellDischargeAllowed: true)
        let data = try BatteryControlCodec.encode(config)
        let decoded = try BatteryControlCodec.decode(BatteryControlConfiguration.self, from: data)
        #expect(decoded.clamshellDischargeAllowed == true)
        #expect(decoded.normalized.clamshellDischargeAllowed == true)
    }

    /// 옵트인 자체는 정책이 아니다 — 한도도 방전도 없는 설정이 이 필드 때문에 "활성"이 되면
    /// 데몬이 아무 일도 없는데 하드웨어 상태를 붙들고 있게 된다.
    @Test func clamshellDischargeDoesNotCountAsActivePolicy() {
        #expect(BatteryControlConfiguration(clamshellDischargeAllowed: true).isActive == false)
    }

    @Test func statusDecodesSleepInhibitionLeniently() throws {
        let legacy = Data(#"{"mode":"charging","currentPercentage":70,"isPowerAdapterConnected":true,"detail":"충전 중","updatedAt":1.0}"#.utf8)
        let decoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: legacy)
        #expect(decoded.isSystemSleepInhibited == nil)

        let status = BatteryControlServiceStatus(
            mode: .charging, currentPercentage: 70, isPowerAdapterConnected: true,
            detail: "OK", updatedAt: 1, isSystemSleepInhibited: true)
        let round = try BatteryControlCodec.decode(
            BatteryControlServiceStatus.self, from: BatteryControlCodec.encode(status))
        #expect(round.isSystemSleepInhibited == true)
    }

    @Test func clamshellCapabilityRoundTripsAndOldCapabilityListsStillDecode() throws {
        let data = try BatteryControlCodec.encode([BatteryControlCapability.clamshellDischargeV1])
        #expect(String(decoding: data, as: UTF8.self) == #"["clamshell-discharge-v1"]"#)
        let decoded = try BatteryControlCodec.decode([BatteryControlCapability].self, from: data)
        #expect(decoded == [.clamshellDischargeV1])
    }

    @Test func persistedPolicyCarriesTheSleepInhibitionMarkerLeniently() throws {
        let legacy = #"{"schemaVersion":1,"ownerUID":501,"configuration":{"enabled":true,"limitPercentage":80,"lowerHysteresisDelta":2},"updatedAt":1.0}"#
        let decoded = try JSONDecoder().decode(PersistedBatteryPolicy.self, from: Data(legacy.utf8))
        #expect(decoded.sleepInhibitedAt == nil)

        let policy = PersistedBatteryPolicy(
            ownerUID: 501, configuration: .init(enabled: true), updatedAt: 5, sleepInhibitedAt: 42)
        let round = try JSONDecoder().decode(
            PersistedBatteryPolicy.self, from: JSONEncoder().encode(policy))
        #expect(round.sleepInhibitedAt == 42)
    }
```

- [ ] **Step 2: 실패 확인**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/BatteryControlProtocolTests 2>&1 | grep -E 'error:' | head -3
```
Expected: `error: extra argument 'clamshellDischargeAllowed' in call` (또는 `has no member 'clamshellDischargeAllowed'`)

- [ ] **Step 3: 설정 필드 추가**

`FanControlShared/BatteryControlProtocol.swift` — `calibrationTargetPercentage` 프로퍼티 선언(21행) 바로 아래:

```swift
    /// 클램쉘 방전 허용 — 앱이 "사용자 옵트인 && 외장 디스플레이 존재"로 계산해 보낸다.
    /// 데몬은 이 값과 엔진의 실제 CHIE 상태가 함께 참일 때만 시스템 잠자기를 억제한다.
    /// `manualDischargeActive`처럼 정책 파일에는 **저장하지 않는다** — 앱이 죽은 채 데몬만
    /// 재시작하면 잠자기 차단 없이 시작하는 것이 안전한 방향이고, 앱이 살아 있으면 60초
    /// reconcile이 다시 보낸다. `isActive`에는 포함하지 않는다: 옵트인은 정책이 아니다.
    public var clamshellDischargeAllowed: Bool
```

memberwise `init`의 마지막 인자와 대입 추가(`calibrationTargetPercentage: Int = 20` 뒤):

```swift
        calibrationTargetPercentage: Int = 20,
        clamshellDischargeAllowed: Bool = false
    ) {
```
그리고 `self.calibrationTargetPercentage = calibrationTargetPercentage` 아래에:
```swift
        self.clamshellDischargeAllowed = clamshellDischargeAllowed
```

`CodingKeys`에 케이스 추가:
```swift
        case calibrationActive, calibrationTargetPercentage
        case clamshellDischargeAllowed
```

`init(from:)` 마지막 줄(`calibrationTargetPercentage = ...`) 아래:
```swift
        clamshellDischargeAllowed = (try? container.decodeIfPresent(Bool.self, forKey: .clamshellDischargeAllowed)) ?? false
```

`normalized`의 `copy.calibrationTargetPercentage = ...` 아래:
```swift
        copy.clamshellDischargeAllowed = clamshellDischargeAllowed
```

- [ ] **Step 4: capability와 status 필드 추가**

`BatteryControlCapability`에 케이스 추가(`case calibrationV1 = "calibration-v1"` 아래):
```swift
    /// 방전 중 뚜껑 닫힘 잠자기 억제. 토글 게이팅에만 쓰고 전역 `requiredCapabilities`에는
    /// 넣지 않는다 — 넣으면 이 기능을 쓰지 않는 전 사용자가 "도우미 업데이트 필요"가 된다.
    case clamshellDischargeV1 = "clamshell-discharge-v1"
```

`BatteryControlServiceStatus`의 `batteryTemperatureCelsius` 프로퍼티 아래:
```swift
    /// 데몬이 지금 클램쉘 방전을 위해 시스템 잠자기를 억제 중인지. `nil`은 이 필드를 모르는
    /// 구버전 헬퍼. 앱은 이걸로 "잠자기 차단 중" 표시를 켠다.
    public var isSystemSleepInhibited: Bool?
```
init 인자(`batteryTemperatureCelsius: Double? = nil` 뒤):
```swift
        batteryTemperatureCelsius: Double? = nil,
        isSystemSleepInhibited: Bool? = nil
    ) {
```
대입(`self.batteryTemperatureCelsius = batteryTemperatureCelsius` 아래):
```swift
        self.isSystemSleepInhibited = isSystemSleepInhibited
```

- [ ] **Step 5: 저장 마커 추가**

`FanControlShared/BatteryPolicyPersistence.swift` — `topUpReachedFullAt` 프로퍼티 아래:
```swift
    /// Wattly가 시스템 `SleepDisabled`를 켠 벽시계 시각. **소유 마커 겸 12시간 만료 시계**다.
    /// 우리가 켜지 않았으면(사용자가 직접 `pmset disablesleep 1`을 했더라도) `nil`.
    /// 플래그를 켜기 **전에** 저장한다 — 그 사이에 데몬이 죽어도 재시작이 마커만 보고 정리한다.
    /// `topUpReachedFullAt`과 같은 이유로 `configuration` 안이 아니라 여기 있다.
    public var sleepInhibitedAt: TimeInterval?
```
init:
```swift
    public init(
        ownerUID: UInt32,
        configuration: BatteryControlConfiguration,
        updatedAt: TimeInterval,
        topUpReachedFullAt: TimeInterval? = nil,
        sleepInhibitedAt: TimeInterval? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.ownerUID = ownerUID
        self.configuration = configuration.normalized
        self.updatedAt = updatedAt
        self.topUpReachedFullAt = topUpReachedFullAt
        self.sleepInhibitedAt = sleepInhibitedAt
    }
```
`BatteryPolicyFileStore.save`의 재정규화(`let normalized = PersistedBatteryPolicy(...)`):
```swift
        let normalized = PersistedBatteryPolicy(
            ownerUID: policy.ownerUID,
            configuration: policy.configuration,
            updatedAt: policy.updatedAt,
            topUpReachedFullAt: policy.topUpReachedFullAt,
            sleepInhibitedAt: policy.sleepInhibitedAt
        )
```

- [ ] **Step 6: 테스트 통과 확인 + 전체 테스트 회귀 없음**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test 2>&1 | grep -E 'Test Suite .All tests|passed|failed' | tail -3
```
Expected: `** TEST SUCCEEDED **` 계열, 실패 0

- [ ] **Step 7: Commit**

```bash
git add FanControlShared/BatteryControlProtocol.swift FanControlShared/BatteryPolicyPersistence.swift WattlyTests/BatteryControlProtocolTests.swift
git commit -m "feat(battery): carry clamshell discharge allowance, sleep-inhibited status and persisted marker

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: 코디네이터 — 억제기 주입, 동기화, 마커 저장/복구/정리

**Files:**
- Modify: `FanControlShared/BatteryControlEngine.swift:80` (`configuration` 아래)
- Modify: `FanControlShared/BatteryControlCoordinator.swift` (init, `restore`, `restoreWithoutPowerReading`, `sample`, `releaseForTermination`, `persistPolicy`, `publish`, `resolvedStoredPolicy`)
- Test: `WattlyTests/BatteryControlCoordinatorTests.swift`

**Interfaces:**
- Consumes: Task 1의 `SystemSleepInhibiting`, `BatteryClamshellSleepPolicy.decide`; Task 2의 필드들.
- Produces: `BatteryControlEngine.isDischargingNow: Bool`; `BatteryControlCoordinator.init(ownerUID:store:engine:now:sleepInhibitor:)`(마지막 인자 기본값 `NoopSystemSleepInhibitor()`); `BatteryControlCoordinator.capabilities`에 `.clamshellDischargeV1`; 모든 `latestStatus`에 `isSystemSleepInhibited` 채움.

- [ ] **Step 1: 스파이와 실패하는 테스트 작성**

`WattlyTests/BatteryControlCoordinatorTests.swift` — `typealias MockBatteryPolicyStore = PolicyStoreSpy` 아래에 스파이 추가:

```swift
final class SleepInhibitorSpy: SystemSleepInhibiting, @unchecked Sendable {
    /// 시스템의 현재 `SleepDisabled`. 테스트가 "사용자가 미리 켜둠"을 흉내낼 때 직접 세운다.
    var current = false
    var readFails = false
    var setShouldFail = false
    /// 모든 쓰기 시도. 중복 쓰기도 보여야 하므로 성공/실패 무관하게 기록한다.
    var writes: [Bool] = []

    func readSleepDisabled() -> Bool? {
        readFails ? nil : current
    }

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        writes.append(disabled)
        if setShouldFail { return false }
        current = disabled
        return true
    }
}
```

같은 파일의 `struct BatteryControlCoordinatorTests {` 안, 마지막 테스트 뒤에 추가:

```swift
    // MARK: - 클램쉘 방전 잠자기 억제

    private func makeClamshellCoordinator(
        clock: MutableClock,
        hardware: MockBatteryHardware = MockBatteryHardware(),
        store: PolicyStoreSpy = PolicyStoreSpy(),
        inhibitor: SleepInhibitorSpy = SleepInhibitorSpy()
    ) -> BatteryControlCoordinator {
        BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: hardware),
            now: { clock.now },
            sleepInhibitor: inhibitor)
    }

    @Test func capabilitiesAdvertiseClamshellDischarge() {
        #expect(BatteryControlCoordinator.capabilities.contains(.clamshellDischargeV1))
    }

    /// 켜는 조건 세 개: allowed && CHIE 걸림. 마커가 플래그보다 먼저 저장된다.
    @Test func engagesSleepInhibitionWhenAllowedAndDischarging() {
        let clock = MutableClock(1_000)
        let hardware = MockBatteryHardware()
        let store = PolicyStoreSpy()
        let inhibitor = SleepInhibitorSpy()
        let coordinator = makeClamshellCoordinator(
            clock: clock, hardware: hardware, store: store, inhibitor: inhibitor)

        let status = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 70,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 85, isPluggedIn: true)

        #expect(hardware.isDischargeActive == true)
        #expect(inhibitor.writes == [true])
        #expect(inhibitor.current == true)
        #expect(status.isSystemSleepInhibited == true)
        #expect(store.stored?.sleepInhibitedAt == 1_000)
        // 옵트인 자체는 저장하지 않는다.
        #expect(store.stored?.configuration.clamshellDischargeAllowed == false)
    }

    @Test func doesNotEngageWithoutAllowanceEvenWhileDischarging() {
        let clock = MutableClock(1_000)
        let inhibitor = SleepInhibitorSpy()
        let coordinator = makeClamshellCoordinator(clock: clock, inhibitor: inhibitor)

        let status = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 70),
            trigger: .clientConfiguration, currentSoC: 85, isPluggedIn: true)

        #expect(inhibitor.writes.isEmpty)
        #expect(status.isSystemSleepInhibited == false)
    }

    /// 자동 방전(sailing)도 CHIE를 걸므로 같은 규칙을 탄다(결정 #20).
    @Test func engagesForAutomaticDischargeToo() {
        let clock = MutableClock(1_000)
        let hardware = MockBatteryHardware()
        let inhibitor = SleepInhibitorSpy()
        let coordinator = makeClamshellCoordinator(
            clock: clock, hardware: hardware, inhibitor: inhibitor)

        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, autoDischargeEnabled: true,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 95, isPluggedIn: true)

        #expect(hardware.isDischargeActive == true)
        #expect(inhibitor.current == true)
    }

    /// 목표 도달 → 엔진이 CHIE를 끔 → 같은 샘플에서 잠자기 차단도 풀린다.
    @Test func disengagesWhenDischargeReachesItsTarget() {
        let clock = MutableClock(1_000)
        let hardware = MockBatteryHardware()
        let store = PolicyStoreSpy()
        let inhibitor = SleepInhibitorSpy()
        let coordinator = makeClamshellCoordinator(
            clock: clock, hardware: hardware, store: store, inhibitor: inhibitor)
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 70,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 85, isPluggedIn: true)
        #expect(inhibitor.current == true)

        let status = coordinator.sample(currentSoC: 70, isPluggedIn: true)

        #expect(hardware.isDischargeActive == false)
        #expect(inhibitor.writes == [true, false])
        #expect(status.isSystemSleepInhibited == false)
        #expect(store.stored?.sleepInhibitedAt == nil)
    }

    /// 가방 시나리오: 어댑터를 뽑으면 데몬이 수동 방전을 끄고, 잠자기 차단도 함께 풀린다.
    @Test func disengagesWhenTheAdapterIsUnplugged() {
        let clock = MutableClock(1_000)
        let inhibitor = SleepInhibitorSpy()
        let coordinator = makeClamshellCoordinator(clock: clock, inhibitor: inhibitor)
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 70,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 85, isPluggedIn: true)

        _ = coordinator.sample(currentSoC: 84, isPluggedIn: false)

        #expect(inhibitor.current == false)
        #expect(inhibitor.writes == [true, false])
    }

    /// 앱이 allowed=false를 보내면(옵트인 해제 또는 외장 디스플레이 분리) 방전은 계속되지만
    /// 잠자기 차단만 풀린다.
    @Test func disengagesWhenTheAppWithdrawsAllowanceWhileStillDischarging() {
        let clock = MutableClock(1_000)
        let hardware = MockBatteryHardware()
        let inhibitor = SleepInhibitorSpy()
        let coordinator = makeClamshellCoordinator(
            clock: clock, hardware: hardware, inhibitor: inhibitor)
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 70,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 85, isPluggedIn: true)

        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 70,
                  clamshellDischargeAllowed: false),
            trigger: .clientConfiguration, currentSoC: 84, isPluggedIn: true)

        #expect(hardware.isDischargeActive == true)
        #expect(inhibitor.current == false)
    }

    /// 발열 보호는 엔진이 CHIE를 끄므로 별도 배선 없이 상속된다.
    @Test func disengagesUnderHeatProtection() {
        let clock = MutableClock(1_000)
        let hardware = MockBatteryHardware()
        let inhibitor = SleepInhibitorSpy()
        let coordinator = makeClamshellCoordinator(
            clock: clock, hardware: hardware, inhibitor: inhibitor)
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  heatProtectionEnabled: true, heatProtectionThresholdCelsius: 35,
                  manualDischargeActive: true, manualDischargeTarget: 70,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 85, isPluggedIn: true,
            temperatureCelsius: 30)
        #expect(inhibitor.current == true)

        _ = coordinator.sample(currentSoC: 84, isPluggedIn: true, temperatureCelsius: 36)

        #expect(hardware.isDischargeActive == false)
        #expect(inhibitor.current == false)
    }

    /// 12시간이 지나면 방전은 계속되지만 잠자기 차단은 풀리고, 앱이 allowed=true를 매분
    /// 되밀어도 같은 방전 세션에서는 다시 켜지지 않는다. 방전이 끝나면 래치가 풀린다.
    @Test func expiresAfterTwelveHoursAndDoesNotReengageUntilDischargeEnds() {
        let clock = MutableClock(1_000)
        let hardware = MockBatteryHardware()
        let inhibitor = SleepInhibitorSpy()
        let coordinator = makeClamshellCoordinator(
            clock: clock, hardware: hardware, inhibitor: inhibitor)
        let running = BatteryControlConfiguration(
            enabled: true, limitPercentage: 80,
            manualDischargeActive: true, manualDischargeTarget: 50,
            clamshellDischargeAllowed: true)
        _ = coordinator.configure(
            running, trigger: .clientConfiguration, currentSoC: 95, isPluggedIn: true)

        clock.advance(by: BatteryClamshellSleepPolicy.duration)
        let expired = coordinator.sample(currentSoC: 60, isPluggedIn: true)
        #expect(hardware.isDischargeActive == true)
        #expect(inhibitor.current == false)
        #expect(expired.isSystemSleepInhibited == false)

        // 앱 reconcile이 다시 보내도 켜지지 않는다.
        _ = coordinator.configure(
            running, trigger: .clientConfiguration, currentSoC: 59, isPluggedIn: true)
        #expect(inhibitor.writes == [true, false])

        // 목표 도달로 방전이 끝나면 래치가 풀려, 다음 방전은 다시 켤 수 있다.
        _ = coordinator.sample(currentSoC: 50, isPluggedIn: true)
        // `manualDischargeTarget`은 50~99로 클램프된다(`clampLimit`은 `max(50, ...)`). 목표를
        // 40으로 요청해도 50으로 잘리므로, 새 방전이 실제로 걸리려면 SoC가 그 클램프된 목표보다
        // 높아야 한다 — SoC 50은 50을 넘지 못해 방전이 시작되지 않는다. 그래서 55에서 다시 켠다.
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 40,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 55, isPluggedIn: true)
        #expect(inhibitor.writes == [true, false, true])
    }

    /// 사용자가 직접 `pmset disablesleep 1`을 해 둔 Mac에서는 소유하지 않는다 — 켜지도, 방전이
    /// 끝났다고 끄지도 않는다.
    @Test func doesNotTakeOwnershipOfAUserSetSleepDisabled() {
        let clock = MutableClock(1_000)
        let store = PolicyStoreSpy()
        let inhibitor = SleepInhibitorSpy()
        inhibitor.current = true
        let coordinator = makeClamshellCoordinator(
            clock: clock, store: store, inhibitor: inhibitor)

        let status = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 70,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 85, isPluggedIn: true)
        _ = coordinator.sample(currentSoC: 70, isPluggedIn: true)

        #expect(inhibitor.writes.isEmpty)
        #expect(inhibitor.current == true)
        #expect(status.isSystemSleepInhibited == false)
        #expect(store.stored?.sleepInhibitedAt == nil)
    }

    /// 읽기 실패는 "꺼져 있음"이 아니다. 모르면 켜지 않는다.
    @Test func doesNotEngageWhenTheCurrentValueCannotBeRead() {
        let clock = MutableClock(1_000)
        let inhibitor = SleepInhibitorSpy()
        inhibitor.readFails = true
        let coordinator = makeClamshellCoordinator(clock: clock, inhibitor: inhibitor)

        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 70,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 85, isPluggedIn: true)

        #expect(inhibitor.writes.isEmpty)
    }

    /// 마커 저장이 실패하면 플래그를 켜지 않는다 — 마커 없는 플래그는 크래시 후 고아가 된다.
    @Test func doesNotEngageWhenTheMarkerCannotBePersisted() {
        let clock = MutableClock(1_000)
        let store = PolicyStoreSpy()
        let inhibitor = SleepInhibitorSpy()
        let coordinator = makeClamshellCoordinator(
            clock: clock, store: store, inhibitor: inhibitor)
        // configure의 첫 persist는 성공시키고, 그 뒤 마커 저장만 실패시킨다.
        var saveCount = 0
        store.onSave = {
            saveCount += 1
            if saveCount >= 2 { store.saveError = BatteryPolicyStoreError.fileOperation(errno: 1) }
        }

        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 70,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 85, isPluggedIn: true)

        #expect(inhibitor.writes.isEmpty)
        #expect(store.stored?.sleepInhibitedAt == nil)
    }

    /// 해제 쓰기가 실패하면 마커를 남겨 다음 샘플이 재시도한다.
    @Test func retriesDisengageUntilTheWriteLands() {
        let clock = MutableClock(1_000)
        let store = PolicyStoreSpy()
        let inhibitor = SleepInhibitorSpy()
        let coordinator = makeClamshellCoordinator(
            clock: clock, store: store, inhibitor: inhibitor)
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 70,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 85, isPluggedIn: true)

        inhibitor.setShouldFail = true
        _ = coordinator.sample(currentSoC: 70, isPluggedIn: true)
        #expect(inhibitor.current == true)
        #expect(store.stored?.sleepInhibitedAt == 1_000)

        inhibitor.setShouldFail = false
        clock.advance(by: 5)
        _ = coordinator.sample(currentSoC: 70, isPluggedIn: true)
        #expect(inhibitor.current == false)
        #expect(store.stored?.sleepInhibitedAt == nil)
    }

    /// 크래시·재부팅 복구: 파일에 마커가 남아 있으면 시작 시 무조건 되돌린다. 옵트인은 저장되지
    /// 않으므로 다시 켜지지도 않는다.
    @Test func restoreClearsAnOrphanedSleepInhibition() {
        let clock = MutableClock(5_000)
        let store = PolicyStoreSpy()
        store.stored = PersistedBatteryPolicy(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 80),
            updatedAt: 1_000,
            sleepInhibitedAt: 1_000)
        let inhibitor = SleepInhibitorSpy()
        inhibitor.current = true
        let coordinator = makeClamshellCoordinator(
            clock: clock, store: store, inhibitor: inhibitor)

        let status = coordinator.restore(currentSoC: 60, isPluggedIn: true)

        #expect(inhibitor.writes == [false])
        #expect(inhibitor.current == false)
        #expect(store.stored?.sleepInhibitedAt == nil)
        #expect(status.isSystemSleepInhibited == false)
    }

    @Test func restoreWithoutPowerReadingAlsoClearsAnOrphanedSleepInhibition() {
        let clock = MutableClock(5_000)
        let store = PolicyStoreSpy()
        store.stored = PersistedBatteryPolicy(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 80),
            updatedAt: 1_000,
            sleepInhibitedAt: 1_000)
        let inhibitor = SleepInhibitorSpy()
        inhibitor.current = true
        let coordinator = makeClamshellCoordinator(
            clock: clock, store: store, inhibitor: inhibitor)

        _ = coordinator.restoreWithoutPowerReading()

        #expect(inhibitor.writes == [false])
        #expect(store.stored?.sleepInhibitedAt == nil)
    }

    /// 마커가 없으면 시작 시 아무것도 쓰지 않는다 — 사용자의 `disablesleep 1`을 건드리면 안 된다.
    @Test func restoreLeavesAForeignSleepDisabledAlone() {
        let clock = MutableClock(5_000)
        let store = PolicyStoreSpy()
        store.stored = PersistedBatteryPolicy(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 80),
            updatedAt: 1_000)
        let inhibitor = SleepInhibitorSpy()
        inhibitor.current = true
        let coordinator = makeClamshellCoordinator(
            clock: clock, store: store, inhibitor: inhibitor)

        _ = coordinator.restore(currentSoC: 60, isPluggedIn: true)

        #expect(inhibitor.writes.isEmpty)
        #expect(inhibitor.current == true)
    }

    @Test func terminationReleasesSleepInhibition() {
        let clock = MutableClock(1_000)
        let store = PolicyStoreSpy()
        let inhibitor = SleepInhibitorSpy()
        let coordinator = makeClamshellCoordinator(
            clock: clock, store: store, inhibitor: inhibitor)
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80,
                  manualDischargeActive: true, manualDischargeTarget: 70,
                  clamshellDischargeAllowed: true),
            trigger: .clientConfiguration, currentSoC: 85, isPluggedIn: true)

        _ = coordinator.releaseForTermination()

        #expect(inhibitor.current == false)
        #expect(store.stored?.sleepInhibitedAt == nil)
    }
```

- [ ] **Step 2: 실패 확인**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/BatteryControlCoordinatorTests 2>&1 | grep -E 'error:' | head -3
```
Expected: `error: extra argument 'sleepInhibitor' in call`

- [ ] **Step 3: 엔진에 `isDischargingNow` 노출**

`FanControlShared/BatteryControlEngine.swift` — `public var configuration: BatteryControlConfiguration { config }`(80행) 아래:

```swift
    /// CHIE 방전이 실제로 걸려 있는지. 클램쉘 잠자기 억제의 **유일한** 트리거다 — 수동·자동·
    /// 캘리브레이션 어느 출처든 이 한 값으로 접히고, 어댑터 분리·발열 보호·15% 하한 가드가
    /// 이 값을 끄는 순간 잠자기 억제도 따라서 풀린다.
    public var isDischargingNow: Bool { isCurrentlyDischarging }
```

- [ ] **Step 4: 코디네이터 수정**

`FanControlShared/BatteryControlCoordinator.swift`:

(a) `capabilities` 배열에 `.clamshellDischargeV1` 추가:
```swift
    public static let capabilities: [BatteryControlCapability] = [
        .persistedPolicyV1,
        .hardwareGateReadbackV1,
        .systemPowerEventsV1,
        .calibrationV1,
        .clamshellDischargeV1,
    ]
```

(b) 프로퍼티 추가(`private var topUpReachedFullAt: TimeInterval?` 아래):
```swift
    private let sleepInhibitor: any SystemSleepInhibiting
    /// Wattly가 시스템 `SleepDisabled`를 켠 시각. 저장 파일의 값을 미러링한다(소유 마커 겸
    /// 12시간 시계). `nil`이면 우리가 켜지 않았다.
    private var sleepInhibitedAt: TimeInterval?
    /// 이번 방전 세션에서 12시간을 다 썼는지. 엔진의 방전이 꺼지는 순간 리셋된다.
    private var clamshellExpiredForCurrentDischarge = false
```

(c) init 시그니처:
```swift
    public init(
        ownerUID: UInt32,
        store: any BatteryPolicyStoring,
        engine: BatteryControlEngine,
        now: @escaping @Sendable () -> TimeInterval,
        sleepInhibitor: any SystemSleepInhibiting = NoopSystemSleepInhibitor()
    ) {
        self.ownerUID = ownerUID
        self.store = store
        self.engine = engine
        self.now = now
        self.sleepInhibitor = sleepInhibitor
```
(나머지 본문은 그대로.)

(d) `restore(...)`의 `engine.configure(desired)` 줄 **바로 아래**에(그 앞이 아니다 — `releaseSleepInhibition`이 `persistPolicy(engine.configuration)`를 부르므로 엔진에 파일의 정책이 실린 뒤여야 기본 설정으로 파일을 덮어쓰지 않는다):
```swift
            // 크래시·재부팅 뒤 고아로 남은 잠자기 차단을 되돌린다. 옵트인은 저장되지 않으므로
            // 아래에서 다시 켜질 일은 없다. 소유자가 다른 파일이면 플래그만 끄고 파일은 건드리지
            // 않는다 — 다음 소유자의 데몬이 같은 마커를 보고 다시(무해하게) 끈다.
            releaseSleepInhibition(persist: ownershipFailure == nil)
            // 남의 파일이면 쓰기 성공 여부와 무관하게 미러를 버린다. 남겨 두면 곧이어
            // `publish`→`sync`의 `.disengage` 재시도가 `persist: true`로 남의 파일에 우리 기본
            // 설정을 쓴다. 플래그가 실제로 남았더라도 그 소유자의 데몬이 같은 마커로 다시 끈다.
            if ownershipFailure != nil { sleepInhibitedAt = nil }
```
`restoreWithoutPowerReading()`의 `engine.configure(desired)` 줄 바로 아래에도 같은 주석 + 같은 두 문장(`releaseSleepInhibition(persist: ownershipFailure == nil)` / `if ownershipFailure != nil { sleepInhibitedAt = nil }`)을 추가.

(e) `sample(...)`에서 `status.desiredConfiguration = engine.configuration` 바로 앞에:
```swift
        syncSleepInhibition()
        status.isSystemSleepInhibited = sleepInhibitedAt != nil
```
(즉 `latestStatus = status` 전에 두 줄이 들어간다.)

(f) `releaseForTermination()`에서 `for _ in 0..<...` 루프 끝난 뒤, `var status = engine.statusForCurrentBelief(` 앞에:
```swift
        // 방전 여부와 무관하게 종료 시에는 무조건 되돌린다. 실패해도 마커는 파일에 남아
        // 다음 시작의 `restore`가 다시 시도한다.
        releaseSleepInhibition()
```

(g) `persistPolicy`:
```swift
    private func persistPolicy(_ configuration: BatteryControlConfiguration) throws {
        var persisted = configuration
        persisted.manualDischargeActive = false
        // 클램쉘 옵트인도 저장하지 않는다. 앱이 죽은 채 데몬만 재시작하면 잠자기 차단 없이
        // 시작하는 것이 안전한 방향이다 — 앱이 살아 있으면 60초 reconcile이 다시 보낸다.
        persisted.clamshellDischargeAllowed = false
        // `calibrationActive`는 의도적으로 남긴다. 앱이 죽어도 엔진의 하한 가드가 살아 있어야
        // 최악이 "하한 도달 후 홀드"라는 설계된 안전 상태로 끝난다 (결정 #35).
        let stamp = persisted.topUpActive ? topUpReachedFullAt : nil
        try store.save(.init(
            ownerUID: ownerUID,
            configuration: persisted,
            updatedAt: now(),
            topUpReachedFullAt: stamp,
            sleepInhibitedAt: sleepInhibitedAt))
        topUpReachedFullAt = stamp
    }
```

(h) `publish(...)`에서 `status.capabilities = Self.capabilities` 바로 앞에:
```swift
        // `configure`의 persist-실패 분기(`publish(latestStatus, …)`)도 여기를 지난다. 그때
        // `syncSleepInhibition`은 이전 설정으로 판정하고 자기 persist는 `try?`라 안전하다.
        syncSleepInhibition()
        status.isSystemSleepInhibited = sleepInhibitedAt != nil
```

(i) `resolvedStoredPolicy()`:
```swift
    private func resolvedStoredPolicy() throws -> (
        configuration: BatteryControlConfiguration,
        ownershipFailure: BatteryControlStatusReason?
    ) {
        guard let stored = try store.load() else {
            topUpReachedFullAt = nil
            sleepInhibitedAt = nil
            return (.init(enabled: false), nil)
        }
        // 잠자기 차단 마커는 소유자와 무관하게 이 Mac의 것이다. 소유자 불일치로 정책을
        // 버리더라도 마커는 미러링해 `restore`가 되돌릴 수 있게 한다.
        sleepInhibitedAt = stored.sleepInhibitedAt
        guard stored.ownerUID == ownerUID else {
            topUpReachedFullAt = nil
            return (
                .init(enabled: false),
                .init(kind: .policyOwnerMismatch))
        }
        var config = stored.configuration
        config.manualDischargeActive = false
        config.clamshellDischargeAllowed = false
        // 데몬 재시작 뒤에도 12시간 시계가 이어지도록 파일의 값을 미러링한다.
        topUpReachedFullAt = config.topUpActive ? stored.topUpReachedFullAt : nil
        return (config, nil)
    }
```

(j) 새 private 함수 두 개 — `persistPolicy` 바로 위에 추가:
```swift
    /// 클램쉘 잠자기 억제의 유일한 동기화 지점. 모든 상태 갱신(`publish`·`sample`)이 지난다.
    ///
    /// 순서가 안전성이다: 켤 때는 **마커를 먼저 저장하고** 플래그를 켠다 — 그 사이에 데몬이
    /// 죽어도 재시작이 마커만 보고 되돌린다. 마커 없는 플래그는 재부팅을 넘어 남는 고아다.
    private func syncSleepInhibition() {
        let discharging = engine.isDischargingNow
        if !discharging { clamshellExpiredForCurrentDischarge = false }
        switch BatteryClamshellSleepPolicy.decide(
            allowed: engine.configuration.clamshellDischargeAllowed,
            isDischarging: discharging,
            inhibitedAt: sleepInhibitedAt,
            expiredForCurrentDischarge: clamshellExpiredForCurrentDischarge,
            now: now()
        ) {
        case .none:
            break
        case .engage:
            // 사용자가 직접 켜둔 값(또는 읽기 실패)은 소유하지 않는다.
            guard sleepInhibitor.readSleepDisabled() == false else { return }
            sleepInhibitedAt = now()
            do {
                try persistPolicy(engine.configuration)
            } catch {
                sleepInhibitedAt = nil
                return
            }
            guard sleepInhibitor.setSleepDisabled(true) else {
                sleepInhibitedAt = nil
                try? persistPolicy(engine.configuration)
                return
            }
        case .restamp(let moment):
            sleepInhibitedAt = moment
            try? persistPolicy(engine.configuration)
        case .disengage:
            releaseSleepInhibition()
        case .expire:
            clamshellExpiredForCurrentDischarge = true
            releaseSleepInhibition()
        }
    }

    /// 마커가 있을 때만 되돌린다. 쓰기가 실패하면 마커를 남겨 다음 샘플·다음 시작이 재시도한다.
    /// `persist: false`는 소유자가 다른 정책 파일을 읽은 시작 경로 전용 — 플래그는 끄되 남의
    /// 파일에 우리 설정을 쓰지 않는다.
    private func releaseSleepInhibition(persist: Bool = true) {
        guard sleepInhibitedAt != nil else { return }
        guard sleepInhibitor.setSleepDisabled(false) else { return }
        sleepInhibitedAt = nil
        if persist { try? persistPolicy(engine.configuration) }
    }
```

- [ ] **Step 5: 테스트 통과 + 전체 회귀 확인**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test 2>&1 | grep -E 'Test Suite .All tests|passed|failed|error:' | tail -5
```
Expected: 실패 0. 특히 기존 `manualDischargeSessionIsNotPersistedToStore`·Top Up 만료 테스트가 그대로 초록이어야 한다(`persistPolicy` 시그니처 변화가 미러 규칙을 깨지 않았다는 증거).

- [ ] **Step 6: Commit**

```bash
git add FanControlShared/BatteryControlEngine.swift FanControlShared/BatteryControlCoordinator.swift WattlyTests/BatteryControlCoordinatorTests.swift
git commit -m "feat(battery): daemon coordinator owns clamshell sleep inhibition with persisted marker and 12h expiry

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: 데몬 — IOPM 바인딩 억제기와 verifier 정리

**Files:**
- Create: `WattlyFanDaemon/IOPMSystemSleepInhibitor.swift`
- Modify: `WattlyFanDaemon/main.swift:3-8`, `:24-29`

**Interfaces:**
- Consumes: Task 1 `SystemSleepInhibiting`; Task 3 코디네이터 init의 `sleepInhibitor:`.
- Produces: `struct IOPMSystemSleepInhibitor: SystemSleepInhibiting`(데몬 전용, 테스트 없음 — 루트 필요).

- [ ] **Step 1: 억제기 구현**

`WattlyFanDaemon/IOPMSystemSleepInhibitor.swift`:

```swift
import Foundation
import IOKit

// IOPMLibPrivate.h의 비공개 심볼. `pmset -a disablesleep`이 내부에서 부르는 것과 같은 함수다.
// 이 Mac(macOS 26.6.2)에서 루트만으로 성공하고 1.5초 안에 `pmset -g`·`ioreg`의 `SleepDisabled`에
// 반영됨을 2026-09-07 실측했다. 비루트는 `kIOReturnNotPrivileged`(0xE00002C1)로 거부된다.
// 별도 Swift 이름을 쓰는 이유는 `MemoryProvider`의 `memorystatus_get_level`과 같다 — 미래 SDK가
// 같은 심볼을 import해도 가리지 않도록.
@_silgen_name("IOPMSetSystemPowerSetting")
private func wattly_IOPMSetSystemPowerSetting(_ key: CFString, _ value: CFTypeRef) -> IOReturn

@_silgen_name("IOPMCopySystemPowerSettings")
private func wattly_IOPMCopySystemPowerSettings() -> Unmanaged<CFDictionary>?

/// 시스템 전역 `SleepDisabled`(`pmset -g`의 "System-wide power settings")의 읽기·쓰기.
/// 재부팅을 넘어 남는 설정이므로 이 타입은 판단하지 않는다 — 언제 켜고 끌지는 전부
/// `BatteryControlCoordinator`와 `BatteryClamshellSleepPolicy`의 몫이다.
struct IOPMSystemSleepInhibitor: SystemSleepInhibiting {
    static let key = "SleepDisabled"

    func readSleepDisabled() -> Bool? {
        guard let dictionary = wattly_IOPMCopySystemPowerSettings()?.takeRetainedValue()
                as? [String: Any] else { return nil }
        // 키가 아예 없으면 macOS 기본값(꺼짐)이다 — 실측에서는 항상 0/1로 존재했다.
        guard let raw = dictionary[Self.key] else { return false }
        if let number = raw as? NSNumber { return number.boolValue }
        return nil
    }

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        let value: CFBoolean = disabled ? kCFBooleanTrue : kCFBooleanFalse
        return wattly_IOPMSetSystemPowerSetting(Self.key as CFString, value) == kIOReturnSuccess
    }
}
```

- [ ] **Step 2: main.swift 배선**

`WattlyFanDaemon/main.swift`의 verifier 분기를 다음으로 교체:

```swift
if CommandLine.arguments.contains("--verify-battery-release") {
    // 잠자기 정리를 SMC guard보다 **먼저** 한다. 둘은 아무 관계가 없는데(하나는 전원 관리
    // 설정, 하나는 AppleSMC 연결), 뒤에 두면 SMC 연결이 실패한 순간 `exit(74)`가 먼저 나가
    // 재부팅을 넘어 살아남는 `SleepDisabled`가 영원히 켜진 채 남는다 — Mac이 다시는 잠들지
    // 않는다. 하드웨어 계층이 이미 이상할 때가 이 경로를 탈 가능성이 가장 높은 때다.
    // 파일에 Wattly의 소유 마커가 있을 때만 되돌린다 — 사용자가 직접 켜둔 값은 건드리지 않는다.
    // `try?`는 옵셔널을 평탄화하므로 `load()`의 `PersistedBatteryPolicy?`가 그대로 나온다.
    // `load()`는 `.battery-control.previous`가 남아 있으면 rename으로 롤백하는 부수효과가 있다 —
    // 데몬 시작과 같은 동작이라 여기서도 문제없다.
    if (try? BatteryPolicyFileStore().load())?.sleepInhibitedAt != nil {
        // 정리 실패는 Mac이 영원히 잠들지 못하게 만드는 유일한 결과다. 종료 코드는 SMC 해제
        // 안전성을 보고하는 자리라 건드리지 않되, 실패는 이 파일의 다른 실패들처럼 남긴다.
        if !IOPMSystemSleepInhibitor().setSleepDisabled(false) {
            fputs("Unable to clear orphaned SleepDisabled\n", stderr)
        }
    }
    guard let verifierSMC = SMCControlConnection() else { exit(74) }
    let verifierHardware = SMCBatteryControlHardware(smc: verifierSMC)
    let verification = verifierHardware.releaseChargingControlAndVerify()
    exit(verification.isSafeToRemove ? 0 : 74)
}
```

코디네이터 생성에 억제기 주입:
```swift
let batteryCoordinator = BatteryControlCoordinator(
    ownerUID: uid,
    store: batteryStore,
    engine: batteryEngine,
    now: { Date().timeIntervalSince1970 },
    sleepInhibitor: IOPMSystemSleepInhibitor()
)
```

- [ ] **Step 3: xcodegen 재생성 + 데몬 빌드 확인**

Run:
```bash
/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml && xcodebuild -project Wattly.xcodeproj -scheme WattlyFanDaemon -configuration Debug -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E 'error:|BUILD' | tail -3
```
Expected: `** BUILD SUCCEEDED **`, `error:` 없음.

- [ ] **Step 4: 전체 테스트 회귀 확인**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test 2>&1 | grep -E 'passed|failed' | tail -2
```
Expected: 실패 0

- [ ] **Step 5: Commit**

```bash
git add WattlyFanDaemon/IOPMSystemSleepInhibitor.swift WattlyFanDaemon/main.swift Wattly.xcodeproj/project.pbxproj
git commit -m "feat(daemon): bind IOPMSetSystemPowerSetting for clamshell discharge and clear orphaned flag in verifier

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: 앱 설정 키 + 외장 디스플레이 판정

**Files:**
- Modify: `Wattly/Settings/Settings.swift:439-440` (Defaults), `:485-486` (StorageKey)
- Modify: `Wattly/Core/SettingsReset.swift:46`
- Create: `Wattly/Core/ExternalDisplayDetector.swift`
- Test: `WattlyTests/ExternalDisplayDetectorTests.swift`, `WattlyTests/SettingsResetTests.swift:210-216`

**Interfaces:**
- Produces: `Defaults.batteryClamshellDischargeEnabled = false`, `StorageKey.batteryClamshellDischargeEnabled = "batteryClamshellDischargeEnabled"`, `enum ExternalDisplayDetector { static func hasExternalDisplay(displayIDs: [CGDirectDisplayID], isBuiltin: (CGDirectDisplayID) -> Bool) -> Bool; @MainActor static func hasExternalDisplay(screens: [NSScreen] = NSScreen.screens) -> Bool }`

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/ExternalDisplayDetectorTests.swift`:

```swift
import AppKit
import Testing
@testable import Wattly

@Suite struct ExternalDisplayDetectorTests {
    /// 내장 화면 하나뿐이면 클램쉘 방전의 전제가 없다.
    @Test func builtinOnlyIsNotExternal() {
        #expect(ExternalDisplayDetector.hasExternalDisplay(
            displayIDs: [1], isBuiltin: { _ in true }) == false)
    }

    @Test func anyNonBuiltinDisplayCounts() {
        #expect(ExternalDisplayDetector.hasExternalDisplay(
            displayIDs: [1, 2], isBuiltin: { $0 == 1 }) == true)
    }

    /// 뚜껑을 닫으면 내장 화면이 목록에서 빠지고 외장만 남는다 — 그때도 참이어야 한다.
    @Test func lidClosedLeavesOnlyTheExternalDisplay() {
        #expect(ExternalDisplayDetector.hasExternalDisplay(
            displayIDs: [2], isBuiltin: { $0 == 1 }) == true)
    }

    /// 뚜껑을 닫은 채 외장 모니터까지 뽑으면 화면이 하나도 없다 — 거짓이어야 데몬이 잠자기를
    /// 되돌린다.
    @Test func noDisplaysIsNotExternal() {
        #expect(ExternalDisplayDetector.hasExternalDisplay(
            displayIDs: [], isBuiltin: { _ in false }) == false)
    }

    @Test func clamshellPreferenceDefaultsOffWithAStableKey() {
        #expect(Defaults.batteryClamshellDischargeEnabled == false)
        #expect(StorageKey.batteryClamshellDischargeEnabled == "batteryClamshellDischargeEnabled")
    }
}
```

`WattlyTests/SettingsResetTests.swift` — 210행 `d.set(false, forKey: StorageKey.batteryAutoDischargeEnabled)` 아래에:
```swift
        d.set(true, forKey: StorageKey.batteryClamshellDischargeEnabled)
```
215행 `#expect(d.bool(forKey: StorageKey.batteryAutoDischargeEnabled) == ...)` 아래에:
```swift
        #expect(d.bool(forKey: StorageKey.batteryClamshellDischargeEnabled) == Defaults.batteryClamshellDischargeEnabled)
```

- [ ] **Step 2: 파일 생성 후 xcodegen 재생성, 실패 확인**

Run:
```bash
/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml && xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/ExternalDisplayDetectorTests 2>&1 | grep -E 'error:' | head -3
```
Expected: `error: cannot find 'ExternalDisplayDetector' in scope`

- [ ] **Step 3: 구현**

`Wattly/Settings/Settings.swift` — `Defaults`의 `static let batteryManualDischargeTarget = 80` 아래:
```swift
    /// 옵트인 전용. 켜면 강제 방전 중에 데몬이 시스템 잠자기를 억제한다(재부팅을 넘어 남는
    /// 시스템 설정을 만지므로 기본은 반드시 꺼짐).
    static let batteryClamshellDischargeEnabled = false
```
`StorageKey`의 `static let batteryManualDischargeTarget = "batteryManualDischargeTarget"` 아래:
```swift
    static let batteryClamshellDischargeEnabled = "batteryClamshellDischargeEnabled"
```

`Wattly/Core/SettingsReset.swift` — 46행 `defaults.set(Defaults.batteryAutoDischargeEnabled, ...)` 아래:
```swift
        defaults.set(Defaults.batteryClamshellDischargeEnabled, forKey: StorageKey.batteryClamshellDischargeEnabled)
```

`Wattly/Core/ExternalDisplayDetector.swift`:
```swift
import AppKit
import CoreGraphics

/// 외장 디스플레이가 하나라도 켜져 있는지.
///
/// 클램쉘 방전의 두 번째 전제다(첫째는 사용자 옵트인). 외장 화면 없이 뚜껑을 닫은 Mac이
/// 깨어 있는 것은 사용자가 원한 것이 아니므로, 앱은 이 값이 거짓이면 데몬에
/// `clamshellDischargeAllowed=false`를 보낸다. 루트 데몬은 WindowServer 없이 CG를 부를 수
/// 없어 이 판정은 앱만 한다.
///
/// 뚜껑을 닫으면 내장 화면은 `NSScreen.screens`에서 빠지고 외장만 남는다 — 그래서 "내장이
/// 아닌 화면이 하나라도 있는가"이지 "화면이 둘 이상인가"가 아니다.
enum ExternalDisplayDetector {
    /// 순수 코어. `isBuiltin`은 `CGDisplayIsBuiltin`을 주입받는다.
    static func hasExternalDisplay(
        displayIDs: [CGDirectDisplayID],
        isBuiltin: (CGDirectDisplayID) -> Bool
    ) -> Bool {
        displayIDs.contains { !isBuiltin($0) }
    }

    @MainActor
    static func hasExternalDisplay(screens: [NSScreen] = NSScreen.screens) -> Bool {
        let ids = screens.compactMap { screen -> CGDirectDisplayID? in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        return hasExternalDisplay(displayIDs: ids, isBuiltin: { CGDisplayIsBuiltin($0) != 0 })
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/ExternalDisplayDetectorTests -only-testing:WattlyTests/SettingsResetTests 2>&1 | grep -E 'passed|failed' | tail -3
```
Expected: 두 스위트 모두 passed

- [ ] **Step 5: Commit**

```bash
git add Wattly/Settings/Settings.swift Wattly/Core/SettingsReset.swift Wattly/Core/ExternalDisplayDetector.swift WattlyTests/ExternalDisplayDetectorTests.swift WattlyTests/SettingsResetTests.swift Wattly.xcodeproj/project.pbxproj
git commit -m "feat(battery): clamshell discharge preference and external display detection

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: 클라이언트 — 데몬으로 나가는 길목에서 허용값 계산

**Files:**
- Modify: `Wattly/Control/BatteryControlClient.swift:33-60` (init), `:126-160` (`revivedConfiguration`), `:352-395` (`reconcile`의 `targetConfig`)
- Test: `WattlyTests/BatteryControlClientTests.swift`

**Interfaces:**
- Consumes: Task 5 `ExternalDisplayDetector`, `StorageKey.batteryClamshellDischargeEnabled`; Task 2 `clamshellDischargeAllowed`.
- Produces: `BatteryControlClient.init(requestHandler:clamshellAllowance:)`(둘 다 기본값), `typealias ClamshellAllowance = @MainActor () -> Bool`, `static let defaultClamshellAllowance`.

- [ ] **Step 1: 실패하는 테스트 작성**

먼저 기존 테스트를 밀폐한다: `WattlyTests/BatteryControlClientTests.swift` 154행 부근의 `sent.configuration == requested`를 단언하는 테스트는 `clamshellAllowance`를 주입하지 않은 클라이언트를 쓴다. 기본 출처는 실제 `UserDefaults.standard`(테스트 호스트 = Wattly.app의 도메인)와 `NSScreen`이라, 사용자가 토글을 켠 채 외장 모니터에 도킹된 Mac에서 스위트를 돌리면 그 테스트가 빨개진다. 그 테스트의 `BatteryControlClient(requestHandler: ...)` 호출에 `clamshellAllowance: { false }`를 추가한다(아래 새 생성자 시그니처 참조).

그 다음 파일 끝(마지막 `}` 앞)에 추가:

```swift
    // MARK: - 클램쉘 방전 허용값

    /// 어떤 호출부도 이 값을 인자로 넘기지 않는다. 길목(`revivedConfiguration`)이 계산해 실어
    /// 보내므로 Shortcuts·스케줄·설정 12곳이 기본값 false로 클램쉘 Mac을 재우는 일이 없다.
    @MainActor @Test func applyCarriesTheClamshellAllowanceFromTheInjectedSource() async throws {
        let receiver = RequestReceiver()
        let client = BatteryControlClient(
            requestHandler: { request in
                await receiver.set(request)
                let status = BatteryControlServiceStatus(
                    mode: .charging, currentPercentage: 80, isPowerAdapterConnected: true,
                    detail: "OK", updatedAt: 1)
                return (try? BatteryControlCodec.encode(status), nil)
            },
            clamshellAllowance: { true })

        await client.apply(enabled: true, limitPercentage: 85)

        guard case .configure(let data) = await receiver.request else {
            Issue.record("Expected configure request"); return
        }
        let req = try BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
        #expect(req.configuration.clamshellDischargeAllowed == true)
    }

    @MainActor @Test func applyOmitsTheClamshellAllowanceWhenTheSourceSaysNo() async throws {
        let receiver = RequestReceiver()
        let client = BatteryControlClient(
            requestHandler: { request in
                await receiver.set(request)
                let status = BatteryControlServiceStatus(
                    mode: .charging, currentPercentage: 80, isPowerAdapterConnected: true,
                    detail: "OK", updatedAt: 1)
                return (try? BatteryControlCodec.encode(status), nil)
            },
            clamshellAllowance: { false })

        // `startManualDischarge`는 알림 권한을 요청하므로 테스트에서는 같은 길목을 지나는 `apply`를 쓴다.
        await client.apply(
            enabled: true, limitPercentage: 80,
            manualDischargeActive: true, manualDischargeTarget: 70)

        guard case .configure(let data) = await receiver.request else {
            Issue.record("Expected configure request"); return
        }
        let req = try BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
        #expect(req.configuration.manualDischargeActive == true)
        #expect(req.configuration.clamshellDischargeAllowed == false)
    }

    /// reconcile의 비교 대상(`targetConfig`)도 같은 값을 들어야 한다. 아니면 데몬이 true를 들고
    /// 있는 동안 매분 "다르다"고 판정해 재적용(파일 쓰기 + SMC 판독)이 60초마다 난다.
    @MainActor @Test func reconcileDoesNotReapplyWhenOnlyTheClamshellAllowanceWouldDiffer() async throws {
        final class Counter: @unchecked Sendable { var configures = 0 }
        let counter = Counter()
        let daemon = BatteryControlConfiguration(
            enabled: true, limitPercentage: 85, lowerHysteresisDelta: 2,
            clamshellDischargeAllowed: true)
        let status = BatteryControlServiceStatus(
            mode: .inhibited, currentPercentage: 90, isPowerAdapterConnected: true,
            detail: "OK", updatedAt: 1,
            desiredConfiguration: daemon,
            capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1])
        let client = BatteryControlClient(
            requestHandler: { request in
                if case .configure = request { counter.configures += 1 }
                return (try? BatteryControlCodec.encode(status), nil)
            },
            clamshellAllowance: { true })

        await client.reconcile(enabled: true, limitPercentage: 85)

        #expect(counter.configures == 0)
    }
```

- [ ] **Step 2: 실패 확인**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/BatteryControlClientTests 2>&1 | grep -E 'error:' | head -3
```
Expected: `error: extra argument 'clamshellAllowance' in call`

- [ ] **Step 3: 클라이언트 수정**

`Wattly/Control/BatteryControlClient.swift`:

(a) `typealias RequestHandler` 아래에:
```swift
    /// 클램쉘 방전 허용값의 출처 — "사용자 옵트인 && 외장 디스플레이 존재". 주입받는 이유는
    /// 테스트다. 기본값은 실제 `UserDefaults`와 `NSScreen`을 읽는다.
    public typealias ClamshellAllowance = @MainActor () -> Bool
    public static let defaultClamshellAllowance: ClamshellAllowance = {
        UserDefaults.standard.bool(forKey: StorageKey.batteryClamshellDischargeEnabled)
            && ExternalDisplayDetector.hasExternalDisplay()
    }
```

(b) 프로퍼티(`private let installHandler: InstallHandler` 아래):
```swift
    private let clamshellAllowance: ClamshellAllowance
```

(c) 생성자:
```swift
    public convenience init(
        requestHandler: RequestHandler? = nil,
        clamshellAllowance: @escaping ClamshellAllowance = BatteryControlClient.defaultClamshellAllowance
    ) {
        self.init(requestHandler: requestHandler, installHandler: nil, clamshellAllowance: clamshellAllowance)
    }

    init(
        requestHandler: RequestHandler?,
        installHandler: InstallHandler?,
        clamshellAllowance: @escaping ClamshellAllowance = BatteryControlClient.defaultClamshellAllowance
    ) {
        self.clamshellAllowance = clamshellAllowance
```
(기존 `self.requestHandler = ...`, `self.installHandler = ...` 본문은 그대로 이어진다.)

(d) `revivedConfiguration`에서 `return config.normalized` 바로 앞에:
```swift
        // 클램쉘 허용값은 호출자가 아니라 여기서 정한다. 이 함수가 데몬으로 나가는 유일한
        // 길목이라, 여기서 정해야 Shortcuts·스케줄·캘리브레이션·도우미 업데이트 재적용 등
        // 호출부 12곳이 기본값 false를 실어 보내 클램쉘 Mac을 재우는 일이 없다.
        config.clamshellDischargeAllowed = clamshellAllowance()
```

(e) `reconcile(...)`의 `let targetConfig = BatteryControlConfiguration(` 호출에 마지막 인자 추가:
```swift
            calibrationActive: isCalibrating,
            calibrationTargetPercentage: calibrationTarget,
            clamshellDischargeAllowed: clamshellAllowance()
        )
```

- [ ] **Step 4: 테스트 통과 + 전체 회귀 확인**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test 2>&1 | grep -E 'passed|failed|error:' | tail -3
```
Expected: 실패 0

- [ ] **Step 5: Commit**

```bash
git add Wattly/Control/BatteryControlClient.swift WattlyTests/BatteryControlClientTests.swift
git commit -m "feat(battery): compute clamshell allowance at the daemon chokepoint

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: 브리지 — 옵트인·디스플레이 변화를 즉시 데몬에 전달

**Files:**
- Modify: `Wattly/Views/BatteryControlBridge.swift` (`@AppStorage` 블록, `makeConfiguration`, `reconcileTaskID`, `configuration`, `.onChange` 핸들러 7곳, `.task(id:)`, 새 `.onChange`/`.onReceive` 2곳)
- Test: `WattlyTests/BatteryControlBridgeTests.swift`

**Interfaces:**
- Consumes: Task 5 `ExternalDisplayDetector`, `StorageKey.batteryClamshellDischargeEnabled`.
- Produces: `BatteryControlBridge.makeConfiguration(..., manualDischargeTarget:, clamshellDischargeAllowed:)`, `reconcileTaskID(..., manualDischargeTarget:, clamshellDischargeAllowed:)` — 둘 다 **필수** 인자(기본값 없음. 기본값을 주면 "저장값이 빠지지 않았다"를 증명하는 테스트가 무력해진다).

- [ ] **Step 1: 기존 테스트의 호출부 갱신 + 새 테스트 작성**

`WattlyTests/BatteryControlBridgeTests.swift`에서 `BatteryControlBridge.makeConfiguration(`와 `BatteryControlBridge.reconcileTaskID(`를 부르는 **모든** 호출에 마지막 인자 `clamshellDischargeAllowed: false`를 추가한다(예: `manualDischargeTarget: 80)` → `manualDischargeTarget: 80, clamshellDischargeAllowed: false)`). 그런 다음 `reconcileTaskIDChangesWithEveryStoredPreference` 테스트의 독스트링에 있는 "eight inputs"를 "nine inputs"로 고치고, 마지막 `#expect` 뒤에 추가:

```swift
        #expect(BatteryControlBridge.reconcileTaskID(
            enabled: true, limitPercentage: 85, sailingEnabled: true, sailingDelta: 5,
            heatProtectionEnabled: true, heatProtectionThresholdCelsius: 38,
            autoDischargeEnabled: true, manualDischargeTarget: 70,
            clamshellDischargeAllowed: true) != baseline)
```

같은 파일 `struct BatteryControlBridgeTests {` 안 끝에 추가:

```swift
    // MARK: - 클램쉘 방전

    @Test func makeConfigurationForwardsTheClamshellAllowance() {
        let config = BatteryControlBridge.makeConfiguration(
            enabled: true, limitPercentage: 80,
            sailingEnabled: false, sailingDelta: 5,
            heatProtectionEnabled: false, heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: false, manualDischargeTarget: 80,
            clamshellDischargeAllowed: true)
        #expect(config.clamshellDischargeAllowed == true)
    }

    /// 데몬이 true를 들고 있고 브리지도 true를 만들면 재적용이 없다. 브리지가 이 값을 빠뜨리면
    /// 매분 재적용이 나서 파일 쓰기와 SMC 판독이 60초마다 반복된다.
    @Test func clamshellAllowanceMismatchIsWhatWouldTriggerAReapply() {
        let daemonConfig = BatteryControlConfiguration(
            enabled: true, limitPercentage: 85, lowerHysteresisDelta: 2,
            clamshellDischargeAllowed: true)
        let status = BatteryControlServiceStatus(
            mode: .inhibited, currentPercentage: 100, isPowerAdapterConnected: true,
            detail: "충전 제한 85% 도달", updatedAt: 100.0,
            desiredConfiguration: daemonConfig,
            capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1])

        let unwired = BatteryControlBridge.makeConfiguration(
            enabled: true, limitPercentage: 85,
            sailingEnabled: false, sailingDelta: 5,
            heatProtectionEnabled: false, heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: false, manualDischargeTarget: 80,
            clamshellDischargeAllowed: false)
        #expect(BatteryControlPolicy.shouldReapply(configuration: unwired, status: status) == true)

        let wired = BatteryControlBridge.makeConfiguration(
            enabled: true, limitPercentage: 85,
            sailingEnabled: false, sailingDelta: 5,
            heatProtectionEnabled: false, heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: false, manualDischargeTarget: 80,
            clamshellDischargeAllowed: true)
        #expect(BatteryControlPolicy.shouldReapply(configuration: wired, status: status) == false)
    }

    /// 활동 보존은 허용값을 덮어쓰지 않는다 — 허용값은 데몬 활동이 아니라 앱이 계산한 사실이다.
    @Test func preservingActivityKeepsTheRequestedClamshellAllowance() {
        let requested = BatteryControlConfiguration(
            enabled: true, limitPercentage: 80, clamshellDischargeAllowed: true)
        let daemon = BatteryControlConfiguration(
            enabled: true, limitPercentage: 80,
            manualDischargeActive: true, manualDischargeTarget: 70,
            clamshellDischargeAllowed: false)
        let merged = BatteryControlBridge.preservingActivity(requested, daemon: daemon)
        #expect(merged.manualDischargeActive == true)
        #expect(merged.clamshellDischargeAllowed == true)
    }
```

- [ ] **Step 2: 실패 확인**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/BatteryControlBridgeTests 2>&1 | grep -E 'error:' | head -3
```
Expected: `error: extra argument 'clamshellDischargeAllowed' in call`

- [ ] **Step 3: 브리지 수정**

`Wattly/Views/BatteryControlBridge.swift`:

(a) `@AppStorage` 블록 끝(`manualDischargeTarget` 줄 아래)에:
```swift
    @AppStorage(StorageKey.batteryClamshellDischargeEnabled) private var clamshellDischargeEnabled = Defaults.batteryClamshellDischargeEnabled
    /// 외장 디스플레이 존재 여부의 마지막 관측값. `handleInitialTask`가 첫 값을 읽고, 그 뒤로는
    /// 화면 구성 변경 알림에서만 갱신한다. 프로퍼티 초기값에서 읽지 않는 이유: `NSScreen`은
    /// `@MainActor`이고 SwiftUI View의 저장 프로퍼티 초기화는 nonisolated라 Swift 6가 거부한다.
    @State private var hasExternalDisplay = false
```

`handleInitialTask()`의 첫 줄(`syncMonitorTarget()` 앞)에:
```swift
        hasExternalDisplay = ExternalDisplayDetector.hasExternalDisplay()
```

(b) `makeConfiguration` 시그니처와 본문:
```swift
    static func makeConfiguration(
        enabled: Bool,
        limitPercentage: Int,
        sailingEnabled: Bool,
        sailingDelta: Int,
        heatProtectionEnabled: Bool,
        heatProtectionThresholdCelsius: Int,
        autoDischargeEnabled: Bool,
        manualDischargeTarget: Int,
        clamshellDischargeAllowed: Bool
    ) -> BatteryControlConfiguration {
        BatteryControlConfiguration(
            enabled: enabled,
            limitPercentage: limitPercentage,
            lowerHysteresisDelta: effectiveDelta(
                sailingEnabled: sailingEnabled, sailingDelta: sailingDelta),
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThresholdCelsius,
            autoDischargeEnabled: autoDischargeEnabled,
            manualDischargeTarget: BatterySectionPresentation
                .clampedManualDischargeTarget(manualDischargeTarget),
            clamshellDischargeAllowed: clamshellDischargeAllowed)
    }
```

(c) `reconcileTaskID`:
```swift
    static func reconcileTaskID(
        enabled: Bool,
        limitPercentage: Int,
        sailingEnabled: Bool,
        sailingDelta: Int,
        heatProtectionEnabled: Bool,
        heatProtectionThresholdCelsius: Int,
        autoDischargeEnabled: Bool,
        manualDischargeTarget: Int,
        clamshellDischargeAllowed: Bool
    ) -> String {
        "\(enabled)-\(limitPercentage)-\(sailingEnabled)-\(sailingDelta)-\(heatProtectionEnabled)-\(heatProtectionThresholdCelsius)-\(autoDischargeEnabled)-\(manualDischargeTarget)-\(clamshellDischargeAllowed)"
    }
```

(d) `private var configuration`에 인자 추가:
```swift
    /// 브리지가 데몬에 보내는 허용값. 클라이언트의 길목이 같은 출처로 다시 계산하지만, 여기서도
    /// 넣어야 `shouldReapply`의 비교 대상이 데몬 값과 일치해 매분 재적용이 나지 않는다.
    private var clamshellDischargeAllowed: Bool {
        clamshellDischargeEnabled && hasExternalDisplay
    }

    private var configuration: BatteryControlConfiguration {
        Self.makeConfiguration(
            enabled: enabled,
            limitPercentage: limit,
            sailingEnabled: sailingEnabled,
            sailingDelta: sailingDelta,
            heatProtectionEnabled: heatProtectionEnabled,
            heatProtectionThresholdCelsius: heatProtectionThreshold,
            autoDischargeEnabled: autoDischargeEnabled,
            manualDischargeTarget: manualDischargeTarget,
            clamshellDischargeAllowed: clamshellDischargeAllowed)
    }
```

(e) 기존 `.onChange` 핸들러 7곳(`enabled`, `limit`, `sailingEnabled`, `sailingDelta`, `heatProtectionEnabled`, `heatProtectionThreshold`, `autoDischargeEnabled`)의 `Self.makeConfiguration(` 호출 각각에서 `manualDischargeTarget: manualDischargeTarget)` 를 다음으로 바꾼다:
```swift
                    manualDischargeTarget: manualDischargeTarget,
                    clamshellDischargeAllowed: clamshellDischargeAllowed)
```

(f) `.task(id: Self.reconcileTaskID(` 호출의 `manualDischargeTarget: manualDischargeTarget))` 를:
```swift
                manualDischargeTarget: manualDischargeTarget,
                clamshellDischargeAllowed: clamshellDischargeAllowed)) {
```

(g) `.onChange(of: autoDischargeEnabled) { ... }` 블록 바로 뒤에 두 핸들러 추가:
```swift
            // 클램쉘 옵트인은 `applyRequested`로 **직접** 간다 — `handleConfigChange`→`push`는
            // `enabled`와 열 보호가 둘 다 꺼져 있으면 `disableRequested`로 빠지는데, 수동 방전은
            // 충전 한도가 꺼진 채로도 돌 수 있어 그 경로가 `manualDischargeActive=false`를 실어
            // 방전 자체를 취소한다. `applyRequested`는 `preservingActivity`로 진행 중 활동을
            // 되살리므로 방전은 그대로 두고 잠자기 차단만 바뀐다(자동 방전 토글과 같은 선례).
            .onChange(of: clamshellDischargeEnabled) { _, isAllowed in
                let requested = Self.makeConfiguration(
                    enabled: enabled,
                    limitPercentage: limit,
                    sailingEnabled: sailingEnabled,
                    sailingDelta: sailingDelta,
                    heatProtectionEnabled: heatProtectionEnabled,
                    heatProtectionThresholdCelsius: heatProtectionThreshold,
                    autoDischargeEnabled: autoDischargeEnabled,
                    manualDischargeTarget: manualDischargeTarget,
                    clamshellDischargeAllowed: isAllowed && hasExternalDisplay)
                Task {
                    await applyRequested(requested, reason: "clamshell-discharge-toggle")
                }
            }
            // 뚜껑을 닫은 채 외장 모니터를 뽑으면 화면이 하나도 남지 않는다. 그 순간 false를
            // 내려보내야 데몬이 잠자기 차단을 풀고 Mac이 정상적으로 잠든다. 60초 reconcile을
            // 기다리지 않는다. 위와 같은 이유로 `applyRequested`를 직접 부른다.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                let detected = ExternalDisplayDetector.hasExternalDisplay()
                guard detected != hasExternalDisplay else { return }
                hasExternalDisplay = detected
                guard clamshellDischargeEnabled else { return }
                let requested = Self.makeConfiguration(
                    enabled: enabled,
                    limitPercentage: limit,
                    sailingEnabled: sailingEnabled,
                    sailingDelta: sailingDelta,
                    heatProtectionEnabled: heatProtectionEnabled,
                    heatProtectionThresholdCelsius: heatProtectionThreshold,
                    autoDischargeEnabled: autoDischargeEnabled,
                    manualDischargeTarget: manualDischargeTarget,
                    clamshellDischargeAllowed: detected)
                Task {
                    await applyRequested(requested, reason: "display-change")
                }
            }
```

(h) `applyRequested`의 `client.apply(` 호출 마지막에 인자를 넘기지 **않는다** — `apply`는 이 인자를 받지 않고 길목이 계산한다(Task 6). 수정 없음. 위 두 핸들러가 `push`/`handleConfigChange`를 쓰지 않는지 커밋 전에 다시 확인한다 — SwiftUI 핸들러라 단위 테스트가 닿지 않으므로 Task 10의 실기 매트릭스 10번이 이 경로를 잡는다.

(i) `handleInitialTask()`가 `hasExternalDisplay`를 세우면 `reconcileTaskID`가 바뀌어 reconcile 루프가 앱 시작 직후 한 번 재시작한다. 무해하며 로그에 "reconcile loop cancelled/started" 한 쌍이 더 찍힐 뿐이다 — 고치려 하지 않는다.

- [ ] **Step 4: 테스트 통과 + 전체 회귀 확인**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test 2>&1 | grep -E 'passed|failed|error:' | tail -3
```
Expected: 실패 0. `error: missing argument for parameter 'clamshellDischargeAllowed'`가 남아 있으면 (e)·(f)에서 빠진 호출부가 있다는 뜻이다.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Views/BatteryControlBridge.swift WattlyTests/BatteryControlBridgeTests.swift
git commit -m "feat(battery): bridge forwards clamshell opt-in and external display changes to the daemon

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: 프레젠테이션 게이팅·문구 + 30개 로케일 번역

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift` (파일 끝, `autoDischargeToggleDisabledReason` 아래)
- Create: `scripts/i18n_additions/battery_clamshell_discharge.json`
- Modify(스크립트): `Wattly/Resources/Localizable.xcstrings`
- Test: `WattlyTests/BatterySectionPresentationTests.swift`

**Interfaces:**
- Produces: `BatterySectionPresentation.isClamshellDischargeToggleEnabled(helperMode:capabilities:isDischargeHardwareSupported:) -> Bool`, `clamshellDischargeToggleDisabledReason(helperMode:capabilities:isDischargeHardwareSupported:locale:) -> String?`, `sleepInhibitedText(locale:) -> String`, `calibrationLidGuidanceText(clamshellAllowed:locale:) -> String`

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/BatterySectionPresentationTests.swift` 끝(마지막 `}` 앞)에 추가:

```swift
    // MARK: - 클램쉘 방전 토글

    private static let current: [BatteryControlCapability] = [
        .persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1,
        .calibrationV1, .clamshellDischargeV1,
    ]

    @Test func clamshellToggleIsEnabledOnlyWithACurrentHelperAndDischargeHardware() {
        #expect(BatterySectionPresentation.isClamshellDischargeToggleEnabled(
            helperMode: .charging, capabilities: Self.current, isDischargeHardwareSupported: true))
        // `nil`은 "모름"이지 "미지원"이 아니다.
        #expect(BatterySectionPresentation.isClamshellDischargeToggleEnabled(
            helperMode: .charging, capabilities: Self.current, isDischargeHardwareSupported: nil))
        #expect(BatterySectionPresentation.isClamshellDischargeToggleEnabled(
            helperMode: .unavailable, capabilities: Self.current, isDischargeHardwareSupported: true) == false)
        #expect(BatterySectionPresentation.isClamshellDischargeToggleEnabled(
            helperMode: .charging, capabilities: [.persistedPolicyV1, .calibrationV1],
            isDischargeHardwareSupported: true) == false)
        #expect(BatterySectionPresentation.isClamshellDischargeToggleEnabled(
            helperMode: .charging, capabilities: Self.current, isDischargeHardwareSupported: false) == false)
    }

    @Test func clamshellToggleDisabledReasonNamesTheBlocker() {
        let ko = Locale(identifier: "ko")
        #expect(BatterySectionPresentation.clamshellDischargeToggleDisabledReason(
            helperMode: .charging, capabilities: Self.current,
            isDischargeHardwareSupported: true, locale: ko) == nil)
        #expect(BatterySectionPresentation.clamshellDischargeToggleDisabledReason(
            helperMode: .unavailable, capabilities: Self.current,
            isDischargeHardwareSupported: true, locale: ko) == "도우미에 연결되지 않음")
        #expect(BatterySectionPresentation.clamshellDischargeToggleDisabledReason(
            helperMode: .charging, capabilities: [.persistedPolicyV1],
            isDischargeHardwareSupported: true, locale: ko)
            == "클램쉘 방전을 사용하려면 도우미 업데이트가 필요합니다.")
        #expect(BatterySectionPresentation.clamshellDischargeToggleDisabledReason(
            helperMode: .charging, capabilities: Self.current,
            isDischargeHardwareSupported: false, locale: ko)
            == "이 Mac은 강제 방전을 지원하지 않습니다.")
    }

    @Test func sleepInhibitedTextUsesTheCatalogKey() {
        #expect(BatterySectionPresentation.sleepInhibitedText(locale: Locale(identifier: "ko"))
            == "잠자기 차단 중 (덮개를 닫아도 방전이 계속됩니다)")
    }

    @Test func calibrationLidGuidanceFollowsTheClamshellAllowance() {
        let ko = Locale(identifier: "ko")
        #expect(BatterySectionPresentation.calibrationLidGuidanceText(clamshellAllowed: false, locale: ko)
            == "방전 구간에는 뚜껑을 열고 Mac을 사용 중인 상태로 두어야 합니다.")
        #expect(BatterySectionPresentation.calibrationLidGuidanceText(clamshellAllowed: true, locale: ko)
            == "클램쉘 방전이 켜져 있어 외장 디스플레이가 연결된 동안은 뚜껑을 닫아도 됩니다.")
    }
```

- [ ] **Step 2: 실패 확인**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/BatterySectionPresentationTests 2>&1 | grep -E 'error:' | head -3
```
Expected: `error: type 'BatterySectionPresentation' has no member 'isClamshellDischargeToggleEnabled'`

- [ ] **Step 3: 프레젠테이션 함수 추가**

`Wattly/Core/BatterySectionPresentation.swift` — `autoDischargeToggleDisabledReason` 함수 뒤, enum의 닫는 `}` 앞에:

```swift
    // MARK: - 클램쉘 방전

    /// "덮개를 닫아도 방전 계속" 토글을 만질 수 있는지. 전역 `requiredCapabilities`에
    /// `.clamshellDischargeV1`을 넣지 않는 대신 여기서만 게이팅한다 — 넣으면 이 기능을 쓰지 않는
    /// 전 사용자가 "도우미 업데이트 필요"가 된다.
    static func isClamshellDischargeToggleEnabled(
        helperMode: BatteryControlServiceMode,
        capabilities: [BatteryControlCapability]?,
        isDischargeHardwareSupported: Bool?
    ) -> Bool {
        clamshellDischargeToggleDisabledReason(
            helperMode: helperMode,
            capabilities: capabilities,
            isDischargeHardwareSupported: isDischargeHardwareSupported) == nil
    }

    /// 위 게이트가 거짓일 때의 사유. 활성일 때는 `nil`. `nil` 하드웨어 지원은 "모름"이라 막지 않는다.
    static func clamshellDischargeToggleDisabledReason(
        helperMode: BatteryControlServiceMode,
        capabilities: [BatteryControlCapability]?,
        isDischargeHardwareSupported: Bool?,
        locale: Locale = Locale(identifier: "ko")
    ) -> String? {
        if helperMode == .unavailable {
            return String(localized: "도우미에 연결되지 않음", locale: locale)
        }
        if capabilities?.contains(.clamshellDischargeV1) != true {
            return String(localized: "클램쉘 방전을 사용하려면 도우미 업데이트가 필요합니다.", locale: locale)
        }
        if isDischargeHardwareSupported == false {
            return String(localized: "이 Mac은 강제 방전을 지원하지 않습니다.", locale: locale)
        }
        return nil
    }

    /// 데몬이 `isSystemSleepInhibited == true`를 보고할 때 방전 배너에 붙는 줄.
    static func sleepInhibitedText(locale: Locale = Locale(identifier: "ko")) -> String {
        String(localized: "잠자기 차단 중 (덮개를 닫아도 방전이 계속됩니다)", locale: locale)
    }

    /// 캘리브레이션 preflight의 뚜껑 안내. 클램쉘 방전이 실제로 적용될 상태(옵트인 && 외장
    /// 디스플레이)면 "닫아도 된다"로 바뀐다(결정 #22).
    static func calibrationLidGuidanceText(
        clamshellAllowed: Bool,
        locale: Locale = Locale(identifier: "ko")
    ) -> String {
        clamshellAllowed
            ? String(localized: "클램쉘 방전이 켜져 있어 외장 디스플레이가 연결된 동안은 뚜껑을 닫아도 됩니다.", locale: locale)
            : String(localized: "방전 구간에는 뚜껑을 열고 Mac을 사용 중인 상태로 두어야 합니다.", locale: locale)
    }
```

- [ ] **Step 4: 번역 파일 작성 후 카탈로그에 병합**

`scripts/i18n_additions/battery_clamshell_discharge.json` (키 5개 — "도우미에 연결되지 않음"·"이 Mac은 강제 방전을 지원하지 않습니다."·"방전 구간에는 뚜껑을 열고 Mac을 사용 중인 상태로 두어야 합니다."는 이미 카탈로그에 있으므로 제외):

```json
{
  "덮개를 닫아도 방전 계속": {
    "ko": "덮개를 닫아도 방전 계속", "en": "Keep discharging with the lid closed", "ja": "ふたを閉じても放電を続ける", "zh-Hans": "合盖后继续放电", "zh-Hant": "闔上上蓋後繼續放電", "de": "Entladen bei geschlossenem Deckel fortsetzen", "fr": "Continuer la décharge capot fermé", "es": "Seguir descargando con la tapa cerrada", "it": "Continua a scaricare con il coperchio chiuso", "pt-BR": "Continuar descarregando com a tampa fechada", "pt-PT": "Continuar a descarregar com a tampa fechada", "ru": "Продолжать разряд с закрытой крышкой", "nl": "Blijven ontladen met gesloten deksel", "pl": "Kontynuuj rozładowywanie przy zamkniętej pokrywie", "tr": "Kapak kapalıyken deşarja devam et", "sv": "Fortsätt urladdning med stängt lock", "da": "Fortsæt afladning med lukket låg", "nb": "Fortsett utlading med lukket lokk", "fi": "Jatka purkamista kansi suljettuna", "cs": "Pokračovat ve vybíjení se zavřeným víkem", "hu": "Kisütés folytatása lecsukott fedéllel", "ro": "Continuă descărcarea cu capacul închis", "el": "Συνέχιση εκφόρτισης με κλειστό καπάκι", "uk": "Продовжувати розряд із закритою кришкою", "he": "המשך פריקה כשהמכסה סגור", "ar": "متابعة التفريغ والغطاء مغلق", "hi": "ढक्कन बंद होने पर भी डिस्चार्ज जारी रखें", "th": "ปล่อยประจุต่อแม้ปิดฝา", "vi": "Tiếp tục xả khi đóng nắp", "id": "Lanjutkan pengosongan saat penutup ditutup"
  },
  "외장 디스플레이가 연결된 동안 방전 중에는 Mac이 잠들지 않습니다. Apple 메뉴의 잠자기도 동작하지 않습니다.": {
    "ko": "외장 디스플레이가 연결된 동안 방전 중에는 Mac이 잠들지 않습니다. Apple 메뉴의 잠자기도 동작하지 않습니다.", "en": "While an external display is connected, the Mac will not sleep during discharge. Sleep in the Apple menu is also disabled.", "ja": "外部ディスプレイ接続中は放電中にMacがスリープしません。Appleメニューのスリープも無効になります。", "zh-Hans": "连接外接显示器时，放电期间 Mac 不会睡眠。Apple 菜单中的“睡眠”也将不可用。", "zh-Hant": "連接外接顯示器時，放電期間 Mac 不會睡眠。Apple 選單中的「睡眠」也會失效。", "de": "Solange ein externes Display angeschlossen ist, geht der Mac während des Entladens nicht in den Ruhezustand. Auch „Ruhezustand“ im Apple-Menü ist deaktiviert.", "fr": "Tant qu’un écran externe est connecté, le Mac ne se met pas en veille pendant la décharge. La commande Suspendre du menu Pomme est aussi désactivée.", "es": "Mientras haya una pantalla externa conectada, el Mac no entrará en reposo durante la descarga. El reposo del menú Apple también queda desactivado.", "it": "Finché è collegato un monitor esterno, il Mac non entra in stop durante la scarica. Anche Stop nel menu Apple è disattivato.", "pt-BR": "Enquanto um monitor externo estiver conectado, o Mac não entrará em repouso durante a descarga. O repouso do menu Apple também fica desativado.", "pt-PT": "Enquanto um monitor externo estiver ligado, o Mac não entra em pausa durante a descarga. A pausa do menu Apple também fica desativada.", "ru": "Пока подключён внешний дисплей, Mac не будет засыпать во время разряда. Пункт «Режим сна» в меню Apple тоже не работает.", "nl": "Zolang een extern beeldscherm is aangesloten, gaat de Mac tijdens het ontladen niet in de sluimerstand. Sluimer in het Apple-menu is ook uitgeschakeld.", "pl": "Gdy podłączony jest zewnętrzny monitor, Mac nie uśpi się podczas rozładowywania. Uśpienie z menu Apple również nie działa.", "tr": "Harici ekran bağlıyken deşarj sırasında Mac uyku moduna girmez. Apple menüsündeki Uyku da devre dışı kalır.", "sv": "Så länge en extern skärm är ansluten går datorn inte i vila under urladdningen. Vila i Apple-menyn är också avstängd.", "da": "Så længe en ekstern skærm er tilsluttet, går Mac’en ikke på vågeblus under afladning. Vågeblus i Apple-menuen er også slået fra.", "nb": "Så lenge en ekstern skjerm er tilkoblet, går ikke Mac-en i dvale under utlading. Dvale i Apple-menyen er også slått av.", "fi": "Kun ulkoinen näyttö on kytkettynä, Mac ei mene lepotilaan purkamisen aikana. Myös Apple-valikon Lepotila on poissa käytöstä.", "cs": "Dokud je připojen externí displej, Mac během vybíjení neusne. Nefunguje ani Uspat v nabídce Apple.", "hu": "Amíg külső kijelző van csatlakoztatva, a Mac nem alszik el kisütés közben. Az Apple menü Altatás parancsa sem működik.", "ro": "Cât timp este conectat un monitor extern, Mac-ul nu intră în repaus în timpul descărcării. Nici Repaus din meniul Apple nu funcționează.", "el": "Όσο είναι συνδεδεμένη εξωτερική οθόνη, το Mac δεν θα μπαίνει σε ύπνο κατά την εκφόρτιση. Η Ύπνωση στο μενού Apple επίσης απενεργοποιείται.", "uk": "Поки під’єднано зовнішній дисплей, Mac не засинатиме під час розряду. Пункт «Сон» у меню Apple також не працює.", "he": "כל עוד מחובר מסך חיצוני, ה‑Mac לא יעבור לשינה במהלך הפריקה. גם ‚שינה‘ בתפריט Apple מושבת.", "ar": "أثناء توصيل شاشة خارجية، لن يدخل Mac في وضع السكون خلال التفريغ. كما يتم تعطيل السكون من قائمة Apple.", "hi": "जब तक बाहरी डिस्प्ले जुड़ा है, डिस्चार्ज के दौरान Mac स्लीप में नहीं जाएगा। Apple मेनू का स्लीप भी अक्षम रहेगा।", "th": "ขณะเชื่อมต่อจอภาพภายนอก Mac จะไม่พักเครื่องระหว่างปล่อยประจุ คำสั่งพักเครื่องในเมนู Apple จะใช้ไม่ได้ด้วย", "vi": "Khi đang kết nối màn hình ngoài, máy Mac sẽ không ngủ trong lúc xả. Lệnh Ngủ trong menu Apple cũng bị tắt.", "id": "Selama layar eksternal terhubung, Mac tidak akan tidur saat pengosongan. Tidur di menu Apple juga dinonaktifkan."
  },
  "잠자기 차단 중 (덮개를 닫아도 방전이 계속됩니다)": {
    "ko": "잠자기 차단 중 (덮개를 닫아도 방전이 계속됩니다)", "en": "Sleep blocked (discharge continues with the lid closed)", "ja": "スリープ抑制中（ふたを閉じても放電は続きます）", "zh-Hans": "已阻止睡眠（合盖后仍继续放电）", "zh-Hant": "已阻止睡眠（闔上上蓋仍繼續放電）", "de": "Ruhezustand blockiert (Entladen läuft bei geschlossenem Deckel weiter)", "fr": "Veille bloquée (la décharge continue capot fermé)", "es": "Reposo bloqueado (la descarga continúa con la tapa cerrada)", "it": "Stop bloccato (la scarica continua con il coperchio chiuso)", "pt-BR": "Repouso bloqueado (a descarga continua com a tampa fechada)", "pt-PT": "Pausa bloqueada (a descarga continua com a tampa fechada)", "ru": "Сон заблокирован (разряд продолжается с закрытой крышкой)", "nl": "Sluimerstand geblokkeerd (ontladen gaat door met gesloten deksel)", "pl": "Uśpienie zablokowane (rozładowywanie trwa przy zamkniętej pokrywie)", "tr": "Uyku engellendi (kapak kapalıyken deşarj sürer)", "sv": "Vila blockerad (urladdningen fortsätter med stängt lock)", "da": "Vågeblus blokeret (afladning fortsætter med lukket låg)", "nb": "Dvale blokkert (utlading fortsetter med lukket lokk)", "fi": "Lepotila estetty (purkaminen jatkuu kansi suljettuna)", "cs": "Uspání blokováno (vybíjení pokračuje se zavřeným víkem)", "hu": "Altatás letiltva (a kisütés lecsukott fedéllel is folytatódik)", "ro": "Repaus blocat (descărcarea continuă cu capacul închis)", "el": "Ύπνωση αποκλεισμένη (η εκφόρτιση συνεχίζεται με κλειστό καπάκι)", "uk": "Сон заблоковано (розряд триває із закритою кришкою)", "he": "שינה חסומה (הפריקה נמשכת כשהמכסה סגור)", "ar": "السكون محظور (يستمر التفريغ والغطاء مغلق)", "hi": "स्लीप अवरुद्ध (ढक्कन बंद होने पर भी डिस्चार्ज जारी)", "th": "บล็อกการพักเครื่อง (ปล่อยประจุต่อแม้ปิดฝา)", "vi": "Đã chặn ngủ (tiếp tục xả khi đóng nắp)", "id": "Tidur diblokir (pengosongan berlanjut saat penutup ditutup)"
  },
  "클램쉘 방전을 사용하려면 도우미 업데이트가 필요합니다.": {
    "ko": "클램쉘 방전을 사용하려면 도우미 업데이트가 필요합니다.", "en": "Update the helper to use clamshell discharge.", "ja": "クラムシェル放電を使うにはヘルパーの更新が必要です。", "zh-Hans": "需要更新辅助程序才能使用合盖放电。", "zh-Hant": "需要更新輔助程式才能使用闔蓋放電。", "de": "Für das Entladen bei geschlossenem Deckel muss der Helfer aktualisiert werden.", "fr": "Mettez à jour l’assistant pour utiliser la décharge capot fermé.", "es": "Actualiza el asistente para usar la descarga con la tapa cerrada.", "it": "Aggiorna l’helper per usare la scarica a coperchio chiuso.", "pt-BR": "Atualize o auxiliar para usar a descarga com a tampa fechada.", "pt-PT": "Atualize o auxiliar para usar a descarga com a tampa fechada.", "ru": "Обновите помощник, чтобы использовать разряд с закрытой крышкой.", "nl": "Werk de helper bij om ontladen met gesloten deksel te gebruiken.", "pl": "Zaktualizuj pomocnika, aby używać rozładowywania przy zamkniętej pokrywie.", "tr": "Kapak kapalı deşarj için yardımcıyı güncelleyin.", "sv": "Uppdatera hjälparen för att använda urladdning med stängt lock.", "da": "Opdater hjælperen for at bruge afladning med lukket låg.", "nb": "Oppdater hjelperen for å bruke utlading med lukket lokk.", "fi": "Päivitä apuohjelma käyttääksesi purkamista kansi suljettuna.", "cs": "Pro vybíjení se zavřeným víkem aktualizujte pomocníka.", "hu": "A lecsukott fedeles kisütéshez frissítsd a segédprogramot.", "ro": "Actualizează asistentul pentru a folosi descărcarea cu capacul închis.", "el": "Ενημερώστε τον βοηθό για εκφόρτιση με κλειστό καπάκι.", "uk": "Оновіть помічник, щоб використовувати розряд із закритою кришкою.", "he": "יש לעדכן את העוזר כדי להשתמש בפריקה עם מכסה סגור.", "ar": "حدّث المساعد لاستخدام التفريغ والغطاء مغلق.", "hi": "ढक्कन बंद डिस्चार्ज के लिए हेल्पर अपडेट करें।", "th": "อัปเดตตัวช่วยเพื่อใช้การปล่อยประจุแบบปิดฝา", "vi": "Cập nhật trình trợ giúp để dùng xả khi đóng nắp.", "id": "Perbarui pembantu untuk menggunakan pengosongan dengan penutup tertutup."
  },
  "클램쉘 방전이 켜져 있어 외장 디스플레이가 연결된 동안은 뚜껑을 닫아도 됩니다.": {
    "ko": "클램쉘 방전이 켜져 있어 외장 디스플레이가 연결된 동안은 뚜껑을 닫아도 됩니다.", "en": "Clamshell discharge is on, so the lid can stay closed while an external display is connected.", "ja": "クラムシェル放電がオンのため、外部ディスプレイ接続中はふたを閉じても構いません。", "zh-Hans": "已开启合盖放电，连接外接显示器时可以合上盖子。", "zh-Hant": "已開啟闔蓋放電，連接外接顯示器時可以闔上上蓋。", "de": "Entladen bei geschlossenem Deckel ist aktiv – solange ein externes Display angeschlossen ist, kann der Deckel zu bleiben.", "fr": "La décharge capot fermé est activée : le capot peut rester fermé tant qu’un écran externe est connecté.", "es": "La descarga con la tapa cerrada está activada: puedes mantener la tapa cerrada mientras haya una pantalla externa conectada.", "it": "La scarica a coperchio chiuso è attiva: puoi tenere il coperchio chiuso finché è collegato un monitor esterno.", "pt-BR": "A descarga com a tampa fechada está ativada: a tampa pode ficar fechada enquanto um monitor externo estiver conectado.", "pt-PT": "A descarga com a tampa fechada está ativada: a tampa pode ficar fechada enquanto um monitor externo estiver ligado.", "ru": "Разряд с закрытой крышкой включён: крышку можно держать закрытой, пока подключён внешний дисплей.", "nl": "Ontladen met gesloten deksel staat aan: het deksel mag dicht blijven zolang een extern beeldscherm is aangesloten.", "pl": "Rozładowywanie przy zamkniętej pokrywie jest włączone – pokrywa może pozostać zamknięta, gdy podłączony jest zewnętrzny monitor.", "tr": "Kapak kapalı deşarj açık; harici ekran bağlıyken kapak kapalı kalabilir.", "sv": "Urladdning med stängt lock är på – locket kan vara stängt så länge en extern skärm är ansluten.", "da": "Afladning med lukket låg er slået til – låget kan forblive lukket, så længe en ekstern skærm er tilsluttet.", "nb": "Utlading med lukket lokk er på – lokket kan være lukket så lenge en ekstern skjerm er tilkoblet.", "fi": "Purkaminen kansi suljettuna on käytössä – kansi voi olla kiinni, kun ulkoinen näyttö on kytkettynä.", "cs": "Vybíjení se zavřeným víkem je zapnuté – víko může zůstat zavřené, dokud je připojen externí displej.", "hu": "A lecsukott fedeles kisütés be van kapcsolva – a fedél zárva maradhat, amíg külső kijelző van csatlakoztatva.", "ro": "Descărcarea cu capacul închis este activată: capacul poate rămâne închis cât timp este conectat un monitor extern.", "el": "Η εκφόρτιση με κλειστό καπάκι είναι ενεργή· το καπάκι μπορεί να μείνει κλειστό όσο είναι συνδεδεμένη εξωτερική οθόνη.", "uk": "Розряд із закритою кришкою увімкнено: кришку можна тримати закритою, поки під’єднано зовнішній дисплей.", "he": "פריקה עם מכסה סגור פעילה – המכסה יכול להישאר סגור כל עוד מחובר מסך חיצוני.", "ar": "التفريغ والغطاء مغلق مفعّل، لذا يمكن إبقاء الغطاء مغلقًا أثناء توصيل شاشة خارجية.", "hi": "ढक्कन बंद डिस्चार्ज चालू है, इसलिए बाहरी डिस्प्ले जुड़े रहने तक ढक्कन बंद रह सकता है।", "th": "เปิดการปล่อยประจุแบบปิดฝาไว้ จึงปิดฝาได้ขณะเชื่อมต่อจอภาพภายนอก", "vi": "Xả khi đóng nắp đang bật, nên có thể đóng nắp khi đang kết nối màn hình ngoài.", "id": "Pengosongan dengan penutup tertutup aktif, jadi penutup boleh tetap tertutup selama layar eksternal terhubung."
  }
}
```

Run:
```bash
python3 scripts/add_localizations.py scripts/i18n_additions/battery_clamshell_discharge.json
```
Expected: `merged 5 keys; catalog now has 659 keys` (기존 654 + 5). 언어가 빠지면 스크립트가 `is missing languages`로 종료한다 — 그 언어를 채워 다시 돌린다.

- [ ] **Step 5: 테스트 통과 확인**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/BatterySectionPresentationTests 2>&1 | grep -E 'passed|failed' | tail -2
```
Expected: passed. 카탈로그 병합 여부는 Step 4의 `merged 5 keys` 출력으로 확인한다.

- [ ] **Step 6: Commit**

```bash
git add Wattly/Core/BatterySectionPresentation.swift scripts/i18n_additions/battery_clamshell_discharge.json Wattly/Resources/Localizable.xcstrings WattlyTests/BatterySectionPresentationTests.swift
git commit -m "feat(battery): clamshell discharge toggle gating, status copy and 30-locale translations

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: 설정 UI — 토글 행, "잠자기 차단 중" 표시, 캘리브레이션 안내

**Files:**
- Modify: `Wattly/Views/Settings/SettingsBatteryDischargeSection.swift` (`@AppStorage` 블록, `autoDischargeCard`의 진행 칩, `manualDischargeCard`의 진행 배너와 카드 끝)
- Modify: `Wattly/Views/Settings/SettingsBatteryCalibrationSection.swift:103-110`

**Interfaces:**
- Consumes: Task 8의 프레젠테이션 함수 4개, Task 5의 `StorageKey.batteryClamshellDischargeEnabled`·`ExternalDisplayDetector`, Task 2의 `status.isSystemSleepInhibited`.

- [ ] **Step 1: 방전 섹션에 `@AppStorage` 추가**

`SettingsBatteryDischargeSection.swift` — `heatProtectionThreshold` `@AppStorage` 줄 아래:
```swift
    @AppStorage(StorageKey.batteryClamshellDischargeEnabled) private var clamshellDischargeEnabled = Defaults.batteryClamshellDischargeEnabled
```

`dischargeOwner` 프로퍼티 아래에 두 프로퍼티 추가:
```swift
    /// 데몬이 지금 시스템 잠자기를 억제 중인지. `nil`(구버전 헬퍼)은 표시하지 않는다.
    private var isSleepInhibited: Bool {
        batteryControl.status.isSystemSleepInhibited == true
    }

    private var isClamshellToggleEnabled: Bool {
        BatterySectionPresentation.isClamshellDischargeToggleEnabled(
            helperMode: batteryControl.status.mode,
            capabilities: batteryControl.status.capabilities,
            isDischargeHardwareSupported: batteryControl.status.isDischargeHardwareSupported)
    }
```

- [ ] **Step 2: 자동 방전 칩 옆에 잠자기 차단 줄**

`autoDischargeCard`에서 `if dischargeOwner == .automatic { HStack(spacing: 4) { ... } }` 블록 바로 뒤(같은 `HStack(spacing: 6)` 안):
```swift
                        if dischargeOwner == .automatic && isSleepInhibited {
                            Text(verbatim: BatterySectionPresentation.sleepInhibitedText(locale: locale))
                                .font(WattlyFont.at(10, weight: .regular))
                                .foregroundStyle(t.faint)
                        }
```

- [ ] **Step 3: 수동 방전 배너에 잠자기 차단 줄 + 카드 끝에 토글 행**

`manualDischargeCard`의 `if isManualDischargeActive { ... VStack(spacing: 8) { ... } }` 안, `HStack { if let sample = liveBatterySample { ... } Spacer() if let eta ... }` 블록 바로 뒤에:
```swift
                        if isSleepInhibited {
                            HStack(spacing: 4) {
                                Image(systemName: "moon.zzz")
                                    .font(.system(size: 10))
                                Text(verbatim: BatterySectionPresentation.sleepInhibitedText(locale: locale))
                            }
                            .font(WattlyFont.at(10.5, weight: .regular))
                            .foregroundStyle(t.sub)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
```

`manualDischargeCard`의 최상위 `VStack(alignment: .leading, spacing: 10) { ... }` 마지막 자식(`if isManualDischargeActive { ... } else { ... }` 블록) 바로 뒤에:
```swift
                Rectangle().fill(t.line).frame(height: 1)

                SettingsToggleRow(
                    isOn: $clamshellDischargeEnabled,
                    divider: false,
                    isEnabled: isClamshellToggleEnabled,
                    disabledReason: BatterySectionPresentation.clamshellDischargeToggleDisabledReason(
                        helperMode: batteryControl.status.mode,
                        capabilities: batteryControl.status.capabilities,
                        isDischargeHardwareSupported: batteryControl.status.isDischargeHardwareSupported,
                        locale: locale)
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        SettingsRowTitle("덮개를 닫아도 방전 계속")
                        Text("외장 디스플레이가 연결된 동안 방전 중에는 Mac이 잠들지 않습니다. Apple 메뉴의 잠자기도 동작하지 않습니다.")
                            .font(WattlyFont.at(10.5, weight: .regular))
                            .foregroundStyle(t.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
```
(`SettingsToggleRow`는 자체 패딩 14/10을 가지므로 바깥에서 패딩을 더하지 않는다. 데몬 전송은 `BatteryControlBridge`의 `.onChange(of: clamshellDischargeEnabled)`가 담당하므로 이 뷰에는 `.onChange`를 달지 않는다 — 자동 방전 토글의 이중 쓰기 경쟁을 되풀이하지 않는다.)

- [ ] **Step 4: 캘리브레이션 preflight 안내 조건부**

`SettingsBatteryCalibrationSection.swift` 107행의
```swift
                        Text("방전 구간에는 뚜껑을 열고 Mac을 사용 중인 상태로 두어야 합니다.")
```
를 다음으로 교체:
```swift
                        Text(verbatim: BatterySectionPresentation.calibrationLidGuidanceText(
                            clamshellAllowed: clamshellDischargeEnabled
                                && ExternalDisplayDetector.hasExternalDisplay(),
                            locale: locale))
```
같은 뷰의 `@State private var confirmedDuration = false` 아래에:
```swift
    @AppStorage(StorageKey.batteryClamshellDischargeEnabled) private var clamshellDischargeEnabled = Defaults.batteryClamshellDischargeEnabled
```
(`@Environment(\.locale) private var locale`은 이 뷰 13행에 이미 있다. 이 문구는 body 평가 시점의 `NSScreen`을 읽으므로 화면 구성 변경만으로는 갱신되지 않고 다음 재렌더에서 반영된다 — 안내문이라 그대로 둔다.)

- [ ] **Step 5: 빌드 + 전체 테스트 + 눈 확인**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E 'error:|BUILD' | tail -3 && xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test 2>&1 | grep -E 'passed|failed' | tail -2
```
Expected: `** BUILD SUCCEEDED **`, 실패 0.

눈 확인(앱 실행 후 설정 › 배터리): 수동 방전 카드 맨 아래에 "덮개를 닫아도 방전 계속" 토글이 보이고, 설치된 도우미가 구버전이면 흐리게 + 사유 "클램쉘 방전을 사용하려면 도우미 업데이트가 필요합니다."가 VoiceOver 힌트로 붙는다. 도우미를 업데이트한 뒤 토글을 켜고 수동 방전을 시작하면 배너에 "잠자기 차단 중" 줄이 나타나야 한다(외장 디스플레이가 연결돼 있을 때만).

- [ ] **Step 6: Commit**

```bash
git add Wattly/Views/Settings/SettingsBatteryDischargeSection.swift Wattly/Views/Settings/SettingsBatteryCalibrationSection.swift
git commit -m "feat(settings): clamshell discharge toggle, sleep-blocked indicator and conditional calibration lid guidance

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: 기능 문서 + 실기 검증 매트릭스

**Files:**
- Create: `docs/features/battery-management/12-clamshell-discharge.md`

- [ ] **Step 1: 문서 작성**

```markdown
# 클램쉘 방전 (Clamshell Discharge)

## 상태

- 단계: 구현됨 (2026-09-07)
- 구현 난이도: 어려움
- 권장 우선순위: 12

## 목표

강제 방전(CHIE) 중 뚜껑을 닫아도 Mac이 잠들지 않게 해, 외장 디스플레이로 작업하는 사용자가 방전을 위해 뚜껑을 열어 둘 필요가 없게 한다. 기본값은 꺼짐이며, 사용자가 명시적으로 켜야 한다.

## 왜 문제가 생기는가 (실측, macOS 26.6.2 / Mac17,2)

- CHIE=0x08이면 `pmset`=Battery Power, `ExternalConnected`=No. macOS는 배터리 구동으로 본다.
- powerd의 클램쉘 규칙(바이너리 문자열): `EvaluateClamshell. Result: %d because {DesktopMode with AC: %u, assertions %d}`. 방전 중엔 AC가 사라져 첫 조건이 깨진다.
- 잠들면 방전이 정지한다: 602초 동안 −0.01%p(깨어 있었으면 −2.37%p). CHIE는 sleep을 넘어 유지된다.
- `caffeinate -i` / `PreventUserIdleSystemSleep`은 뚜껑 닫힘을 막지 못한다.
- `AppliesOnLidClose` 어설션은 비루트·루트 모두 `0xE00002C1`(kIOReturnNotPrivileged). powerd에 `com.apple.private.iokit.assertonlidclose` 엔타이틀먼트가 있다.
- `IOPMSetSystemPowerSetting("SleepDisabled", true)`는 루트만으로 성공하고 1.5초 안에 `pmset -g`·`ioreg`에 반영된다. `pmset -a disablesleep 1`과 같은 경로다.
- `ioreg`의 `AppleClamshellCausesSleep`은 클램쉘 조건만 반영한다. `SleepDisabled=1`이어도 Yes로 남으므로 실효 검증은 뚜껑을 실제로 닫아야 한다.

## 설계

- **소유자**: 데몬 `BatteryControlCoordinator`. 앱은 비루트라 호출이 거부된다.
- **켜는 조건(동시에 참)**: 앱이 보낸 `clamshellDischargeAllowed`(= 옵트인 && 외장 디스플레이 존재) · 엔진 `isDischargingNow`(수동·자동·캘리브레이션 전부) · 이번 방전 세션에서 12시간 만료가 안 됨.
- **끄는 경로**: 방전 종료(목표 도달·사용자 중지) · 어댑터 분리 · 발열 보호 · 옵트인 해제 · 외장 디스플레이 분리 · 12시간 만료 · 데몬 시작(`restore`) · 데몬 종료 · `--verify-battery-release`(도우미 교체·삭제).
- **마커 우선**: 켜기 전에 `PersistedBatteryPolicy.sleepInhibitedAt`을 저장한다. 크래시·재부팅 후 데몬이 마커만 보고 되돌린다.
- **소유하지 않는 경우**: 켜기 전 현재값이 이미 `true`(사용자가 직접 `disablesleep 1`) 또는 읽기 실패.
- **저장하지 않는 것**: `clamshellDischargeAllowed`. 앱이 죽은 채 데몬만 재시작하면 잠자기 차단 없이 시작한다.
- **판정은 순수 함수** `BatteryClamshellSleepPolicy.decide`, 호출은 `SystemSleepInhibiting` 프로토콜 뒤.

## 사용자에게 알리는 부작용

- 플래그가 켜진 동안 Apple 메뉴의 "잠자기"도 동작하지 않는다(설정 문구에 명시).
- 화면 끄기(displaysleep)는 그대로 동작한다. 방전은 화면이 꺼져도 계속된다.

## 관련 코드

- `FanControlShared/BatteryClamshellSleepPolicy.swift`, `FanControlShared/SystemSleepInhibiting.swift`
- `FanControlShared/BatteryControlCoordinator.swift` (`syncSleepInhibition`, `releaseSleepInhibition`)
- `WattlyFanDaemon/IOPMSystemSleepInhibitor.swift`, `WattlyFanDaemon/main.swift`
- `Wattly/Core/ExternalDisplayDetector.swift`, `Wattly/Control/BatteryControlClient.swift` (`revivedConfiguration`), `Wattly/Views/BatteryControlBridge.swift`
- `Wattly/Views/Settings/SettingsBatteryDischargeSection.swift`

## 실기 검증 매트릭스 (구현 후, 사용자)

| # | 시나리오 | 기대 | 결과 |
|---|---|---|---|
| 1 | 클램쉘(외장 디스플레이+어댑터)에서 옵션 ON, 수동 방전 시작 → 뚜껑 닫기 | 외장 화면 유지, `pmset -g` SleepDisabled 1, SoC 하락 | |
| 2 | 1 상태에서 어댑터 분리 | 5초 내 방전 취소 + SleepDisabled 0, 이후 Mac 잠자기 진입(즉시 또는 idle 타이머 1분) | |
| 3 | 1 상태에서 외장 모니터 분리 | 앱이 allowed=false 전송 → SleepDisabled 0 → 잠자기 진입 | |
| 4 | 방전 중 `sudo kill -9 <daemon pid>` | 재기동 후 SleepDisabled 0, 60초 내 앱 reconcile로 다시 1 | |
| 5 | 방전 중 목표 도달 | SleepDisabled 0, 배너의 "잠자기 차단 중" 사라짐 | |
| 6 | 미리 `sudo pmset -a disablesleep 1` 후 방전 시작·종료 | Wattly가 값을 건드리지 않음(계속 1) | |
| 7 | 방전 중 앱 삭제 흐름 | 삭제 후 `pmset -g` SleepDisabled 0 | |
| 8 | 옵션 ON, 외장 디스플레이 없음, 수동 방전 시작 | SleepDisabled 0 유지(허용값 false) | |
| 9 | 캘리브레이션 방전 단계, 옵션 ON, 클램쉘 | 방전 단계에서만 SleepDisabled 1, 충전 단계 전환 시 0 | |
| 10 | 충전 한도 OFF + 열 보호 OFF 상태에서 수동 방전 시작 → 옵션 토글 ON/OFF, 외장 모니터 분리·재연결 | 방전은 계속 진행(취소되지 않음), SleepDisabled만 1/0으로 바뀜 | |
```

- [ ] **Step 2: Commit**

```bash
git add docs/features/battery-management/12-clamshell-discharge.md
git commit -m "docs(battery): clamshell discharge feature doc with on-device facts and verification matrix

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```
