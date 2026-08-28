# Top Up 시간 기반 자동 해제 (Auto-Expiry) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** "한 번만 완충"(Top Up)이 100%에 도달한 뒤 12시간이 지나면 데몬이 스스로 `topUpActive`를 끄고 원래 충전 정책으로 복귀시키며, 앱이 그 사실을 알림으로 알려준다.

**Architecture:** 만료 판정은 **순수 함수 하나**(`BatteryTopUpExpiry.decide`)로 격리하고, 그 함수를 호출하는 지점은 `BatteryControlCoordinator` **단 한 곳**(`evaluateTopUpExpiry`)뿐이다. 코디네이터만이 주입된 `now`와 정책 저장소를 동시에 소유하기 때문이다. 완충 도달 시각은 `PersistedBatteryPolicy`의 **Optional 신규 필드**로 저장한다 — `BatteryControlConfiguration` 안에 넣으면 앱의 60초 reconcile이 덮어써 지워버린다. 만료 사실은 새 `BatteryMaintenanceTrigger.topUpExpired` 레코드로 앱에 전달되고, 앱은 그것을 보고 알림을 띄운다.

**Tech Stack:** Swift 6 (strict concurrency, deploy target macOS 14.0), SwiftUI, Swift Testing (`@Test`), XcodeGen(`project.yml`), `Localizable.xcstrings`(30개 언어) + `scripts/add_localizations.py`.

## Global Constraints

- Swift 6 언어 모드, `MACOSX_DEPLOYMENT_TARGET = 14.0`, `ARCHS = arm64`. (`project.yml`)
- **`PersistedBatteryPolicy.currentSchemaVersion`은 1에서 절대 올리지 않는다.** `BatteryPolicyFileStore.load()`가 정확한 일치를 요구하므로(`FanControlShared/BatteryPolicyPersistence.swift:83`), 버전을 올리면 구버전 헬퍼가 정책 파일을 못 읽고 충전 제한이 통째로 해제된다. 신규 필드는 반드시 **Optional**로 추가한다(합성 Codable이 Optional에 `decodeIfPresent`를 쓰므로 상·하위 호환이 성립한다 — 이 사실은 실제 컴파일 프로브로 검증됨).
- **완충 도달 시각을 `BatteryControlConfiguration`에 넣지 않는다.** `BatteryControlPolicy.shouldReapply`가 `desired.normalized != requested`로 비교하고 `topUpActive`/`manualDischarge*`만 보존하므로, 앱이 모르는 필드는 60초 내 reconcile에서 지워진다.
- **만료 판정 호출 지점은 코디네이터의 `evaluateTopUpExpiry` 한 곳뿐.** 향후 배터리 캘리브레이션 모드가 추가할 `calibrationActive` 예외는 `BatteryTopUpExpiry.decide`의 동명 파라미터 한 줄로 들어간다. 지금 그 플래그는 존재하지 않으므로 **구현하지 않는다**(기본값 `false`만 둔다).
- 만료 판정에 `AppleRawCurrentCapacity/AppleRawMaxCapacity` 비율을 쓰지 않는다. 데몬이 엔진에 넘기는 SoC는 IOPS `kIOPSCurrentCapacity/kIOPSMaxCapacity` 기반이며(`WattlyFanDaemon/FanControlDaemon.swift:175-177`), 이것만이 100에 도달한다. 이 계획은 SoC를 직접 읽지 않고 엔진이 이미 계산한 `detailReason.kind == .topUpComplete`를 사용한다.
- 사용자에게 보이는 새 문자열은 **30개 언어 전부** 채워야 한다. `scripts/add_localizations.py`가 하나라도 빠지면 실패시킨다. 언어 목록: `ar cs da de el en es fi fr he hi hu id it ja ko nb nl pl pt-BR pt-PT ro ru sv th tr uk vi zh-Hans zh-Hant`.
- 만료 시간은 **고정 상수 12시간**. `@AppStorage` 키를 만들지 않으므로 `StorageKey`/`Defaults`/`SettingsReset`은 **건드리지 않는다**.
- `FanControlShared/`, `WattlyTests/`에 **파일을 새로 추가하면 반드시 xcodegen을 다시 돌린다**: `/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml`
- 테스트는 워크트리에서 반드시 `-derivedDataPath`를 지정해야 통과한다(자산 카탈로그 권한 문제). 기준선: 이 계획 시작 시점 `** TEST SUCCEEDED **`, `@Test` 1048개.

---

## File Structure

**신규 생성**
- `FanControlShared/BatteryTopUpExpiry.swift` — 만료 상수 + 순수 판정 함수. 이 기능의 유일한 정책 소재지.
- `WattlyTests/BatteryTopUpExpiryTests.swift` — 위 순수 함수 테스트.
- `scripts/i18n_additions/top_up_auto_expiry.json` — 신규 문자열 5개 × 30개 언어 번역 원본.

**수정**
- `FanControlShared/BatteryPolicyPersistence.swift` — `PersistedBatteryPolicy.topUpReachedFullAt: TimeInterval?` 추가.
- `FanControlShared/BatteryControlProtocol.swift` — `BatteryMaintenanceTrigger.topUpExpired` 케이스 추가.
- `FanControlShared/BatteryControlCoordinator.swift` — 도달 시각 스탬프 · 만료 실행 · 저장 배선.
- `Wattly/Core/BatterySectionPresentation.swift` — 신규 trigger 문구 + Top Up 설명 문구 생성기.
- `Wattly/Core/BatteryNotificationManager.swift` — 만료 감지기 + 만료 알림 + 완충 알림 문구 갱신.
- `Wattly/Views/BatteryControlBridge.swift` — 만료 감지기 배선.
- `Wattly/Views/Settings/SettingsBatterySection.swift` — Top Up 설명 문구 교체.
- `Wattly/Resources/Localizable.xcstrings` — 스크립트로 병합(직접 편집 금지).
- `README.md`, `docs/features/battery-management/02-top-up.md` — 동작 문서화.

**테스트 수정**
- `WattlyTests/BatteryPolicyPersistenceTests.swift`, `WattlyTests/BatteryControlCoordinatorTests.swift`, `WattlyTests/BatterySectionPresentationTests.swift`, `WattlyTests/BatteryNotificationManagerTests.swift`

---

### Task 1: 순수 만료 판정 (`BatteryTopUpExpiry`)

만료 로직 전체를 하드웨어·저장소·시계와 무관한 순수 함수로 먼저 만든다. 이후 모든 태스크는 이 함수를 호출만 한다.

**Files:**
- Create: `FanControlShared/BatteryTopUpExpiry.swift`
- Test: `WattlyTests/BatteryTopUpExpiryTests.swift`
- Modify: `Wattly.xcodeproj` (xcodegen 재생성으로 자동)

**Interfaces:**
- Consumes: 없음 (Foundation만).
- Produces:
  - `BatteryTopUpExpiry.duration: TimeInterval` (= 43200)
  - `BatteryTopUpExpiry.durationHours: Int` (= 12)
  - `BatteryTopUpExpiry.Decision` — `.none` / `.stamp(TimeInterval)` / `.expire`
  - `BatteryTopUpExpiry.decide(topUpActive:isHoldingAtFull:reachedFullAt:now:duration:calibrationActive:) -> Decision`

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`WattlyTests/BatteryTopUpExpiryTests.swift` 생성:

```swift
import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryTopUpExpiryTests {
    private let hour: TimeInterval = 3600

    @Test func defaultDurationIsTwelveHours() {
        #expect(BatteryTopUpExpiry.duration == 12 * 3600)
        #expect(BatteryTopUpExpiry.durationHours == 12)
    }

    /// Top Up이 꺼져 있으면 시계는 돌지 않는다.
    @Test func doesNothingWhileTopUpIsOff() {
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: false, isHoldingAtFull: true,
            reachedFullAt: nil, now: 1_000) == .none)
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: false, isHoldingAtFull: true,
            reachedFullAt: 0, now: 1_000_000) == .none)
    }

    /// 100%에 도달하기 전에는 스탬프를 찍지 않는다 — 충전에 걸리는 시간은 만료 시계에 포함되지 않는다.
    @Test func doesNotStampWhileStillChargingUp() {
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: true, isHoldingAtFull: false,
            reachedFullAt: nil, now: 1_000) == .none)
    }

    @Test func stampsOnTheFirstFullHoldObservation() {
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: true, isHoldingAtFull: true,
            reachedFullAt: nil, now: 1_000) == .stamp(1_000))
    }

    /// 이미 스탬프가 있으면 다시 찍지 않는다 (도달 시각이 뒤로 밀리면 영원히 만료되지 않는다).
    @Test func doesNotRestampAnExistingStamp() {
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: true, isHoldingAtFull: true,
            reachedFullAt: 1_000, now: 2_000) == .none)
    }

    /// 발열 보호 등으로 100% 홀드가 잠시 풀려도 시계는 계속 간다.
    @Test func keepsCountingWhenTheHoldIsTemporarilyLost() {
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: true, isHoldingAtFull: false,
            reachedFullAt: 1_000, now: 1_000 + 12 * 3600) == .expire)
    }

    @Test func expiresExactlyAtTheBoundaryAndNotBefore() {
        let stamp: TimeInterval = 10_000
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: true, isHoldingAtFull: true,
            reachedFullAt: stamp, now: stamp + 12 * 3600 - 1) == .none)
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: true, isHoldingAtFull: true,
            reachedFullAt: stamp, now: stamp + 12 * 3600) == .expire)
    }

    /// 잠자기를 12시간 건너뛰어도 벽시계 비교라 한 번에 만료된다.
    @Test func expiresAfterALongSleepGap() {
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: true, isHoldingAtFull: true,
            reachedFullAt: 0, now: 30 * 3600) == .expire)
    }

    /// 시계가 뒤로 점프하면 스탬프가 미래에 남는다. 그대로 두면 영구 미만료가 되므로 현재로 재고정한다.
    @Test func reanchorsWhenTheClockMovesBackwards() {
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: true, isHoldingAtFull: true,
            reachedFullAt: 5_000, now: 1_000) == .stamp(1_000))
    }

    /// 캘리브레이션 예외 자리. 지금은 호출자가 없고 기본값은 false다.
    @Test func neverExpiresWhileCalibrationOwnsTheTopUpPrimitive() {
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: true, isHoldingAtFull: true,
            reachedFullAt: 0, now: 30 * 3600,
            calibrationActive: true) == .none)
    }

    @Test func honoursAnInjectedDuration() {
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: true, isHoldingAtFull: true,
            reachedFullAt: 0, now: 60, duration: 60) == .expire)
        #expect(BatteryTopUpExpiry.decide(
            topUpActive: true, isHoldingAtFull: true,
            reachedFullAt: 0, now: 59, duration: 60) == .none)
    }
}
```

- [ ] **Step 2: xcodegen을 돌려 새 테스트 파일을 프로젝트에 반영한다**

```bash
/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml
```

기대 출력: `Created project at .../Wattly.xcodeproj` (`No "base" settings found` 경고는 정상이며 무시한다)

- [ ] **Step 3: 테스트가 실패하는지 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath /tmp/wattly-dd build-for-testing 2>&1 | tail -20
```

기대: 컴파일 실패 — `cannot find 'BatteryTopUpExpiry' in scope`

- [ ] **Step 4: 최소 구현을 작성한다**

`FanControlShared/BatteryTopUpExpiry.swift` 생성:

```swift
import Foundation

/// "한 번만 완충"(Top Up)이 스스로 끝나야 하는지에 대한 **유일한** 판정.
///
/// Top Up의 원래 종료 조건은 어댑터 분리 하나뿐이었다. 데스크톱처럼 늘 꽂아 두는 사용자가 켜고 잊으면
/// 배터리는 무기한 100%에 머문다 — Battery University BU-808 Table 3 기준 25°C에서 100% 유지는
/// 연 20% 용량 손실(40% 유지는 4%)이므로, 충전 제한 앱이 존재하는 이유와 정면으로 충돌한다.
///
/// 판정을 순수 함수로 떼어 둔 이유는 두 가지다. 하나는 시간이 얽힌 상태 기계를 실시간 대기 없이
/// 테스트하기 위해서고, 다른 하나는 **예외를 넣을 자리를 한 곳으로 고정**하기 위해서다. 배터리
/// 캘리브레이션 모드가 최종 100% 홀드 단계에서 같은 `topUpActive` 원시 명령을 빌려 쓸 예정인데,
/// 그때 만료가 절차를 중간에 끊으면 안 된다. 그 예외는 아래 `calibrationActive` 한 줄이 된다.
public enum BatteryTopUpExpiry {
    /// 100% 도달 후 이만큼 지나면 Top Up을 자동 해제한다. 설정에 노출하지 않는 고정 상수다 —
    /// 노출하려면 `@AppStorage` 키 하나가 `StorageKey`/`Defaults`/`SettingsReset`/설정 UI/30개
    /// 언어 번역을 함께 끌고 오므로, 값이 실제로 문제가 된다는 근거가 생긴 뒤에 하는 편이 싸다.
    public static let duration: TimeInterval = 12 * 60 * 60

    /// 사용자에게 보여 줄 시간 수. 문구가 상수와 갈라지지 않도록 문자열에 12를 직접 쓰지 않는다.
    public static var durationHours: Int { Int(duration / 3600) }

    public enum Decision: Equatable, Sendable {
        /// 할 일 없음.
        case none
        /// 완충 도달 시각을 이 값으로 기록(또는 재고정)한다.
        case stamp(TimeInterval)
        /// Top Up을 해제하고 원래 정책으로 되돌린다.
        case expire
    }

    /// - Parameters:
    ///   - topUpActive: 헬퍼가 실제로 들고 있는 Top Up 상태.
    ///   - isHoldingAtFull: 이번 샘플에서 엔진이 100% 홀드로 판정했는지
    ///     (`BatteryControlStatusReason.Kind.topUpComplete`). SoC 정수를 직접 보지 않는 이유는,
    ///     엔진이 이미 하드웨어 게이트까지 반영해 내린 결론이 이것이기 때문이다.
    ///   - reachedFullAt: 저장된 완충 도달 시각. 아직 도달 전이면 `nil`.
    ///   - now: 벽시계. 잠자기 동안에도 진행해야 하므로 단조 시계를 쓰면 안 된다.
    ///   - calibrationActive: 캘리브레이션 절차가 `topUpActive`를 빌려 쓰는 중인지. 그 플래그는
    ///     아직 코드베이스에 없으므로 항상 기본값 `false`로 호출된다.
    public static func decide(
        topUpActive: Bool,
        isHoldingAtFull: Bool,
        reachedFullAt: TimeInterval?,
        now: TimeInterval,
        duration: TimeInterval = BatteryTopUpExpiry.duration,
        calibrationActive: Bool = false
    ) -> Decision {
        guard topUpActive, !calibrationActive else { return .none }
        guard let reachedFullAt else {
            // 충전이 오래 걸린 시간은 만료 시계에 넣지 않는다. 시계는 100%에 닿은 순간 시작한다.
            return isHoldingAtFull ? .stamp(now) : .none
        }
        // 사용자가 시계를 되돌리거나 NTP가 뒤로 점프하면 스탬프가 미래에 남는다. 그대로 두면 만료가
        // 영원히 오지 않으므로 현재로 재고정한다 — 손해는 최대 한 주기 연장뿐이다.
        guard now >= reachedFullAt else { return .stamp(now) }
        return now - reachedFullAt >= duration ? .expire : .none
    }
}
```

- [ ] **Step 5: 테스트가 통과하는지 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath /tmp/wattly-dd test -only-testing:WattlyTests/BatteryTopUpExpiryTests 2>&1 | tail -20
```

기대: `** TEST SUCCEEDED **`, 11개 테스트 통과

- [ ] **Step 6: 커밋**

```bash
git add FanControlShared/BatteryTopUpExpiry.swift WattlyTests/BatteryTopUpExpiryTests.swift Wattly.xcodeproj/project.pbxproj && git commit -m "feat(battery): add pure Top Up auto-expiry decision"
```

---

### Task 2: 완충 도달 시각 영속화 (`PersistedBatteryPolicy.topUpReachedFullAt`)

데몬은 재시작·재부팅 후에도 `topUpActive`를 파일에서 복원한다(`BatteryControlCoordinator.restore`). 도달 시각도 같은 파일에 살아남아야 하며, 스키마 버전은 그대로 1이어야 한다.

**Files:**
- Modify: `FanControlShared/BatteryPolicyPersistence.swift:4-22`
- Test: `WattlyTests/BatteryPolicyPersistenceTests.swift`

**Interfaces:**
- Consumes: 없음.
- Produces: `PersistedBatteryPolicy.topUpReachedFullAt: TimeInterval?`, 생성자 파라미터 `topUpReachedFullAt: TimeInterval? = nil` (마지막 인자, 기본값 있음 → 기존 호출부 전부 그대로 컴파일된다)

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`WattlyTests/BatteryPolicyPersistenceTests.swift` 파일 **끝의 마지막 `}` 바로 앞**에 추가:

```swift
    @Test func persistsTheTopUpFullChargeTimestamp() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("battery-control-v1.json")
        let store = BatteryPolicyFileStore(
            fileURL: url, fileManager: .default, synchronizeDirectory: { _ in })
        defer { try? store.remove() }

        try store.save(.init(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 80, topUpActive: true),
            updatedAt: 1_000,
            topUpReachedFullAt: 900))

        #expect(try store.load()?.topUpReachedFullAt == 900)
    }

    /// 도달 전에는 값이 없다. `nil`은 "아직 100%에 닿지 않았다"는 뜻이다.
    @Test func topUpFullChargeTimestampDefaultsToNil() {
        let policy = PersistedBatteryPolicy(
            ownerUID: 501, configuration: .init(enabled: true), updatedAt: 1_000)
        #expect(policy.topUpReachedFullAt == nil)
    }

    /// 구버전 헬퍼가 쓴 파일(필드 없음)을 현재 코드가 읽을 수 있어야 한다.
    /// 스키마 버전은 1로 유지되므로 `unsupportedSchema`가 나서는 안 된다.
    @Test func decodesAPolicyWrittenBeforeTheTimestampFieldExisted() throws {
        let legacy = """
        {"schemaVersion":1,"ownerUID":501,"updatedAt":1000,
         "configuration":{"enabled":true,"limitPercentage":80,
                          "lowerHysteresisDelta":2,"topUpActive":true}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PersistedBatteryPolicy.self, from: legacy)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.configuration.topUpActive == true)
        #expect(decoded.topUpReachedFullAt == nil)
    }

    /// 현재 코드가 쓴 파일을 구버전 헬퍼가 읽어도 스키마 검사를 통과해야 한다.
    @Test func keepsSchemaVersionOneSoOlderHelpersCanStillRead() throws {
        let data = try JSONEncoder().encode(PersistedBatteryPolicy(
            ownerUID: 501,
            configuration: .init(enabled: true, topUpActive: true),
            updatedAt: 1_000,
            topUpReachedFullAt: 900))
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == 1)
        #expect(json["topUpReachedFullAt"] as? Double == 900)
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath /tmp/wattly-dd build-for-testing 2>&1 | tail -20
```

기대: 컴파일 실패 — `extra argument 'topUpReachedFullAt' in call`

- [ ] **Step 3: 최소 구현을 작성한다**

`FanControlShared/BatteryPolicyPersistence.swift`의 `PersistedBatteryPolicy` 전체를 아래로 교체:

```swift
public struct PersistedBatteryPolicy: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var ownerUID: UInt32
    public var configuration: BatteryControlConfiguration
    public var updatedAt: TimeInterval
    /// Top Up이 100%에 도달한 벽시계 시각. 도달 전에는 `nil`.
    ///
    /// **`configuration` 안이 아니라 여기 있는 이유가 핵심이다.** 설정 구조체는 앱이 60초마다
    /// 되밀어 주는 값이고, `BatteryControlPolicy.shouldReapply`는 `topUpActive`와 수동 방전
    /// 필드만 헬퍼 쪽 값으로 보존한다. 앱이 모르는 필드를 설정에 넣으면 다음 reconcile이 앱의
    /// 사본(=nil)으로 덮어써서 만료 시계가 조용히 사라진다.
    ///
    /// Optional이라 합성 Codable이 `decodeIfPresent`를 쓰고, 따라서 이 필드를 모르는 구버전
    /// 헬퍼가 쓴 파일도 그대로 읽힌다. `schemaVersion`을 올려서는 안 되는 이유는
    /// `BatteryPolicyFileStore.load()`가 정확한 일치를 요구하기 때문이다.
    public var topUpReachedFullAt: TimeInterval?

    public init(
        ownerUID: UInt32,
        configuration: BatteryControlConfiguration,
        updatedAt: TimeInterval,
        topUpReachedFullAt: TimeInterval? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.ownerUID = ownerUID
        self.configuration = configuration.normalized
        self.updatedAt = updatedAt
        self.topUpReachedFullAt = topUpReachedFullAt
    }
}
```

같은 파일 `save(_:)`의 정규화 재구성(현재 95-99행)이 새 필드를 떨어뜨리지 않도록 교체:

```swift
        let normalized = PersistedBatteryPolicy(
            ownerUID: policy.ownerUID,
            configuration: policy.configuration,
            updatedAt: policy.updatedAt,
            topUpReachedFullAt: policy.topUpReachedFullAt
        )
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath /tmp/wattly-dd test -only-testing:WattlyTests/BatteryPolicyPersistenceTests 2>&1 | tail -20
```

기대: `** TEST SUCCEEDED **`

- [ ] **Step 5: 커밋**

```bash
git add FanControlShared/BatteryPolicyPersistence.swift WattlyTests/BatteryPolicyPersistenceTests.swift && git commit -m "feat(battery): persist Top Up full-charge timestamp in schema 1"
```

---

### Task 3: 만료 신호 채널 (`BatteryMaintenanceTrigger.topUpExpired`) + 문구

앱이 "자동 만료"와 "사용자가 직접 취소"를 구분할 수 있어야 한다. 만료 후 상태는 그냥 `inhibitedAtLimit`이라 상태만 봐서는 구분이 불가능하므로, 유지보수 레코드의 trigger로 구분한다. `BatterySectionPresentation`의 switch가 전수라 이 태스크에서 문구까지 같이 넣는다.

**Files:**
- Modify: `FanControlShared/BatteryControlProtocol.swift:169-186` (`BatteryMaintenanceTrigger`)
- Modify: `Wattly/Core/BatterySectionPresentation.swift:157-168` (`maintenanceTriggerText`)
- Create: `scripts/i18n_additions/top_up_auto_expiry.json`
- Modify: `Wattly/Resources/Localizable.xcstrings` (스크립트로만 병합)
- Test: `WattlyTests/BatterySectionPresentationTests.swift:144-146`

**Interfaces:**
- Consumes: 없음.
- Produces: `BatteryMaintenanceTrigger.topUpExpired` (rawValue `"topUpExpired"`), 카탈로그 키 5개 (K1~K5, 이후 태스크가 사용).

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`WattlyTests/BatterySectionPresentationTests.swift:144-146`의 `triggers` 배열을 교체:

```swift
        let triggers: [BatteryMaintenanceTrigger] = [
            .startup, .wake, .clientConfiguration, .adapterTransition, .termination,
            .topUpExpired, .unrecognized,
        ]
```

같은 파일의 마지막 `}` 바로 앞에 추가:

```swift
    @Test func topUpExpiredTriggerHasItsOwnKoreanSentence() {
        let ko = Locale(identifier: "ko")
        let text = BatterySectionPresentation.maintenanceStatus(
            ownership: .owner(501), currentUID: 501,
            capabilities: BatteryControlCoordinator.capabilities,
            record: .init(trigger: .topUpExpired, result: .applied,
                          occurredAt: 100, reason: nil),
            locale: ko, timestampText: { _ in "21:04" })!.text
        #expect(text.contains("완충 자동 해제"))
    }

    /// 모르는 trigger는 예전처럼 관용 디코딩으로 `.unrecognized`가 되어야 한다 —
    /// 구버전 앱이 신버전 헬퍼의 상태 전체를 잃지 않게 하는 장치다.
    @Test func topUpExpiredTriggerRoundTripsAndDegradesGracefully() throws {
        let data = try JSONEncoder().encode(BatteryMaintenanceTrigger.topUpExpired)
        #expect(String(data: data, encoding: .utf8) == "\"topUpExpired\"")
        let unknown = try JSONDecoder().decode(
            BatteryMaintenanceTrigger.self, from: "\"someFutureTrigger\"".data(using: .utf8)!)
        #expect(unknown == .unrecognized)
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath /tmp/wattly-dd build-for-testing 2>&1 | tail -20
```

기대: 컴파일 실패 — `type 'BatteryMaintenanceTrigger' has no member 'topUpExpired'`

- [ ] **Step 3: enum 케이스를 추가한다**

`FanControlShared/BatteryControlProtocol.swift`의 `BatteryMaintenanceTrigger`에서 `case termination` 다음 줄에 추가:

```swift
    /// Top Up이 100% 도달 후 제한 시간을 넘겨 스스로 해제됐다. 앱은 이 trigger를 보고 사용자
    /// 취소와 구분해 알림을 띄운다 — 해제 후 상태는 평범한 `inhibitedAtLimit`이라 상태만으로는
    /// 두 경우를 구분할 수 없다.
    case topUpExpired
```

- [ ] **Step 4: 문구 스위치에 새 arm을 추가한다**

`Wattly/Core/BatterySectionPresentation.swift`의 `maintenanceTriggerText`에서 `case .termination:` 다음 줄에 추가:

```swift
        case .topUpExpired: String(localized: "유지보수: 완충 자동 해제", locale: locale)
```

- [ ] **Step 5: 번역 원본 파일을 만든다**

`scripts/i18n_additions/top_up_auto_expiry.json` 생성 (이 기능이 추가하는 문자열 5개 전부. 뒤 태스크에서 나머지 4개를 쓴다):

```json
{
  "유지보수: 완충 자동 해제": {
    "ko": "유지보수: 완충 자동 해제",
    "en": "Maintenance: Top Up auto-ended",
    "ja": "メンテナンス: 完全充電の自動解除",
    "zh-Hans": "维护：自动结束一次性充满",
    "zh-Hant": "維護：自動結束一次性充滿",
    "de": "Wartung: Vollladen automatisch beendet",
    "fr": "Maintenance : charge complète arrêtée automatiquement",
    "es": "Mantenimiento: carga completa finalizada automáticamente",
    "it": "Manutenzione: ricarica completa terminata automaticamente",
    "pt-BR": "Manutenção: carga total encerrada automaticamente",
    "pt-PT": "Manutenção: carga total terminada automaticamente",
    "ru": "Обслуживание: полная зарядка отключена автоматически",
    "nl": "Onderhoud: volladen automatisch beëindigd",
    "sv": "Underhåll: fulladdning avslutades automatiskt",
    "da": "Vedligeholdelse: fuld opladning afsluttet automatisk",
    "nb": "Vedlikehold: full lading avsluttet automatisk",
    "fi": "Ylläpito: täyteen lataus päättyi automaattisesti",
    "pl": "Konserwacja: pełne ładowanie zakończone automatycznie",
    "cs": "Údržba: plné nabití automaticky ukončeno",
    "hu": "Karbantartás: a teljes töltés automatikusan befejeződött",
    "ro": "Întreținere: încărcarea completă s-a încheiat automat",
    "el": "Συντήρηση: η πλήρης φόρτιση τερματίστηκε αυτόματα",
    "tr": "Bakım: tam şarj otomatik olarak sonlandırıldı",
    "uk": "Обслуговування: повну зарядку вимкнено автоматично",
    "he": "תחזוקה: טעינה מלאה הופסקה אוטומטית",
    "ar": "الصيانة: تم إنهاء الشحن الكامل تلقائيًا",
    "hi": "रखरखाव: फुल चार्जिंग अपने आप समाप्त",
    "th": "การบำรุงรักษา: สิ้นสุดการชาร์จเต็มโดยอัตโนมัติ",
    "vi": "Bảo trì: đã tự động kết thúc sạc đầy",
    "id": "Pemeliharaan: pengisian penuh berakhir otomatis"
  },
  "한 번만 완충 자동 해제": {
    "ko": "한 번만 완충 자동 해제",
    "en": "Top Up Ended Automatically",
    "ja": "一度だけ完全充電を自動解除",
    "zh-Hans": "一次性充满已自动结束",
    "zh-Hant": "一次性充滿已自動結束",
    "de": "Einmaliges Vollladen automatisch beendet",
    "fr": "Charge complète unique arrêtée automatiquement",
    "es": "Carga completa única finalizada automáticamente",
    "it": "Ricarica completa una tantum terminata automaticamente",
    "pt-BR": "Carga total única encerrada automaticamente",
    "pt-PT": "Carga total única terminada automaticamente",
    "ru": "Разовая полная зарядка отключена автоматически",
    "nl": "Eenmalig volladen automatisch beëindigd",
    "sv": "Engångsfulladdning avslutades automatiskt",
    "da": "Engangs fuld opladning afsluttet automatisk",
    "nb": "Engangs full lading avsluttet automatisk",
    "fi": "Kertaluonteinen täyteen lataus päättyi automaattisesti",
    "pl": "Jednorazowe pełne ładowanie zakończone automatycznie",
    "cs": "Jednorázové plné nabití automaticky ukončeno",
    "hu": "Az egyszeri teljes töltés automatikusan befejeződött",
    "ro": "Încărcarea completă unică s-a încheiat automat",
    "el": "Η εφάπαξ πλήρης φόρτιση τερματίστηκε αυτόματα",
    "tr": "Tek seferlik tam şarj otomatik olarak sonlandırıldı",
    "uk": "Одноразову повну зарядку вимкнено автоматично",
    "he": "טעינה מלאה חד-פעמית הופסקה אוטומטית",
    "ar": "تم إنهاء الشحن الكامل لمرة واحدة تلقائيًا",
    "hi": "एक बार की फुल चार्जिंग अपने आप समाप्त",
    "th": "สิ้นสุดการชาร์จเต็มครั้งเดียวโดยอัตโนมัติ",
    "vi": "Đã tự động kết thúc sạc đầy một lần",
    "id": "Pengisian penuh sekali pakai berakhir otomatis"
  },
  "완충 후 %lld시간이 지나 기존 충전 제한으로 복귀했습니다.": {
    "ko": "완충 후 %lld시간이 지나 기존 충전 제한으로 복귀했습니다.",
    "en": "%lld hours after reaching full charge, your usual charge limit has been restored.",
    "ja": "満充電から%lld時間が経過したため、元の充電上限に戻しました。",
    "zh-Hans": "充满后已过 %lld 小时，已恢复原有充电上限。",
    "zh-Hant": "充滿後已過 %lld 小時，已恢復原有充電上限。",
    "de": "%lld Stunden nach dem Vollladen wurde die übliche Ladegrenze wiederhergestellt.",
    "fr": "%lld heures après la charge complète, la limite de charge habituelle a été rétablie.",
    "es": "%lld horas después de la carga completa, se ha restaurado el límite de carga habitual.",
    "it": "%lld ore dopo la carica completa, il limite di carica abituale è stato ripristinato.",
    "pt-BR": "%lld horas após a carga completa, o limite de carga habitual foi restaurado.",
    "pt-PT": "%lld horas após a carga completa, o limite de carga habitual foi reposto.",
    "ru": "Через %lld ч после полной зарядки восстановлен обычный предел заряда.",
    "nl": "%lld uur na het volladen is de gebruikelijke laadlimiet hersteld.",
    "sv": "%lld timmar efter fulladdning har den vanliga laddgränsen återställts.",
    "da": "%lld timer efter fuld opladning er den normale opladningsgrænse gendannet.",
    "nb": "%lld timer etter full lading er den vanlige ladegrensen gjenopprettet.",
    "fi": "%lld tuntia täyteen lataamisen jälkeen tavallinen latausraja palautettiin.",
    "pl": "%lld godz. po pełnym naładowaniu przywrócono zwykły limit ładowania.",
    "cs": "%lld hodin po plném nabití byl obnoven obvyklý limit nabíjení.",
    "hu": "A teljes töltés után %lld órával visszaállt a megszokott töltési korlát.",
    "ro": "La %lld ore după încărcarea completă, limita obișnuită de încărcare a fost restabilită.",
    "el": "%lld ώρες μετά την πλήρη φόρτιση, το συνηθισμένο όριο φόρτισης αποκαταστάθηκε.",
    "tr": "Tam doluluktan %lld saat sonra normal şarj sınırına dönüldü.",
    "uk": "Через %lld год після повного заряду відновлено звичайний ліміт заряду.",
    "he": "%lld שעות לאחר טעינה מלאה, מגבלת הטעינה הרגילה שוחזרה.",
    "ar": "بعد %lld ساعة من اكتمال الشحن، تمت استعادة حد الشحن المعتاد.",
    "hi": "पूरा चार्ज होने के %lld घंटे बाद सामान्य चार्ज सीमा बहाल कर दी गई।",
    "th": "หลังจากชาร์จเต็มแล้ว %lld ชั่วโมง ระบบได้กลับไปใช้ขีดจำกัดการชาร์จเดิม",
    "vi": "Sau %lld giờ kể từ khi sạc đầy, giới hạn sạc thường ngày đã được khôi phục.",
    "id": "%lld jam setelah terisi penuh, batas pengisian biasa telah dipulihkan."
  },
  "배터리가 100%%까지 충전되었습니다. 어댑터를 분리하거나 %lld시간이 지나면 기존 충전 제한으로 자동 복귀합니다.": {
    "ko": "배터리가 100%%까지 충전되었습니다. 어댑터를 분리하거나 %lld시간이 지나면 기존 충전 제한으로 자동 복귀합니다.",
    "en": "Battery is charged to 100%%. It returns to your usual charge limit when you unplug, or after %lld hours.",
    "ja": "バッテリーが100%%まで充電されました。アダプタを取り外すか、%lld時間が経過すると、元の充電上限に自動で戻ります。",
    "zh-Hans": "电池已充至 100%%。拔下电源适配器后，或 %lld 小时后，将自动恢复原有充电上限。",
    "zh-Hant": "電池已充至 100%%。拔除電源轉接器後，或 %lld 小時後，將自動恢復原有充電上限。",
    "de": "Der Akku ist auf 100%% geladen. Nach dem Trennen des Netzteils oder nach %lld Stunden wird die übliche Ladegrenze automatisch wiederhergestellt.",
    "fr": "La batterie est chargée à 100%%. La limite de charge habituelle est rétablie lorsque vous débranchez l'adaptateur ou après %lld heures.",
    "es": "La batería está cargada al 100%%. El límite de carga habitual se restaura al desconectar el adaptador o después de %lld horas.",
    "it": "La batteria è carica al 100%%. Il limite di carica abituale viene ripristinato scollegando l'alimentatore o dopo %lld ore.",
    "pt-BR": "A bateria está carregada a 100%%. O limite de carga habitual é restaurado ao desconectar o adaptador ou após %lld horas.",
    "pt-PT": "A bateria está carregada a 100%%. O limite de carga habitual é reposto ao desligar o adaptador ou após %lld horas.",
    "ru": "Аккумулятор заряжен до 100%%. Обычный предел заряда восстановится после отключения адаптера или через %lld ч.",
    "nl": "De batterij is opgeladen tot 100%%. De gebruikelijke laadlimiet wordt hersteld zodra je de adapter loskoppelt of na %lld uur.",
    "sv": "Batteriet är laddat till 100%%. Den vanliga laddgränsen återställs när du kopplar ur adaptern eller efter %lld timmar.",
    "da": "Batteriet er opladet til 100%%. Den normale opladningsgrænse gendannes, når du frakobler adapteren, eller efter %lld timer.",
    "nb": "Batteriet er ladet til 100%%. Den vanlige ladegrensen gjenopprettes når du kobler fra adapteren, eller etter %lld timer.",
    "fi": "Akku on ladattu 100%%:iin. Tavallinen latausraja palautuu, kun irrotat verkkolaitteen tai %lld tunnin kuluttua.",
    "pl": "Bateria została naładowana do 100%%. Zwykły limit ładowania wróci po odłączeniu zasilacza lub po %lld godz.",
    "cs": "Baterie je nabitá na 100%%. Obvyklý limit nabíjení se obnoví po odpojení adaptéru nebo po %lld hodinách.",
    "hu": "Az akkumulátor 100%%-ra töltődött. A megszokott töltési korlát a hálózati adapter leválasztásakor vagy %lld óra múlva áll vissza.",
    "ro": "Bateria este încărcată la 100%%. Limita obișnuită de încărcare revine la deconectarea adaptorului sau după %lld ore.",
    "el": "Η μπαταρία φορτίστηκε στο 100%%. Το συνηθισμένο όριο φόρτισης επανέρχεται όταν αποσυνδέσετε τον προσαρμογέα ή μετά από %lld ώρες.",
    "tr": "Pil %%100 doldu. Adaptörü çıkardığınızda ya da %lld saat sonra normal şarj sınırına otomatik olarak dönülür.",
    "uk": "Акумулятор заряджено до 100%%. Звичайний ліміт заряду відновиться після від'єднання адаптера або через %lld год.",
    "he": "הסוללה נטענה ל-100%%. מגבלת הטעינה הרגילה תחזור עם ניתוק המתאם או לאחר %lld שעות.",
    "ar": "تم شحن البطارية إلى 100%%. سيعود حد الشحن المعتاد عند فصل المحوّل أو بعد %lld ساعة.",
    "hi": "बैटरी 100%% तक चार्ज हो गई है। अडैप्टर हटाने पर, या %lld घंटे बाद, सामान्य चार्ज सीमा अपने आप लौट आएगी।",
    "th": "แบตเตอรี่ชาร์จเต็ม 100%% แล้ว ระบบจะกลับไปใช้ขีดจำกัดการชาร์จเดิมเมื่อถอดอะแดปเตอร์ หรือหลังจากผ่านไป %lld ชั่วโมง",
    "vi": "Pin đã sạc đến 100%%. Giới hạn sạc thường ngày sẽ tự khôi phục khi bạn rút bộ chuyển đổi nguồn hoặc sau %lld giờ.",
    "id": "Baterai terisi 100%%. Batas pengisian biasa kembali saat adaptor dilepas atau setelah %lld jam."
  },
  "다음 외출이나 출장을 위해 배터리를 일회성으로 100%%까지 완전 충전합니다. 어댑터를 분리하거나 완충 후 %lld시간이 지나면 기존 충전 제한으로 자동 복귀합니다.": {
    "ko": "다음 외출이나 출장을 위해 배터리를 일회성으로 100%%까지 완전 충전합니다. 어댑터를 분리하거나 완충 후 %lld시간이 지나면 기존 충전 제한으로 자동 복귀합니다.",
    "en": "Charges the battery to 100%% just once for your next trip. It returns to your usual charge limit when you unplug the adapter, or %lld hours after reaching full.",
    "ja": "次のお出かけや出張のために、一度だけバッテリーを100%%まで充電します。アダプタを取り外すか、満充電から%lld時間が経過すると、元の充電上限に自動で戻ります。",
    "zh-Hans": "为下次外出或出差，一次性将电池充至 100%%。拔下电源适配器后，或充满 %lld 小时后，将自动恢复原有充电上限。",
    "zh-Hant": "為下次外出或出差，一次性將電池充至 100%%。拔除電源轉接器後，或充滿 %lld 小時後，將自動恢復原有充電上限。",
    "de": "Lädt den Akku einmalig auf 100%% für die nächste Reise. Nach dem Trennen des Netzteils oder %lld Stunden nach dem Vollladen wird die übliche Ladegrenze automatisch wiederhergestellt.",
    "fr": "Charge la batterie à 100%% une seule fois pour votre prochain déplacement. La limite de charge habituelle est rétablie lorsque vous débranchez l'adaptateur ou %lld heures après la charge complète.",
    "es": "Carga la batería al 100%% una sola vez para tu próximo viaje. El límite de carga habitual se restaura al desconectar el adaptador o %lld horas después de la carga completa.",
    "it": "Carica la batteria al 100%% una sola volta per il prossimo viaggio. Il limite di carica abituale viene ripristinato scollegando l'alimentatore o %lld ore dopo la carica completa.",
    "pt-BR": "Carrega a bateria até 100%% uma única vez para a próxima viagem. O limite de carga habitual é restaurado ao desconectar o adaptador ou %lld horas após a carga completa.",
    "pt-PT": "Carrega a bateria até 100%% uma única vez para a próxima viagem. O limite de carga habitual é reposto ao desligar o adaptador ou %lld horas após a carga completa.",
    "ru": "Однократно заряжает аккумулятор до 100%% перед поездкой. Обычный предел заряда восстанавливается после отключения адаптера или через %lld ч после полной зарядки.",
    "nl": "Laadt de batterij eenmalig tot 100%% op voor je volgende reis. De gebruikelijke laadlimiet wordt hersteld zodra je de adapter loskoppelt of %lld uur na het volladen.",
    "sv": "Laddar batteriet till 100%% en enda gång inför nästa resa. Den vanliga laddgränsen återställs när du kopplar ur adaptern eller %lld timmar efter fulladdning.",
    "da": "Oplader batteriet til 100%% én enkelt gang før næste rejse. Den normale opladningsgrænse gendannes, når du frakobler adapteren, eller %lld timer efter fuld opladning.",
    "nb": "Lader batteriet til 100%% én gang før neste tur. Den vanlige ladegrensen gjenopprettes når du kobler fra adapteren, eller %lld timer etter full lading.",
    "fi": "Lataa akun kerran 100%%:iin seuraavaa matkaa varten. Tavallinen latausraja palautuu, kun irrotat verkkolaitteen tai %lld tunnin kuluttua täyteen lataamisesta.",
    "pl": "Jednorazowo ładuje baterię do 100%% przed kolejną podróżą. Zwykły limit ładowania wraca po odłączeniu zasilacza lub %lld godz. po pełnym naładowaniu.",
    "cs": "Jednorázově nabije baterii na 100%% před další cestou. Obvyklý limit nabíjení se obnoví po odpojení adaptéru nebo %lld hodin po plném nabití.",
    "hu": "Egyszeri alkalommal 100%%-ra tölti az akkumulátort a következő útra. A megszokott töltési korlát a hálózati adapter leválasztásakor, vagy a teljes töltés után %lld órával áll vissza.",
    "ro": "Încarcă bateria la 100%% o singură dată, înainte de următoarea călătorie. Limita obișnuită de încărcare revine la deconectarea adaptorului sau după %lld ore de la încărcarea completă.",
    "el": "Φορτίζει την μπαταρία στο 100%% μία μόνο φορά για το επόμενο ταξίδι. Το συνηθισμένο όριο φόρτισης επανέρχεται όταν αποσυνδέσετε τον προσαρμογέα ή %lld ώρες μετά την πλήρη φόρτιση.",
    "tr": "Bir sonraki yolculuğunuz için pili yalnızca bir kez %%100 doldurur. Adaptörü çıkardığınızda ya da tam doluluktan %lld saat sonra normal şarj sınırına otomatik olarak döner.",
    "uk": "Одноразово заряджає акумулятор до 100%% перед поїздкою. Звичайний ліміт заряду відновлюється після від'єднання адаптера або через %lld год після повного заряду.",
    "he": "טוען את הסוללה ל-100%% פעם אחת בלבד לקראת הנסיעה הבאה. מגבלת הטעינה הרגילה חוזרת עם ניתוק המתאם או %lld שעות לאחר טעינה מלאה.",
    "ar": "يشحن البطارية إلى 100%% لمرة واحدة استعدادًا لرحلتك القادمة. ويعود حد الشحن المعتاد عند فصل المحوّل أو بعد %lld ساعة من اكتمال الشحن.",
    "hi": "अगली यात्रा के लिए बैटरी को एक बार 100%% तक चार्ज करता है। अडैप्टर हटाने पर, या पूरा चार्ज होने के %lld घंटे बाद, सामान्य चार्ज सीमा अपने आप लौट आती है।",
    "th": "ชาร์จแบตเตอรี่จนเต็ม 100%% เพียงครั้งเดียวสำหรับการเดินทางครั้งถัดไป ระบบจะกลับไปใช้ขีดจำกัดการชาร์จเดิมเมื่อถอดอะแดปเตอร์ หรือหลังจากชาร์จเต็ม %lld ชั่วโมง",
    "vi": "Sạc pin lên 100%% một lần duy nhất cho chuyến đi sắp tới. Giới hạn sạc thường ngày sẽ tự khôi phục khi bạn rút bộ chuyển đổi nguồn hoặc sau %lld giờ kể từ khi sạc đầy.",
    "id": "Mengisi daya baterai hingga 100%% sekali saja untuk perjalanan berikutnya. Batas pengisian biasa kembali saat adaptor dilepas atau %lld jam setelah terisi penuh."
  }
}
```

- [ ] **Step 6: 카탈로그에 병합한다**

```bash
python3 scripts/add_localizations.py scripts/i18n_additions/top_up_auto_expiry.json
```

기대 출력: `merged 5 keys; catalog now has 531 keys`
(언어가 하나라도 빠지면 `key '...' is missing languages: [...]`로 실패한다. 실패하면 JSON을 고치고 다시 실행한다.)

- [ ] **Step 7: 테스트가 통과하는지 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath /tmp/wattly-dd test -only-testing:WattlyTests/BatterySectionPresentationTests 2>&1 | tail -20
```

기대: `** TEST SUCCEEDED **` (30개 로케일 × 7개 trigger 전수 검사 포함)

- [ ] **Step 8: 커밋**

```bash
git add FanControlShared/BatteryControlProtocol.swift Wattly/Core/BatterySectionPresentation.swift Wattly/Resources/Localizable.xcstrings scripts/i18n_additions/top_up_auto_expiry.json WattlyTests/BatterySectionPresentationTests.swift && git commit -m "feat(battery): add topUpExpired maintenance trigger with 30-locale copy"
```

---

### Task 4: 코디네이터 배선 (스탬프 · 만료 · 영속화)

기능의 심장. 완충 도달 시각을 찍고, 12시간이 지나면 `topUpActive`를 끄고, 저장하고, `.topUpExpired` 레코드를 발행한다. 판정 호출은 `evaluateTopUpExpiry` **한 곳**이며 `sample`과 `reconcile` 양쪽이 그것을 호출한다 — 잠자기 중 만료가 도래하면 wake의 `reconcile`이 처리해야 하기 때문이다.

**Files:**
- Modify: `FanControlShared/BatteryControlCoordinator.swift` (필드 추가, `restore`, `configure`, `configureWithoutPowerReading`, `sample`, `reconcile`, `resolvedStoredPolicy`)
- Test: `WattlyTests/BatteryControlCoordinatorTests.swift`

**Interfaces:**
- Consumes: `BatteryTopUpExpiry.decide(...)` (Task 1), `PersistedBatteryPolicy.topUpReachedFullAt` (Task 2), `BatteryMaintenanceTrigger.topUpExpired` (Task 3).
- Produces: 코디네이터가 만료 시 발행하는 상태 — `lastMaintenance.trigger == .topUpExpired`, `result == .applied`(하드웨어 실패 시 `.failed`), `desiredConfiguration.topUpActive == false`. 저장 파일의 `topUpReachedFullAt`은 만료 후 `nil`.

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`WattlyTests/BatteryControlCoordinatorTests.swift`의 **파일 맨 위 `import` 아래**에 가변 시계 헬퍼를 추가한다 (기존 테스트는 전부 `now: { 100 }` 상수를 쓰므로 시간을 움직일 수단이 없다):

```swift
/// 시간을 앞뒤로 움직일 수 있는 테스트 시계. 기존 테스트들이 쓰는 `now: { 100 }` 상수로는
/// 만료처럼 시간이 얽힌 전이를 실제 대기 없이 검증할 수 없다.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ value: TimeInterval) { self.value = value }

    var now: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        value += seconds
    }

    func set(_ newValue: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
}
```

같은 파일의 `struct BatteryControlCoordinatorTests { ... }` 안, 마지막 `}` 바로 앞에 추가:

```swift
    // MARK: - Top Up 자동 만료

    /// 100% 홀드를 처음 관측한 순간 도달 시각이 파일에 남아야 한다. 데몬은 재시작 후
    /// `restore()`로 `topUpActive`를 되살리므로, 시각이 메모리에만 있으면 매 재시작마다
    /// 12시간이 처음부터 다시 시작된다.
    @Test func stampsTheFullChargeMomentIntoThePolicyFile() {
        let clock = MutableClock(1_000)
        let hardware = MockBatteryHardware()
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: hardware),
            now: { clock.now })

        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: true),
            trigger: .clientConfiguration, currentSoC: 98, isPluggedIn: true)
        #expect(store.stored?.topUpReachedFullAt == nil)

        clock.advance(by: 600)
        _ = coordinator.sample(currentSoC: 100, isPluggedIn: true)

        #expect(store.stored?.topUpReachedFullAt == 1_600)
    }

    /// 스탬프는 한 번만. 매 샘플마다 다시 찍히면 만료가 영원히 오지 않는다.
    @Test func doesNotRestampOnEverySample() {
        let clock = MutableClock(1_000)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: PolicyStoreSpy(),
            engine: BatteryControlEngine(hardware: MockBatteryHardware()),
            now: { clock.now })
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: true),
            trigger: .clientConfiguration, currentSoC: 100, isPluggedIn: true)
        _ = coordinator.sample(currentSoC: 100, isPluggedIn: true)

        clock.advance(by: 3_600)
        _ = coordinator.sample(currentSoC: 100, isPluggedIn: true)

        clock.advance(by: 11 * 3_600)   // 스탬프 기준 12시간 경과
        let status = coordinator.sample(currentSoC: 100, isPluggedIn: true)
        #expect(status.desiredConfiguration?.topUpActive == false)
    }

    @Test func expiresTopUpTwelveHoursAfterReachingFull() {
        let clock = MutableClock(1_000)
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()),
            now: { clock.now })
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: true),
            trigger: .clientConfiguration, currentSoC: 100, isPluggedIn: true)
        _ = coordinator.sample(currentSoC: 100, isPluggedIn: true)

        clock.advance(by: 12 * 3_600 - 1)
        #expect(coordinator.sample(currentSoC: 100, isPluggedIn: true)
                    .desiredConfiguration?.topUpActive == true)

        clock.advance(by: 1)
        let status = coordinator.sample(currentSoC: 100, isPluggedIn: true)

        #expect(status.desiredConfiguration?.topUpActive == false)
        #expect(status.lastMaintenance?.trigger == .topUpExpired)
        #expect(status.lastMaintenance?.result == .applied)
        #expect(store.stored?.configuration.topUpActive == false)
        #expect(store.stored?.topUpReachedFullAt == nil)
        // 사용자의 원래 한도는 그대로 남는다.
        #expect(store.stored?.configuration.limitPercentage == 80)
    }

    /// 12시간짜리 잠자기 뒤 깨어난 경우. 타이머는 잠자기 중 돌지 않으므로 wake reconcile이
    /// 같은 판정에 도달해야 한다.
    @Test func expiresOnWakeAfterASleepThatOutlastedTheWindow() {
        let clock = MutableClock(1_000)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: PolicyStoreSpy(),
            engine: BatteryControlEngine(hardware: MockBatteryHardware()),
            now: { clock.now })
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: true),
            trigger: .clientConfiguration, currentSoC: 100, isPluggedIn: true)
        _ = coordinator.sample(currentSoC: 100, isPluggedIn: true)

        clock.advance(by: 13 * 3_600)
        let status = coordinator.reconcile(
            trigger: .wake, currentSoC: 100, isPluggedIn: true)

        #expect(status.desiredConfiguration?.topUpActive == false)
        #expect(status.lastMaintenance?.trigger == .topUpExpired)
    }

    /// 어댑터를 뽑아 Top Up이 끝나면 스탬프도 함께 사라져야 한다. 남아 있으면 다음 Top Up이
    /// 켜지자마자 즉시 만료된다.
    @Test func clearsTheStampWhenTopUpEndsByUnplugging() {
        let clock = MutableClock(1_000)
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()),
            now: { clock.now })
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: true),
            trigger: .clientConfiguration, currentSoC: 100, isPluggedIn: true)
        _ = coordinator.sample(currentSoC: 100, isPluggedIn: true)
        #expect(store.stored?.topUpReachedFullAt == 1_000)

        _ = coordinator.reconcile(
            trigger: .adapterTransition, currentSoC: 100, isPluggedIn: false)

        #expect(store.stored?.configuration.topUpActive == false)
        #expect(store.stored?.topUpReachedFullAt == nil)
    }

    /// 사용자가 Top Up을 직접 끄면 스탬프도 사라진다.
    @Test func clearsTheStampWhenTheUserCancelsTopUp() {
        let clock = MutableClock(1_000)
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()),
            now: { clock.now })
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: true),
            trigger: .clientConfiguration, currentSoC: 100, isPluggedIn: true)
        _ = coordinator.sample(currentSoC: 100, isPluggedIn: true)

        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: false),
            trigger: .clientConfiguration, currentSoC: 100, isPluggedIn: true)

        #expect(store.stored?.topUpReachedFullAt == nil)
    }

    /// Top Up 유지 중 다른 설정(예: 한도)만 바뀐 재푸시는 시계를 되감지 않는다.
    @Test func keepsTheStampAcrossAConfigurePushThatLeavesTopUpOn() {
        let clock = MutableClock(1_000)
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()),
            now: { clock.now })
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: true),
            trigger: .clientConfiguration, currentSoC: 100, isPluggedIn: true)
        _ = coordinator.sample(currentSoC: 100, isPluggedIn: true)

        clock.advance(by: 3_600)
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 75, topUpActive: true),
            trigger: .clientConfiguration, currentSoC: 100, isPluggedIn: true)

        #expect(store.stored?.topUpReachedFullAt == 1_000)
    }

    /// 데몬이 재시작해도 시계는 이어져야 한다.
    @Test func restoresTheStampFromDiskOnDaemonRestart() {
        let clock = MutableClock(50_000)
        let store = PolicyStoreSpy()
        store.stored = .init(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 80, topUpActive: true),
            updatedAt: 1_000,
            topUpReachedFullAt: 1_000)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()),
            now: { clock.now })

        // 1_000 + 12h = 44_200 < 50_000 → 복원 직후 첫 샘플에서 만료된다.
        _ = coordinator.restore(currentSoC: 100, isPluggedIn: true)
        let status = coordinator.sample(currentSoC: 100, isPluggedIn: true)

        #expect(status.desiredConfiguration?.topUpActive == false)
        #expect(status.lastMaintenance?.trigger == .topUpExpired)
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath /tmp/wattly-dd test -only-testing:WattlyTests/BatteryControlCoordinatorTests 2>&1 | tail -25
```

기대: 새 테스트 8개 실패 (`stampsTheFullChargeMomentIntoThePolicyFile` 등에서 `topUpReachedFullAt == nil`)

- [ ] **Step 3: 코디네이터에 상태와 저장 헬퍼를 추가한다**

`FanControlShared/BatteryControlCoordinator.swift`의 `private let now: @Sendable () -> TimeInterval` 다음 줄에 추가:

```swift
    /// Top Up이 100%에 도달한 벽시계 시각. 저장 파일의 값을 그대로 미러링한다 — 이 값은 앱이
    /// 되밀어 주는 `BatteryControlConfiguration`이 아니라 코디네이터가 소유한다.
    private var topUpReachedFullAt: TimeInterval?
```

같은 파일의 `private func publish(...)` 바로 위에 헬퍼 두 개를 추가:

```swift
    /// 정책 저장의 유일한 경로. Top Up이 꺼져 있으면 도달 시각도 함께 지운다 — 남겨 두면 다음
    /// Top Up이 켜지자마자 즉시 만료된다.
    private func persistPolicy(_ configuration: BatteryControlConfiguration) throws {
        var persisted = configuration
        persisted.manualDischargeActive = false
        if !persisted.topUpActive {
            topUpReachedFullAt = nil
        }
        try store.save(.init(
            ownerUID: ownerUID,
            configuration: persisted,
            updatedAt: now(),
            topUpReachedFullAt: persisted.topUpActive ? topUpReachedFullAt : nil))
    }

    /// Top Up 자동 만료의 **유일한** 판정 지점.
    ///
    /// 캘리브레이션 모드가 최종 100% 홀드에 같은 `topUpActive` 원시 명령을 빌려 쓰게 되면,
    /// 예외는 아래 `calibrationActive:` 인자 하나로 들어간다. 그 플래그는 아직 존재하지 않으므로
    /// 지금은 기본값(false)에 맡긴다.
    ///
    /// 만료를 실제로 수행한 경우에만 상태를 반환한다(이미 `publish`까지 마친 상태다). `nil`이면
    /// 호출자는 평소 경로를 그대로 진행하면 된다.
    private func evaluateTopUpExpiry(
        status: BatteryControlServiceStatus,
        currentSoC: Int,
        isPluggedIn: Bool,
        temperatureCelsius: Double?
    ) -> BatteryControlServiceStatus? {
        switch BatteryTopUpExpiry.decide(
            topUpActive: engine.configuration.topUpActive,
            isHoldingAtFull: status.detailReason?.kind == .topUpComplete,
            reachedFullAt: topUpReachedFullAt,
            now: now()
        ) {
        case .none:
            return nil
        case .stamp(let moment):
            topUpReachedFullAt = moment
            // 저장 실패는 치명적이지 않다 — 다음 샘플이 다시 찍는다. 만료가 그만큼 늦어질 뿐이다.
            try? persistPolicy(engine.configuration)
            return nil
        case .expire:
            var updated = engine.configuration
            updated.topUpActive = false
            topUpReachedFullAt = nil
            try? persistPolicy(updated)
            engine.configure(updated)
            let settled = engine.verifyAndUpdate(
                currentSoC: currentSoC,
                isPluggedIn: isPluggedIn,
                temperatureCelsius: temperatureCelsius)
            let failure = hardwareFailureReason(in: settled)
            return publish(
                settled,
                trigger: .topUpExpired,
                result: failure == nil ? .applied : .failed,
                reason: failure)
        }
    }
```

- [ ] **Step 4: 저장 시각을 복원·초기화하도록 기존 경로를 수정한다**

같은 파일 `resolvedStoredPolicy()`의 본문을 교체 (미러 값을 여기서 한 번에 채운다):

```swift
    private func resolvedStoredPolicy() throws -> (
        configuration: BatteryControlConfiguration,
        ownershipFailure: BatteryControlStatusReason?
    ) {
        guard let stored = try store.load() else {
            topUpReachedFullAt = nil
            return (.init(enabled: false), nil)
        }
        guard stored.ownerUID == ownerUID else {
            topUpReachedFullAt = nil
            return (
                .init(enabled: false),
                .init(kind: .policyOwnerMismatch))
        }
        var config = stored.configuration
        config.manualDischargeActive = false
        // 데몬 재시작 뒤에도 12시간 시계가 이어지도록 파일의 값을 미러링한다.
        topUpReachedFullAt = config.topUpActive ? stored.topUpReachedFullAt : nil
        return (config, nil)
    }
```

`restore(...)`의 배터리 전원 분기(현재 52-57행 — `if !isPluggedIn && desired.topUpActive {`로 시작)를 교체:

```swift
            if !isPluggedIn && desired.topUpActive {
                desired.topUpActive = false
                try? persistPolicy(desired)
            }
```

`configure(...)`의 저장 블록(현재 158-168행)을 교체:

```swift
        do {
            try persistPolicy(normalized)
        } catch {
```

`configureWithoutPowerReading(...)`의 저장 블록(현재 219-229행 — `var persisted = normalized`로 시작하는 블록)도 동일하게 교체:

```swift
        do {
            try persistPolicy(normalized)
        } catch {
```

두 곳 모두 `var persisted = normalized` / `persisted.manualDischargeActive = false` 두 줄은 `persistPolicy`가 대신하므로 삭제한다.

`reconcile(...)`의 배터리 전원 분기(현재 296-304행)를 교체:

```swift
            do {
                try persistPolicy(updatedConfig)
            } catch {
                // If persistence write fails, proceed with in-memory policy reset
            }
```

(마찬가지로 그 블록의 `var persisted = updatedConfig` / `persisted.manualDischargeActive = false` 두 줄을 삭제한다.)

- [ ] **Step 5: 만료 판정을 두 샘플 경로에 연결한다**

`sample(...)` 전체를 교체:

```swift
    public func sample(
        currentSoC: Int,
        isPluggedIn: Bool,
        temperatureCelsius: Double? = nil
    ) -> BatteryControlServiceStatus {
        if !isPluggedIn && engine.configuration.manualDischargeActive {
            var updatedConfig = engine.configuration
            updatedConfig.manualDischargeActive = false
            engine.configure(updatedConfig)
        }
        var status = engine.update(
            currentSoC: currentSoC,
            isPluggedIn: isPluggedIn,
            temperatureCelsius: temperatureCelsius)
        if let expired = evaluateTopUpExpiry(
            status: status,
            currentSoC: currentSoC,
            isPluggedIn: isPluggedIn,
            temperatureCelsius: temperatureCelsius) {
            return expired
        }
        status.desiredConfiguration = engine.configuration
        status.lastMaintenance = latestStatus.lastMaintenance
        status.capabilities = Self.capabilities
        latestStatus = status
        return status
    }
```

`reconcile(...)`의 끝부분(`let status = engine.verifyAndUpdate(...)`부터 `return publish(...)`까지)을 교체:

```swift
        let status = engine.verifyAndUpdate(
            currentSoC: currentSoC,
            isPluggedIn: isPluggedIn,
            temperatureCelsius: temperatureCelsius)
        // 잠자기 동안에는 5초 타이머가 돌지 않는다. 12시간을 자고 깨어난 Mac은 여기서 만료된다.
        if let expired = evaluateTopUpExpiry(
            status: status,
            currentSoC: currentSoC,
            isPluggedIn: isPluggedIn,
            temperatureCelsius: temperatureCelsius) {
            return expired
        }
        let failure = hardwareFailureReason(in: status)
        return publish(
            status,
            trigger: trigger,
            result: failure == nil ? .verified : .failed,
            reason: failure)
```

- [ ] **Step 6: 테스트가 통과하는지 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath /tmp/wattly-dd test -only-testing:WattlyTests/BatteryControlCoordinatorTests -only-testing:WattlyTests/BatteryDaemonControlServiceTests 2>&1 | tail -20
```

기대: `** TEST SUCCEEDED **`

- [ ] **Step 7: 커밋**

```bash
git add FanControlShared/BatteryControlCoordinator.swift WattlyTests/BatteryControlCoordinatorTests.swift && git commit -m "feat(battery): auto-expire Top Up 12h after reaching full charge"
```

---

### Task 5: 만료 알림 (감지기 + 알림 + 완충 문구 갱신)

데몬은 root로 세션 밖에서 돌기 때문에 사용자 알림을 띄울 수 없다. 앱이 상태의 유지보수 레코드를 보고 대신 띄운다.

**Files:**
- Modify: `Wattly/Core/BatteryNotificationManager.swift`
- Test: `WattlyTests/BatteryNotificationManagerTests.swift`

**Interfaces:**
- Consumes: `BatteryMaintenanceTrigger.topUpExpired` (Task 3), `BatteryTopUpExpiry.durationHours` (Task 1), Task 3에서 병합한 카탈로그 키.
- Produces:
  - `BatteryTopUpExpiryDetector` — `mutating func update(record: BatteryMaintenanceRecord?, now: TimeInterval) -> Bool`
  - `BatteryNotificationManager.topUpExpiredTitle(locale:)`, `.topUpExpiredBody(hours:locale:)`, `.postTopUpExpiredNotification()`
  - `BatteryNotificationManager.topUpCompleteBody(hours:locale:)` — **시그니처 변경**(기존 `topUpCompleteBody(locale:)`)

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`WattlyTests/BatteryNotificationManagerTests.swift`의 `notificationTitleAndBodyAreLocalized` 안 마지막 두 `#expect`를 교체:

```swift
        #expect(BatteryNotificationManager.topUpCompleteBody(hours: 12, locale: ko)
                == "배터리가 100%까지 충전되었습니다. 어댑터를 분리하거나 12시간이 지나면 기존 충전 제한으로 자동 복귀합니다.")
        #expect(BatteryNotificationManager.topUpCompleteBody(hours: 12, locale: en)
                == "Battery is charged to 100%. It returns to your usual charge limit when you unplug, or after 12 hours.")
```

같은 파일의 마지막 `}` 바로 앞에 추가:

```swift
    @Test func expiryNotificationTitleAndBodyAreLocalized() {
        let ko = Locale(identifier: "ko")
        let en = Locale(identifier: "en")

        #expect(BatteryNotificationManager.topUpExpiredTitle(locale: ko) == "한 번만 완충 자동 해제")
        #expect(BatteryNotificationManager.topUpExpiredTitle(locale: en) == "Top Up Ended Automatically")

        #expect(BatteryNotificationManager.topUpExpiredBody(hours: 12, locale: ko)
                == "완충 후 12시간이 지나 기존 충전 제한으로 복귀했습니다.")
        #expect(BatteryNotificationManager.topUpExpiredBody(hours: 12, locale: en)
                == "12 hours after reaching full charge, your usual charge limit has been restored.")
    }

    @Test func expiryDetectorFiresOnceForOneExpiryRecord() {
        var detector = BatteryTopUpExpiryDetector()
        let record = BatteryMaintenanceRecord(
            trigger: .topUpExpired, result: .applied, occurredAt: 1_000, reason: nil)

        #expect(detector.update(record: record, now: 1_000) == true)
        #expect(detector.update(record: record, now: 1_005) == false)
    }

    /// 다른 유지보수 이벤트는 알림을 만들지 않는다 — 특히 사용자가 직접 취소한 경우
    /// (`.clientConfiguration`)에 "자동 해제됐다"고 말하면 거짓말이 된다.
    @Test func expiryDetectorIgnoresOtherTriggers() {
        var detector = BatteryTopUpExpiryDetector()
        #expect(detector.update(record: nil, now: 1_000) == false)
        #expect(detector.update(record: .init(trigger: .clientConfiguration, result: .applied,
                                              occurredAt: 1_000, reason: nil),
                                now: 1_000) == false)
        #expect(detector.update(record: .init(trigger: .wake, result: .verified,
                                              occurredAt: 1_000, reason: nil),
                                now: 1_000) == false)
    }

    /// 두 번째 만료는 다시 알린다.
    @Test func expiryDetectorFiresAgainForALaterExpiry() {
        var detector = BatteryTopUpExpiryDetector()
        #expect(detector.update(record: .init(trigger: .topUpExpired, result: .applied,
                                              occurredAt: 1_000, reason: nil),
                                now: 1_000) == true)
        #expect(detector.update(record: .init(trigger: .topUpExpired, result: .applied,
                                              occurredAt: 90_000, reason: nil),
                                now: 90_010) == true)
    }

    /// 앱을 나중에 켰을 때 헬퍼가 들고 있던 오래된 만료 레코드로 뒤늦은 알림이 뜨면 안 된다.
    @Test func expiryDetectorIgnoresAStaleRecordSeenAfterRelaunch() {
        var detector = BatteryTopUpExpiryDetector()
        #expect(detector.update(record: .init(trigger: .topUpExpired, result: .applied,
                                              occurredAt: 1_000, reason: nil),
                                now: 1_000 + 3_600) == false)
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath /tmp/wattly-dd build-for-testing 2>&1 | tail -20
```

기대: 컴파일 실패 — `cannot find 'BatteryTopUpExpiryDetector' in scope`

- [ ] **Step 3: 감지기를 추가한다**

`Wattly/Core/BatteryNotificationManager.swift`의 `BatteryTopUpTransitionDetector` 선언 바로 다음에 추가:

```swift
/// Top Up이 **스스로** 끝났을 때만 참을 반환한다.
///
/// 만료 후의 상태는 평범한 `inhibitedAtLimit`이라, 사용자가 버튼으로 취소한 경우와 상태만으로는
/// 구분할 수 없다. 그래서 헬퍼가 남긴 유지보수 레코드의 trigger를 본다. 신선도 창을 두는 이유는
/// 앱을 몇 시간 뒤에 켰을 때 헬퍼가 아직 들고 있는 오래된 레코드로 뒤늦은 알림이 뜨는 것을
/// 막기 위해서다.
public struct BatteryTopUpExpiryDetector: Sendable {
    /// 이보다 오래된 만료 레코드는 알리지 않는다.
    public static let freshnessWindow: TimeInterval = 300

    private var lastSeenOccurredAt: TimeInterval?

    public init() {}

    public mutating func update(record: BatteryMaintenanceRecord?, now: TimeInterval) -> Bool {
        guard let record, record.trigger == .topUpExpired else { return false }
        let isNew = lastSeenOccurredAt != record.occurredAt
        lastSeenOccurredAt = record.occurredAt
        return isNew && (now - record.occurredAt) <= Self.freshnessWindow
    }
}
```

- [ ] **Step 4: 알림 문구와 발송 함수를 추가/교체한다**

같은 파일에서 `topUpCompleteBody(locale:)`를 교체:

```swift
    public static func topUpCompleteBody(hours: Int, locale: Locale) -> String {
        String(format: String(localized: "배터리가 100%%까지 충전되었습니다. 어댑터를 분리하거나 %lld시간이 지나면 기존 충전 제한으로 자동 복귀합니다.", locale: locale),
               locale: locale, Int64(hours))
    }
```

`postTopUpCompleteNotification()` 안의 본문 대입을 교체:

```swift
            content.body = topUpCompleteBody(hours: BatteryTopUpExpiry.durationHours, locale: locale)
```

`postTopUpCompleteNotification()` 함수 전체 다음에 추가:

```swift
    public static func topUpExpiredTitle(locale: Locale) -> String {
        String(localized: "한 번만 완충 자동 해제", locale: locale)
    }

    public static func topUpExpiredBody(hours: Int, locale: Locale) -> String {
        String(format: String(localized: "완충 후 %lld시간이 지나 기존 충전 제한으로 복귀했습니다.", locale: locale),
               locale: locale, Int64(hours))
    }

    public static func postTopUpExpiredNotification() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let appLang = UserDefaults.standard.string(forKey: StorageKey.appLanguage) ?? Defaults.appLanguage
            let locale = AppLanguage.locale(for: appLang)
            let content = UNMutableNotificationContent()
            content.title = topUpExpiredTitle(locale: locale)
            content.body = topUpExpiredBody(hours: BatteryTopUpExpiry.durationHours, locale: locale)
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "dev.jjundev.Wattly.topUpExpired",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }
```

- [ ] **Step 5: 테스트가 통과하는지 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath /tmp/wattly-dd test -only-testing:WattlyTests/BatteryNotificationManagerTests 2>&1 | tail -20
```

기대: `** TEST SUCCEEDED **`

- [ ] **Step 6: 커밋**

```bash
git add Wattly/Core/BatteryNotificationManager.swift WattlyTests/BatteryNotificationManagerTests.swift && git commit -m "feat(battery): notify when Top Up ends automatically"
```

---

### Task 6: 앱 배선 + 설명 문구 + 문서

감지기를 브리지에 연결하고, 사용자에게 보이는 설명을 실제 동작과 일치시킨다. 브리지는 `MenuBarLabel`에 붙어 항상 살아 있고 60초마다 상태를 다시 읽으므로, 만료 레코드는 신선도 창(300초) 안에 관측된다.

**Files:**
- Modify: `Wattly/Views/BatteryControlBridge.swift:22`, `:122-127`
- Modify: `Wattly/Core/BatterySectionPresentation.swift` (설명 문구 생성기 추가)
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift:166`
- Modify: `README.md:141-143`
- Modify: `docs/features/battery-management/02-top-up.md`
- Test: `WattlyTests/BatterySectionPresentationTests.swift`

**Interfaces:**
- Consumes: `BatteryTopUpExpiryDetector`, `BatteryNotificationManager.postTopUpExpiredNotification()` (Task 5), `BatteryTopUpExpiry.durationHours` (Task 1).
- Produces: `BatterySectionPresentation.topUpDescription(hours:locale:) -> String`

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`WattlyTests/BatterySectionPresentationTests.swift`의 마지막 `}` 바로 앞에 추가:

```swift
    @Test func topUpDescriptionNamesBothEndConditions() {
        let ko = Locale(identifier: "ko")
        let en = Locale(identifier: "en")

        let korean = BatterySectionPresentation.topUpDescription(hours: 12, locale: ko)
        #expect(korean.contains("어댑터를 분리하거나"))
        #expect(korean.contains("12시간"))
        #expect(korean.contains("100%"))

        let english = BatterySectionPresentation.topUpDescription(hours: 12, locale: en)
        #expect(english.contains("12 hours"))
        #expect(english != korean)
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath /tmp/wattly-dd build-for-testing 2>&1 | tail -20
```

기대: 컴파일 실패 — `type 'BatterySectionPresentation' has no member 'topUpDescription'`

- [ ] **Step 3: 설명 문구 생성기를 추가한다**

`Wattly/Core/BatterySectionPresentation.swift`의 `maintenanceActionLabel(_:locale:)` 바로 앞에 추가:

```swift
    /// 설정 화면의 "한 번만 완충" 설명. 종료 조건이 두 개(어댑터 분리 / 시간 만료)가 되었으므로
    /// 둘 다 문장에 나온다. 시간 수를 인자로 받는 이유는 `BatteryTopUpExpiry.duration`이 바뀌어도
    /// 문구가 따로 놀지 않게 하기 위해서다.
    static func topUpDescription(hours: Int, locale: Locale) -> String {
        String(format: String(localized: "다음 외출이나 출장을 위해 배터리를 일회성으로 100%%까지 완전 충전합니다. 어댑터를 분리하거나 완충 후 %lld시간이 지나면 기존 충전 제한으로 자동 복귀합니다.", locale: locale),
               locale: locale, Int64(hours))
    }
```

- [ ] **Step 4: 설정 화면의 문구를 교체한다**

`Wattly/Views/Settings/SettingsBatterySection.swift:166`의 `Text(LocalizedStringKey("다음 외출이나 출장을 위해 ... 자동 복귀합니다."))` 한 줄을 교체:

```swift
                            Text(BatterySectionPresentation.topUpDescription(
                                hours: BatteryTopUpExpiry.durationHours, locale: locale))
```

- [ ] **Step 5: 브리지에 감지기를 연결한다**

`Wattly/Views/BatteryControlBridge.swift:22`의 `@State private var topUpDetector = BatteryTopUpTransitionDetector()` 다음 줄에 추가:

```swift
    @State private var topUpExpiryDetector = BatteryTopUpExpiryDetector()
```

같은 파일의 `.onChange(of: client.status) { _, newStatus in ... }` 블록을 교체:

```swift
            .onChange(of: client.status) { _, newStatus in
                syncMonitorTarget()
                if topUpDetector.update(reasonKind: newStatus.detailReason?.kind) {
                    BatteryNotificationManager.postTopUpCompleteNotification()
                }
                // 헬퍼가 스스로 Top Up을 끝낸 경우에만 참이 된다. 사용자가 버튼으로 취소한
                // 경우와 만료 후 상태가 동일하기 때문에 유지보수 레코드로 구분한다.
                if topUpExpiryDetector.update(record: newStatus.lastMaintenance,
                                              now: Date().timeIntervalSince1970) {
                    BatteryNotificationManager.postTopUpExpiredNotification()
                }
            }
```

- [ ] **Step 6: 문서를 갱신한다**

`README.md:143`의 자동 복귀 항목을 교체:

```markdown
- **이중 자동 복귀 메커니즘**: 100% 완충 후 전원 어댑터를 분리하면 기존에 설정해 둔 충전 한도(예: 80%)로 자동 복귀합니다. 어댑터를 계속 꽂아 두더라도 100% 도달 후 12시간이 지나면 헬퍼가 스스로 Top Up을 해제하고 알림을 보냅니다 — 켜 두고 잊어도 배터리가 100%에 무기한 머물지 않습니다.
```

`docs/features/battery-management/02-top-up.md`의 `## 최소 기능 범위` 목록에서 마지막 항목(`6. 사용자가 언제든 취소 가능`) **바로 다음 줄**에 추가:

```markdown
7. 100% 도달 후 12시간 경과 시 자동 종료 + 알림
```

같은 파일의 `## 안전·동작 규칙` 목록 마지막 항목 다음 줄에 추가:

```markdown
- 만료 판정은 데몬(`BatteryControlCoordinator.evaluateTopUpExpiry`) 한 곳에서만 내린다. Calibration이 최종 100% 홀드에 `topUpActive`를 빌려 쓰게 되면 그 지점의 `calibrationActive` 인자로 예외를 넣는다.
```

같은 파일의 `## 미결정 사항` 첫 항목을 교체:

```markdown
- ~~100% 도달 즉시 종료할지, 어댑터 분리 전까지 100% 상태를 유지할지 결정해야 한다.~~ **결정됨(2026-08-28)**: 100% 도달 후에도 홀드하되, 어댑터 분리 또는 **완충 후 12시간 경과** 중 먼저 오는 쪽에서 종료한다. 상시 전원 연결 사용자가 켜고 잊는 경우를 막기 위한 상한이다(Battery University BU-808 기준 25°C·100% 상시 유지는 연 20% 용량 손실).
```

- [ ] **Step 7: 전체 테스트를 돌린다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath /tmp/wattly-dd test 2>&1 | tail -20
```

기대: `** TEST SUCCEEDED **`, 기준선 1048개 + 신규 약 26개

- [ ] **Step 8: 커밋**

```bash
git add Wattly/Views/BatteryControlBridge.swift Wattly/Core/BatterySectionPresentation.swift Wattly/Views/Settings/SettingsBatterySection.swift WattlyTests/BatterySectionPresentationTests.swift README.md docs/features/battery-management/02-top-up.md && git commit -m "feat(battery): surface Top Up auto-expiry in the app and docs"
```

---

## 실기 확인 (선택, 코드 변경 없음)

12시간을 기다리지 않고 전체 경로를 확인하려면 `BatteryTopUpExpiry.duration`을 임시로 `120`(2분)으로 바꿔 빌드한 뒤 Top Up을 켜고 100% 도달을 기다린다. 확인할 것:

1. 2분 뒤 설정 화면의 "한 번만 완충" 버튼이 `활성화됨` → `비활성화됨`으로 바뀐다.
2. "한 번만 완충 자동 해제" 알림이 한 번만 뜬다.
3. 유지보수 상태 줄에 "유지보수: 완충 자동 해제"가 보인다.
4. `sudo cat '/Library/Application Support/Wattly/battery-control-v1.json'`에 `"topUpActive":false`, `topUpReachedFullAt` 키 없음, `"schemaVersion":1`.

확인 후 상수를 `12 * 60 * 60`으로 되돌리고 재빌드한다. **이 임시 변경을 커밋하지 않는다.**
