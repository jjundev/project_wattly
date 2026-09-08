# 데몬 방어 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** root 데몬이 XPC 클라이언트를 **믿지 않아도** 안전하게 만든다: 요청 속도 제한, 있을 수 없는 generation 거부, 24시간 동안 앱이 연락하지 않으면 캘리브레이션·수동 방전·Top Up을 단순 한도로 강등, root 소유가 아닌 정책 파일 경로 거부, 시작 실패 시 launchd 재시작 폭주 완화.

**Architecture:** 판정은 전부 `FanControlShared`의 순수 타입(`RequestRateLimiter`, `ClientGenerationPolicy`, `BatteryClientAbsencePolicy`)에 두고 테스트한다. 데몬 쪽 배선은 `BatteryDaemonControlService`(배터리 XPC 진입), `FanControlEngine.acceptClientCommand`(팬 XPC 진입), `BatteryControlCoordinator.sample`(deadman), `BatteryPolicyFileStore`(경로 신뢰), `FanControlDaemon.run`(백오프)에 한 줄씩 들어간다.

**Tech Stack:** Swift 6, Darwin `lstat`, Swift Testing.

**Spec:** 감사 보고서 §1 Medium("XPC 진입점에 속도 제한·generation 잠금 방어가 없다"), Medium("배터리 정책이 앱 없이 무기한 지속"), Low("정책 디렉터리를 데몬이 lazy 생성", "KeepAlive 크래시 루프") — https://claude.ai/code/artifact/20a3c5b7-ad33-4ec3-ae78-288a0259454d

## Global Constraints

- 선행: 2단계(설치 스크립트가 `/Library/Application Support/Wattly`를 root:wheel 755로 만든다). 이 계획의 Task 4는 그 전제 위에서 root 소유가 아닌 경로를 거부한다.
- 3단계가 끝났다면 브리지가 250 ms 디바운스로 밀어 넣으므로 정상 사용은 분당 수 회다. 속도 제한 상한(20회 버킷, 초당 0.5 회 충전)은 그보다 훨씬 넉넉하다.
- `BatteryMaintenanceTrigger`·`BatteryControlStatusReason.Kind`는 lenient 디코딩이라 새 케이스를 추가해도 구버전 앱이 깨지지 않는다.
- 데몬 타깃에 테스트가 없으므로 배선 코드는 짧게, 판정은 순수 타입에.
- Swift 6 strict concurrency, macOS 14.0.

---

## 파일 구조

| 파일 | 책임 |
|------|------|
| `FanControlShared/ClientRequestPolicy.swift` (신규) | `RequestRateLimiter`(토큰 버킷), `ClientGenerationPolicy.isPlausible`. |
| `FanControlShared/BatteryClientAbsencePolicy.swift` (신규) | deadman 판정 + 강등 규칙. |
| `FanControlShared/BatteryControlProtocol.swift:212-222` (수정) | `BatteryMaintenanceTrigger.clientAbsenceExpired`. |
| `FanControlShared/BatteryDaemonControlService.swift` (수정) | `now` 주입, 속도 제한, plausibility, `noteClientContact`. |
| `FanControlShared/FanControlEngine.swift:326-330` (수정) | `acceptClientCommand(generation:now:)` + 속도 제한. |
| `FanControlShared/BatteryControlCoordinator.swift` (수정) | `lastClientContactAt`, `noteClientContact()`, `evaluateClientAbsence`. |
| `FanControlShared/BatteryPolicyPersistence.swift` (수정) | `expectedOwnerUID`, `lstat` 검사, `BatteryPolicyStoreError.untrustedPath`. |
| `WattlyFanDaemon/FanControlDaemon.swift:59` (수정) | 시작 실패 백오프. |
| 테스트: `ClientRequestPolicyTests.swift`, `BatteryClientAbsencePolicyTests.swift` (신규), `BatteryDaemonControlServiceTests.swift`, `FanControlEngineTests.swift`, `BatteryControlCoordinatorTests.swift`, `BatteryPolicyPersistenceTests.swift` (추가) | |

---

### Task 1: `RequestRateLimiter`와 `ClientGenerationPolicy`

**Files:**
- Create: `FanControlShared/ClientRequestPolicy.swift`
- Create: `WattlyTests/ClientRequestPolicyTests.swift`

**Interfaces:**
- Produces:
  - `public struct RequestRateLimiter: Equatable, Sendable { public init(capacity: Int, refillPerSecond: Double); public mutating func allow(now: TimeInterval) -> Bool }`
  - `public enum ClientGenerationPolicy { public static let maximumSkewSeconds: TimeInterval = 86_400; public static func isPlausible(_ generation: UInt64, now: TimeInterval) -> Bool }`

- [ ] **Step 1: 실패하는 테스트**

```swift
// WattlyTests/ClientRequestPolicyTests.swift
import Testing
import Foundation
@testable import Wattly

@Suite struct ClientRequestPolicyTests {
    @Test func bucketAllowsUpToCapacityThenRefillsOverTime() {
        var limiter = RequestRateLimiter(capacity: 3, refillPerSecond: 1.0)
        #expect(limiter.allow(now: 100))
        #expect(limiter.allow(now: 100))
        #expect(limiter.allow(now: 100))
        #expect(!limiter.allow(now: 100))          // 비었다
        #expect(!limiter.allow(now: 100.5))        // 0.5 토큰 — 아직 부족
        #expect(limiter.allow(now: 101.0))         // 1 토큰 충전
        #expect(!limiter.allow(now: 101.0))
    }

    @Test func bucketNeverExceedsCapacityAndIgnoresClockGoingBackwards() {
        var limiter = RequestRateLimiter(capacity: 2, refillPerSecond: 10)
        #expect(limiter.allow(now: 100))
        #expect(limiter.allow(now: 100))
        #expect(!limiter.allow(now: 100))
        _ = limiter.allow(now: 1_000)             // 오래 지나도 용량까지만
        #expect(limiter.allow(now: 1_000))
        #expect(!limiter.allow(now: 1_000))
        #expect(!limiter.allow(now: 900))          // 시계가 뒤로 가도 토큰이 생기지 않는다
    }

    /// 클라이언트 generation은 μs 단위 벽시계로 시작한다(`BatteryControlClient`/`FanControlClient`).
    /// 하루 이상 미래는 스푸핑된 `UInt64.max` 잠금 시도로 본다.
    @Test func generationMustNotBeMoreThanADayInTheFuture() {
        let now: TimeInterval = 1_800_000_000
        let nowMicros = UInt64(now * 1_000_000)
        #expect(ClientGenerationPolicy.isPlausible(nowMicros, now: now))
        #expect(ClientGenerationPolicy.isPlausible(nowMicros + 1_000, now: now))
        #expect(ClientGenerationPolicy.isPlausible(UInt64((now + 86_000) * 1_000_000), now: now))
        #expect(!ClientGenerationPolicy.isPlausible(UInt64((now + 90_000) * 1_000_000), now: now))
        #expect(!ClientGenerationPolicy.isPlausible(UInt64.max, now: now))
        #expect(ClientGenerationPolicy.isPlausible(1, now: now))     // 작은 값은 언제나 가능(테스트 픽스처)
    }
}
```

- [ ] **Step 2: 실패 확인** — Expected: 컴파일 실패.

- [ ] **Step 3: 구현**

```swift
// FanControlShared/ClientRequestPolicy.swift
import Foundation

/// 토큰 버킷. XPC 진입점은 호출 속도를 호출자가 정하므로, 데몬이 상한을 갖는다.
/// 정상 사용(앱 시작·wake·설정 변경 디바운스)은 분당 몇 번이고, 버킷은 그 수십 배다.
public struct RequestRateLimiter: Equatable, Sendable {
    public let capacity: Double
    public let refillPerSecond: Double
    private var tokens: Double
    private var lastRefillAt: TimeInterval?

    public init(capacity: Int, refillPerSecond: Double) {
        self.capacity = Double(capacity)
        self.refillPerSecond = refillPerSecond
        self.tokens = Double(capacity)
    }

    public mutating func allow(now: TimeInterval) -> Bool {
        if let last = lastRefillAt {
            if now > last {
                tokens = min(capacity, tokens + (now - last) * refillPerSecond)
                lastRefillAt = now
            }
        } else {
            lastRefillAt = now
        }
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

/// 상태 변경 요청의 `generation`은 클라이언트가 μs 벽시계에서 시작해 1씩 올린다. 데몬은 "더 큰 값만 수락"으로
/// 순서를 지키는데, 그 규칙만 있으면 `UInt64.max` 한 번으로 정상 앱을 재시작 전까지 잠글 수 있다.
/// 하루 이상 미래인 값은 거부한다 — 시계가 그만큼 틀린 앱은 어차피 만료 판정도 틀린다.
public enum ClientGenerationPolicy {
    public static let maximumSkewSeconds: TimeInterval = 86_400

    public static func isPlausible(_ generation: UInt64, now: TimeInterval) -> Bool {
        let ceiling = (now + maximumSkewSeconds) * 1_000_000
        guard ceiling > 0 else { return false }
        return Double(generation) <= ceiling
    }
}
```

- [ ] **Step 4: 통과 확인** — Run: `… -only-testing:WattlyTests/ClientRequestPolicyTests` — Expected: 3개 PASS.

- [ ] **Step 5: Commit**

```bash
git add FanControlShared/ClientRequestPolicy.swift WattlyTests/ClientRequestPolicyTests.swift
git commit -m "feat(daemon): add pure request rate limiter and generation plausibility policy"
```

---

### Task 2: 배터리·팬 XPC 진입점에 배선

**Files:**
- Modify: `FanControlShared/BatteryDaemonControlService.swift:38-49, 63-84`
- Modify: `FanControlShared/FanControlEngine.swift:69-81, 208-212, 326-330`
- Modify: `WattlyFanDaemon/FanControlDaemon.swift:44-46` (`BatteryDaemonControlService(coordinator:now:)`)
- Test: `WattlyTests/BatteryDaemonControlServiceTests.swift`, `WattlyTests/FanControlEngineTests.swift`

**Interfaces:**
- `BatteryDaemonControlService.init(coordinator:now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 })`
- `BatteryDaemonControlService.configure(encodedRequest:currentReading:)`: 거부(속도·plausibility·stale)는 모두 `coordinator.latestStatus`를 인코딩해 돌려준다(기존 stale 경로와 동일).
- `FanControlEngine`: `configure(_:clientGeneration:now:)`와 `release(now:reason:clientGeneration:)`가 `acceptClientCommand(generation:now:)`를 부른다.

- [ ] **Step 1: 실패하는 테스트** — `BatteryDaemonControlServiceTests`에 추가(파일의 `MockBatteryHardware`, `PolicyStoreSpy` 사용):

```swift
    @Test func implausibleGenerationIsIgnoredWithoutATransaction() throws {
        let hardware = MockBatteryHardware()
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store, engine: BatteryControlEngine(hardware: hardware), now: { 100 })
        let service = BatteryDaemonControlService(coordinator: coordinator, now: { 100 })
        let request = BatteryControlConfigurationRequest(
            configuration: .init(enabled: true, limitPercentage: 80), generation: UInt64.max)
        _ = try service.configure(encodedRequest: BatteryControlCodec.encode(request), currentReading: nil)
        #expect(store.events.isEmpty)
        // 그 뒤 정상 generation은 여전히 수락된다 — 잠기지 않았다.
        let sane = BatteryControlConfigurationRequest(
            configuration: .init(enabled: true, limitPercentage: 80), generation: 100_000_000)
        _ = try service.configure(encodedRequest: BatteryControlCodec.encode(sane), currentReading: nil)
        #expect(store.events.contains("save"))
    }

    @Test func configureFloodIsRateLimitedToTheBucket() throws {
        let hardware = MockBatteryHardware()
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store, engine: BatteryControlEngine(hardware: hardware), now: { 100 })
        let service = BatteryDaemonControlService(coordinator: coordinator, now: { 100 })
        for generation in 1...(BatteryDaemonControlService.configureBucketCapacity + 5) {
            let request = BatteryControlConfigurationRequest(
                configuration: .init(enabled: true, limitPercentage: 50 + generation % 50), generation: UInt64(generation))
            _ = try service.configure(encodedRequest: BatteryControlCodec.encode(request), currentReading: nil)
        }
        #expect(store.events.filter { $0 == "save" }.count == BatteryDaemonControlService.configureBucketCapacity)
    }
```

`FanControlEngineTests`에 추가(파일 하단의 `private final class FakeFanControlHardware`를 그대로 쓴다):

```swift
    @Test func implausibleFanGenerationIsRejectedWithoutLockingLaterCommands() throws {
        let hardware = FakeFanControlHardware()
        let engine = FanControlEngine(hardware: hardware)
        engine.resetAllFansToAutomatic(now: 100)
        let before = engine.status
        let configuration = FanControlConfiguration(enabled: true, curve: FanCurvePreset.balanced.curve)
        try engine.configure(configuration, clientGeneration: UInt64.max, now: 100)
        #expect(engine.status == before)                  // 무시됨 — 상태가 그대로
        try engine.configure(configuration, clientGeneration: 100_000_000, now: 100)
        #expect(engine.status != before)                  // 잠기지 않음 — 정상 generation은 받아들여진다
    }
```

- [ ] **Step 2: 실패 확인** — Expected: 컴파일 실패(`now:` 라벨, `configureBucketCapacity` 없음).

- [ ] **Step 3: `BatteryDaemonControlService` 수정**

```swift
public final class BatteryDaemonControlService {
    /// 버킷 20, 초당 0.5 충전 = 지속 분당 30회. 앱의 디바운스된 밀어 넣기는 그 1/10도 안 된다.
    public static let configureBucketCapacity = 20
    public static let configureRefillPerSecond = 0.5

    private let coordinator: BatteryControlCoordinator
    private let now: @Sendable () -> TimeInterval
    private var lastGeneration: UInt64 = 0
    private var lastPowerReading: BatteryPowerSourceReading?
    private var configureLimiter: RequestRateLimiter

    public init(
        coordinator: BatteryControlCoordinator,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.coordinator = coordinator
        self.now = now
        self.configureLimiter = RequestRateLimiter(
            capacity: Self.configureBucketCapacity, refillPerSecond: Self.configureRefillPerSecond)
    }
```

`configure(encodedRequest:currentReading:)`의 generation 가드를 다음으로 교체:

```swift
        let request = try BatteryControlCodec.decode(
            BatteryControlConfigurationRequest.self,
            from: encodedRequest)
        let moment = now()
        // 순서: plausibility → stale → 속도. 스푸핑된 거대 generation은 lastGeneration에 닿기 전에 떨어진다.
        guard ClientGenerationPolicy.isPlausible(request.generation, now: moment),
              request.generation > lastGeneration,
              configureLimiter.allow(now: moment) else {
            return try BatteryControlCodec.encode(coordinator.latestStatus)
        }
        lastGeneration = request.generation
        coordinator.noteClientContact()
```

`sample(currentReading:force:)`의 첫 줄에 추가:

```swift
        if force { coordinator.noteClientContact() }
```

(`noteClientContact()`는 Task 3에서 정의한다. Task 2를 먼저 컴파일하려면 Task 3의 Step 3 코디네이터 부분을 먼저 넣거나, 두 태스크를 한 커밋으로 묶는다 — 아래 Step 6 참고.)

- [ ] **Step 4: `FanControlEngine` 수정**

```swift
    private var commandLimiter = RequestRateLimiter(capacity: 20, refillPerSecond: 0.5)

    private func acceptClientCommand(generation: UInt64, now: TimeInterval) -> Bool {
        guard ClientGenerationPolicy.isPlausible(generation, now: now) else { return false }
        guard latestClientCommandGeneration.map({ generation > $0 }) ?? true else { return false }
        guard commandLimiter.allow(now: now) else { return false }
        latestClientCommandGeneration = generation
        return true
    }
```

`configure(_:clientGeneration:now:)`(75행)와 `release(now:reason:clientGeneration:)`(208행)의 `acceptClientCommand(generation: clientGeneration)` 호출에 `now: now`를 추가한다.

- [ ] **Step 5: `FanControlDaemon.init`** — `BatteryDaemonControlService(coordinator: batteryCoordinator)`를 `BatteryDaemonControlService(coordinator: batteryCoordinator, now: { Date().timeIntervalSince1970 })`로.

- [ ] **Step 6: 통과 확인** — Task 3 Step 3의 코디네이터 변경(`noteClientContact`)을 먼저 적용한 뒤: Run: `… -only-testing:WattlyTests/BatteryDaemonControlServiceTests`, `… -only-testing:WattlyTests/FanControlEngineTests` — Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add FanControlShared/BatteryDaemonControlService.swift FanControlShared/FanControlEngine.swift WattlyFanDaemon/FanControlDaemon.swift WattlyTests/BatteryDaemonControlServiceTests.swift WattlyTests/FanControlEngineTests.swift
git commit -m "fix(daemon): rate-limit XPC commands and reject implausible client generations"
```

---

### Task 3: 배터리 정책 deadman — 24시간 무연락이면 단순 한도로 강등

**Files:**
- Create: `FanControlShared/BatteryClientAbsencePolicy.swift`
- Modify: `FanControlShared/BatteryControlProtocol.swift:212-222`
- Modify: `FanControlShared/BatteryControlCoordinator.swift` (필드, `noteClientContact`, `sample` 앞부분, `evaluateClientAbsence`)
- Create: `WattlyTests/BatteryClientAbsencePolicyTests.swift`
- Test: `WattlyTests/BatteryControlCoordinatorTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum BatteryClientAbsencePolicy {
      public static let expiry: TimeInterval = 24 * 60 * 60
      public enum Decision: Equatable, Sendable { case none, degrade }
      public static func decide(configuration: BatteryControlConfiguration, lastContactAt: TimeInterval, now: TimeInterval, expiry: TimeInterval = expiry) -> Decision
      public static func degraded(_ configuration: BatteryControlConfiguration) -> BatteryControlConfiguration
  }
  ```
  - `BatteryMaintenanceTrigger.clientAbsenceExpired`
  - `BatteryControlCoordinator.noteClientContact()`

- [ ] **Step 1: 실패하는 테스트**

```swift
// WattlyTests/BatteryClientAbsencePolicyTests.swift
import Testing
import Foundation
@testable import Wattly

@Suite struct BatteryClientAbsencePolicyTests {
    private var calibrating: BatteryControlConfiguration {
        .init(enabled: true, limitPercentage: 80, topUpActive: true, calibrationActive: true, calibrationTargetPercentage: 20)
    }

    @Test func plainLimitNeverDegrades() {
        let plain = BatteryControlConfiguration(enabled: true, limitPercentage: 80)
        #expect(BatteryClientAbsencePolicy.decide(configuration: plain, lastContactAt: 0, now: 10 * 86_400) == .none)
    }

    @Test func activityDegradesOnlyAfterTheExpiry() {
        #expect(BatteryClientAbsencePolicy.decide(configuration: calibrating, lastContactAt: 100, now: 100 + 86_399) == .none)
        #expect(BatteryClientAbsencePolicy.decide(configuration: calibrating, lastContactAt: 100, now: 100 + 86_400) == .degrade)
        let manual = BatteryControlConfiguration(enabled: true, limitPercentage: 80, manualDischargeActive: true, manualDischargeTarget: 60)
        #expect(BatteryClientAbsencePolicy.decide(configuration: manual, lastContactAt: 100, now: 100 + 86_400) == .degrade)
        let topUp = BatteryControlConfiguration(enabled: true, limitPercentage: 80, topUpActive: true)
        #expect(BatteryClientAbsencePolicy.decide(configuration: topUp, lastContactAt: 100, now: 100 + 86_400) == .degrade)
    }

    @Test func clockGoingBackwardsDoesNotDegrade() {
        #expect(BatteryClientAbsencePolicy.decide(configuration: calibrating, lastContactAt: 1_000_000, now: 100) == .none)
    }

    @Test func degradedKeepsTheLimitAndDropsEveryActivity() {
        let d = BatteryClientAbsencePolicy.degraded(calibrating)
        #expect(d.enabled == true && d.limitPercentage == 80)
        #expect(d.topUpActive == false && d.manualDischargeActive == false && d.calibrationActive == false)
    }
}
```

`BatteryControlCoordinatorTests`에 추가(파일의 `MutableClock`, `PolicyStoreSpy`, `MockBatteryHardware` 사용):

```swift
    @Test func calibrationIsDegradedToThePlainLimitAfterADayWithoutTheApp() {
        let clock = MutableClock(1_000)
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .allowed
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store, engine: BatteryControlEngine(hardware: hardware), now: { clock.now })
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, topUpActive: true, calibrationActive: true, calibrationTargetPercentage: 20),
            trigger: .clientConfiguration, currentSoC: 50, isPluggedIn: true)
        coordinator.noteClientContact()

        clock.advance(by: 23 * 3600)
        _ = coordinator.sample(currentSoC: 50, isPluggedIn: true)
        #expect(coordinator.latestStatus.desiredConfiguration?.calibrationActive == true)

        clock.advance(by: 2 * 3600)
        let status = coordinator.sample(currentSoC: 50, isPluggedIn: true)
        #expect(status.desiredConfiguration?.calibrationActive == false)
        #expect(status.desiredConfiguration?.topUpActive == false)
        #expect(status.desiredConfiguration?.enabled == true)
        #expect(status.lastMaintenance?.trigger == .clientAbsenceExpired)
        #expect(store.stored?.configuration.calibrationActive == false)
    }

    @Test func aStatusCallCountsAsClientContact() {
        let clock = MutableClock(1_000)
        let hardware = MockBatteryHardware()
        hardware.reportedGate = .allowed
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store, engine: BatteryControlEngine(hardware: hardware), now: { clock.now })
        _ = coordinator.configure(
            .init(enabled: true, limitPercentage: 80, manualDischargeActive: true, manualDischargeTarget: 60),
            trigger: .clientConfiguration, currentSoC: 90, isPluggedIn: true)
        coordinator.noteClientContact()
        clock.advance(by: 20 * 3600)
        coordinator.noteClientContact()              // 앱의 60초 status 폴링이 이걸 부른다
        clock.advance(by: 20 * 3600)
        let status = coordinator.sample(currentSoC: 90, isPluggedIn: true)
        #expect(status.desiredConfiguration?.manualDischargeActive == true)
    }
```

- [ ] **Step 2: 실패 확인** — Expected: 컴파일 실패.

- [ ] **Step 3: 구현**

```swift
// FanControlShared/BatteryClientAbsencePolicy.swift
import Foundation

/// 팬에는 15초 heartbeat가 있지만 배터리 정책은 앱 없이도 영속한다(캘리브레이션은 의도적으로). 사용자가
/// Wattly.app만 지우면 Mac이 15~50% 구간이나 100% 홀드에 갇힌 채 되돌릴 UI가 없다. 하루 동안 앱이
/// 한 번도 연락하지 않으면 활동(캘리브레이션·수동 방전·Top Up)만 내리고 단순 한도는 남긴다 —
/// 한도는 사용자가 고른 정상 상태고, 활동은 절차다.
public enum BatteryClientAbsencePolicy {
    public static let expiry: TimeInterval = 24 * 60 * 60

    public enum Decision: Equatable, Sendable {
        case none
        case degrade
    }

    public static func decide(
        configuration: BatteryControlConfiguration,
        lastContactAt: TimeInterval,
        now: TimeInterval,
        expiry: TimeInterval = BatteryClientAbsencePolicy.expiry
    ) -> Decision {
        let hasActivity = configuration.calibrationActive || configuration.manualDischargeActive || configuration.topUpActive
        guard hasActivity, now >= lastContactAt, now - lastContactAt >= expiry else { return .none }
        return .degrade
    }

    public static func degraded(_ configuration: BatteryControlConfiguration) -> BatteryControlConfiguration {
        var copy = configuration
        copy.calibrationActive = false
        copy.manualDischargeActive = false
        copy.topUpActive = false
        return copy
    }
}
```

`BatteryMaintenanceTrigger`에 `case topUpExpired` 아래:

```swift
    /// 앱이 하루 동안 연락하지 않아 데몬이 캘리브레이션·수동 방전·Top Up을 스스로 내렸다. 한도는 유지된다.
    case clientAbsenceExpired
```

`BatteryControlCoordinator`: 필드 추가(`private var clamshellExpiredForCurrentDischarge` 아래):

```swift
    /// 앱이 마지막으로 XPC로 연락한 시각(configure 또는 강제 status). 시작 시각으로 초기화한다.
    private var lastClientContactAt: TimeInterval
```

`init`의 `self.sleepInhibitor = sleepInhibitor` 다음에 `lastClientContactAt = now()`. 공개 메서드 추가:

```swift
    public func noteClientContact() { lastClientContactAt = now() }
```

`sample(currentSoC:isPluggedIn:temperatureCelsius:)`의 첫 줄에:

```swift
        if let degraded = evaluateClientAbsence(
            currentSoC: currentSoC, isPluggedIn: isPluggedIn, temperatureCelsius: temperatureCelsius) {
            return degraded
        }
```

`evaluateTopUpExpiry` 아래에:

```swift
    /// `evaluateTopUpExpiry`와 같은 형태: 강등을 실제로 수행한 경우에만 상태를 돌려준다.
    private func evaluateClientAbsence(
        currentSoC: Int,
        isPluggedIn: Bool,
        temperatureCelsius: Double?
    ) -> BatteryControlServiceStatus? {
        guard BatteryClientAbsencePolicy.decide(
            configuration: engine.configuration, lastContactAt: lastClientContactAt, now: now()) == .degrade
        else { return nil }
        let degraded = BatteryClientAbsencePolicy.degraded(engine.configuration)
        do {
            try persistPolicy(degraded)
        } catch {
            // 저장 실패면 물러난다. 다음 샘플이 같은 판정에 다시 도달해 재시도한다.
            return nil
        }
        engine.configure(degraded)
        lastClientContactAt = now()
        let settled = engine.verifyAndUpdate(
            currentSoC: currentSoC, isPluggedIn: isPluggedIn, temperatureCelsius: temperatureCelsius)
        let failure = hardwareFailureReason(in: settled)
        return publish(
            settled,
            trigger: .clientAbsenceExpired,
            result: failure == nil ? .applied : .failed,
            reason: failure)
    }
```

- [ ] **Step 4: 통과 확인** — Run: `… -only-testing:WattlyTests/BatteryClientAbsencePolicyTests`, `… -only-testing:WattlyTests/BatteryControlCoordinatorTests`, `… -only-testing:WattlyTests/BatteryControlProtocolTests` — Expected: PASS. (`BatteryControlProtocolTests`에 트리거 케이스를 전수 열거하는 테스트가 있으면 `.clientAbsenceExpired`를 추가한다.)

- [ ] **Step 5: Commit**

```bash
git add FanControlShared/BatteryClientAbsencePolicy.swift FanControlShared/BatteryControlProtocol.swift FanControlShared/BatteryControlCoordinator.swift WattlyTests/BatteryClientAbsencePolicyTests.swift WattlyTests/BatteryControlCoordinatorTests.swift
git commit -m "feat(daemon): degrade calibration, manual discharge and Top Up after a day without the app"
```

---

### Task 4: 정책 파일 경로는 root 소유·비심볼릭만 신뢰

**Files:**
- Modify: `FanControlShared/BatteryPolicyPersistence.swift:60-67, 73-96, 98-122, 124-140`
- Test: `WattlyTests/BatteryPolicyPersistenceTests.swift`

**Interfaces:**
- `BatteryPolicyStoreError.untrustedPath` 추가.
- `BatteryPolicyFileStore.init(fileURL:fileManager:synchronizeDirectory:expectedOwnerUID: uid_t = geteuid())` — 데몬(root)은 0, 테스트는 자기 uid를 기본값으로 얻는다.

- [ ] **Step 1: 실패하는 테스트** — `BatteryPolicyPersistenceTests`에 추가:

```swift
    @Test func symlinkedPolicyFileIsRefused() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let real = dir.appendingPathComponent("elsewhere.json")
        try Data("{}".utf8).write(to: real)
        let link = dir.appendingPathComponent("battery-control-v1.json")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)

        let store = BatteryPolicyFileStore(fileURL: link)
        #expect(throws: BatteryPolicyStoreError.untrustedPath) { _ = try store.load() }
    }

    @Test func fileOwnedByAnotherUIDIsRefused() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("battery-control-v1.json")
        try Data("{}".utf8).write(to: file)

        // 우리 uid로 만든 파일을 "root가 기대하는" 저장소로 열면 거부되어야 한다.
        let store = BatteryPolicyFileStore(fileURL: file, fileManager: fm,
                                           synchronizeDirectory: { _ in }, expectedOwnerUID: 0)
        #expect(throws: BatteryPolicyStoreError.untrustedPath) { _ = try store.load() }
        #expect(throws: BatteryPolicyStoreError.untrustedPath) {
            try store.save(.init(ownerUID: 501, configuration: .init(enabled: false), updatedAt: 1))
        }
    }
```

- [ ] **Step 2: 실패 확인** — Expected: 컴파일 실패(`untrustedPath`, `expectedOwnerUID` 없음).

- [ ] **Step 3: 구현**

`BatteryPolicyStoreError`에 `case untrustedPath` 추가. 저장소:

```swift
public final class BatteryPolicyFileStore: BatteryPolicyStoring, @unchecked Sendable {
    // defaultURL, fileURL, fileManager, synchronizeDirectory 그대로
    private let expectedOwnerUID: uid_t

    public convenience init(
        fileURL: URL = BatteryPolicyFileStore.defaultURL,
        fileManager: FileManager = .default
    ) {
        self.init(
            fileURL: fileURL,
            fileManager: fileManager,
            synchronizeDirectory: BatteryPolicyFileStore.fsyncDirectory,
            expectedOwnerUID: geteuid())
    }

    /// `expectedOwnerUID`: 디렉터리·파일·`.previous`가 이 uid 소유이고 심볼릭 링크가 아니어야 신뢰한다.
    /// 데몬은 root(0), 테스트는 자기 uid. 기본값 `geteuid()`가 둘 다 맞춘다.
    public init(
        fileURL: URL,
        fileManager: FileManager = .default,
        synchronizeDirectory: @escaping @Sendable (URL) throws -> Void,
        expectedOwnerUID: uid_t = geteuid()
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.synchronizeDirectory = synchronizeDirectory
        self.expectedOwnerUID = expectedOwnerUID
    }

    /// 없는 경로는 통과(아직 안 만든 것). 있는데 심볼릭 링크이거나 소유자가 다르면 거부.
    private func assertTrusted(_ path: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        guard (st.st_mode & S_IFMT) != S_IFLNK, st.st_uid == expectedOwnerUID else {
            throw BatteryPolicyStoreError.untrustedPath
        }
    }
```

`load()`의 첫 줄들:

```swift
        let directory = fileURL.deletingLastPathComponent()
        let previousURL = directory.appendingPathComponent(".battery-control.previous")
        try assertTrusted(directory.path)
        try assertTrusted(previousURL.path)
        try assertTrusted(fileURL.path)
```

`save(_:)`에서 `createDirectory` 직후, `chmod` 앞에 `try assertTrusted(directory.path)`. `loadSleepInhibitedAtLenient()`는 원시 바이트 읽기라 그대로 둔다(정리 목적이고 값 하나만 뽑는다).

- [ ] **Step 4: 통과 확인** — Run: `… -only-testing:WattlyTests/BatteryPolicyPersistenceTests` — Expected: 기존 + 2개 PASS(기존 테스트는 `geteuid()` 기본값으로 자기 임시 디렉터리를 신뢰한다).

- [ ] **Step 5: Commit**

```bash
git add FanControlShared/BatteryPolicyPersistence.swift WattlyTests/BatteryPolicyPersistenceTests.swift
git commit -m "fix(daemon): refuse policy files that are symlinks or not owned by the daemon's uid"
```

---

### Task 5: 시작 실패 백오프

**Files:**
- Modify: `WattlyFanDaemon/FanControlDaemon.swift:59`

- [ ] **Step 1: 구현** — `guard batteryCoordinator.isSafeToServe else { exit(74) }`를 다음으로:

```swift
        guard batteryCoordinator.isSafeToServe else {
            // launchd KeepAlive는 10초마다 재시작한다. 롤백 실패는 재시작으로 낫지 않으므로 60초 쉬어
            // 로그를 분당 1건으로 줄인다. 잠자는 동안 SMC는 이미 해제됐다(`releaseForTermination`).
            fputs("Persisted battery policy could not be recovered; retrying in 60 s\n", stderr)
            Thread.sleep(forTimeInterval: 60)
            exit(74)
        }
```

- [ ] **Step 2: 데몬 빌드** — Expected: BUILD SUCCEEDED.

- [ ] **Step 3: 전체 테스트** — Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add WattlyFanDaemon/FanControlDaemon.swift
git commit -m "fix(daemon): back off before exiting on unrecoverable startup so launchd does not spin"
```

---

## Self-Review

- **Spec coverage:** 속도 제한·generation → Task 1·2 ✔. deadman → Task 3 ✔. 정책 디렉터리 소유자 → Task 4(+2단계 스크립트) ✔. KeepAlive 루프 → Task 5 ✔.
- **Placeholder scan:** 없음. `FakeFanControlHardware`는 `FanControlEngineTests.swift:309`에 이미 있는 private 클래스다.
- **Type consistency:** `RequestRateLimiter.allow(now:)`, `ClientGenerationPolicy.isPlausible(_:now:)`, `BatteryClientAbsencePolicy.decide(configuration:lastContactAt:now:)`/`degraded(_:)`, `noteClientContact()` — 정의와 호출 라벨 일치. Task 2가 Task 3의 `noteClientContact`에 의존함을 Step 6에 명시 ✔.
