# macOS 27 네이티브 충전 제한 백엔드 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS 27에서 SMC 충전 레지스터가 사라져 멈춘 충전 제한과 Top Up을, 애플 네이티브 충전 제한(비공개 PowerUI)을 앱이 직접 구동하는 백엔드로 복구한다.

**Architecture:** 앱 안 전역 actor `NativeChargeLimitService`가 `BatteryControlClient`의 기존 요청 계약(`.configure(Data)`/`.status` → 인코딩된 `BatteryControlServiceStatus`)을 그대로 말하고, 클라이언트의 기본 핸들러가 `BatteryControlBackendSelector.current`에 따라 XPC(루트 데몬) 또는 이 서비스로 보낸다. 판단은 순수 함수 둘(`NativeChargeLimitPlan` = 설정 → 명령, `NativeChargeLimitStatus` = 상태 DTO 합성)에 두고, I/O는 프로토콜 뒤(`NativeChargeLimitDriving`)와 리더(`NativeLimitBatteryReader`)에 둔다. 브리지·정책·표시·단축어·스케줄은 상태 DTO만 읽으므로 수정하지 않는다.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI 메뉴바 앱, ObjC 런타임(`dlopen` + `NSClassFromString` + `@convention(c)` IMP 캐스트)으로 비공개 `PowerUI.framework` 호출, IOKit(`IOPSCopyPowerSourcesInfo`, `AppleSmartBattery` 레지스트리, 기존 `SMCConnection`), XcodeGen(`project.yml`이 `Wattly.xcodeproj`의 원본), Swift Testing(`@Test`/`#expect`).

**Spec:** `docs/superpowers/specs/2026-09-17-macos-27-native-charge-limit.md`

## Global Constraints

- **기존 SMC 경로는 한 줄도 바꾸지 않는다.** `FanControlShared/BatteryControlEngine.swift`, `BatteryControlCoordinator.swift`, `BatteryControlKeys.swift`, `BatteryControlPolicy.swift`, `WattlyFanDaemon/*`는 수정 금지. `FanControlShared/BatteryControlProtocol.swift`는 Task 1의 옵셔널 필드 추가만 허용.
- **기존 테스트는 수정하지 않는다.** 테스트 호스트에서는 선택기가 항상 `.smc`를 반환해야 한다(실제 시스템 충전 제한을 테스트가 건드리면 안 된다).
- 네이티브 백엔드 선택 조건: `BatteryControlKeys.runtimeDrivableRegisterProbe == .noDrivableRegisterAtRuntime` **그리고** 드라이버 `isSupported`. 그 외는 전부 `.smc`.
- PowerUI 셀렉터(정확한 철자): `isMCLSupported`, `availableChargeLimitsWithError:`, `getMCLLimitWithError:`, `isMCLCurrentlyEnabled:`, `setMCLLimit:error:`, `temporarilyDisableMCL:`. 클래스 `PowerUISmartChargeClient`, 생성 `initWithClientName:`, 프레임워크 경로 `/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI`.
- 활성 상태 원시값: `0` = 꺼짐, `1` = 켜짐, `3` = 일시 해제. 해제용 제한값은 `100`. 폴백 허용 목록은 `[80, 85, 90, 95, 100]`.
- `currentChargeLimit:`은 readback으로 쓰지 않는다(실기에서 항상 100).
- 방전(drain) 판정은 **전류 부호**: 어댑터 연결 + 잔량 > 제한 + 배터리 전류 ≤ `-100` mA.
- Wattly 제한을 끌 때는 **Wattly가 건 제한만** 푼다(`nativeLimitOwned`).
- 목록 밖 요청값은 **요청값 이상인 최소 허용값**으로 올린다(70 → 80).
- 영속 키(`UserDefaults`): `nativeLimitDesiredConfiguration`(JSON `Data`), `nativeLimitTopUpReachedFullAt`(`Double`), `nativeLimitOwned`(`Bool`). `SettingsReset`은 이 키를 건드리지 않는다.
- 새 Swift 파일을 추가한 태스크는 반드시 `xcodegen generate`로 `Wattly.xcodeproj`를 재생성하고 `project.pbxproj`를 같은 커밋에 넣는다(pbxproj 직접 편집 금지). 이 개발기에서 xcodegen은 `/Users/hyunjun_macbook_pro/bin/xcodegen`에 있다: `/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml`. 새 파일은 전부 `Wattly/` 또는 `WattlyTests/` 아래라 `project.yml` 자체는 수정할 필요가 없다.
- Swift 6 strict concurrency: 새 타입은 `Sendable`, 클로저 파라미터는 `@Sendable`. 경고 0.
- 새 사용자 노출 문자열은 `scripts/add_localizations.py`로 **30개 언어 전부** 추가한다(부분 번역은 스크립트가 거부한다).
- 테스트 실행: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/<SuiteName> 2>&1 | tail -25`. 전체: 같은 명령에서 `-only-testing` 제거.
- 커밋 메시지는 Conventional Commits, 스코프 `battery`.

## File Structure

| 파일 | 상태 | 책임 |
|---|---|---|
| `FanControlShared/BatteryControlProtocol.swift` | 수정 | `BatteryControlBackend`, `BatteryControlServiceStatus.controlBackend` |
| `Wattly/Control/BatteryControlClient.swift` | 수정 | `updateUnavailable`가 `controlBackend` 보존(Task 1), 기본 핸들러 라우팅(Task 6) |
| `Wattly/Control/NativeChargeLimitPlan.swift` | 신규 | `NativeLimitEnabledState`, `NativeLimitSnapshot`, `NativeLimitCommand`, 스냅, 설정 → 명령 (순수) |
| `Wattly/Control/NativeChargeLimitStatus.swift` | 신규 | `NativeLimitBatteryReading`, `NativeLimitWriteOutcome`, 상태 DTO 합성 (순수) |
| `Wattly/Control/NativeChargeLimitDriver.swift` | 신규 | `NativeChargeLimitDriving`, `NativeChargeLimitError`, `PowerUIChargeLimitDriver` |
| `Wattly/Control/NativeChargeLimitService.swift` | 신규 | 전역 actor: 요청 처리·영속·Top Up 종료·소유 플래그 |
| `Wattly/Control/NativeLimitBatteryReader.swift` | 신규 | IOPS + 레지스트리 판독, 순수 조립 함수 |
| `Wattly/Control/BatteryControlBackendSelector.swift` | 신규 | 백엔드 선택 + 프로세스 캐시 |
| `Wattly/Settings/Settings.swift` | 수정 | `StorageKey` 3개 |
| `Wattly/Core/BatterySectionPresentation.swift` | 수정 | `BatteryFeature`, `hiddenFeatures(backend:)`, `nativeLimitNotice` |
| `Wattly/Views/Settings/SettingsBatterySection.swift` | 수정 | 세 행 게이팅 + 안내 한 줄 |
| `scripts/i18n_additions/native_charge_limit.json` | 신규 | 안내 문구 30개 언어 |
| `Wattly/App/WattlyApp.swift` | 수정 | `-WattlyNativeLimitProbe` 등록 |
| `docs/features/battery-management/14-macos-27-native-charge-limit.md` | 신규 | 기능 문서 + 실기 체크리스트 |
| `WattlyTests/BatteryControlBackendTests.swift` 외 6개 | 신규 | 태스크별 테스트 |

---

### Task 1: 상태 DTO에 `controlBackend` 추가

**Files:**
- Modify: `FanControlShared/BatteryControlProtocol.swift` (`BatteryControlCapability` enum 뒤, 그리고 `BatteryControlServiceStatus`)
- Modify: `Wattly/Control/BatteryControlClient.swift` (`updateUnavailable`)
- Test: `WattlyTests/BatteryControlBackendTests.swift`

**Interfaces:**
- Consumes: 없음.
- Produces: `public enum BatteryControlBackend: String, Codable, Equatable, Sendable { case smc; case nativeLimit = "native-limit"; case unrecognized }`, `BatteryControlServiceStatus.controlBackend: BatteryControlBackend?` (이니셜라이저 **마지막** 파라미터 `controlBackend: BatteryControlBackend? = nil`).

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/BatteryControlBackendTests.swift`:

```swift
import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryControlBackendTests {
    private func status(backend: BatteryControlBackend?) -> BatteryControlServiceStatus {
        BatteryControlServiceStatus(
            mode: .charging,
            currentPercentage: 70,
            isPowerAdapterConnected: true,
            detail: "테스트",
            updatedAt: 1,
            controlBackend: backend)
    }

    @Test func payloadFromHelperThatNeverHeardOfBackendsDecodesAsNil() throws {
        let data = try BatteryControlCodec.encode(status(backend: nil))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["controlBackend"] == nil)
        let decoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: data)
        #expect(decoded.controlBackend == nil)
    }

    @Test func nativeLimitRoundTrips() throws {
        let data = try BatteryControlCodec.encode(status(backend: .nativeLimit))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["controlBackend"] as? String == "native-limit")
        let decoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: data)
        #expect(decoded.controlBackend == .nativeLimit)
    }

    @Test func unknownBackendTokenDoesNotFailTheWholeStatus() throws {
        let data = try BatteryControlCodec.encode(status(backend: .smc))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["controlBackend"] = "quantum"
        let mutated = try JSONSerialization.data(withJSONObject: object)
        let decoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: mutated)
        #expect(decoded.controlBackend == .unrecognized)
        #expect(decoded.currentPercentage == 70)
    }
}
```

- [ ] **Step 2: 프로젝트 재생성 후 실패 확인**

Run: `/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml && xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/BatteryControlBackendTests 2>&1 | tail -25`
Expected: 컴파일 실패 — `extra argument 'controlBackend' in call`, `cannot find type 'BatteryControlBackend'`.

- [ ] **Step 3: enum 추가**

`FanControlShared/BatteryControlProtocol.swift`에서 `public enum BatteryControlCapability … }` 블록이 끝난 바로 다음 줄에 추가:

```swift
/// Which mechanism is enforcing the charge limit on this Mac.
///
/// `smc` is the root helper writing charge-control registers. `nativeLimit` is the app driving
/// Apple's own charge limit, which is all that is left on macOS 27 firmware — the registers are
/// gone and the firmware-managed keys are refused even to root. The settings screen reads this to
/// hide the options that mechanism cannot express (sailing, heat protection, sleep-until-limit).
///
/// Optional on the status and lenient on decode for the same reason every other token here is: a
/// helper that predates the field, or an app that predates a future case, must still decode the
/// rest of the status.
public enum BatteryControlBackend: String, Codable, Equatable, Sendable {
    case smc
    case nativeLimit = "native-limit"
    case unrecognized

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unrecognized
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
```

- [ ] **Step 4: 상태 필드 추가**

같은 파일 `BatteryControlServiceStatus`에서:

1. `public var isSystemSleepInhibited: Bool?` 선언 바로 아래에 추가:

```swift
    /// Which backend produced this status. `nil` from the root helper, which predates the field and
    /// is by construction the SMC backend.
    public var controlBackend: BatteryControlBackend?
```

2. 이니셜라이저 파라미터 목록의 마지막 `isSystemSleepInhibited: Bool? = nil` 뒤에 `,`를 붙이고 다음 줄 추가:

```swift
        controlBackend: BatteryControlBackend? = nil
```

3. 이니셜라이저 본문의 마지막 `self.isSystemSleepInhibited = isSystemSleepInhibited` 아래에 추가:

```swift
        self.controlBackend = controlBackend
```

- [ ] **Step 5: `updateUnavailable`가 백엔드를 보존하게 한다**

`Wattly/Control/BatteryControlClient.swift`의 `updateUnavailable(_:)`에서 `capabilities: status.capabilities` 줄을 다음 두 줄로 바꾼다:

```swift
            capabilities: status.capabilities,
            controlBackend: status.controlBackend
```

(백엔드는 연결 상태가 아니라 이 Mac의 사실이다 — 일시적 실패 때 떨어뜨리면 숨겼던 설정 행이 깜빡인다. 바로 위 주석이 `isHardwareSupported`에 대해 말하는 것과 같은 이유.)

- [ ] **Step 6: 통과 확인**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/BatteryControlBackendTests -only-testing:WattlyTests/BatteryControlProtocolTests -only-testing:WattlyTests/BatteryControlClientTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`, 새 테스트 3개 통과, 기존 두 스위트 회귀 없음.

- [ ] **Step 7: 커밋**

```bash
git add FanControlShared/BatteryControlProtocol.swift Wattly/Control/BatteryControlClient.swift WattlyTests/BatteryControlBackendTests.swift Wattly.xcodeproj/project.pbxproj
git commit -m "feat(battery): add an optional controlBackend field to the service status"
```

---

### Task 2: 순수 계획 함수 `NativeChargeLimitPlan`

**Files:**
- Create: `Wattly/Control/NativeChargeLimitPlan.swift`
- Test: `WattlyTests/NativeChargeLimitPlanTests.swift`

**Interfaces:**
- Consumes: `BatteryControlConfiguration`(`enabled`, `topUpActive`, `clampedLimitPercentage`).
- Produces:
  - `enum NativeLimitEnabledState: Equatable, Sendable { case off, on, temporarilyDisabled, unknown(UInt64); init(rawState: UInt64) }`
  - `struct NativeLimitSnapshot: Equatable, Sendable { var limit: Int; var state: NativeLimitEnabledState }`
  - `enum NativeLimitCommand: Equatable, Sendable { case none, setLimit(Int), temporarilyDisable, release }`
  - `NativeChargeLimitPlan.fallbackLimits: [Int]`, `.releaseLimit: Int`
  - `NativeChargeLimitPlan.snapped(_ requested: Int, to available: [Int]) -> Int`
  - `NativeChargeLimitPlan.command(configuration: BatteryControlConfiguration, isPluggedIn: Bool, native: NativeLimitSnapshot, ownsNativeLimit: Bool, availableLimits: [Int]) -> NativeLimitCommand`

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/NativeChargeLimitPlanTests.swift`:

```swift
import Testing
@testable import Wattly

@Suite struct NativeChargeLimitPlanTests {
    private let limits = [80, 85, 90, 95, 100]

    private func command(
        _ configuration: BatteryControlConfiguration,
        plugged: Bool = true,
        native: NativeLimitSnapshot,
        owns: Bool = false
    ) -> NativeLimitCommand {
        NativeChargeLimitPlan.command(
            configuration: configuration,
            isPluggedIn: plugged,
            native: native,
            ownsNativeLimit: owns,
            availableLimits: limits)
    }

    // MARK: enabledState

    @Test func rawStateMapsTheThreeMeasuredValues() {
        #expect(NativeLimitEnabledState(rawState: 0) == .off)
        #expect(NativeLimitEnabledState(rawState: 1) == .on)
        #expect(NativeLimitEnabledState(rawState: 3) == .temporarilyDisabled)
        #expect(NativeLimitEnabledState(rawState: 2) == .unknown(2))
    }

    // MARK: snapped

    @Test func snappedKeepsAnAllowedValue() {
        #expect(NativeChargeLimitPlan.snapped(85, to: limits) == 85)
    }

    @Test func snappedRoundsUpToTheNextAllowedValue() {
        #expect(NativeChargeLimitPlan.snapped(70, to: limits) == 80)
        #expect(NativeChargeLimitPlan.snapped(81, to: limits) == 85)
    }

    @Test func snappedFallsBackWhenTheListIsEmptyOrTooLow() {
        #expect(NativeChargeLimitPlan.snapped(70, to: []) == 80)
        #expect(NativeChargeLimitPlan.snapped(99, to: [80, 85]) == 100)
    }

    // MARK: command — enabled

    @Test func armsTheLimitWhenNativeIsOff() {
        let result = command(.init(enabled: true, limitPercentage: 80),
                             native: .init(limit: 100, state: .off))
        #expect(result == .setLimit(80))
    }

    @Test func doesNothingWhenNativeAlreadyMatches() {
        let result = command(.init(enabled: true, limitPercentage: 90),
                             native: .init(limit: 90, state: .on))
        #expect(result == .none)
    }

    @Test func rearmsWhenSomeoneElseChangedTheValue() {
        let result = command(.init(enabled: true, limitPercentage: 80),
                             native: .init(limit: 95, state: .on))
        #expect(result == .setLimit(80))
    }

    @Test func rearmsAfterATopUpThatIsNoLongerRequested() {
        let result = command(.init(enabled: true, limitPercentage: 80),
                             native: .init(limit: 100, state: .temporarilyDisabled))
        #expect(result == .setLimit(80))
    }

    @Test func offListRequestIsRoundedUpBeforeComparing() {
        let result = command(.init(enabled: true, limitPercentage: 70),
                             native: .init(limit: 80, state: .on))
        #expect(result == .none)
    }

    @Test func enabledAtOneHundredWithNativeOffIsAlreadySatisfied() {
        let result = command(.init(enabled: true, limitPercentage: 100),
                             native: .init(limit: 100, state: .off))
        #expect(result == .none)
    }

    // MARK: command — Top Up

    @Test func topUpTemporarilyDisablesAnArmedLimit() {
        let result = command(.init(enabled: true, limitPercentage: 80, topUpActive: true),
                             native: .init(limit: 80, state: .on))
        #expect(result == .temporarilyDisable)
    }

    @Test func topUpIsIdempotent() {
        let result = command(.init(enabled: true, limitPercentage: 80, topUpActive: true),
                             native: .init(limit: 100, state: .temporarilyDisabled))
        #expect(result == .none)
    }

    @Test func topUpWithNothingArmedHasNothingToDisable() {
        let result = command(.init(enabled: true, limitPercentage: 80, topUpActive: true),
                             native: .init(limit: 100, state: .off))
        #expect(result == .none)
    }

    @Test func topUpOnBatteryPowerFallsThroughToTheOrdinaryLimit() {
        let result = command(.init(enabled: true, limitPercentage: 80, topUpActive: true),
                             plugged: false,
                             native: .init(limit: 100, state: .temporarilyDisabled))
        #expect(result == .setLimit(80))
    }

    // MARK: command — disabled

    @Test func disablingReleasesOnlyALimitThisAppArmed() {
        let armed = NativeLimitSnapshot(limit: 80, state: .on)
        #expect(command(.init(enabled: false), native: armed, owns: true) == .release)
        #expect(command(.init(enabled: false), native: armed, owns: false) == .none)
    }

    @Test func disablingWithNothingArmedStillClearsOwnershipThroughRelease() {
        // 소유 플래그가 남아 있으면 release가 한 번 나가고, 서비스가 그때 플래그를 내린다.
        #expect(command(.init(enabled: false), native: .init(limit: 100, state: .off), owns: true) == .release)
    }
}
```

- [ ] **Step 2: 프로젝트 재생성 후 실패 확인**

Run: `/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml && xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/NativeChargeLimitPlanTests 2>&1 | tail -25`
Expected: 컴파일 실패 — `cannot find 'NativeChargeLimitPlan' in scope`.

- [ ] **Step 3: 구현**

`Wattly/Control/NativeChargeLimitPlan.swift`:

```swift
import Foundation

/// `PowerUISmartChargeClient.isMCLCurrentlyEnabled:`가 돌려주는 원시값. 실측(macOS 27.0,
/// 26A428): 0 = 꺼짐, 1 = 켜짐, 3 = "이번만 완충" 일시 해제. 2와 그 밖의 값은 본 적이 없어
/// 의미를 추측하지 않고 그대로 들고 다닌다.
enum NativeLimitEnabledState: Equatable, Sendable {
    case off
    case on
    case temporarilyDisabled
    case unknown(UInt64)

    init(rawState: UInt64) {
        switch rawState {
        case 0: self = .off
        case 1: self = .on
        case 3: self = .temporarilyDisabled
        default: self = .unknown(rawState)
        }
    }
}

/// 네이티브 제한을 한 번 읽은 결과. `limit`은 일시 해제 중에는 100으로 가려진다 — 사용자가
/// 원한 값은 서비스가 따로 기억한다.
struct NativeLimitSnapshot: Equatable, Sendable {
    var limit: Int
    var state: NativeLimitEnabledState
}

enum NativeLimitCommand: Equatable, Sendable {
    case none
    case setLimit(Int)
    case temporarilyDisable
    /// Wattly가 건 제한을 푼다. 실행은 `setLimit(releaseLimit)`이지만 소유 플래그를 내리는
    /// 부수 효과가 달라 별도 케이스다.
    case release
}

/// 설정과 네이티브 상태를 보고 다음에 쓸 명령 하나를 고른다. 순수 함수 — I/O도 시계도 없다.
enum NativeChargeLimitPlan {
    /// `availableChargeLimitsWithError:`를 못 읽었을 때 쓰는 목록. 실측값 그대로다.
    static let fallbackLimits = [80, 85, 90, 95, 100]
    /// 이 값을 쓰면 네이티브 제한이 스스로 꺼진다(실측: `setMCLLimit:100` → enabled 0).
    static let releaseLimit = 100

    /// 요청값 이상인 최소 허용값. API는 목록 밖 값을 `PowerUISmartChargingErrorDomain Code=4`로
    /// 거부하므로 쓰기 전에 여기서 맞춘다. 내림이 아니라 올림인 이유: 단축어가 70을 요청했을 때
    /// "요청보다 덜 충전"은 이 API로 불가능하고, 가장 가까운 가능한 값은 80이다.
    static func snapped(_ requested: Int, to available: [Int]) -> Int {
        let candidates = available.isEmpty ? fallbackLimits : available
        return candidates.sorted().first { $0 >= requested } ?? releaseLimit
    }

    static func command(
        configuration: BatteryControlConfiguration,
        isPluggedIn: Bool,
        native: NativeLimitSnapshot,
        ownsNativeLimit: Bool,
        availableLimits: [Int]
    ) -> NativeLimitCommand {
        // Top Up은 어댑터가 있어야 의미가 있다. 없으면 평소 제한 경로로 떨어져 제한을 다시 건다 —
        // 일시 해제는 어댑터 분리로도 스스로 풀리지 않기 때문에(실측) 여기서 풀어 줘야 한다.
        if configuration.topUpActive, isPluggedIn {
            return native.state == .on ? .temporarilyDisable : .none
        }
        guard configuration.enabled else {
            return ownsNativeLimit ? .release : .none
        }
        let target = snapped(configuration.clampedLimitPercentage, to: availableLimits)
        if target >= releaseLimit {
            return native.state == .off ? .none : .setLimit(releaseLimit)
        }
        if native.state == .on, native.limit == target { return .none }
        return .setLimit(target)
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/NativeChargeLimitPlanTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`, 16개 통과.

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Control/NativeChargeLimitPlan.swift WattlyTests/NativeChargeLimitPlanTests.swift Wattly.xcodeproj/project.pbxproj
git commit -m "feat(battery): add the pure native charge-limit planner"
```

---

### Task 3: 순수 상태 합성 `NativeChargeLimitStatus`

**Files:**
- Create: `Wattly/Control/NativeChargeLimitStatus.swift`
- Test: `WattlyTests/NativeChargeLimitStatusTests.swift`

**Interfaces:**
- Consumes: Task 1 `BatteryControlBackend`/`controlBackend`, Task 2 `NativeLimitSnapshot`, `NativeChargeLimitPlan.snapped(_:to:)`.
- Produces:
  - `struct NativeLimitBatteryReading: Equatable, Sendable { var percentage: Int; var isPluggedIn: Bool; var batteryMilliamps: Int? }`
  - `enum NativeLimitWriteOutcome: Equatable, Sendable { case none, applied, failed }`
  - `NativeChargeLimitStatus.make(configuration: BatteryControlConfiguration, reading: NativeLimitBatteryReading, native: NativeLimitSnapshot?, availableLimits: [Int], outcome: NativeLimitWriteOutcome, now: TimeInterval) -> BatteryControlServiceStatus` (`lastMaintenance`는 채우지 않는다 — Task 5의 서비스가 채운다)
  - `NativeChargeLimitStatus.powerSourceUnreadable(configuration: BatteryControlConfiguration, now: TimeInterval) -> BatteryControlServiceStatus`

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/NativeChargeLimitStatusTests.swift`:

```swift
import Testing
@testable import Wattly

@Suite struct NativeChargeLimitStatusTests {
    private let limits = [80, 85, 90, 95, 100]
    private let armed80 = NativeLimitSnapshot(limit: 80, state: .on)

    private func make(
        _ configuration: BatteryControlConfiguration,
        pct: Int,
        plugged: Bool = true,
        mA: Int? = 0,
        native: NativeLimitSnapshot?,
        outcome: NativeLimitWriteOutcome = .none
    ) -> BatteryControlServiceStatus {
        NativeChargeLimitStatus.make(
            configuration: configuration,
            reading: .init(percentage: pct, isPluggedIn: plugged, batteryMilliamps: mA),
            native: native,
            availableLimits: limits,
            outcome: outcome,
            now: 1_000)
    }

    @Test func everyStatusCarriesTheFixedFacts() {
        let status = make(.init(enabled: true, limitPercentage: 80), pct: 60, native: armed80)
        #expect(status.controlBackend == .nativeLimit)
        #expect(status.isHardwareSupported == true)
        #expect(status.isDischargeHardwareSupported == false)
        #expect(status.capabilities == [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1])
        #expect(status.desiredConfiguration == BatteryControlConfiguration(enabled: true, limitPercentage: 80).normalized)
        #expect(status.currentPercentage == 60)
        #expect(status.isPowerAdapterConnected == true)
        #expect(status.updatedAt == 1_000)
        #expect(status.mode != .unavailable)
        #expect(status.mode != .unsupported)
    }

    @Test func chargingTowardTheLimit() {
        let status = make(.init(enabled: true, limitPercentage: 80), pct: 60, mA: 4_100, native: armed80)
        #expect(status.activity == .chargingToLimit)
        #expect(status.detailReason == .init(kind: .chargingToTarget, limitPercentage: 80))
        #expect(status.mode == .charging)
        #expect(status.actualGate == .allowed)
        #expect(status.appliedLimitPercentage == 80)
    }

    @Test func holdingAtTheLimit() {
        let status = make(.init(enabled: true, limitPercentage: 80), pct: 80, mA: 0, native: armed80)
        #expect(status.activity == .holdingAtLimit)
        #expect(status.detailReason == .init(kind: .inhibitedAtLimit, limitPercentage: 80))
        #expect(status.mode == .inhibited)
        #expect(status.actualGate == .inhibited(appliedLimitPercentage: 80))
    }

    @Test func firmwareDrainAboveTheLimitReadsAsDischarging() {
        let status = make(.init(enabled: true, limitPercentage: 80), pct: 96, mA: -850, native: armed80)
        #expect(status.activity == .discharging)
        #expect(status.detailReason == .init(kind: .dischargingToTarget, limitPercentage: 80))
        #expect(status.mode == .inhibited)
    }

    @Test func aboveTheLimitWithoutNegativeCurrentIsJustHolding() {
        let status = make(.init(enabled: true, limitPercentage: 80), pct: 96, mA: -40, native: armed80)
        #expect(status.activity == .holdingAtLimit)
        let unknownCurrent = make(.init(enabled: true, limitPercentage: 80), pct: 96, mA: nil, native: armed80)
        #expect(unknownCurrent.activity == .holdingAtLimit)
    }

    @Test func onBatteryPower() {
        let status = make(.init(enabled: true, limitPercentage: 80), pct: 70, plugged: false, mA: -500, native: armed80)
        #expect(status.activity == .onBatteryPower)
        #expect(status.detailReason == .init(kind: .onBatteryPower))
        #expect(status.actualGate == .allowed)
    }

    @Test func disabledLimit() {
        let status = make(.init(enabled: false), pct: 70, native: .init(limit: 100, state: .off))
        #expect(status.activity == .inactive)
        #expect(status.detailReason == .init(kind: .limitDisabled))
        #expect(status.appliedLimitPercentage == nil)
        #expect(status.actualGate == .allowed)
    }

    @Test func topUpChargingThenComplete() {
        let config = BatteryControlConfiguration(enabled: true, limitPercentage: 80, topUpActive: true)
        let tempDisabled = NativeLimitSnapshot(limit: 100, state: .temporarilyDisabled)
        let charging = make(config, pct: 90, mA: 2_800, native: tempDisabled)
        #expect(charging.activity == .topUp)
        #expect(charging.detailReason == .init(kind: .topUpCharging))
        #expect(charging.appliedLimitPercentage == nil)
        let full = make(config, pct: 100, mA: 0, native: tempDisabled)
        #expect(full.activity == .topUp)
        #expect(full.detailReason == .init(kind: .topUpComplete))
        #expect(full.mode == .inhibited)
    }

    @Test func writeFailureWhileEnablingIsApplyFailed() {
        let status = make(.init(enabled: true, limitPercentage: 80), pct: 60,
                          native: .init(limit: 100, state: .off), outcome: .failed)
        #expect(status.detailReason == .init(kind: .applyFailed))
        #expect(status.activity == .inactive)
    }

    @Test func writeFailureWhileDisablingIsReleaseFailed() {
        let status = make(.init(enabled: false), pct: 60, native: armed80, outcome: .failed)
        #expect(status.detailReason == .init(kind: .releaseFailed))
    }

    @Test func unreadableNativeStateIsAReadbackFailure() {
        let status = make(.init(enabled: true, limitPercentage: 80), pct: 60, native: nil)
        #expect(status.detailReason == .init(kind: .hardwareReadbackFailed))
        #expect(status.actualGate == .unreadable)
        #expect(status.appliedLimitPercentage == nil)
    }

    @Test func powerSourceUnreadable() {
        let status = NativeChargeLimitStatus.powerSourceUnreadable(
            configuration: .init(enabled: true, limitPercentage: 80), now: 5)
        #expect(status.detailReason == .init(kind: .powerSourceUnreadable))
        #expect(status.controlBackend == .nativeLimit)
        #expect(status.isHardwareSupported == true)
    }

    // The contract that lets every existing caller work unmodified.

    @Test func anAppliedConfigureIsAcceptedByTheExistingPolicy() {
        let config = BatteryControlConfiguration(enabled: true, limitPercentage: 80).normalized
        var status = make(config, pct: 60, native: armed80, outcome: .applied)
        status.lastMaintenance = .init(trigger: .clientConfiguration, result: .applied, occurredAt: 1_000, reason: nil)
        #expect(BatteryControlPolicy.accepted(configuration: config, by: status))
        #expect(BatteryControlPolicy.shouldReapply(configuration: config, status: status) == false)
        #expect(BatteryControlPolicy.shouldRunInstaller(mode: status.mode) == false)
    }

    @Test func aDisableIsAcceptedBecauseTheGateReadsAllowed() {
        let config = BatteryControlConfiguration(enabled: false).normalized
        var status = make(config, pct: 60, native: .init(limit: 100, state: .off), outcome: .applied)
        status.lastMaintenance = .init(trigger: .clientConfiguration, result: .applied, occurredAt: 1_000, reason: nil)
        #expect(BatteryControlPolicy.accepted(configuration: config, by: status))
    }
}
```

- [ ] **Step 2: 프로젝트 재생성 후 실패 확인**

Run: `/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml && xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/NativeChargeLimitStatusTests 2>&1 | tail -25`
Expected: 컴파일 실패 — `cannot find 'NativeChargeLimitStatus' in scope`.

- [ ] **Step 3: 구현**

`Wattly/Control/NativeChargeLimitStatus.swift`:

```swift
import Foundation

/// 네이티브 백엔드가 한 요청에 필요한 배터리 사실. `batteryMilliamps`는 +충전 / −방전이고,
/// 못 읽으면 `nil`이다(그때는 "방전 중" 표시를 포기하고 "유지 중"으로 본다).
struct NativeLimitBatteryReading: Equatable, Sendable {
    var percentage: Int
    var isPluggedIn: Bool
    var batteryMilliamps: Int?
}

enum NativeLimitWriteOutcome: Equatable, Sendable {
    case none
    case applied
    case failed
}

/// 루트 도우미가 만들던 `BatteryControlServiceStatus`를 네이티브 백엔드용으로 합성한다. 순수 함수.
///
/// 브리지·정책·표시·단축어·스케줄은 이 DTO만 읽는다. 그래서 여기서 도우미와 같은 모양을 내는
/// 것이 "기존 코드를 고치지 않는다"는 설계의 전부다 — 특히 `BatteryControlPolicy.accepted`가
/// 요구하는 `desiredConfiguration`·`actualGate`, 그리고 `shouldReapply`를
/// `desiredConfiguration` 비교 경로로 보내는 세 capability.
enum NativeChargeLimitStatus {
    static let capabilities: [BatteryControlCapability] = [
        .persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1
    ]
    /// 제한 초과 상태에서 펌웨어가 배터리를 끌어 쓰는 중이라고 볼 전류. 실측 drain은
    /// −650~−1000 mA였고 유지 중에는 정확히 0 mA라, −100은 둘 사이의 넉넉한 문턱이다.
    static let drainThresholdMilliamps = -100
    /// `detailReason`이 항상 있으므로 앱은 이 문장을 쓰지 않는다. 구버전 호환 필드를 비워 두지
    /// 않으려는 값일 뿐이다.
    static let detail = "시스템 충전 제한 사용 중"

    static func make(
        configuration: BatteryControlConfiguration,
        reading: NativeLimitBatteryReading,
        native: NativeLimitSnapshot?,
        availableLimits: [Int],
        outcome: NativeLimitWriteOutcome,
        now: TimeInterval
    ) -> BatteryControlServiceStatus {
        let configuration = configuration.normalized
        let applied: Int? = native?.state == .on ? native?.limit : nil
        let limit = applied ?? NativeChargeLimitPlan.snapped(
            configuration.clampedLimitPercentage, to: availableLimits)

        var mode = BatteryControlServiceMode.charging
        var gate = BatteryHardwareGate.allowed
        var activity = BatteryControlActivity.inactive
        var reason: BatteryControlStatusReason

        if native == nil {
            reason = .init(kind: .hardwareReadbackFailed)
            gate = .unreadable
        } else if outcome == .failed {
            let wantsControl = configuration.enabled || configuration.topUpActive
            reason = .init(kind: wantsControl ? .applyFailed : .releaseFailed)
        } else if !configuration.enabled, !configuration.topUpActive {
            reason = .init(kind: .limitDisabled)
        } else if !reading.isPluggedIn {
            reason = .init(kind: .onBatteryPower)
            activity = .onBatteryPower
        } else if configuration.topUpActive {
            let isFull = reading.percentage >= 100
            reason = .init(kind: isFull ? .topUpComplete : .topUpCharging)
            activity = .topUp
            if isFull {
                mode = .inhibited
                gate = .inhibited(appliedLimitPercentage: nil)
            }
        } else if reading.percentage > limit,
                  let milliamps = reading.batteryMilliamps,
                  milliamps <= drainThresholdMilliamps {
            reason = .init(kind: .dischargingToTarget, limitPercentage: limit)
            activity = .discharging
            mode = .inhibited
            gate = .inhibited(appliedLimitPercentage: limit)
        } else if reading.percentage >= limit {
            reason = .init(kind: .inhibitedAtLimit, limitPercentage: limit)
            activity = .holdingAtLimit
            mode = .inhibited
            gate = .inhibited(appliedLimitPercentage: limit)
        } else {
            reason = .init(kind: .chargingToTarget, limitPercentage: limit)
            activity = .chargingToLimit
        }

        return BatteryControlServiceStatus(
            mode: mode,
            currentPercentage: reading.percentage,
            isPowerAdapterConnected: reading.isPluggedIn,
            detail: detail,
            updatedAt: now,
            appliedLimitPercentage: applied,
            isHardwareSupported: true,
            isDischargeHardwareSupported: false,
            detailReason: reason,
            activity: activity,
            desiredConfiguration: configuration,
            actualGate: gate,
            capabilities: capabilities,
            controlBackend: .nativeLimit)
    }

    static func powerSourceUnreadable(
        configuration: BatteryControlConfiguration,
        now: TimeInterval
    ) -> BatteryControlServiceStatus {
        BatteryControlServiceStatus(
            mode: .charging,
            currentPercentage: 0,
            isPowerAdapterConnected: false,
            detail: detail,
            updatedAt: now,
            isHardwareSupported: true,
            isDischargeHardwareSupported: false,
            detailReason: .init(kind: .powerSourceUnreadable),
            activity: .inactive,
            desiredConfiguration: configuration.normalized,
            actualGate: .unreadable,
            capabilities: capabilities,
            controlBackend: .nativeLimit)
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/NativeChargeLimitStatusTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`, 14개 통과.

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Control/NativeChargeLimitStatus.swift WattlyTests/NativeChargeLimitStatusTests.swift Wattly.xcodeproj/project.pbxproj
git commit -m "feat(battery): synthesize the service status for the native charge-limit backend"
```

---

### Task 4: PowerUI 드라이버

**Files:**
- Create: `Wattly/Control/NativeChargeLimitDriver.swift`
- Create: `WattlyTests/FakeNativeChargeLimitDriver.swift` (Task 5가 쓴다)
- Test: `WattlyTests/NativeChargeLimitDriverTests.swift`

**Interfaces:**
- Consumes: Task 2 `NativeLimitSnapshot`, `NativeLimitEnabledState`.
- Produces:
  - `enum NativeChargeLimitError: Error, Equatable { case unavailable; case callFailed(selector: String, code: Int) }`
  - `protocol NativeChargeLimitDriving: Sendable { var isSupported: Bool { get }; func availableLimits() throws -> [Int]; func snapshot() throws -> NativeLimitSnapshot; func setLimit(_ percentage: Int) throws; func temporarilyDisable() throws }`
  - `final class PowerUIChargeLimitDriver: NativeChargeLimitDriving` — `init(clientName: String = "Wattly", frameworkPath: String = PowerUIChargeLimitDriver.defaultFrameworkPath)`
  - 테스트 전용 `final class FakeNativeChargeLimitDriver: NativeChargeLimitDriving` — `var isSupported`, `var limits`, `var current: NativeLimitSnapshot`, `var writes: [String]`, `var failWrites`, `var failReads`

이 드라이버의 호출 방식(`@convention(c)` IMP 캐스트)은 2026-09-17에 Swift 6 모드(`swiftc -swift-version 6`)로 경고 없이 컴파일되고, 실기에서 `availableLimits = [80, 85, 90, 95, 100]`, `currentLimit = 80`, `enabledState = on`을 돌려주는 것을 확인했다. **상태를 바꾸는 호출(`setLimit`, `temporarilyDisable`)은 단위 테스트에서 절대 실제 드라이버로 부르지 않는다.**

- [ ] **Step 1: 실패하는 테스트 + 가짜 드라이버 작성**

`WattlyTests/FakeNativeChargeLimitDriver.swift`:

```swift
import Foundation
@testable import Wattly

/// 네이티브 제한을 흉내 내는 테스트 더블. 실측 거동을 그대로 옮겼다: 목록 밖 값은 Code 4로
/// 거부, 100은 스스로 꺼짐, 일시 해제 중 제한은 100으로 가려짐.
final class FakeNativeChargeLimitDriver: NativeChargeLimitDriving, @unchecked Sendable {
    var isSupported = true
    var limits = [80, 85, 90, 95, 100]
    var current = NativeLimitSnapshot(limit: 100, state: .off)
    var writes: [String] = []
    var failWrites = false
    var failReads = false

    func availableLimits() throws -> [Int] {
        if failReads { throw NativeChargeLimitError.unavailable }
        return limits
    }

    func snapshot() throws -> NativeLimitSnapshot {
        if failReads { throw NativeChargeLimitError.unavailable }
        return current
    }

    func setLimit(_ percentage: Int) throws {
        if failWrites { throw NativeChargeLimitError.callFailed(selector: "setMCLLimit:error:", code: 1) }
        guard limits.contains(percentage) else {
            throw NativeChargeLimitError.callFailed(selector: "setMCLLimit:error:", code: 4)
        }
        writes.append("set:\(percentage)")
        current = .init(limit: percentage, state: percentage >= 100 ? .off : .on)
    }

    func temporarilyDisable() throws {
        if failWrites { throw NativeChargeLimitError.callFailed(selector: "temporarilyDisableMCL:", code: 1) }
        writes.append("tempDisable")
        current = .init(limit: 100, state: .temporarilyDisabled)
    }
}
```

`WattlyTests/NativeChargeLimitDriverTests.swift`:

```swift
import Testing
@testable import Wattly

@Suite struct NativeChargeLimitDriverTests {
    /// 프레임워크를 못 찾는 Mac(구형 macOS, 애플이 경로를 옮긴 미래)에서 드라이버는 조용히
    /// "미지원"이어야 한다 — 백엔드 선택기가 이 값 하나로 SMC 경로로 물러난다.
    @Test func missingFrameworkMeansUnsupportedAndEveryCallThrows() {
        let driver = PowerUIChargeLimitDriver(frameworkPath: "/nonexistent/PowerUI.framework/PowerUI")
        #expect(driver.isSupported == false)
        #expect(throws: NativeChargeLimitError.unavailable) { try driver.availableLimits() }
        #expect(throws: NativeChargeLimitError.unavailable) { try driver.snapshot() }
        #expect(throws: NativeChargeLimitError.unavailable) { try driver.setLimit(80) }
        #expect(throws: NativeChargeLimitError.unavailable) { try driver.temporarilyDisable() }
    }

    @Test func fakeDriverRejectsOffListValuesLikeTheRealOne() {
        let fake = FakeNativeChargeLimitDriver()
        #expect(throws: NativeChargeLimitError.callFailed(selector: "setMCLLimit:error:", code: 4)) {
            try fake.setLimit(70)
        }
        #expect(fake.writes.isEmpty)
    }

    @Test func fakeDriverTurnsItselfOffAtOneHundred() throws {
        let fake = FakeNativeChargeLimitDriver()
        try fake.setLimit(80)
        #expect(fake.current == .init(limit: 80, state: .on))
        try fake.setLimit(100)
        #expect(fake.current == .init(limit: 100, state: .off))
    }
}
```

- [ ] **Step 2: 프로젝트 재생성 후 실패 확인**

Run: `/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml && xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/NativeChargeLimitDriverTests 2>&1 | tail -25`
Expected: 컴파일 실패 — `cannot find type 'NativeChargeLimitDriving' in scope`.

- [ ] **Step 3: 구현**

`Wattly/Control/NativeChargeLimitDriver.swift`:

```swift
import Foundation

enum NativeChargeLimitError: Error, Equatable {
    /// 프레임워크·클래스·셀렉터 중 하나가 없다. 이 Mac에서는 네이티브 백엔드를 쓸 수 없다.
    case unavailable
    /// 호출은 됐지만 실패했다. `code`는 `PowerUISmartChargingErrorDomain`의 코드(목록 밖 값 = 4),
    /// NSError 없이 `NO`만 돌아오면 -1.
    case callFailed(selector: String, code: Int)
}

/// 애플 네이티브 충전 제한에 대한 최소 인터페이스. 서비스와 테스트가 이 뒤에서만 I/O를 본다.
protocol NativeChargeLimitDriving: Sendable {
    var isSupported: Bool { get }
    func availableLimits() throws -> [Int]
    func snapshot() throws -> NativeLimitSnapshot
    func setLimit(_ percentage: Int) throws
    func temporarilyDisable() throws
}

/// 비공개 `PowerUI.framework`의 `PowerUISmartChargeClient`를 ObjC 런타임으로 부른다.
///
/// 헤더도 링크도 없다. `dlopen`으로 올리고 `NSClassFromString`으로 찾은 뒤, 필요한 셀렉터
/// 여섯 개가 **전부** 응답할 때만 `client`를 갖는다. 하나라도 빠지면 `client == nil`이고 모든
/// 호출이 `.unavailable`을 던진다 — 애플이 이 비공개 API를 바꾸는 날, 앱은 크래시가 아니라
/// "이 Mac은 지원되지 않음"으로 떨어져야 한다.
///
/// 타입 인코딩은 macOS 27.0(26A428)에서 `method_getTypeEncoding`으로 읽은 값이다:
/// `getMCLLimitWithError:` = `C24@0:8^@16`(UInt8), `isMCLCurrentlyEnabled:` = `Q24@0:8^@16`(UInt64),
/// `setMCLLimit:error:` = `B28@0:8C16^@20`, `temporarilyDisableMCL:` = `B24@0:8^@16`,
/// `availableChargeLimitsWithError:` = `@24@0:8^@16`, `isMCLSupported` = `B16@0:8`.
///
/// `@unchecked Sendable`: `client`는 불변이고 호출은 전부 `NativeChargeLimitService` actor 안에서
/// 직렬로 일어난다. 각 호출은 `PowerUIAgent`로 가는 동기 XPC 왕복이므로 메인 스레드에서 부르지 않는다.
final class PowerUIChargeLimitDriver: NativeChargeLimitDriving, @unchecked Sendable {
    static let defaultFrameworkPath = "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI"

    private typealias ErrorPointer = AutoreleasingUnsafeMutablePointer<NSError?>?
    private static let requiredSelectors = [
        "isMCLSupported", "availableChargeLimitsWithError:", "getMCLLimitWithError:",
        "isMCLCurrentlyEnabled:", "setMCLLimit:error:", "temporarilyDisableMCL:"
    ]

    private let client: NSObject?

    init(clientName: String = "Wattly", frameworkPath: String = PowerUIChargeLimitDriver.defaultFrameworkPath) {
        guard dlopen(frameworkPath, RTLD_NOW) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type,
              // `alloc`의 +1은 `init…`이 소비하므로 여기서는 소유권을 가져오지 않는다.
              let allocated = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              let instance = allocated.perform(NSSelectorFromString("initWithClientName:"), with: clientName)?
                  .takeRetainedValue() as? NSObject,
              Self.requiredSelectors.allSatisfy({ instance.responds(to: NSSelectorFromString($0)) })
        else {
            client = nil
            return
        }
        client = instance
    }

    var isSupported: Bool {
        guard let client else { return false }
        let sel = NSSelectorFromString("isMCLSupported")
        let fn = unsafeBitCast(client.method(for: sel), to: (@convention(c) (AnyObject, Selector) -> Bool).self)
        return fn(client, sel)
    }

    func availableLimits() throws -> [Int] {
        let name = "availableChargeLimitsWithError:"
        let (client, sel) = try target(name)
        let fn = unsafeBitCast(
            client.method(for: sel),
            to: (@convention(c) (AnyObject, Selector, ErrorPointer) -> Unmanaged<AnyObject>?).self)
        var error: NSError?
        let result = fn(client, sel, &error)?.takeUnretainedValue()
        if let error { throw NativeChargeLimitError.callFailed(selector: name, code: error.code) }
        return ((result as? [NSNumber]) ?? []).map(\.intValue).sorted()
    }

    func snapshot() throws -> NativeLimitSnapshot {
        NativeLimitSnapshot(limit: try currentLimit(), state: try enabledState())
    }

    func setLimit(_ percentage: Int) throws {
        let name = "setMCLLimit:error:"
        let (client, sel) = try target(name)
        let fn = unsafeBitCast(
            client.method(for: sel),
            to: (@convention(c) (AnyObject, Selector, UInt8, ErrorPointer) -> Bool).self)
        var error: NSError?
        let ok = fn(client, sel, UInt8(clamping: percentage), &error)
        guard ok, error == nil else {
            throw NativeChargeLimitError.callFailed(selector: name, code: error?.code ?? -1)
        }
    }

    func temporarilyDisable() throws {
        let name = "temporarilyDisableMCL:"
        let (client, sel) = try target(name)
        let fn = unsafeBitCast(
            client.method(for: sel),
            to: (@convention(c) (AnyObject, Selector, ErrorPointer) -> Bool).self)
        var error: NSError?
        let ok = fn(client, sel, &error)
        guard ok, error == nil else {
            throw NativeChargeLimitError.callFailed(selector: name, code: error?.code ?? -1)
        }
    }

    private func currentLimit() throws -> Int {
        let name = "getMCLLimitWithError:"
        let (client, sel) = try target(name)
        let fn = unsafeBitCast(
            client.method(for: sel),
            to: (@convention(c) (AnyObject, Selector, ErrorPointer) -> UInt8).self)
        var error: NSError?
        let value = fn(client, sel, &error)
        if let error { throw NativeChargeLimitError.callFailed(selector: name, code: error.code) }
        return Int(value)
    }

    private func enabledState() throws -> NativeLimitEnabledState {
        let name = "isMCLCurrentlyEnabled:"
        let (client, sel) = try target(name)
        let fn = unsafeBitCast(
            client.method(for: sel),
            to: (@convention(c) (AnyObject, Selector, ErrorPointer) -> UInt64).self)
        var error: NSError?
        let value = fn(client, sel, &error)
        if let error { throw NativeChargeLimitError.callFailed(selector: name, code: error.code) }
        return NativeLimitEnabledState(rawState: value)
    }

    private func target(_ selector: String) throws -> (NSObject, Selector) {
        guard let client else { throw NativeChargeLimitError.unavailable }
        return (client, NSSelectorFromString(selector))
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/NativeChargeLimitDriverTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`, 3개 통과, 새 파일에 경고 0.

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Control/NativeChargeLimitDriver.swift WattlyTests/FakeNativeChargeLimitDriver.swift WattlyTests/NativeChargeLimitDriverTests.swift Wattly.xcodeproj/project.pbxproj
git commit -m "feat(battery): drive Apple's native charge limit through PowerUI behind a protocol"
```

---

### Task 5: 전역 서비스 `NativeChargeLimitService`

**Files:**
- Create: `Wattly/Control/NativeChargeLimitService.swift`
- Modify: `Wattly/Settings/Settings.swift` (`StorageKey`의 `batteryCalibrationHistory` 줄 아래)
- Test: `WattlyTests/NativeChargeLimitServiceTests.swift`

**Interfaces:**
- Consumes: Task 2 `NativeChargeLimitPlan.command/fallbackLimits/releaseLimit`, Task 3 `NativeChargeLimitStatus.make/powerSourceUnreadable`, `NativeLimitBatteryReading`, `NativeLimitWriteOutcome`, Task 4 `NativeChargeLimitDriving`, 기존 `BatteryTopUpExpiry.decide(topUpActive:isHoldingAtFull:reachedFullAt:now:)`, `BatteryControlClient.BatteryControlClientRequest`, `BatteryControlConfigurationRequest`, `BatteryControlCodec`.
- Produces:
  - `actor NativeChargeLimitService`
  - `typealias NativeChargeLimitService.Reader = @Sendable () -> NativeLimitBatteryReading?`
  - `init(driver: any NativeChargeLimitDriving, reader: @escaping Reader, defaults: UserDefaults, now: @escaping @Sendable () -> TimeInterval)`
  - `func handle(_ request: BatteryControlClient.BatteryControlClientRequest) -> (Data?, NSError?)`
  - `func process(_ request: BatteryControlClient.BatteryControlClientRequest) -> BatteryControlServiceStatus`
  - `StorageKey.nativeLimitDesiredConfiguration`, `.nativeLimitTopUpReachedFullAt`, `.nativeLimitOwned`

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/NativeChargeLimitServiceTests.swift`:

```swift
import Foundation
import Testing
@testable import Wattly

@Suite struct NativeChargeLimitServiceTests {
    /// 테스트가 바꿔 끼우는 세계. 서비스는 `@Sendable` 클로저로만 읽는다.
    private final class World: @unchecked Sendable {
        var reading: NativeLimitBatteryReading? = .init(percentage: 60, isPluggedIn: true, batteryMilliamps: 4_000)
        var now: TimeInterval = 1_000_000
    }

    private struct Rig {
        let service: NativeChargeLimitService
        let driver: FakeNativeChargeLimitDriver
        let world: World
        let defaults: UserDefaults
    }

    private func rig(defaults: UserDefaults? = nil, driver: FakeNativeChargeLimitDriver? = nil) -> Rig {
        let defaults = defaults ?? UserDefaults(suiteName: "native-limit-\(UUID().uuidString)")!
        let driver = driver ?? FakeNativeChargeLimitDriver()
        let world = World()
        let service = NativeChargeLimitService(
            driver: driver,
            reader: { world.reading },
            defaults: defaults,
            now: { world.now })
        return Rig(service: service, driver: driver, world: world, defaults: defaults)
    }

    private func configure(_ configuration: BatteryControlConfiguration) throws -> BatteryControlClient.BatteryControlClientRequest {
        .configure(try BatteryControlCodec.encode(
            BatteryControlConfigurationRequest(configuration: configuration, generation: 1)))
    }

    @Test func enablingArmsTheNativeLimitAndIsAcceptedByTheExistingPolicy() async throws {
        let r = rig()
        let config = BatteryControlConfiguration(enabled: true, limitPercentage: 80).normalized
        let status = await r.service.process(try configure(config))
        #expect(r.driver.writes == ["set:80"])
        #expect(status.appliedLimitPercentage == 80)
        #expect(status.lastMaintenance?.trigger == .clientConfiguration)
        #expect(status.lastMaintenance?.result == .applied)
        #expect(BatteryControlPolicy.accepted(configuration: config, by: status))
        #expect(r.defaults.bool(forKey: StorageKey.nativeLimitOwned))
    }

    @Test func handleReturnsADecodableStatus() async throws {
        let r = rig()
        let (data, error) = await r.service.handle(.status)
        #expect(error == nil)
        let decoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: try #require(data))
        #expect(decoded.controlBackend == .nativeLimit)
    }

    @Test func aSecondIdenticalConfigureWritesNothingAndReportsVerified() async throws {
        let r = rig()
        let config = BatteryControlConfiguration(enabled: true, limitPercentage: 80)
        _ = await r.service.process(try configure(config))
        let status = await r.service.process(try configure(config))
        #expect(r.driver.writes == ["set:80"])
        #expect(status.lastMaintenance?.result == .verified)
        #expect(BatteryControlPolicy.accepted(configuration: config.normalized, by: status))
    }

    @Test func aStatusTickRearmsAfterSomeoneElseChangedTheLimit() async throws {
        let r = rig()
        _ = await r.service.process(try configure(.init(enabled: true, limitPercentage: 80)))
        r.driver.current = .init(limit: 95, state: .on)   // 시스템 설정에서 바꿨다
        let status = await r.service.process(.status)
        #expect(r.driver.writes == ["set:80", "set:80"])
        #expect(status.appliedLimitPercentage == 80)
    }

    @Test func offListRequestIsRoundedUpAndReported() async throws {
        let r = rig()
        let status = await r.service.process(try configure(.init(enabled: true, limitPercentage: 70)))
        #expect(r.driver.writes == ["set:80"])
        #expect(status.appliedLimitPercentage == 80)
    }

    @Test func disablingReleasesOnlyWhatThisAppArmed() async throws {
        let owned = rig()
        _ = await owned.service.process(try configure(.init(enabled: true, limitPercentage: 80)))
        let released = await owned.service.process(try configure(.init(enabled: false)))
        #expect(owned.driver.writes == ["set:80", "set:100"])
        #expect(owned.defaults.bool(forKey: StorageKey.nativeLimitOwned) == false)
        #expect(BatteryControlPolicy.accepted(configuration: BatteryControlConfiguration(enabled: false).normalized, by: released))

        let foreignDriver = FakeNativeChargeLimitDriver()
        foreignDriver.current = .init(limit: 90, state: .on)   // 사용자가 시스템 설정에서 직접 건 제한
        let foreign = rig(driver: foreignDriver)
        _ = await foreign.service.process(try configure(.init(enabled: false)))
        #expect(foreignDriver.writes.isEmpty)
        #expect(foreignDriver.current == .init(limit: 90, state: .on))
    }

    @Test func topUpDisablesTemporarilyAndUnpluggingEndsItAndRearms() async throws {
        let r = rig()
        _ = await r.service.process(try configure(.init(enabled: true, limitPercentage: 80)))
        let topUp = await r.service.process(try configure(.init(enabled: true, limitPercentage: 80, topUpActive: true)))
        #expect(r.driver.writes == ["set:80", "tempDisable"])
        #expect(topUp.activity == .topUp)
        #expect(topUp.desiredConfiguration?.topUpActive == true)

        r.world.reading = .init(percentage: 92, isPluggedIn: false, batteryMilliamps: -600)
        let unplugged = await r.service.process(.status)
        #expect(unplugged.desiredConfiguration?.topUpActive == false)
        #expect(unplugged.lastMaintenance?.trigger == .adapterTransition)
        #expect(r.driver.writes == ["set:80", "tempDisable", "set:80"])
    }

    @Test func topUpExpiresTwelveHoursAfterReachingFull() async throws {
        let r = rig()
        _ = await r.service.process(try configure(.init(enabled: true, limitPercentage: 80)))
        _ = await r.service.process(try configure(.init(enabled: true, limitPercentage: 80, topUpActive: true)))

        r.world.reading = .init(percentage: 100, isPluggedIn: true, batteryMilliamps: 0)
        let stamped = await r.service.process(.status)
        #expect(stamped.desiredConfiguration?.topUpActive == true)
        #expect(r.defaults.double(forKey: StorageKey.nativeLimitTopUpReachedFullAt) == 1_000_000)

        r.world.now += BatteryTopUpExpiry.duration - 1
        let stillOn = await r.service.process(.status)
        #expect(stillOn.desiredConfiguration?.topUpActive == true)

        r.world.now += 1
        let expired = await r.service.process(.status)
        #expect(expired.desiredConfiguration?.topUpActive == false)
        #expect(expired.lastMaintenance?.trigger == .topUpExpired)
        #expect(r.driver.writes.last == "set:80")
        #expect(r.defaults.object(forKey: StorageKey.nativeLimitTopUpReachedFullAt) == nil)
    }

    @Test func cancellingTopUpDropsTheClockAndRearms() async throws {
        let r = rig()
        _ = await r.service.process(try configure(.init(enabled: true, limitPercentage: 80, topUpActive: true)))
        r.world.reading = .init(percentage: 100, isPluggedIn: true, batteryMilliamps: 0)
        _ = await r.service.process(.status)
        _ = await r.service.process(try configure(.init(enabled: true, limitPercentage: 80)))
        #expect(r.defaults.object(forKey: StorageKey.nativeLimitTopUpReachedFullAt) == nil)
        #expect(r.driver.current == .init(limit: 80, state: .on))
    }

    @Test func aRelaunchedServiceRemembersThePolicyAndFinishesAnExpiredTopUp() async throws {
        let defaults = UserDefaults(suiteName: "native-limit-\(UUID().uuidString)")!
        let driver = FakeNativeChargeLimitDriver()
        let first = rig(defaults: defaults, driver: driver)
        _ = await first.service.process(try configure(.init(enabled: true, limitPercentage: 85, topUpActive: true)))
        first.world.reading = .init(percentage: 100, isPluggedIn: true, batteryMilliamps: 0)
        _ = await first.service.process(.status)

        let second = rig(defaults: defaults, driver: driver)   // 앱 재실행
        second.world.reading = .init(percentage: 100, isPluggedIn: true, batteryMilliamps: 0)
        second.world.now = 1_000_000 + BatteryTopUpExpiry.duration
        let status = await second.service.process(.status)
        #expect(status.desiredConfiguration?.limitPercentage == 85)
        #expect(status.desiredConfiguration?.topUpActive == false)
        #expect(driver.current == .init(limit: 85, state: .on))
    }

    @Test func aFailedWriteIsReportedAndNotAccepted() async throws {
        let r = rig()
        r.driver.failWrites = true
        let config = BatteryControlConfiguration(enabled: true, limitPercentage: 80).normalized
        let status = await r.service.process(try configure(config))
        #expect(status.lastMaintenance?.result == .failed)
        #expect(status.detailReason == .init(kind: .applyFailed))
        #expect(BatteryControlPolicy.accepted(configuration: config, by: status) == false)
        #expect(r.defaults.bool(forKey: StorageKey.nativeLimitOwned) == false)
    }

    @Test func unreadableNativeStateWritesNothing() async throws {
        let r = rig()
        r.driver.failReads = true
        let status = await r.service.process(try configure(.init(enabled: true, limitPercentage: 80)))
        #expect(r.driver.writes.isEmpty)
        #expect(status.detailReason == .init(kind: .hardwareReadbackFailed))
    }

    @Test func unreadablePowerSourceWritesNothing() async throws {
        let r = rig()
        r.world.reading = nil
        let status = await r.service.process(try configure(.init(enabled: true, limitPercentage: 80)))
        #expect(r.driver.writes.isEmpty)
        #expect(status.detailReason == .init(kind: .powerSourceUnreadable))
        #expect(status.desiredConfiguration?.enabled == true)
    }

    @Test func anUndecodableConfigureIsAFailedMaintenanceAndKeepsThePreviousPolicy() async throws {
        let r = rig()
        _ = await r.service.process(try configure(.init(enabled: true, limitPercentage: 80)))
        let status = await r.service.process(.configure(Data("not json".utf8)))
        #expect(status.lastMaintenance?.result == .failed)
        #expect(status.desiredConfiguration?.limitPercentage == 80)
    }
}
```

- [ ] **Step 2: 프로젝트 재생성 후 실패 확인**

Run: `/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml && xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/NativeChargeLimitServiceTests 2>&1 | tail -25`
Expected: 컴파일 실패 — `cannot find 'NativeChargeLimitService' in scope`, `type 'StorageKey' has no member 'nativeLimitOwned'`.

- [ ] **Step 3: 저장 키 추가**

`Wattly/Settings/Settings.swift`의 `enum StorageKey` 안, `static let batteryCalibrationHistory = "batteryCalibrationHistory"` 줄 바로 아래에 추가:

```swift
    // 네이티브 충전 제한 백엔드(macOS 27)의 서비스 상태. 환경설정이 아니므로 `Defaults`에도
    // `SettingsReset`에도 넣지 않는다 — 초기화가 `batteryLimitEnabled`를 끄면 브리지가 disable을
    // 밀어 서비스가 스스로 푼다.
    static let nativeLimitDesiredConfiguration = "nativeLimitDesiredConfiguration"
    static let nativeLimitTopUpReachedFullAt = "nativeLimitTopUpReachedFullAt"
    static let nativeLimitOwned = "nativeLimitOwned"
```

- [ ] **Step 4: 서비스 구현**

`Wattly/Control/NativeChargeLimitService.swift`:

```swift
import Foundation

/// macOS 27에서 루트 도우미 대신 충전 제한 요청에 답하는 앱 안 서비스.
///
/// `BatteryControlClient`의 요청 계약을 그대로 말한다(`.configure(Data)` / `.status` → 인코딩된
/// `BatteryControlServiceStatus`). 그래서 브리지·정책·표시·단축어·스케줄은 자기가 도우미와
/// 말하는지 이 서비스와 말하는지 모른다.
///
/// **모든 요청이 조정 패스다.** 네이티브 상태를 읽고, 저장된 정책과 다르면 다시 쓴다. 도우미는
/// 5초 타이머로 스스로 돌지만 이 서비스는 타이머가 없다 — 앱의 60초 reconcile 루프와 설정 창의
/// 5초 상태 폴링이 곧 박동이다. 앱이 꺼져 있는 동안은 펌웨어가 제한을 쥐고 있으므로 놓치는 것은
/// Top Up 만료뿐이고, 그건 다음 실행의 첫 요청에서 처리된다.
///
/// actor인 이유: PowerUI 호출은 `PowerUIAgent`로 가는 동기 XPC라 메인 스레드에서 부르면 안 되고,
/// 단축어는 호출마다 새 `BatteryControlClient`를 만들므로 상태를 클라이언트가 들고 있을 수 없다.
actor NativeChargeLimitService {
    typealias Reader = @Sendable () -> NativeLimitBatteryReading?

    private let driver: any NativeChargeLimitDriving
    private let reader: Reader
    private let defaults: UserDefaults
    private let now: @Sendable () -> TimeInterval
    private var lastMaintenance: BatteryMaintenanceRecord?
    private var hasHandledRequest = false

    init(
        driver: any NativeChargeLimitDriving,
        reader: @escaping Reader,
        defaults: UserDefaults,
        now: @escaping @Sendable () -> TimeInterval
    ) {
        self.driver = driver
        self.reader = reader
        self.defaults = defaults
        self.now = now
    }

    func handle(_ request: BatteryControlClient.BatteryControlClientRequest) -> (Data?, NSError?) {
        do {
            return (try BatteryControlCodec.encode(process(request)), nil)
        } catch {
            return (nil, error as NSError)
        }
    }

    func process(_ request: BatteryControlClient.BatteryControlClientRequest) -> BatteryControlServiceStatus {
        var configuration = storedConfiguration()
        // 프로세스의 첫 요청은 "서비스가 올라와 정책을 다시 세웠다"로 기록한다.
        var trigger: BatteryMaintenanceTrigger? = hasHandledRequest ? nil : .startup
        hasHandledRequest = true
        var decodeFailed = false

        if case .configure(let data) = request {
            trigger = .clientConfiguration
            if let decoded = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data) {
                let incoming = decoded.configuration.normalized
                // 새로 시작하는 Top Up은 새 시계를 갖고, 끝난 Top Up은 시계를 버린다. 진행 중인
                // Top Up 위로 같은 설정이 다시 오면(60초 reconcile) 시계를 건드리지 않는다.
                if !incoming.topUpActive || !configuration.topUpActive { setReachedFullAt(nil) }
                configuration = incoming
                store(configuration)
            } else {
                decodeFailed = true
            }
        }

        guard let reading = reader() else {
            return NativeChargeLimitStatus.powerSourceUnreadable(configuration: configuration, now: now())
        }

        if configuration.topUpActive {
            if !reading.isPluggedIn {
                // 도우미와 같은 규칙: 어댑터 분리는 Top Up의 종료 사유다.
                configuration.topUpActive = false
                setReachedFullAt(nil)
                store(configuration)
                trigger = trigger ?? .adapterTransition
            } else {
                switch BatteryTopUpExpiry.decide(
                    topUpActive: true,
                    isHoldingAtFull: reading.percentage >= 100,
                    reachedFullAt: reachedFullAt(),
                    now: now()
                ) {
                case .none:
                    break
                case .stamp(let moment):
                    setReachedFullAt(moment)
                case .expire:
                    configuration.topUpActive = false
                    setReachedFullAt(nil)
                    store(configuration)
                    trigger = .topUpExpired
                }
            }
        }

        let listed = (try? driver.availableLimits()) ?? []
        let availableLimits = listed.isEmpty ? NativeChargeLimitPlan.fallbackLimits : listed
        var snapshot = try? driver.snapshot()
        var outcome = NativeLimitWriteOutcome.none

        if let current = snapshot {
            let command = NativeChargeLimitPlan.command(
                configuration: configuration,
                isPluggedIn: reading.isPluggedIn,
                native: current,
                ownsNativeLimit: defaults.bool(forKey: StorageKey.nativeLimitOwned),
                availableLimits: availableLimits)
            do {
                switch command {
                case .none:
                    break
                case .setLimit(let percentage):
                    try driver.setLimit(percentage)
                    defaults.set(percentage < NativeChargeLimitPlan.releaseLimit, forKey: StorageKey.nativeLimitOwned)
                    outcome = .applied
                case .temporarilyDisable:
                    try driver.temporarilyDisable()
                    outcome = .applied
                case .release:
                    try driver.setLimit(NativeChargeLimitPlan.releaseLimit)
                    defaults.set(false, forKey: StorageKey.nativeLimitOwned)
                    outcome = .applied
                }
            } catch {
                outcome = .failed
            }
            if outcome == .applied { snapshot = try? driver.snapshot() }
        }

        var status = NativeChargeLimitStatus.make(
            configuration: configuration,
            reading: reading,
            native: snapshot,
            availableLimits: availableLimits,
            outcome: outcome,
            now: now())

        // 요청이 없던 쓰기(상태 폴링 중 자가 복구)는 `.startup`으로 남긴다 — "서비스가 정책을
        // 다시 세웠다"는 뜻으로 도우미가 쓰는 것과 같은 의미다.
        if let effectiveTrigger = trigger ?? (outcome == .none ? nil : .startup) {
            let failed = decodeFailed || outcome == .failed || snapshot == nil
            lastMaintenance = BatteryMaintenanceRecord(
                trigger: effectiveTrigger,
                result: failed ? .failed : (outcome == .applied ? .applied : .verified),
                occurredAt: now(),
                reason: failed ? status.detailReason : nil)
        }
        status.lastMaintenance = lastMaintenance
        return status
    }

    // MARK: - Persistence

    private func storedConfiguration() -> BatteryControlConfiguration {
        guard let data = defaults.data(forKey: StorageKey.nativeLimitDesiredConfiguration),
              let decoded = try? BatteryControlCodec.decode(BatteryControlConfiguration.self, from: data)
        else { return BatteryControlConfiguration() }
        return decoded.normalized
    }

    private func store(_ configuration: BatteryControlConfiguration) {
        guard let data = try? BatteryControlCodec.encode(configuration) else { return }
        defaults.set(data, forKey: StorageKey.nativeLimitDesiredConfiguration)
    }

    private func reachedFullAt() -> TimeInterval? {
        defaults.object(forKey: StorageKey.nativeLimitTopUpReachedFullAt) as? TimeInterval
    }

    private func setReachedFullAt(_ moment: TimeInterval?) {
        if let moment {
            defaults.set(moment, forKey: StorageKey.nativeLimitTopUpReachedFullAt)
        } else {
            defaults.removeObject(forKey: StorageKey.nativeLimitTopUpReachedFullAt)
        }
    }
}
```

- [ ] **Step 5: 통과 확인**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/NativeChargeLimitServiceTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`, 14개 통과.

- [ ] **Step 6: 커밋**

```bash
git add Wattly/Control/NativeChargeLimitService.swift Wattly/Settings/Settings.swift WattlyTests/NativeChargeLimitServiceTests.swift Wattly.xcodeproj/project.pbxproj
git commit -m "feat(battery): add the in-app native charge-limit service"
```

---

### Task 6: 배터리 리더 + 백엔드 선택기 + 클라이언트 라우팅

**Files:**
- Create: `Wattly/Control/NativeLimitBatteryReader.swift`
- Create: `Wattly/Control/BatteryControlBackendSelector.swift`
- Modify: `Wattly/Control/BatteryControlClient.swift` (기본 `requestHandler` 클로저, 현재 69–76행 부근)
- Test: `WattlyTests/BatteryControlBackendSelectorTests.swift`

**Interfaces:**
- Consumes: Task 3 `NativeLimitBatteryReading`, Task 4 `PowerUIChargeLimitDriver`, Task 5 `NativeChargeLimitService.init(driver:reader:defaults:now:)`/`handle(_:)`, 기존 `BatteryControlKeys.runtimeDrivableRegisterProbe(probing:)`, `BatteryControlKeyProbeResult.fromSMCKeyInfo(kernelSucceeded:smcResult:type:size:)`, `SMCConnection.probeKeyInfo(_:)`/`SMCConnection.string(_:)`.
- Produces:
  - `NativeLimitBatteryReader.read() -> NativeLimitBatteryReading?`
  - `NativeLimitBatteryReader.reading(currentCapacity: Int, maxCapacity: Int, isACPower: Bool, externalConnected: Bool?, adapterWatts: Int?, instantAmperage: Int?) -> NativeLimitBatteryReading`
  - `BatteryControlBackendSelector.select(isRunningTests: Bool, smcProbe: (String) -> BatteryControlKeyProbeResult, isNativeSupported: () -> Bool) -> BatteryControlBackend`
  - `BatteryControlBackendSelector.current: BatteryControlBackend`, `.isRunningTests: Bool`
  - `NativeChargeLimitService.sharedDriver`, `NativeChargeLimitService.shared`

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/BatteryControlBackendSelectorTests.swift`:

```swift
import Testing
@testable import Wattly

@Suite struct BatteryControlBackendSelectorTests {
    private let allAbsent: (String) -> BatteryControlKeyProbeResult = { _ in .confirmedAbsent }

    @Test func macOS27ShapeSelectsTheNativeBackend() {
        let backend = BatteryControlBackendSelector.select(
            isRunningTests: false, smcProbe: allAbsent, isNativeSupported: { true })
        #expect(backend == .nativeLimit)
    }

    /// 단위 테스트가 개발자의 실제 시스템 충전 제한을 건드리면 안 된다.
    @Test func theTestHostNeverSelectsTheNativeBackend() {
        let backend = BatteryControlBackendSelector.select(
            isRunningTests: true, smcProbe: allAbsent, isNativeSupported: { true })
        #expect(backend == .smc)
    }

    @Test func aMacThatStillHasARegisterStaysOnTheHelper() {
        var nativeWasAsked = false
        let backend = BatteryControlBackendSelector.select(
            isRunningTests: false,
            smcProbe: { $0 == "CHTE" ? .readable(type: "ui32", size: 4) : .confirmedAbsent },
            isNativeSupported: { nativeWasAsked = true; return true })
        #expect(backend == .smc)
        #expect(nativeWasAsked == false)   // PowerUI는 필요할 때만 올린다
    }

    @Test func anUncertainProbeIsNotProofOfAbsence() {
        let backend = BatteryControlBackendSelector.select(
            isRunningTests: false,
            smcProbe: { $0 == "CH0B" ? .uncertain : .confirmedAbsent },
            isNativeSupported: { true })
        #expect(backend == .smc)
    }

    @Test func noRegisterAndNoPowerUIFallsBackToTheHelperPath() {
        let backend = BatteryControlBackendSelector.select(
            isRunningTests: false, smcProbe: allAbsent, isNativeSupported: { false })
        #expect(backend == .smc)
    }

    @Test func theRunningTestHostIsDetected() {
        #expect(BatteryControlBackendSelector.isRunningTests)
        #expect(BatteryControlBackendSelector.current == .smc)
    }

    // MARK: reader assembly

    @Test func readingScalesCapacityAndTreatsAnyAdapterSignalAsPluggedIn() {
        let onAC = NativeLimitBatteryReader.reading(
            currentCapacity: 80, maxCapacity: 100, isACPower: true,
            externalConnected: true, adapterWatts: 68, instantAmperage: 0)
        #expect(onAC == .init(percentage: 80, isPluggedIn: true, batteryMilliamps: 0))

        let wattsOnly = NativeLimitBatteryReader.reading(
            currentCapacity: 3_000, maxCapacity: 6_000, isACPower: false,
            externalConnected: false, adapterWatts: 68, instantAmperage: -850)
        #expect(wattsOnly == .init(percentage: 50, isPluggedIn: true, batteryMilliamps: -850))

        let onBattery = NativeLimitBatteryReader.reading(
            currentCapacity: 72, maxCapacity: 100, isACPower: false,
            externalConnected: false, adapterWatts: nil, instantAmperage: nil)
        #expect(onBattery == .init(percentage: 72, isPluggedIn: false, batteryMilliamps: nil))
    }

    @Test func readingSurvivesAZeroMaxCapacity() {
        let reading = NativeLimitBatteryReader.reading(
            currentCapacity: 64, maxCapacity: 0, isACPower: true,
            externalConnected: nil, adapterWatts: nil, instantAmperage: nil)
        #expect(reading.percentage == 64)
    }
}
```

- [ ] **Step 2: 프로젝트 재생성 후 실패 확인**

Run: `/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml && xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/BatteryControlBackendSelectorTests 2>&1 | tail -25`
Expected: 컴파일 실패 — `cannot find 'BatteryControlBackendSelector' in scope`.

- [ ] **Step 3: 리더 구현**

`Wattly/Control/NativeLimitBatteryReader.swift`:

```swift
import Foundation
import IOKit
import IOKit.ps

/// 네이티브 백엔드가 한 요청에 필요한 세 가지 — 잔량 %, 어댑터 연결, 배터리 전류 — 를 읽는다.
///
/// 어댑터 판정은 도우미(`WattlyFanDaemon/FanControlDaemon.swift`의 `readPowerSourceState`)와
/// 같은 OR 규칙이다: IOPS가 AC라고 하거나, 레지스트리가 `ExternalConnected`라고 하거나,
/// `AdapterDetails.Watts > 0`이면 연결이다. 전류는 레지스트리 `InstantAmperage`(macOS 27에도
/// 남아 있음, +충전/−방전)를 쓴다 — 음수는 부호 없는 64비트로 인코딩돼 오므로 `int64Value`로
/// 되돌린다.
enum NativeLimitBatteryReader {
    static func read() -> NativeLimitBatteryReading? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(snapshot, $0)?.takeUnretainedValue() as? [String: Any]
        }
        // 내장 배터리가 없으면(데스크톱) 읽을 것이 없다.
        guard let battery = descriptions.first(where: {
            ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
        }) else { return nil }

        var externalConnected: Bool?
        var adapterWatts: Int?
        var instantAmperage: Int?
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            externalConnected = property(service, "ExternalConnected") as? Bool
            adapterWatts = ((property(service, "AdapterDetails") as? [String: Any])?["Watts"] as? NSNumber)?.intValue
            instantAmperage = (property(service, "InstantAmperage") as? NSNumber).map { Int($0.int64Value) }
        }

        return reading(
            currentCapacity: battery[kIOPSCurrentCapacityKey] as? Int ?? 0,
            maxCapacity: battery[kIOPSMaxCapacityKey] as? Int ?? 100,
            isACPower: (battery[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
            externalConnected: externalConnected,
            adapterWatts: adapterWatts,
            instantAmperage: instantAmperage)
    }

    /// I/O 없는 조립. 테스트가 보는 것은 이 함수다.
    static func reading(
        currentCapacity: Int,
        maxCapacity: Int,
        isACPower: Bool,
        externalConnected: Bool?,
        adapterWatts: Int?,
        instantAmperage: Int?
    ) -> NativeLimitBatteryReading {
        let percentage = maxCapacity > 0
            ? Int((Double(currentCapacity) / Double(maxCapacity) * 100.0).rounded())
            : currentCapacity
        let isPluggedIn = isACPower || externalConnected == true || (adapterWatts ?? 0) > 0
        return NativeLimitBatteryReading(
            percentage: percentage,
            isPluggedIn: isPluggedIn,
            batteryMilliamps: instantAmperage)
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
```

- [ ] **Step 4: 선택기 + 전역 인스턴스 구현**

`Wattly/Control/BatteryControlBackendSelector.swift`:

```swift
import Foundation

/// 이 프로세스가 충전 제한 요청을 어디로 보낼지 정한다.
///
/// 네이티브 백엔드는 **다른 길이 없다고 증명된 Mac에서만** 고른다: 구동 가능한 레지스터
/// (`CHTE`/`CH0B`/`BCLM`)가 전부 SMC result 132로 부재가 확인됐고(`uncertain`은 증명이 아니다),
/// PowerUI가 지원한다고 답할 때. 레지스터가 하나라도 남아 있는 Mac — macOS 26.x 전부 — 은
/// 예전 그대로 루트 도우미를 쓴다. 도우미 경로는 세일링·열 보호·80% 미만 목표를 표현할 수
/// 있고 네이티브는 못 하므로, 둘 다 가능할 때 네이티브를 고를 이유가 없다.
enum BatteryControlBackendSelector {
    static func select(
        isRunningTests: Bool,
        smcProbe: (String) -> BatteryControlKeyProbeResult,
        isNativeSupported: () -> Bool
    ) -> BatteryControlBackend {
        guard !isRunningTests else { return .smc }
        guard BatteryControlKeys.runtimeDrivableRegisterProbe(probing: smcProbe) == .noDrivableRegisterAtRuntime else {
            return .smc
        }
        return isNativeSupported() ? .nativeLimit : .smc
    }

    /// 테스트 호스트는 실제 Wattly.app이다. 여기서 네이티브 백엔드가 선택되면 핸들러를 주입하지
    /// 않은 `BatteryControlClient()`를 만드는 기존 테스트가 개발자의 시스템 충전 제한을 바꾼다.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// 프로세스당 한 번. 레지스터 세대는 펌웨어의 사실이라 실행 중에 바뀌지 않는다.
    static let current: BatteryControlBackend = {
        guard let smc = SMCConnection() else { return .smc }
        return select(
            isRunningTests: isRunningTests,
            smcProbe: { key in
                let reply = smc.probeKeyInfo(key)
                return .fromSMCKeyInfo(
                    kernelSucceeded: reply.kernel == KERN_SUCCESS,
                    smcResult: reply.output.result,
                    type: SMCConnection.string(reply.output.keyInfo.dataType),
                    size: Int(reply.output.keyInfo.dataSize))
            },
            isNativeSupported: { NativeChargeLimitService.sharedDriver.isSupported })
    }()
}

extension NativeChargeLimitService {
    /// 실제 PowerUI 드라이버. `static let`이라 처음 읽힐 때 — 즉 선택기가 "레지스터가 없다"고
    /// 판정한 뒤에만 — 프레임워크를 올린다.
    static let sharedDriver = PowerUIChargeLimitDriver()

    static let shared = NativeChargeLimitService(
        driver: sharedDriver,
        reader: { NativeLimitBatteryReader.read() },
        defaults: .standard,
        now: { Date().timeIntervalSince1970 })
}
```

- [ ] **Step 5: 클라이언트 기본 핸들러에 라우팅 추가**

`Wattly/Control/BatteryControlClient.swift`의 지정 이니셜라이저에서:

```swift
        self.requestHandler = requestHandler ?? { req in
            switch req {
```

를 다음으로 바꾼다(`switch`부터의 나머지 본문은 그대로 둔다):

```swift
        self.requestHandler = requestHandler ?? { req in
            // macOS 27: 충전 레지스터가 없으면 루트 도우미는 "미지원"밖에 답할 수 없다. 그때는 앱
            // 안 서비스가 같은 계약으로 답한다 — `BatteryControlBackendSelector` 참고. 핸들러를
            // 주입하는 테스트는 이 클로저 자체를 쓰지 않으므로 영향이 없다.
            if BatteryControlBackendSelector.current == .nativeLimit {
                return await NativeChargeLimitService.shared.handle(req)
            }
            switch req {
```

- [ ] **Step 6: 통과 확인 (새 스위트 + 클라이언트·브리지·인텐트 회귀)**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/BatteryControlBackendSelectorTests -only-testing:WattlyTests/BatteryControlClientTests -only-testing:WattlyTests/BatteryControlBridgeTests -only-testing:WattlyTests/BatteryIntentBridgeTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`, 새 테스트 8개 통과, 기존 세 스위트 회귀 없음.

- [ ] **Step 7: 커밋**

```bash
git add Wattly/Control/NativeLimitBatteryReader.swift Wattly/Control/BatteryControlBackendSelector.swift Wattly/Control/BatteryControlClient.swift WattlyTests/BatteryControlBackendSelectorTests.swift Wattly.xcodeproj/project.pbxproj
git commit -m "feat(battery): route charge-limit requests to the native backend when no SMC register exists"
```

---

### Task 7: 설정 화면 — 표현할 수 없는 옵션 숨김 + 안내 한 줄

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift` (`showsConfigurationControls` 함수 바로 위)
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift`
- Create: `scripts/i18n_additions/native_charge_limit.json`
- Modify: `Wattly/Resources/Localizable.xcstrings` (스크립트가 수정)
- Test: `WattlyTests/NativeLimitPresentationTests.swift`

**Interfaces:**
- Consumes: Task 1 `BatteryControlBackend`, `BatteryControlServiceStatus.controlBackend`.
- Produces: `enum BatteryFeature: Hashable, Sendable { case sailing, heatProtection, sleepUntilLimit }`, `BatterySectionPresentation.hiddenFeatures(backend: BatteryControlBackend?) -> Set<BatteryFeature>`, `BatterySectionPresentation.nativeLimitNotice(backend: BatteryControlBackend?, locale: Locale) -> String?`.

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/NativeLimitPresentationTests.swift`:

```swift
import Foundation
import Testing
@testable import Wattly

@Suite struct NativeLimitPresentationTests {
    @Test func theHelperBackendHidesNothing() {
        #expect(BatterySectionPresentation.hiddenFeatures(backend: .smc).isEmpty)
        // nil = 필드를 모르는 도우미 = SMC 백엔드.
        #expect(BatterySectionPresentation.hiddenFeatures(backend: nil).isEmpty)
        #expect(BatterySectionPresentation.hiddenFeatures(backend: .unrecognized).isEmpty)
    }

    @Test func theNativeBackendHidesWhatACeilingCannotExpress() {
        #expect(BatterySectionPresentation.hiddenFeatures(backend: .nativeLimit)
                == [.sailing, .heatProtection, .sleepUntilLimit])
    }

    @Test func theNoticeAppearsOnlyForTheNativeBackend() {
        let korean = Locale(identifier: "ko")
        #expect(BatterySectionPresentation.nativeLimitNotice(backend: .smc, locale: korean) == nil)
        #expect(BatterySectionPresentation.nativeLimitNotice(backend: nil, locale: korean) == nil)
        #expect(BatterySectionPresentation.nativeLimitNotice(backend: .nativeLimit, locale: korean)
                == "이 macOS에서는 시스템 충전 제한을 사용합니다. 일부 옵션은 사용할 수 없습니다.")
    }
}
```

- [ ] **Step 2: 프로젝트 재생성 후 실패 확인**

Run: `/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml && xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/NativeLimitPresentationTests 2>&1 | tail -25`
Expected: 컴파일 실패 — `type 'BatterySectionPresentation' has no member 'hiddenFeatures'`.

- [ ] **Step 3: 표시 계층 구현**

`Wattly/Core/BatterySectionPresentation.swift`에서 파일 맨 위 `enum BatterySectionPresentation {` **앞**에 추가:

```swift
/// 백엔드에 따라 설정 화면에서 빠질 수 있는 옵션.
enum BatteryFeature: Hashable, Sendable {
    case sailing
    case heatProtection
    case sleepUntilLimit
}
```

같은 파일의 `static func showsConfigurationControls(isHardwareSupported: Bool?) -> Bool` 선언(문서 주석 포함) **바로 위**에 추가:

```swift
    /// 이 백엔드가 표현할 수 없어 숨기는 옵션.
    ///
    /// 네이티브 제한(macOS 27)은 "상한 하나"가 전부다. 세일링은 재충전 하한을, 발열 보호는 임의
    /// 잔량에서의 즉시 충전 중단을 요구하는데 둘 다 원시 명령이 없다. "한도 도달 시까지 잠자기
    /// 방지"는 도우미가 깨어 있어야 제한에서 멈출 수 있던 시절의 기능이고, 네이티브에서는
    /// 펌웨어가 잠든 동안에도 집행하므로 필요가 없다.
    ///
    /// 숨길 뿐 저장값은 지우지 않는다 — 같은 환경설정이 레지스터가 있는 Mac에 도달하면 그 값은
    /// 다시 유효하다(`isToggleEnabled`의 주석과 같은 규칙).
    static func hiddenFeatures(backend: BatteryControlBackend?) -> Set<BatteryFeature> {
        backend == .nativeLimit ? [.sailing, .heatProtection, .sleepUntilLimit] : []
    }

    /// 옵션이 왜 줄었는지 한 줄. 네이티브 백엔드가 아니면 `nil`.
    static func nativeLimitNotice(backend: BatteryControlBackend?, locale: Locale) -> String? {
        guard backend == .nativeLimit else { return nil }
        return String(localized: "이 macOS에서는 시스템 충전 제한을 사용합니다. 일부 옵션은 사용할 수 없습니다.", locale: locale)
    }
```

- [ ] **Step 4: 번역 추가**

`scripts/i18n_additions/native_charge_limit.json`:

```json
{
  "이 macOS에서는 시스템 충전 제한을 사용합니다. 일부 옵션은 사용할 수 없습니다.": {
    "ar": "يستخدم macOS هذا حد الشحن الخاص بالنظام. بعض الخيارات غير متاحة.",
    "cs": "Tento macOS používá systémový limit nabíjení. Některé možnosti nejsou dostupné.",
    "da": "Denne macOS bruger systemets opladningsgrænse. Nogle indstillinger er ikke tilgængelige.",
    "de": "Dieses macOS verwendet das Ladelimit des Systems. Einige Optionen sind nicht verfügbar.",
    "el": "Αυτό το macOS χρησιμοποιεί το όριο φόρτισης του συστήματος. Ορισμένες επιλογές δεν είναι διαθέσιμες.",
    "en": "This macOS uses the system charge limit. Some options are unavailable.",
    "es": "Este macOS usa el límite de carga del sistema. Algunas opciones no están disponibles.",
    "fi": "Tämä macOS käyttää järjestelmän latausrajaa. Jotkin asetukset eivät ole käytettävissä.",
    "fr": "Ce macOS utilise la limite de charge du système. Certaines options ne sont pas disponibles.",
    "he": "macOS זה משתמש במגבלת הטעינה של המערכת. חלק מהאפשרויות אינן זמינות.",
    "hi": "यह macOS सिस्टम की चार्ज सीमा का उपयोग करता है। कुछ विकल्प उपलब्ध नहीं हैं।",
    "hu": "Ez a macOS a rendszer töltési korlátját használja. Néhány beállítás nem érhető el.",
    "id": "macOS ini menggunakan batas pengisian daya sistem. Beberapa opsi tidak tersedia.",
    "it": "Questo macOS utilizza il limite di carica di sistema. Alcune opzioni non sono disponibili.",
    "ja": "このmacOSではシステムの充電上限を使用します。一部のオプションは利用できません。",
    "ko": "이 macOS에서는 시스템 충전 제한을 사용합니다. 일부 옵션은 사용할 수 없습니다.",
    "nb": "Denne macOS bruker systemets ladegrense. Noen alternativer er ikke tilgjengelige.",
    "nl": "Deze macOS gebruikt de oplaadlimiet van het systeem. Sommige opties zijn niet beschikbaar.",
    "pl": "Ten system macOS używa systemowego limitu ładowania. Niektóre opcje są niedostępne.",
    "pt-BR": "Este macOS usa o limite de carga do sistema. Algumas opções não estão disponíveis.",
    "pt-PT": "Este macOS utiliza o limite de carga do sistema. Algumas opções não estão disponíveis.",
    "ro": "Acest macOS folosește limita de încărcare a sistemului. Unele opțiuni nu sunt disponibile.",
    "ru": "Эта версия macOS использует системное ограничение зарядки. Некоторые параметры недоступны.",
    "sv": "Denna macOS använder systemets laddningsgräns. Vissa alternativ är inte tillgängliga.",
    "th": "macOS นี้ใช้ขีดจำกัดการชาร์จของระบบ ตัวเลือกบางอย่างไม่พร้อมใช้งาน",
    "tr": "Bu macOS, sistemin şarj sınırını kullanır. Bazı seçenekler kullanılamaz.",
    "uk": "Ця версія macOS використовує системне обмеження заряджання. Деякі параметри недоступні.",
    "vi": "macOS này sử dụng giới hạn sạc của hệ thống. Một số tùy chọn không khả dụng.",
    "zh-Hans": "此 macOS 使用系统充电上限。部分选项不可用。",
    "zh-Hant": "此 macOS 使用系統充電上限。部分選項無法使用。"
  }
}
```

Run: `python3 scripts/add_localizations.py scripts/i18n_additions/native_charge_limit.json`
Expected: `merged 1 keys; catalog now has 672 keys` (기준 카탈로그가 671개일 때).

- [ ] **Step 5: 설정 화면 게이팅**

`Wattly/Views/Settings/SettingsBatterySection.swift`에서 네 군데를 고친다.

**(a)** `private var isHardwareUnsupported: Bool {` 계산 프로퍼티 **바로 위**에 추가:

```swift
    /// 백엔드가 표현할 수 없어 숨기는 행. 판단은 `BatterySectionPresentation`이 갖는다.
    private var hiddenFeatures: Set<BatteryFeature> {
        BatterySectionPresentation.hiddenFeatures(backend: batteryControl.status.controlBackend)
    }
```

**(b)** 안내 한 줄. 다음 세 줄을:

```swift
                    // Always visible: unsupported hardware must explain itself with the same
                    // icon-and-text status interface instead of making the entire status row vanish.
                    batteryStatusIndicator
```

다음으로 바꾼다:

```swift
                    // Always visible: unsupported hardware must explain itself with the same
                    // icon-and-text status interface instead of making the entire status row vanish.
                    batteryStatusIndicator

                    if let notice = BatterySectionPresentation.nativeLimitNotice(
                        backend: batteryControl.status.controlBackend, locale: locale) {
                        Text(verbatim: notice)
                            .font(WattlyFont.at(10.5, weight: .regular))
                            .foregroundStyle(t.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
```

**(c)** `if showsConfigurationControls {` 블록 안의 세 묶음을 각각 `if !hiddenFeatures.contains(…) { … }`로 감싼다. 각 묶음은 **구분선 한 줄 + 그 아래 행**이다. 구분선까지 같이 감싸야 숨긴 자리에 선이 두 줄 남지 않는다.

1. 잠자기 방지 — 다음으로 시작해서:

```swift
                    Rectangle().fill(t.line).frame(height: 1)

                    SettingsToggleRow(isOn: $batterySleepUntilLimitEnabled,
```

그 `SettingsToggleRow`의 후행 클로저가 닫히는 `}`(다음 `Rectangle().fill(t.line).frame(height: 1)` 직전)까지를:

```swift
                    if !hiddenFeatures.contains(.sleepUntilLimit) {
                        Rectangle().fill(t.line).frame(height: 1)

                        SettingsToggleRow(isOn: $batterySleepUntilLimitEnabled,
                        // …기존 행 본문 그대로, 한 단계 들여쓰기…
                        }
                    }
```

2. 세일링 — `Rectangle().fill(t.line).frame(height: 1)` + `SettingsToggleRow(isOn: $batterySailingEnabled, …) { … }` + 바로 이어지는 `if batterySailingEnabled { … }` 블록 전체(그 블록의 `.padding(EdgeInsets(top: 0, leading: 14, bottom: 14, trailing: 14))`와 닫는 `}`까지)를 `if !hiddenFeatures.contains(.sailing) { … }`로 감싼다.

3. 발열 보호 — `Rectangle().fill(t.line).frame(height: 1)` + `SettingsToggleRow(isOn: $batteryHeatProtectionEnabled, …) { … }`를 `if !hiddenFeatures.contains(.heatProtection) { … }`로 감싼다.

그 뒤의 구분선 + "한 번만 완충" 행(`SettingsToggleRow(isOn: topUpBinding,`)은 감싸지 않는다 — Top Up은 네이티브에서도 동작한다.

**(d)** 확인: 감싼 뒤 `if showsConfigurationControls {` 블록의 직계 자식은 `Rectangle`·`if`·`if`·`if`·`Rectangle`·`SettingsToggleRow`(Top Up) 순이다. 첫 `Rectangle`(블록 맨 위 구분선)이 잠자기 방지 묶음 안으로 들어갔다면, 블록 맨 위에는 구분선이 없어야 하고 Top Up 앞의 구분선은 남아 있어야 한다.

- [ ] **Step 6: 통과 확인 (새 스위트 + 현지화·설정 회귀)**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/NativeLimitPresentationTests -only-testing:WattlyTests/LocalizationTests -only-testing:WattlyTests/SettingsBatterySectionTests -only-testing:WattlyTests/BatterySectionPresentationTests 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`. `LocalizationTests`의 "모든 키에 모든 로케일" 검사가 새 키를 포함해 통과한다.

- [ ] **Step 7: 커밋**

```bash
git add Wattly/Core/BatterySectionPresentation.swift Wattly/Views/Settings/SettingsBatterySection.swift scripts/i18n_additions/native_charge_limit.json Wattly/Resources/Localizable.xcstrings WattlyTests/NativeLimitPresentationTests.swift Wattly.xcodeproj/project.pbxproj
git commit -m "feat(battery): hide options the native charge limit cannot express and say why"
```

---

### Task 8: DEBUG 실기 프로브 + 기능 문서 + 전체 검증

**Files:**
- Modify: `Wattly/Control/BatteryControlBackendSelector.swift` (파일 끝에 DEBUG 프로브 추가)
- Modify: `Wattly/App/WattlyApp.swift` (`PowerProbe.runIfRequested()` 줄 아래)
- Create: `docs/features/battery-management/14-macos-27-native-charge-limit.md`

**Interfaces:**
- Consumes: Task 4 `PowerUIChargeLimitDriver`, Task 6 `BatteryControlBackendSelector.select`, `NativeLimitBatteryReader.read()`, `NativeChargeLimitService.sharedDriver`.
- Produces: `NativeLimitProbe.runIfRequested()` (DEBUG 전용, **읽기만** 한다).

- [ ] **Step 1: 프로브 구현**

`Wattly/Control/BatteryControlBackendSelector.swift` 파일 끝에 추가:

```swift
#if DEBUG
/// DEBUG 실기 프로브. 이 Mac에서 어느 백엔드가 선택되는지와 네이티브 제한의 현재 상태를 출력하고
/// 종료한다. **읽기만 한다** — `setLimit`/`temporarilyDisable`은 부르지 않는다.
///   `Wattly.app/Contents/MacOS/Wattly -WattlyNativeLimitProbe`
/// Release에서는 제외.
enum NativeLimitProbe {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("-WattlyNativeLimitProbe") else { return }
        print("[native-limit-probe] selected backend: \(BatteryControlBackendSelector.current.rawValue)")
        let driver = NativeChargeLimitService.sharedDriver
        print("[native-limit-probe] PowerUI supported: \(driver.isSupported)")
        do {
            print("[native-limit-probe] available limits: \(try driver.availableLimits())")
            let snapshot = try driver.snapshot()
            print("[native-limit-probe] native limit: \(snapshot.limit) state: \(snapshot.state)")
        } catch {
            print("[native-limit-probe] PowerUI read failed: \(error)")
        }
        if let reading = NativeLimitBatteryReader.read() {
            print("[native-limit-probe] battery: \(reading.percentage)% plugged=\(reading.isPluggedIn) mA=\(reading.batteryMilliamps.map(String.init) ?? "nil")")
        } else {
            print("[native-limit-probe] battery: unreadable")
        }
        let defaults = UserDefaults.standard
        print("[native-limit-probe] owned=\(defaults.bool(forKey: StorageKey.nativeLimitOwned)) topUpReachedFullAt=\(defaults.object(forKey: StorageKey.nativeLimitTopUpReachedFullAt) ?? "nil")")
        exit(0)
    }
}
#endif
```

`Wattly/App/WattlyApp.swift`의 `#if DEBUG` 블록에서 `PowerProbe.runIfRequested()` 줄 바로 아래에 추가:

```swift
        NativeLimitProbe.runIfRequested()  // -WattlyNativeLimitProbe: dump backend + native limit state and exit (macOS 27)
```

- [ ] **Step 2: 빌드 후 실기 프로브 실행**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5
APP="$(xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')/Wattly.app"
"$APP/Contents/MacOS/Wattly" -WattlyNativeLimitProbe
```
Expected (macOS 27 개발기): `** BUILD SUCCEEDED **`, 그리고

```
[native-limit-probe] selected backend: native-limit
[native-limit-probe] PowerUI supported: true
[native-limit-probe] available limits: [80, 85, 90, 95, 100]
[native-limit-probe] native limit: <현재값> state: <on|off|temporarilyDisabled>
[native-limit-probe] battery: <n>% plugged=<true|false> mA=<n>
```

`selected backend: smc`가 나오면 멈추고 원인을 본다: `swift scripts/probe-charge-registers.swift`에서 `CHTE`/`CH0B`/`BCLM`이 전부 `absent`인지(하나라도 `present`/`UNCERTAIN`이면 SMC가 맞다), `PowerUI supported`가 `true`인지.

- [ ] **Step 3: 기능 문서 작성**

`docs/features/battery-management/14-macos-27-native-charge-limit.md`:

```markdown
# macOS 27 네이티브 충전 제한 백엔드

## 상태

- 단계: 구현 및 자동 검증 완료 · 실기 체크리스트 진행 중
- 대상: 구동 가능한 SMC 충전 레지스터가 하나도 없는 Mac(macOS 27 릴리스 펌웨어 `20457.1.29`+)
- 설계: `docs/superpowers/specs/2026-09-17-macos-27-native-charge-limit.md`

## 구현된 동작

macOS 27 펌웨어에서 `CHTE`/`CH0B`/`BCLM`이 사라지고 `bfF0`/`bfD0`/`bfE0`는 루트에게도 거부된다. 이 Mac에서 Wattly는 루트 도우미 대신 애플 네이티브 충전 제한(시스템 설정 > 배터리의 그 제한)을 비공개 `PowerUI.framework`로 직접 구동한다. 관리자 인증도 도우미 설치도 필요 없다.

- 선택은 프로세스 시작 시 한 번(`BatteryControlBackendSelector.current`): 레지스터 부재가 **증명**되고 PowerUI가 지원할 때만 네이티브. 그 외는 전부 기존 도우미 경로.
- 앱 안 actor `NativeChargeLimitService`가 `BatteryControlClient`의 요청 계약을 그대로 말한다. 브리지·정책·표시·단축어·스케줄은 수정되지 않았다.
- 모든 요청이 조정 패스다: 네이티브 상태를 읽고 저장된 정책과 다르면 다시 쓴다. 앱이 켜져 있는 동안 시스템 설정에서 값을 바꾸면 60초 안에 Wattly 값으로 돌아간다.
- 제한은 80/85/90/95/100만 가능하다. 목록 밖 요청은 요청값 이상인 최소 허용값으로 올린다(70 → 80).
- 잔량이 제한보다 높으면 **펌웨어가** 어댑터를 둔 채 배터리로 구동해 제한까지 끌어내린다. 상태 줄은 "제한까지 방전 중"을 재사용하고, 판정은 배터리 전류 부호(≤ −100 mA)로 한다 — pmset은 이 상태를 "AC attached"로 표시한다.
- Top Up은 `temporarilyDisableMCL:`이다. 네이티브의 일시 해제는 완충으로도 어댑터 분리로도 스스로 풀리지 않으므로, 종료(100% 후 12시간 · 어댑터 분리 · 사용자 취소)는 Wattly가 `setMCLLimit:`으로 직접 다시 건다. 앱이 꺼져 있던 동안 만료됐다면 다음 실행의 첫 요청에서 처리된다.
- Wattly 제한을 끄면 **Wattly가 건 제한만** 푼다. 사용자가 시스템 설정에서 직접 건 제한은 건드리지 않는다.
- 앱을 종료해도 제한은 유지된다(펌웨어가 쥐고 있다).

## 이 백엔드에서 빠지는 것

| 옵션 | 이유 |
|---|---|
| Sailing 모드 | 재충전 하한을 정할 원시 명령이 없다. 재충전 시점은 펌웨어가 정한다 |
| 발열 보호 | 임의 잔량에서 충전을 즉시 멈출 원시 명령이 없다 |
| 한도 도달 시까지 잠자기 방지 | 펌웨어가 잠든 동안에도 제한을 집행하므로 불필요 |
| 80% 미만 제한 | API가 거부한다(`PowerUISmartChargingErrorDomain Code=4`) |
| 수동/자동 방전 · 캘리브레이션 · 클램쉘 방전 | CHIE가 필요하다. 실기 가능성은 확인했고 별도 작업으로 복구한다 |

저장된 환경설정은 지우지 않는다.

## 실패 시

PowerUI 프레임워크·클래스·셀렉터 중 하나라도 없으면 네이티브 백엔드는 선택되지 않고, 화면은 기존 "이 Mac은 충전 제어를 지원하지 않습니다"로 떨어진다. 쓰기 실패는 "적용 실패", 읽기 실패는 "하드웨어 확인 실패" 상태로 표시된다.

## 실기 체크리스트 (릴리스 전)

- [ ] `Wattly -WattlyNativeLimitProbe` → `selected backend: native-limit`
- [ ] 도우미 미설치 상태에서 제한 토글 on → 설치 창 없이 적용, `pmset -g battlimit`에 `chargeSocLimitSoc = 80`
- [ ] 80% 미만에서 충전 → 80% 도달 1~2분 내 0 mA, 20분 유지
- [ ] 제한 초과 상태에서 제한 on → 어댑터 연결인 채 음(−) 전류, 상태 줄 "방전 중", 제한 도달 후 0 mA
- [ ] Top Up on → 1분 내 충전 재개 · Top Up 취소 → 제한 복귀
- [ ] Top Up 중 어댑터 분리 → 재연결 후 제한이 걸려 있음
- [ ] 시스템 설정에서 제한을 95로 변경 → 60초 안에 Wattly 값으로 복귀
- [ ] Wattly 제한 off → 시스템 설정에서 제한이 꺼짐 / 시스템 설정에서 직접 건 제한은 Wattly off로 안 꺼짐
- [ ] 뚜껑 닫고 10분 → 열었을 때 제한 유지
- [ ] 재부팅 → `pmset -g battlimit`에 제한 유지, Wattly 실행 후 상태 줄 정상
- [ ] 단축어 "충전 제한 70%" → 80 적용
- [ ] 설정 화면: Sailing·발열 보호·잠자기 방지 행이 없고 안내 한 줄이 보임
- [ ] macOS 26.x 기기(있다면): `selected backend: smc`, 동작 변화 없음
```

- [ ] **Step 4: 전체 테스트**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`. 기준(이 계획 전) 테스트 수 + 새 테스트 61개(3 + 16 + 14 + 3 + 14 + 8 + 3). 새 파일에서 나온 Swift 6 동시성 경고 0 — `xcodebuild … build 2>&1 | grep -E "warning:.*(NativeChargeLimit|NativeLimit|BatteryControlBackend)"`가 비어 있어야 한다.

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Control/BatteryControlBackendSelector.swift Wattly/App/WattlyApp.swift docs/features/battery-management/14-macos-27-native-charge-limit.md
git commit -m "docs(battery): document the macOS 27 native charge-limit backend and add an on-device probe"
```

---

## Self-Review 결과

- **스펙 커버리지:** §3-2의 #0(Task 5·6) · #1(Task 6 선택기) · #2(Task 6 Step 5) · #3(Task 5 영속) · #4(Task 2 `.temporarilyDisable`) · #5(Task 5 만료/분리/취소, 재실행 테스트) · #6(Task 5 "모든 요청이 조정 패스", drift 테스트) · #7·#8(Task 3 capability/gate + `accepted` 테스트, Task 5 maintenance) · #9(Task 1) · #10·#12(Task 7) · #11(Task 3 `isDischargeHardwareSupported = false`) · #13(Task 3 `shouldRunInstaller` 테스트) · #14(Task 3 drain) · #15(Task 3 실패 사유, Task 4 `.unavailable`, Task 6 폴백). §3-3 N2(Task 5 drift 테스트) · N3(Task 2·5 소유 플래그) · N4(Task 2 `snapped`, Task 5 off-list 테스트) · N5(Task 7 번역) · N6(무변경 — Task 3의 `shouldRunInstaller == false` 테스트가 근거). §6 실기(Task 8 체크리스트).
- **플레이스홀더:** Task 7 Step 5(c)의 `// …기존 행 본문 그대로, 한 단계 들여쓰기…`는 "기존 코드를 옮기지 말고 그대로 두라"는 지시이지 채울 내용이 아니다 — 감쌀 범위의 시작·끝 앵커를 본문에 명시했다.
- **타입 일관성:** `NativeLimitSnapshot(limit:state:)`, `NativeLimitBatteryReading(percentage:isPluggedIn:batteryMilliamps:)`, `NativeLimitWriteOutcome`, `NativeLimitCommand`, `NativeChargeLimitDriving`의 5개 멤버, `NativeChargeLimitService.init(driver:reader:defaults:now:)`·`process(_:)`·`handle(_:)`, `StorageKey.nativeLimit*` 3개가 정의 태스크와 소비 태스크에서 같은 철자다.
