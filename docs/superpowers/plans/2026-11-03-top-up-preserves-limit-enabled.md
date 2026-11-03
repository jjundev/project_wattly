# 한 번만 완충이 충전 제한을 강제로 켜지 않게 하기 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Top Up이 끝난 뒤 충전 제한이 Top Up 이전의 소유 상태·값으로 돌아가게 한다. 특히 Wattly 제한이 꺼진 채 시스템 설정에서 직접 건 제한이 사라지지 않게 한다.

**Architecture:** 백엔드(네이티브 서비스·도우미 엔진)는 이미 `enabled=false, topUpActive=true`를 올바르게 처리한다. Task 1이 그 계약을 회귀 테스트로 고정하고, Task 2가 클라이언트의 `enabled = true` 강제 세 곳 중 Top Up 몫을 걷어낸다. 마지막 Task 3이 전체 테스트와 실기 1회로 검증한다.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI 메뉴바 앱, Swift Testing(`@Test`/`#expect`), xcodebuild.

**Spec:** `docs/superpowers/specs/2026-11-03-top-up-preserves-limit-enabled.md`

## Global Constraints

- **프로덕션 코드 변경은 `Wattly/Control/BatteryControlClient.swift`와 `Wattly/Views/BatteryControlBridge.swift`(주석만) 두 파일뿐이다.** `NativeChargeLimitPlan/Service/Status`, `FanControlShared/*`, `WattlyFanDaemon/*`는 수정 금지.
- 캘리브레이션(`applyCalibration`, `revivedConfiguration`의 `calibrationActive` 블록)과 수동 방전(`effectiveEnabled`의 `isManualDischarge`)의 `enabled` 강제는 그대로 둔다.
- 매개변수 버전 `startTopUp(limitPercentage:…)`/`cancelTopUp(limitPercentage:…)`는 건드리지 않는다(스펙 결정 #8).
- 새 파일 없음 → `xcodegen` 불필요. 새 사용자 노출 문자열 없음.
- 테스트 실행: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/<SuiteName> 2>&1 | grep -E "^✘|Test run with|TEST (SUCCEEDED|FAILED)"`. 전체: `-only-testing` 제거.
- 전체 테스트는 `SnapshotGeneratorTests`가 `docs/assets/*.png`를 다시 그린다 → 끝나면 `git checkout -- docs/assets`.
- 커밋 메시지는 Conventional Commits, 스코프 `battery`.

## Review Focus

1. **Top Up 중 Wattly 제한을 켬** → 끝나면 Wattly 값이 걸리고 Wattly가 소유한다(사용자가 방금 켰으므로). Task 1 테스트 `turningWattlyOnDuringTopUpHandsTheLimitToWattlyWhenItEnds`.
2. **Top Up 중 Wattly 제한을 끔(Wattly가 소유하던 제한)** → 끝나면 Wattly 제한이 해제되고 아무것도 남지 않는다. Task 1 테스트 `turningWattlyOffDuringTopUpReleasesItsOwnLimitWhenItEnds`.
3. **업데이트 직전에 시작된 Top Up**(`enabled=true`로 저장) → reconcile이 Top Up을 살린 채 `enabled=false`로 한 번만 고쳐 쓴다. Task 2 테스트 `reconcileRewritesALegacyTopUpThatForcedEnabledWithoutCancellingIt`.
4. **Top Up 중 60초 reconcile이 반복될 때** → 쓰기 0회(매분 재적용 금지), Top Up 유지. Task 2 테스트 `reconcileLeavesATopUpWithTheLimitOffAlone`.
5. **도우미 경로(macOS 26 이하)에서 제한 꺼짐 Top Up 만료** → 억제가 즉시 풀리고 상태가 `limitDisabled`. Task 1 테스트 `topUpWithTheLimitOffReleasesTheGateWhenItExpires`.

---

### Task 1: 백엔드 계약 고정 — `enabled=false`인 Top Up의 종료

Task 2가 기대는 계약을 먼저 테스트로 못 박는다. 백엔드 코드는 바꾸지 않으므로 **새 테스트는 처음부터 통과해야 한다.** 하나라도 실패하면 구현하지 말고 멈춰서 보고한다 — 스펙이 예상하지 못한 백엔드 수정이 필요하다는 뜻이다.

**Files:**
- Test: `WattlyTests/NativeChargeLimitServiceTests.swift` (`// MARK: - 사용자가 직접 건 제한` 섹션 끝에 추가. 같은 파일의 `private` `rig(...)`/`configure(...)`/`World`를 쓴다)
- Test: `WattlyTests/BatteryControlCoordinatorTests.swift` (`expiresTopUpTwelveHoursAfterReachingFull` 바로 아래에 추가. `MutableClock`, `PolicyStoreSpy`, `MockBatteryHardware` 사용)

**Interfaces:**
- Consumes: `NativeChargeLimitService.process(_:)`, `FakeNativeChargeLimitDriver.writes/current`, `StorageKey.nativeLimitOwned/nativeLimitSuspendedLimit`, `BatteryControlCoordinator.configure(_:trigger:currentSoC:isPluggedIn:)`/`sample(currentSoC:isPluggedIn:)`, `BatteryTopUpExpiry.duration`.
- Produces: 없음(테스트만).

- [ ] **Step 1: 네이티브 서비스 테스트 4개 작성**

```swift
enum TopUpEnding: CaseIterable { case cancel, expire, unplug }

@Test(arguments: TopUpEnding.allCases)
func topUpWithWattlyOffRestoresAForeignLimitHoweverItEnds(_ ending: TopUpEnding) async throws {
    let driver = FakeNativeChargeLimitDriver()
    driver.current = .init(limit: 90, state: .on)   // 시스템 설정에서 직접 건 90%
    let r = rig(driver: driver)
    defer { r.cleanup() }
    _ = await r.service.process(try configure(.init(enabled: false, limitPercentage: 80)))
    _ = await r.service.process(try configure(.init(enabled: false, limitPercentage: 80, topUpActive: true)))
    #expect(driver.writes == ["tempDisable"])
    switch ending {
    case .cancel:
        _ = await r.service.process(try configure(.init(enabled: false, limitPercentage: 80)))
    case .expire:
        r.world.reading = .init(percentage: 100, isPluggedIn: true, batteryMilliamps: 0)
        _ = await r.service.process(.status)
        r.world.now += BatteryTopUpExpiry.duration
        _ = await r.service.process(.status)
    case .unplug:
        r.world.reading = .init(percentage: 92, isPluggedIn: false, batteryMilliamps: -600)
        _ = await r.service.process(.status)
    }
    #expect(driver.writes == ["tempDisable", "set:90"])
    #expect(driver.current == .init(limit: 90, state: .on))
    #expect(r.defaults.bool(forKey: StorageKey.nativeLimitOwned) == false)
    #expect(r.defaults.object(forKey: StorageKey.nativeLimitSuspendedLimit) == nil)
}

@Test func topUpWithWattlyOffAndNoSystemLimitNeverWritesALimit() async throws
// rig() 기본 드라이버(100, .off). configure(enabled:false,80) → configure(enabled:false,80,topUp:true)
// → reading 100%/plugged, .status → now += duration, .status 를 `expired`로 받는다.
// #expect(r.driver.writes.isEmpty)
// #expect(expired.desiredConfiguration?.topUpActive == false)
// #expect(expired.detailReason == .init(kind: .limitDisabled))
// #expect(expired.lastMaintenance?.trigger == .topUpExpired)

@Test func turningWattlyOnDuringTopUpHandsTheLimitToWattlyWhenItEnds() async throws
// driver.current = (90, .on). configure(enabled:false,80) → configure(enabled:false,80,topUp:true)
// → configure(enabled:true,80,topUp:true) → configure(enabled:true,80)
// #expect(driver.writes == ["tempDisable", "set:80"])
// #expect(r.defaults.bool(forKey: StorageKey.nativeLimitOwned) == true)
// #expect(r.defaults.object(forKey: StorageKey.nativeLimitSuspendedLimit) == nil)

@Test func turningWattlyOffDuringTopUpReleasesItsOwnLimitWhenItEnds() async throws
// rig() 기본. configure(enabled:true,80) → configure(enabled:true,80,topUp:true)
// → configure(enabled:false,80,topUp:true) → configure(enabled:false,80)
// #expect(r.driver.writes == ["set:80", "tempDisable", "set:100"])
// #expect(r.driver.current == .init(limit: 100, state: .off))
// #expect(r.defaults.bool(forKey: StorageKey.nativeLimitOwned) == false)
```

`TopUpEnding`은 파일 안 `private` 타입으로 둔다.

- [ ] **Step 2: 코디네이터 테스트 작성**

```swift
@Test func topUpWithTheLimitOffReleasesTheGateWhenItExpires() {
    let clock = MutableClock(1_000)
    let hardware = MockBatteryHardware()
    let coordinator = BatteryControlCoordinator(
        ownerUID: 501, store: PolicyStoreSpy(),
        engine: BatteryControlEngine(hardware: hardware),
        now: { clock.now })
    _ = coordinator.configure(
        .init(enabled: false, limitPercentage: 80, topUpActive: true),
        trigger: .clientConfiguration, currentSoC: 100, isPluggedIn: true)
    _ = coordinator.sample(currentSoC: 100, isPluggedIn: true)

    clock.advance(by: 12 * 3_600)
    let status = coordinator.sample(currentSoC: 100, isPluggedIn: true)

    #expect(status.desiredConfiguration?.topUpActive == false)
    #expect(status.desiredConfiguration?.enabled == false)
    #expect(status.lastMaintenance?.trigger == .topUpExpired)
    #expect(status.detailReason?.kind == .limitDisabled)
    #expect(hardware.chargingInhibited == false)
}
```

- [ ] **Step 3: 두 묶음 실행 — 통과 확인**

Run: 테스트 명령에 `-only-testing:WattlyTests/NativeChargeLimitServiceTests -only-testing:WattlyTests/BatteryControlCoordinatorTests`
Expected: `** TEST SUCCEEDED **`, `✘` 없음. 실패하면 멈추고 실패한 단언과 실제 값을 보고한다.

- [ ] **Step 4: 커밋**

```bash
git add WattlyTests/NativeChargeLimitServiceTests.swift WattlyTests/BatteryControlCoordinatorTests.swift
git commit -m "test(battery): pin how both backends end a Top Up while the limit is off"
```

---

### Task 2: 클라이언트가 Top Up에 `enabled = true`를 강제하지 않게 하기

**Files:**
- Modify: `Wattly/Control/BatteryControlClient.swift:313-327` (`startTopUp(preferences:)`, `cancelTopUp(preferences:)`)
- Modify: `Wattly/Control/BatteryControlClient.swift:450` (`reconcile`의 `effectiveEnabled`)
- Modify: `Wattly/Views/BatteryControlBridge.swift:118-130` (`preservingActivity` 주석만)
- Test: `WattlyTests/BatteryControlClientTests.swift` (`startTopUpFromPreferencesSetsTopUpActive`(:1168) 수정 + 새 테스트 4개를 그 아래에)

**Interfaces:**
- Consumes: Task 1이 고정한 백엔드 계약. 테스트 헬퍼 `RequestReceiver`(마지막 요청 1개 보관), `BatteryPreferences.standard`(`limitEnabled == false`).
- Produces: `startTopUp(preferences:)`/`cancelTopUp(preferences:)`가 `enabled == p.limitEnabled`를 보냄. `reconcile`은 Top Up 중에도 `enabled`를 그대로 비교·전송한다.

- [ ] **Step 1: 실패하는 테스트 작성**

기존 `startTopUpFromPreferencesSetsTopUpActive`의 마지막 단언을 다음으로 바꾼다(`.standard`는 제한 꺼짐):

```swift
#expect(sent.topUpActive == true && sent.enabled == false && sent.lowerHysteresisDelta == 4)
```

새 테스트(모두 `@MainActor @Test`, 핸들러 모양은 기존 테스트를 따른다):

- `startTopUpFromPreferencesKeepsTheLimitOnWhenItWasOn` — `prefs.limitEnabled = true`. `#expect(sent.enabled == true && sent.topUpActive == true)`.
- `cancelTopUpFromPreferencesSendsTheStoredLimitSwitch` — `.standard`로 `cancelTopUp(preferences:)`. `#expect(sent.enabled == false && sent.topUpActive == false)`.
- `reconcileLeavesATopUpWithTheLimitOffAlone` — 핸들러는 모든 요청에 아래 상태를 돌려주고 `configure` 수를 센다(`reconcileDoesNotReapplyWhenOnlyTheClamshellAllowanceWouldDiffer`의 `Counter` 패턴). `clamshellAllowance: { false }`.
  ```swift
  let status = BatteryControlServiceStatus(
      mode: .charging, currentPercentage: 90, isPowerAdapterConnected: true,
      detail: "OK", updatedAt: 1,
      desiredConfiguration: .init(enabled: false, limitPercentage: 80, topUpActive: true),
      capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1])
  await client.reconcile(enabled: false, limitPercentage: 80)
  #expect(counter.configures == 0)
  ```
- `reconcileRewritesALegacyTopUpThatForcedEnabledWithoutCancellingIt` — 위와 같되 `desiredConfiguration: .init(enabled: true, limitPercentage: 80, topUpActive: true)`. 마지막 `configure` 요청을 디코드해 `#expect(sent.enabled == false && sent.topUpActive == true)`.

- [ ] **Step 2: 실행 — 실패 확인**

Run: 테스트 명령에 `-only-testing:WattlyTests/BatteryControlClientTests`
Expected: FAIL — `startTopUpFromPreferencesSetsTopUpActive`, `cancelTopUpFromPreferencesSendsTheStoredLimitSwitch`, `reconcileLeavesATopUpWithTheLimitOffAlone`, `reconcileRewritesALegacyTopUpThatForcedEnabledWithoutCancellingIt`이 `✘`. `startTopUpFromPreferencesKeepsTheLimitOnWhenItWasOn`은 통과.

- [ ] **Step 3: 구현**

- `startTopUp(preferences:)`, `cancelTopUp(preferences:)`에서 `config.enabled = true` 줄을 지운다. 두 함수 위에 한 줄 주석: Top Up은 `enabled`와 무관하게 백엔드가 먼저 판정하므로 사용자의 스위치를 그대로 싣는다 — 강제하면 종료 시 사용자가 끈 제한이 걸리고 시스템 설정의 제한을 덮어쓴다.
- `reconcile`: `let effectiveEnabled = enabled || isManualDischarge || isCalibrating`. 그 아래 `if enabled || heatProtectionEnabled || isTopUp || isManualDischarge || isCalibrating`은 **그대로 둔다.** 이 조건 위에 한 줄 주석: `isTopUp`은 여기 남아야 한다 — `disableAndConfirm`은 `topUpActive: false`를 보내 Top Up을 취소한다.
- `BatteryControlBridge.preservingActivity` 주석(:125-130): "If a Top Up or manual discharge is running…" 문단을 수동 방전만 해당하도록 고친다(Top Up은 이제 `enabled`를 강제하지 않으므로 어긋남이 없다).

- [ ] **Step 4: 실행 — 통과 확인**

Run: 테스트 명령에 `-only-testing:WattlyTests/BatteryControlClientTests -only-testing:WattlyTests/BatteryControlBridgeTests -only-testing:WattlyTests/BatteryIntentBridgeTests -only-testing:WattlyTests/BatteryScheduleCoordinatorTests`
Expected: `** TEST SUCCEEDED **`, `✘` 없음.

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Control/BatteryControlClient.swift Wattly/Views/BatteryControlBridge.swift WattlyTests/BatteryControlClientTests.swift
git commit -m "fix(battery): stop Top Up from switching the charge limit on behind the user"
```

---

### Task 3: 전체 검증 + 실기 1회

**Files:**
- Modify: `docs/features/battery-management/14-macos-27-native-charge-limit.md` (`## 실기 체크리스트 (릴리스 전)` 섹션에 결과 한 줄 추가)

**Interfaces:**
- Consumes: Task 1·2의 결과물.
- Produces: green 전체 테스트, 실기 기록 한 줄.

- [ ] **Step 1: 전체 테스트**

Run: 테스트 명령에서 `-only-testing` 제거, 이어서 `git checkout -- docs/assets`
Expected: `** TEST SUCCEEDED **`, `git status`에 `docs/assets` 변경 없음.

- [ ] **Step 2: 실기 (이 Mac, macOS 27, 네이티브 백엔드) — 사용자 협조 필요**

1. Debug 빌드 → `/Applications`의 Wattly 종료 → Debug 앱 실행.
2. Wattly 설정에서 충전 제한 **끔**. 사용자에게 **시스템 설정 → 배터리 → 충전 제한 90%**를 켜 달라고 요청.
3. `Wattly.app/Contents/MacOS/Wattly -WattlyNativeLimitProbe` → `native limit: 90 state: on`, `owned=false`.
4. 어댑터 연결 상태에서 팝오버의 "한 번만 완충"을 켠다 → 프로브가 `state: temporarilyDisabled`.
5. 다시 눌러 취소 → 70초 기다린 뒤 프로브.
Expected: `native limit: 90 state: on`, `owned=false`. 이전 동작이면 `limit: 100 state: off`.
6. 끝나면 사용자에게 시스템 설정 제한을 원래대로 되돌려 달라고 요청한다.

- [ ] **Step 3: 기록 커밋**

```bash
git add docs/features/battery-management/14-macos-27-native-charge-limit.md
git commit -m "docs(battery): record the on-device check that Top Up keeps a System Settings limit"
```
