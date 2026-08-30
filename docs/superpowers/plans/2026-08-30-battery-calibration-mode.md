# 배터리 캘리브레이션 모드 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 사용자가 시작할 때만 도는 7단계·약 10.5시간짜리 배터리 잔량 추정 보정 절차를, 앱이 소유한 순수 상태기계로 구동하고 데몬에는 원시 명령 2개만 추가해 구현한다.

**Architecture:** 절차의 판단은 전부 `Wattly/Core/BatteryCalibration.swift`의 순수 함수(`tick` / `decide` / `preflightBlockers`)에 있고, `BatteryCalibrationCoordinator`는 그 결정을 XPC 호출로 번역만 한다. 데몬(`FanControlShared` + `WattlyFanDaemon`)에는 `calibrationActive` / `calibrationTargetPercentage` 두 필드와 엔진 분기 하나만 들어가며, 하한 클램프와 SoC 가드는 앱이 죽어도 살아 있도록 **엔진 안에** 둔다. 충전 단계는 기존 `topUpActive` 원시 명령을 그대로 빌려 쓴다.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Swift Testing (`import Testing`), XcodeGen, XPC(NSXPCConnection), IOKit(AppleSmartBattery / IOPMAssertion), SMC.

## Global Constraints

- **SoC 출처는 데몬 `BatteryControlServiceStatus.currentPercentage`(IOPS) 단일.** `BatterySample.percentage`(= `AppleRawCurrentCapacity/AppleRawMaxCapacity`)는 이 절차의 어떤 판정에도 쓰지 않는다 — 실기에서 **98.99%가 천장**이라 `chargeToFull`이 영원히 끝나지 않는다. (결정 #27)
- **어댑터 연결 판정은 `AdapterDetails.Watts > 0`을 반드시 포함.** CHIE 강제 방전 중 `ExternalConnected`와 IOPS는 둘 다 "배터리 전원"으로 보고한다(실기 3회 재현). (결정 #10)
- **완충 판정은 `soc >= 100 && !isCharging`이 60초 지속.** `FullyCharged` 플래그는 완충 후에도 `No`로 남으므로 **사용 금지**. 전력(W) 임계값도 쓰지 않는다 — 테이퍼가 8.01W → 0.00W 한 스텝으로 떨어진다. (결정 #21)
- **정체·완충·충전정체 타이머는 깨어 있던 시간만 누적.** tick 간격이 90초를 넘으면 sleep으로 판정해 해당 타이머를 리셋한다. clamshell sleep이 "SoC 무변화"와 동일한 signature를 만들기 때문. (결정 #22 / #36)
- **하한 클램프와 SoC 하드 가드는 데몬 엔진 안에.** 배터리 경로에는 팬과 달리 하트비트 데드맨이 없어, 앱 FSM에만 두면 앱 크래시 시 무제한 방전이 된다. (결정 #32)
- **`BatterySectionPresentation`의 전역 `requiredCapabilities` 목록은 불변.** `.calibrationV1`을 넣으면 캘리브레이션을 쓰지 않는 전 사용자가 "도우미 업데이트 필요" 상태가 된다. 게이팅은 캘리브레이션 카드 안에서만 한다. (결정 #2 / B4)
- **완료 리포트는 용량 회복을 약속하지 않는다.** 헤드라인은 "잔량 표시 보정 완료"이고 mAh는 참고값으로만, **자연 변동폭 86 mAh를 반드시 병기**한다. 1회 사이클로는 용량 재추정이 관측되지 않음이 실기로 확인됐다(+35 mAh < 86 mAh 변동폭). (결정 #15)
- **Heat Protection은 어떤 경우에도 자동 비활성화하지 않는다.** 발동하면 절차를 일시정지하고 타이머를 멈춘다. (결정 #11)
- 새 사용자 노출 문자열은 전부 한국어 키 + `String(localized:)`, `Wattly/Resources/Localizable.xcstrings`에 30개 로케일 전체 등록.
- Swift 6 strict concurrency. 순수 로직은 `@MainActor` 없이, I/O는 actor 또는 `@MainActor`.
- `Wattly/` 또는 `WattlyTests/` 아래 **파일을 추가하면 반드시 xcodegen 재생성**: `/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml`
- 빌드/테스트는 워크트리에서 DerivedData를 명시해야 한다(에셋 카탈로그 권한 문제):
  `-derivedDataPath .build/DerivedData`

---

## File Structure

### 공유 계층 (`FanControlShared` — 앱과 데몬 양쪽에 컴파일됨)

| 파일 | 책임 | 변경 |
|---|---|---|
| `BatteryControlProtocol.swift` | 설정 필드 2개 · 전용 클램프 · `.calibrationV1` capability · status의 방전 지원 플래그 | 수정 |
| `BatteryControlStatusReason.swift` | 캘리브레이션 상태 3종(`calibrationCharging`/`calibrationHolding`/`calibrationDischarging`) | 수정 |
| `BatteryControlActivity.swift` | 위 3종 → 기존 `.calibration` 매핑 | 수정 |
| `BatteryControlEngine.swift` | 우선순위 파이프라인의 캘리브레이션 분기 · 하한 가드 · CHIE 실프로브 사용 | 수정 |
| `BatteryControlCoordinator.swift` | 어댑터 분리 시 캘리브레이션 해제 예외 3곳 · 정책 파일 저장 · Top Up 만료 차단 | 수정 |
| `BatteryControlPolicy.swift` | reconcile이 캘리브레이션을 되돌리지 않도록 보존 | 수정 |

### 데몬 (`WattlyFanDaemon`)

| 파일 | 책임 | 변경 |
|---|---|---|
| `BatteryControlHardware.swift` | `CHIE` 실제 프로브 결과를 `isDischargeSupported`로 노출 | 수정 |

### 앱 순수 계층 (`Wattly/Core` — 테이블 테스트 대상, SwiftUI/IO 없음)

| 파일 | 책임 | 변경 |
|---|---|---|
| `BatteryCalibrationState.swift` | 단계·일시정지·결과·타이머·스냅샷·실행상태·리포트 값 타입 | **신규** |
| `BatteryCalibration.swift` | 상수 · `tick` · `decide` · `preflightBlockers` · ETA · 리포트 문구 | **신규** |

### 앱 런타임 계층 (`Wattly`)

| 파일 | 책임 | 변경 |
|---|---|---|
| `Core/SleepAssertion.swift` | `IOPMAssertionCreateWithName` RAII 래퍼 | **신규** |
| `Core/AppleSmartBatteryReader.swift` | 폴링 파이프라인과 무관한 자족적 배터리 판독(netW·IsCharging·ChargingCurrent·용량·사이클) | **신규** |
| `Core/BatteryCalibrationCoordinator.swift` | 10초 tick · 지속 저장 · 결정→XPC 번역 · 재개/고아 처리 | **신규** |
| `Control/BatteryControlClient.swift` | 캘리브레이션 쓰기 경로 · 다른 호출자로부터 캘리브레이션 보존 | 수정 |
| `Views/BatteryControlBridge.swift` | `preservingActivity` 확장 · 절차 중 Top Up 만료 알림 억제 | 수정 |
| `Settings/Settings.swift` | `StorageKey` / `Defaults` 2키 | 수정 |
| `Core/SettingsReset.swift` | **원복 → 키 제거** 순서 강제 | 수정 |
| `Core/AppUninstaller.swift` | 동일 순서 | 수정 |
| `Core/BatteryScheduleCoordinator.swift` | 절차 중 스케줄 skip | 수정 |
| `Core/BatteryScheduleLogEntry.swift` | `SkipReason.calibrationRunning` | 수정 |
| `Core/BatteryNotificationManager.swift` | 완료/조치필요/실패 알림 3종 | 수정 |
| `Views/Settings/SettingsBatteryCalibrationSection.swift` | preflight → 진행 → 리포트 카드 | **신규** |
| `Views/SettingsView.swift` | 섹션 마운트 | 수정 |
| `App/WattlyApp.swift` | 코디네이터 생성·주입 | 수정 |
| `Views/CardExpandRegion.swift` | 팝오버 배터리 카드 1줄 요약 · 절차 중 Top Up/수동방전 행 비활성 | 수정 |
| `Resources/Localizable.xcstrings` | 신규 문자열 30개 로케일 | 수정 |

### 테스트 (`WattlyTests`)

`BatteryCalibrationTests.swift`(신규) · `BatteryCalibrationStateTests.swift`(신규) · `BatteryCalibrationCoordinatorTests.swift`(신규) · 기존 `BatteryControlProtocolTests` / `BatteryControlEngineTests` / `BatteryControlCoordinatorTests` / `BatteryControlPolicyTests` / `BatteryControlBridgeTests` / `BatteryControlActivityTests` / `BatteryStatusTextTests` / `SettingsResetTests` / `BatteryScheduleCoordinatorTests` / `LocalizationTests` 확장.

### 설계 대비 명시적 이탈 4건

1. **지속 저장 키는 3개가 아니라 2개.** 결정 #6은 `state` / `history` / `lastCompletedAt` 3키였으나, `lastCompletedAt`과 `cycleCountAtLastCompletion`은 이력의 마지막 완료 항목에서 유도한다. 파생값은 어긋날 수 없고 `SettingsReset`이 관리할 키도 하나 준다.
2. **하드웨어 미지원 시 카드를 숨기지 않고 사유를 보여 준다.** 결정 #13은 "카드 자체를 숨김"이었으나, 이 코드베이스의 확립된 규칙은 그 반대다 — `BatterySectionPresentation` 헤더가 명시하듯 "하위 항목은 항상 보이고 **조작할 수 없는 부분만** 비활성으로 표시한다". 숨기면 사용자는 왜 없는지 알 수 없다. 카드는 접힌 채 남고, 펼치면 `dischargeUnsupported` 사유가 뜨며 시작 버튼이 비활성된다.

3. **구버전 헬퍼 감지는 카드 안에서만 한다.** 결정 #31의 보강 사항은 "버튼만 두지 말고 앱 시작 시 자동 감지"였다. 그러나 앱 시작 시 전역으로 감지하면 그 결과를 보여 줄 자리가 전역 유지보수 배너뿐이고, 그건 `requiredCapabilities`를 건드리지 말라는 제약(#2)과 정면으로 충돌한다 — 캘리브레이션을 쓰지 않는 전 사용자에게 "업데이트 필요"가 뜬다. 그래서 감지는 카드를 열 때 `preflightBlockers`가 수행하고, 인라인 업데이트 버튼이 해소한다. 카드를 열지 않은 사용자는 아무 영향도 받지 않는다.

4. **`BatteryProvider`는 건드리지 않는다.** 설계는 "프로바이더의 판독부를 추출해 공유"였으나, 순수 디코딩 함수(`Wattly/Core/BatteryPower.swift`의 `netWatts`/`smcDouble` 등)는 **이미 공유되고 있다**. 중복되는 것은 IOKit 배선 30줄뿐이고, 프로바이더를 리팩터링하면 기존 320개 테스트가 회귀 위험에 노출된다. 새 리더는 자기 SMC 연결을 따로 연다(읽기 전용이라 안전).

### 결정 → 태스크 대응표 (36건)

| 결정 | 태스크 | 결정 | 태스크 |
|---|---|---|---|
| #1 프로토콜 2필드 | T1 | #19 90일 쿨다운 + 2차 확인 | T9 · T18 |
| #2 capability 게이트 | T1 · T9 · T18 | #20 앱 소유 FSM | T13 |
| #3 엔진 우선순위 | T3 | #21 완충 판정 (100 && !charging 60s) | T7 · T8 |
| #4 전용 클램프(15…50) | T1 | #22 정체 판정 = 깨어있던 15분 | T7 · T8 |
| #5 7단계 | T6 | #23 타임아웃 6h/12h/2h | T7 · T8 |
| #6 지속 저장 | T13 (2키, 이탈 1) | #24 상호 배제 | T5 · T12 · T18 · T19 |
| #7 재개 · 12h 만료 | T8 · T13 | #25 최적화 충전 차단 + 정체 감지 | T8 · T9 · T11 |
| #8 스냅샷 원복 | T6 · T13 | #26 90일 또는 40사이클 | T9 |
| #9 sleep assertion (방전만) | T10 · T13 | #27 SoC 단일 출처 | 전역 제약 · T13 |
| #10 어댑터 = Watts>0 | T11 · T13 | #28 데몬 write 단독 | T12 |
| #11 열보호 = 일시정지 | T7 · T8 | #29 스케줄 skip | T16 |
| #12 UI 위치 · ETA · 만료 차단 | T5 · T9 · T14 · T18 · T19 | #30 어댑터 분리 예외 3곳 | T5 |
| #13 하드웨어 게이팅 | T9 · T18 (이탈 2) | #31 CHIE 실프로브 | T4 (이탈 3) |
| #14 알림 3종 | T17 | #32 하한 가드는 엔진 안 | T3 |
| #15 완료 리포트 | T9 · T17 · T18 | #33 원복 → 키 제거 순서 | T15 |
| #16 v1 제외 (스케줄·Shortcuts·자동 실행 없음) | 계획에 없음 = 준수 | #34 알림 권한 선취득 | T17 |
| #17 하한 20% | T7 | #35 정책 파일 저장 | T5 |
| #18 soak 10분/60분 | T7 | #36 잠자기는 예산 미소모 | T6 · T7 · T8 |

---

## Task 1: 데몬 설정 필드 · 전용 클램프 · capability

**Files:**
- Modify: `FanControlShared/BatteryControlProtocol.swift`
- Test: `WattlyTests/BatteryControlProtocolTests.swift`

**Interfaces:**
- Consumes: 없음 (첫 태스크)
- Produces:
  - `BatteryControlConfiguration.calibrationActive: Bool` (기본 `false`)
  - `BatteryControlConfiguration.calibrationTargetPercentage: Int` (기본 `20`)
  - `BatteryControlConfiguration.clampedCalibrationTarget: Int` (15…50)
  - `BatteryControlCapability.calibrationV1` (rawValue `"calibration-v1"`)

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/BatteryControlProtocolTests.swift` 끝의 닫는 `}` 앞에 추가:

```swift
    @Test func calibrationFieldsDefaultOffAndDecodeLeniently() throws {
        // 필드를 모르는 구버전 페이로드
        let legacy = #"{"enabled":true,"limitPercentage":80,"lowerHysteresisDelta":2}"#
        let decoded = try BatteryControlCodec.decode(
            BatteryControlConfiguration.self, from: Data(legacy.utf8))
        #expect(decoded.calibrationActive == false)
        #expect(decoded.calibrationTargetPercentage == 20)
    }

    @Test func calibrationTargetClampsToFifteenThroughFifty() {
        #expect(BatteryControlConfiguration(calibrationTargetPercentage: 5)
            .clampedCalibrationTarget == 15)
        #expect(BatteryControlConfiguration(calibrationTargetPercentage: 20)
            .clampedCalibrationTarget == 20)
        #expect(BatteryControlConfiguration(calibrationTargetPercentage: 90)
            .clampedCalibrationTarget == 50)
        // 기존 수동 방전 계약(하한 50)은 손대지 않는다.
        #expect(BatteryControlConfiguration(manualDischargeTarget: 20)
            .clampedManualDischargeTarget == 50)
    }

    @Test func calibrationCountsAsActivePolicy() {
        var config = BatteryControlConfiguration(enabled: false)
        #expect(config.isActive == false)
        config.calibrationActive = true
        #expect(config.isActive)
    }

    @Test func normalizedClampsCalibrationTarget() {
        let normalized = BatteryControlConfiguration(
            calibrationActive: true, calibrationTargetPercentage: 3).normalized
        #expect(normalized.calibrationActive)
        #expect(normalized.calibrationTargetPercentage == 15)
    }

    @Test func calibrationCapabilityRoundTrips() throws {
        let encoded = try BatteryControlCodec.encode([BatteryControlCapability.calibrationV1])
        let decoded = try BatteryControlCodec.decode([BatteryControlCapability].self, from: encoded)
        #expect(decoded == [.calibrationV1])
        #expect(BatteryControlCapability.calibrationV1.rawValue == "calibration-v1")
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryControlProtocolTests test
```
Expected: 컴파일 실패 — `value of type 'BatteryControlConfiguration' has no member 'calibrationActive'`

- [ ] **Step 3: 필드 추가**

`FanControlShared/BatteryControlProtocol.swift`에서 `manualDischargeTarget` 저장 프로퍼티 바로 아래에 추가:

```swift
    /// 캘리브레이션 절차가 실행 중인지. 앱이 소유한 FSM이 세우고 내리는 원시 명령이며, 데몬은
    /// 단계 개념을 모른다. `topUpActive`와 달리 정책 파일에 **저장**된다 — 앱이 죽어도 엔진의
    /// 하한 가드가 살아 있어야 최악이 "하한 도달 후 홀드"라는 설계된 안전 상태로 끝난다.
    public var calibrationActive: Bool
    /// 캘리브레이션이 내려갈 하한. `manualDischargeTarget`(하한 50)과 클램프 범위가 다르므로
    /// 별도 필드다 — 기존 수동 방전 계약을 바꾸면 Shortcuts·스케줄·UI가 전부 재검증 대상이 된다.
    public var calibrationTargetPercentage: Int
```

`init`의 `manualDischargeTarget: Int = 80` 다음에 파라미터 2개를 추가하고 대입도 추가:

```swift
        manualDischargeTarget: Int = 80,
        calibrationActive: Bool = false,
        calibrationTargetPercentage: Int = 20
    ) {
```
```swift
        self.manualDischargeTarget = manualDischargeTarget
        self.calibrationActive = calibrationActive
        self.calibrationTargetPercentage = calibrationTargetPercentage
```

`CodingKeys`를 수정:

```swift
        case autoDischargeEnabled, manualDischargeActive, manualDischargeTarget
        case calibrationActive, calibrationTargetPercentage
```

`init(from:)` 마지막 줄 뒤에 추가:

```swift
        calibrationActive = (try? container.decodeIfPresent(Bool.self, forKey: .calibrationActive)) ?? false
        calibrationTargetPercentage = (try? container.decodeIfPresent(Int.self, forKey: .calibrationTargetPercentage)) ?? 20
```

`normalized`의 `return copy` 앞에 추가:

```swift
        copy.calibrationActive = calibrationActive
        copy.calibrationTargetPercentage = Self.clampCalibrationTarget(calibrationTargetPercentage)
```

`isActive`를 교체:

```swift
    public var isActive: Bool {
        enabled || heatProtectionEnabled || topUpActive || manualDischargeActive || calibrationActive
    }
```

`clampedManualDischargeTarget` 다음에 추가:

```swift
    public var clampedCalibrationTarget: Int { Self.clampCalibrationTarget(calibrationTargetPercentage) }
```

`clampLimit` 옆에 추가:

```swift
    /// 캘리브레이션 전용 하한. 15는 엔진의 하드 가드와 같은 값이라 그 아래로는 어차피 방전이
    /// 멈춘다. 50은 "이건 캘리브레이션이 아니다"라고 부를 수 있는 상한이다. v1이 실제로 쓰는
    /// 값은 `BatteryCalibration.floorPercentage`(20) 하나뿐이며, 이 범위는 코드가 허용하는
    /// 폭이지 UI가 노출하는 폭이 아니다.
    private static func clampCalibrationTarget(_ value: Int) -> Int { max(15, min(50, value)) }
```

`BatteryControlCapability`에 케이스 추가 (`unrecognized` 앞):

```swift
    case calibrationV1 = "calibration-v1"
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryControlProtocolTests test
```
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add FanControlShared/BatteryControlProtocol.swift WattlyTests/BatteryControlProtocolTests.swift && git commit -m "feat(battery): add calibration configuration fields and capability"
```

---

## Task 2: 캘리브레이션 상태 이유 3종과 activity 매핑

**Files:**
- Modify: `FanControlShared/BatteryControlStatusReason.swift`
- Modify: `FanControlShared/BatteryControlActivity.swift`
- Modify: `Wattly/Core/BatteryStatusText.swift`
- Test: `WattlyTests/BatteryControlStatusReasonTests.swift`, `WattlyTests/BatteryControlActivityTests.swift`, `WattlyTests/BatteryStatusTextTests.swift`

> ⚠️ `BatteryStatusText.text(reason:detail:locale:)`의 `switch resolved.kind`는 **총망라 switch**다([BatteryStatusText.swift:48](Wattly/Core/BatteryStatusText.swift:48)). `Kind`에 케이스를 추가하는 순간 앱 타깃이 컴파일되지 않으므로, 이 태스크 안에서 함께 채운다. `LegacyBatteryDetail`은 `String`을 switch하므로 영향이 없고, **절대 수정하지 않는다** — 그 표는 이미 디스크에 설치된 구버전 헬퍼의 문장을 알아보기 위한 것이다.

**Interfaces:**
- Consumes: Task 1의 설정 필드
- Produces: `BatteryControlStatusReason.Kind.calibrationCharging` / `.calibrationHolding` / `.calibrationDischarging`, 이들이 `BatteryControlActivity.calibration`으로 매핑됨

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/BatteryControlStatusReasonTests.swift` 닫는 `}` 앞:

```swift
    @Test func calibrationReasonsCarryLegacySentences() {
        #expect(BatteryControlStatusReason(kind: .calibrationCharging, limitPercentage: 100)
            .legacyKoreanDetail == "캘리브레이션: 100%까지 충전 중")
        #expect(BatteryControlStatusReason(kind: .calibrationDischarging, limitPercentage: 20)
            .legacyKoreanDetail == "캘리브레이션: 20%까지 방전 중")
        #expect(BatteryControlStatusReason(kind: .calibrationHolding, limitPercentage: 20)
            .legacyKoreanDetail == "캘리브레이션: 20% 유지 중")
    }

    @Test func everyReasonKindHasANonEmptySentence() {
        for kind in BatteryControlStatusReason.Kind.allCases where kind != .unrecognized {
            #expect(BatteryControlStatusReason(kind: kind).legacyKoreanDetail.isEmpty == false)
        }
    }
```

`WattlyTests/BatteryStatusTextTests.swift` 닫는 `}` 앞:

```swift
    @Test func calibrationReasonsRenderInTheUsersLanguage() {
        let en = Locale(identifier: "en")
        let charging = BatteryStatusText.text(
            reason: .init(kind: .calibrationCharging, limitPercentage: 100),
            detail: "", locale: en)
        #expect(charging.contains("100"))
        #expect(charging.contains("캘리브레이션") == false)   // 카탈로그를 거쳐야 한다

        let discharging = BatteryStatusText.text(
            reason: .init(kind: .calibrationDischarging, limitPercentage: 20),
            detail: "", locale: Locale(identifier: "ko"))
        #expect(discharging == "캘리브레이션: 20%까지 방전 중")
    }
```

`WattlyTests/BatteryControlActivityTests.swift` 닫는 `}` 앞:

```swift
    @Test func calibrationReasonsInferCalibrationActivity() {
        for kind in [BatteryControlStatusReason.Kind.calibrationCharging,
                     .calibrationHolding, .calibrationDischarging] {
            #expect(BatteryControlActivity.inferred(from: .init(kind: kind)) == .calibration)
        }
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryControlStatusReasonTests test
```
Expected: 컴파일 실패 — `type 'BatteryControlStatusReason.Kind' has no member 'calibrationCharging'`

- [ ] **Step 3: 케이스와 문장 추가**

`FanControlShared/BatteryControlStatusReason.swift`의 `Kind`에서 `case batterySensorUnreadable` 앞에 추가:

```swift
        /// 캘리브레이션 절차가 100%까지 충전 중이다(원시 명령은 Top Up과 같다).
        case calibrationCharging
        /// 캘리브레이션 절차가 하한 또는 100%에서 안정화 대기 중이다.
        case calibrationHolding
        /// 캘리브레이션 절차가 CHIE로 하한까지 강제 방전 중이다.
        case calibrationDischarging
```

`legacyKoreanDetail`의 `case .dischargingManual` 다음에 추가:

```swift
        case .calibrationCharging: return "캘리브레이션: \(target)%까지 충전 중"
        case .calibrationDischarging: return "캘리브레이션: \(target)%까지 방전 중"
        case .calibrationHolding: return "캘리브레이션: \(target)% 유지 중"
```

`FanControlShared/BatteryControlActivity.swift`의 `inferred(from:)`에서 discharging 케이스 다음에 추가:

```swift
        case .some(.calibrationCharging), .some(.calibrationHolding),
             .some(.calibrationDischarging):
            return .calibration
```

`Wattly/Core/BatteryStatusText.swift`의 `case .dischargingManual:` 다음에 추가 (이 switch는 총망라라 빠뜨리면 컴파일되지 않는다):

```swift
        case .calibrationCharging:
            return String(format: String(localized: "캘리브레이션: %lld%%까지 충전 중", locale: locale),
                          locale: locale, target)
        case .calibrationDischarging:
            return String(format: String(localized: "캘리브레이션: %lld%%까지 방전 중", locale: locale),
                          locale: locale, target)
        case .calibrationHolding:
            return String(format: String(localized: "캘리브레이션: %lld%% 유지 중", locale: locale),
                          locale: locale, target)
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryControlStatusReasonTests -only-testing:WattlyTests/BatteryControlActivityTests -only-testing:WattlyTests/BatteryStatusTextTests test
```
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add FanControlShared/BatteryControlStatusReason.swift FanControlShared/BatteryControlActivity.swift Wattly/Core/BatteryStatusText.swift WattlyTests/ && git commit -m "feat(battery): add calibration status reasons and activity mapping"
```

---

## Task 3: 엔진 캘리브레이션 분기와 하한 가드

**Files:**
- Modify: `FanControlShared/BatteryControlEngine.swift`
- Test: `WattlyTests/BatteryControlEngineTests.swift`

**Interfaces:**
- Consumes: Task 1의 `calibrationActive` / `clampedCalibrationTarget`, Task 2의 reason kinds
- Produces: 엔진 우선순위 `heat > calibration > manualDischarge > topUp > autoDischarge > 표준`, 캘리브레이션 중 하한 도달 시 CHIE 해제 + 억제 유지

**설계 근거:** 하한 클램프와 `currentSoC >= 15` 가드는 **엔진 안에** 있어야 한다(결정 #32). 배터리 경로에는 팬과 달리 하트비트 데드맨이 없어서, 앱 FSM에만 두면 앱이 크래시했을 때 방전을 멈출 주체가 사라진다.

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/BatteryControlEngineTests.swift` 닫는 `}` 앞:

```swift
    @Test func calibrationDischargesUntilItsOwnFloor() {
        let hw = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: hw)
        engine.configure(BatteryControlConfiguration(
            enabled: true, limitPercentage: 80,
            calibrationActive: true, calibrationTargetPercentage: 20))

        // 하한 위: CHIE 방전 + 게이트 억제를 동시에 건다.
        _ = engine.update(currentSoC: 60, isPluggedIn: true)
        #expect(hw.isDischargeActive)
        #expect(hw.isInhibited)

        // 하한 도달: 방전만 끊고 억제는 유지해 되오르지 않게 한다.
        _ = engine.update(currentSoC: 20, isPluggedIn: true)
        #expect(hw.isDischargeActive == false)
        #expect(hw.isInhibited)
    }

    @Test func calibrationNeverDischargesBelowFifteenPercent() {
        let hw = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: hw)
        // 클램프가 15로 끌어올려도, 엔진의 하드 가드가 한 겹 더 막는다.
        engine.configure(BatteryControlConfiguration(
            enabled: true, calibrationActive: true, calibrationTargetPercentage: 5))
        _ = engine.update(currentSoC: 14, isPluggedIn: true)
        #expect(hw.isDischargeActive == false)
    }

    @Test func heatProtectionPreemptsCalibration() {
        let hw = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: hw)
        engine.configure(BatteryControlConfiguration(
            enabled: true, heatProtectionEnabled: true, heatProtectionThresholdCelsius: 35,
            calibrationActive: true, calibrationTargetPercentage: 20))
        let status = engine.update(currentSoC: 60, isPluggedIn: true, temperatureCelsius: 40)
        #expect(hw.isDischargeActive == false)
        #expect(hw.isInhibited)
        #expect(status.detailReason?.kind == .heatProtectionActive)
    }

    @Test func calibrationPreemptsManualDischarge() {
        let hw = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: hw)
        engine.configure(BatteryControlConfiguration(
            enabled: true,
            manualDischargeActive: true, manualDischargeTarget: 80,
            calibrationActive: true, calibrationTargetPercentage: 20))
        let status = engine.update(currentSoC: 60, isPluggedIn: true)
        #expect(status.detailReason?.kind == .calibrationDischarging)
        #expect(status.detailReason?.limitPercentage == 20)
    }

    @Test func calibrationChargeStepBorrowsTopUpBehaviour() {
        let hw = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: hw)
        // 절차 전체에서 `calibrationActive`는 켜져 있고, `topUpActive`가 "지금이 충전 단계"를
        // 말한다. 그래야 어댑터 분리·헬퍼 재시작에서 데몬이 절차를 하나의 활동으로 본다.
        engine.configure(BatteryControlConfiguration(
            enabled: true, topUpActive: true,
            calibrationActive: true, calibrationTargetPercentage: 20))

        let charging = engine.update(currentSoC: 60, isPluggedIn: true)
        #expect(hw.isDischargeActive == false)
        #expect(hw.isInhibited == false)          // 100%까지 실제로 충전되어야 한다
        #expect(charging.detailReason?.kind == .calibrationCharging)
        #expect(charging.detailReason?.limitPercentage == 100)

        let full = engine.update(currentSoC: 100, isPluggedIn: true)
        #expect(hw.isInhibited)                   // 100% 도달 후 홀드
        #expect(full.detailReason?.kind == .calibrationHolding)
    }

    @Test func calibrationReportsHoldingAtFloor() {
        let hw = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: hw)
        engine.configure(BatteryControlConfiguration(
            enabled: true, calibrationActive: true, calibrationTargetPercentage: 20))
        let holding = engine.update(currentSoC: 20, isPluggedIn: true)
        #expect(holding.detailReason?.kind == .calibrationHolding)
        #expect(holding.detailReason?.limitPercentage == 20)
    }

    @Test func calibrationStandsDownOnBatteryPower() {
        let hw = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: hw)
        engine.configure(BatteryControlConfiguration(
            enabled: true, calibrationActive: true, calibrationTargetPercentage: 20))
        _ = engine.update(currentSoC: 60, isPluggedIn: true)
        #expect(hw.isDischargeActive)
        // 어댑터가 빠지면 CHIE로 뺄 전원이 없다. 자연 방전이 이어받는다.
        _ = engine.update(currentSoC: 59, isPluggedIn: false)
        #expect(hw.isDischargeActive == false)
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryControlEngineTests test
```
Expected: FAIL — `calibrationDischargesUntilItsOwnFloor`에서 `hw.isDischargeActive`가 `false`

- [ ] **Step 3: 엔진 분기 추가**

`FanControlShared/BatteryControlEngine.swift`의 `update(...)` 안, `} else if isInHeatProtection {` 블록 **다음**이자 `} else if config.manualDischargeActive {` **앞**에 삽입:

```swift
        } else if config.calibrationActive {
            // `calibrationActive`는 절차 **전체**에서 켜져 있고, `topUpActive`가 "지금이 충전
            // 단계인지"를 말한다. 이렇게 나누면 데몬이 절차를 하나의 활동으로 볼 수 있어
            // 어댑터 분리·헬퍼 재시작 예외를 한 곳에서 처리할 수 있고, 앱이 죽어도 아래 하한
            // 가드가 계속 살아 있다.
            if config.topUpActive {
                // 충전 단계 — Top Up과 동작이 같다.
                target = 100
                shouldDischarge = false
                if currentSoC >= 100 {
                    topUpCompletedHold = true
                    shouldInhibit = true
                } else {
                    shouldInhibit = false
                }
            } else {
                // 방전·홀드 단계. 하한과 15% 하드 가드를 여기에 두는 이유는, 앱이 크래시해도
                // 방전을 멈출 주체가 남아 있어야 하기 때문이다 — 배터리 경로에는 팬과 달리
                // 하트비트 데드맨이 없다.
                let floor = config.clampedCalibrationTarget
                target = floor
                if currentSoC >= 15 && isDischargeHardwareSupported && currentSoC > floor {
                    shouldDischarge = true
                    // 강제 방전은 두 게이트가 함께 필요하다: CHIE가 어댑터를 격리하는 동안 일반
                    // 충전 게이트는 억제된 채로 있어야 한다.
                    shouldInhibit = true
                } else {
                    // 하한 도달 후에도 억제는 유지한다. 풀면 다음 단계를 기다리는 사이에 다시
                    // 충전이 시작돼 안정화 구간이 무의미해진다.
                    shouldDischarge = false
                    shouldInhibit = true
                }
            }
```

> 이 분기는 기존 `if !isPluggedIn { ... }` 단락 **뒤**에 놓인다. 의도된 것이다 — 어댑터가 실제로 빠지면 CHIE로 뺄 전원이 없고 자연 방전이 이어받는다. 그 구간 동안 `detailReason`도 (아래 삽입 위치보다 앞에 있는 `!isPluggedIn` 검사 때문에) `.onBatteryPower`를 반환한다. 앱 FSM은 `detailReason.kind`를 읽지 않으므로 절차에는 영향이 없고, 데몬 상태 문장만 그 구간에서 "배터리 전원으로 구동 중"이 된다. 이 동작을 바꾸지 말 것 — 캘리브레이션을 앞으로 끌어올리면 어댑터가 없는 상태에서 억제 write를 시도하게 된다.

`detailReason(...)`에서 `if config.manualDischargeActive {` **앞**에 삽입:

```swift
        if config.calibrationActive {
            if config.topUpActive {
                return .init(kind: (currentSoC >= 100 || topUpCompletedHold)
                                ? .calibrationHolding : .calibrationCharging,
                             limitPercentage: 100)
            }
            return .init(kind: isCurrentlyDischarging ? .calibrationDischarging : .calibrationHolding,
                         limitPercentage: target)
        }
```

`statusForCurrentBelief(...)`의 `target` 계산도 캘리브레이션을 먼저 보게 교체:

```swift
        let target: Int
        if config.calibrationActive {
            target = config.topUpActive ? 100 : config.clampedCalibrationTarget
        } else if config.topUpActive {
            target = 100
        } else if config.manualDischargeActive {
            target = config.clampedManualDischargeTarget
        } else {
            target = config.clampedLimitPercentage
        }
```

`status(...)`의 `appliedLimit` 조건에 캘리브레이션을 포함:

```swift
        if isHardwareSupported && !hasActionableFailure
            && (config.enabled || config.manualDischargeActive || config.topUpActive
                || config.calibrationActive) {
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryControlEngineTests test
```
Expected: PASS (기존 엔진 테스트 전부 포함)

- [ ] **Step 5: 커밋**

```bash
git add FanControlShared/BatteryControlEngine.swift WattlyTests/BatteryControlEngineTests.swift && git commit -m "feat(battery): add calibration branch to the control engine"
```

---

## Task 4: CHIE 실제 프로브 배선과 방전 지원 플래그 (#31)

**Files:**
- Modify: `FanControlShared/BatteryControlEngine.swift` (프로토콜 요구사항 + 기본 구현)
- Modify: `FanControlShared/BatteryControlProtocol.swift` (status 필드)
- Modify: `WattlyFanDaemon/BatteryControlHardware.swift`
- Test: `WattlyTests/BatteryControlEngineTests.swift`, `WattlyTests/BatteryControlProtocolTests.swift`

**Interfaces:**
- Consumes: Task 1·3
- Produces:
  - `BatteryControlHardwareProtocol.isDischargeSupported: Bool` (기본 구현 = `registerSet.isDischargeSupported`)
  - `BatteryControlServiceStatus.isDischargeHardwareSupported: Bool?` (구버전 헬퍼는 `nil` = "모름")

**설계 근거:** 현재 `isDischargeHardwareSupported`는 `registerSet` enum에서 파생되므로 `.modern`이면 CHIE가 없어도 `true`다. `BatteryControlKeys.isDischargeSupported(probing:)`라는 진짜 프로브가 이미 있는데 아무도 부르지 않는 사문이다. 이걸 실배선하면 캘리브레이션 preflight뿐 아니라 **기존 수동·자동 방전 게이팅도 정확해진다**.

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/BatteryControlEngineTests.swift` 닫는 `}` 앞:

```swift
    @Test func engineHonorsProbedDischargeSupportOverRegisterSet() {
        let hw = MockBatteryHardware()
        hw.registerSet = .modern           // 표에 따르면 지원
        hw.probedDischargeSupport = false  // 실제 프로브는 CHIE 없음
        let engine = BatteryControlEngine(hardware: hw)
        #expect(engine.isDischargeHardwareSupported == false)

        engine.configure(BatteryControlConfiguration(
            enabled: true, calibrationActive: true, calibrationTargetPercentage: 20))
        _ = engine.update(currentSoC: 60, isPluggedIn: true)
        #expect(hw.isDischargeActive == false)
    }

    @Test func statusReportsDischargeHardwareSupport() {
        let hw = MockBatteryHardware()
        hw.probedDischargeSupport = true
        let engine = BatteryControlEngine(hardware: hw)
        engine.configure(BatteryControlConfiguration(enabled: true))
        let status = engine.update(currentSoC: 70, isPluggedIn: true)
        #expect(status.isDischargeHardwareSupported == true)
    }
```

`MockBatteryHardware`(같은 파일 상단)에 추가:

```swift
    /// `nil`이면 기존처럼 `registerSet`에서 파생한다.
    var probedDischargeSupport: Bool?
    var isDischargeSupported: Bool { probedDischargeSupport ?? registerSet.isDischargeSupported }
```

`WattlyTests/BatteryControlProtocolTests.swift` 닫는 `}` 앞:

```swift
    @Test func dischargeSupportFlagIsOptionalForOlderHelpers() throws {
        let legacy = #"{"mode":"charging","currentPercentage":80,"isPowerAdapterConnected":true,"detail":"","updatedAt":0}"#
        let decoded = try BatteryControlCodec.decode(
            BatteryControlServiceStatus.self, from: Data(legacy.utf8))
        #expect(decoded.isDischargeHardwareSupported == nil)
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryControlEngineTests test
```
Expected: 컴파일 실패 — `value of type 'BatteryControlServiceStatus' has no member 'isDischargeHardwareSupported'`

- [ ] **Step 3: 프로토콜·status·하드웨어 배선**

`FanControlShared/BatteryControlEngine.swift`의 프로토콜에 요구사항 추가:

```swift
public protocol BatteryControlHardwareProtocol: Sendable {
    var registerSet: BatteryControlRegisterSet { get }
    /// CHIE가 실제로 존재하는지 **프로브한** 결과. `registerSet`은 정책 세대를 말할 뿐이라
    /// `.modern`인데 CHIE가 없는 기계를 걸러내지 못한다.
    var isDischargeSupported: Bool { get }
    func readChargingGate(targetLimit: Int) -> BatteryHardwareGate
    func setChargingInhibited(_ inhibited: Bool, targetLimit: Int) -> Bool
    func setDischargingActive(_ active: Bool) -> Bool
    func releaseChargingControlAndVerify() -> BatteryReleaseVerification
}

public extension BatteryControlHardwareProtocol {
    /// 프로브를 제공하지 않는 구현(테스트 더블 등)은 기존 동작을 유지한다.
    var isDischargeSupported: Bool { registerSet.isDischargeSupported }
}
```

엔진의 파생 프로퍼티를 교체:

```swift
    /// Whether the Mac's hardware supports active discharge control via CHIE.
    public var isDischargeHardwareSupported: Bool {
        hardware.isDischargeSupported
    }
```

`status(...)`의 `BatteryControlServiceStatus(...)` 생성부에 인자 추가 (`isHardwareSupported:` 다음 줄):

```swift
            isDischargeHardwareSupported: isDischargeHardwareSupported,
```

`FanControlShared/BatteryControlProtocol.swift`의 `BatteryControlServiceStatus`에 `isHardwareSupported` 바로 아래로 필드·init 파라미터·대입을 추가:

```swift
    /// 이 Mac이 CHIE 강제 방전을 지원하는지 — 레지스터 세대 추정이 아니라 실제 프로브 결과.
    /// `nil`은 이 필드를 모르는 구버전 헬퍼이며 "미지원"이 아니라 "모름"이다.
    public var isDischargeHardwareSupported: Bool?
```
```swift
        isHardwareSupported: Bool? = nil,
        isDischargeHardwareSupported: Bool? = nil,
```
```swift
        self.isHardwareSupported = isHardwareSupported
        self.isDischargeHardwareSupported = isDischargeHardwareSupported
```

`WattlyFanDaemon/BatteryControlHardware.swift`에 저장 프로퍼티와 프로브를 추가 — `public let registerSet` 아래:

```swift
    /// `registerSet`과 별개로 CHIE 키 자체를 프로브한 결과. 세대 표가 "지원"이라고 말하는
    /// 기계에도 이 키가 없을 수 있고, 그때 방전 요청은 조용히 아무 일도 하지 않는다.
    public let isDischargeSupported: Bool
```
`init`의 `self.registerSet = registerSet` 다음:

```swift
        isDischargeSupported = BatteryControlKeys.isDischargeSupported { smc.keyInfo($0) }
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryControlEngineTests -only-testing:WattlyTests/BatteryControlProtocolTests test
```
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add FanControlShared/BatteryControlEngine.swift FanControlShared/BatteryControlProtocol.swift WattlyFanDaemon/BatteryControlHardware.swift WattlyTests/ && git commit -m "feat(battery): wire the real CHIE probe and report discharge support"
```

---

## Task 5: 데몬 코디네이터 — 어댑터 분리 예외·저장·Top Up 만료 차단

**Files:**
- Modify: `FanControlShared/BatteryControlCoordinator.swift`
- Modify: `FanControlShared/BatteryControlPolicy.swift`
- Test: `WattlyTests/BatteryControlCoordinatorTests.swift`, `WattlyTests/BatteryControlPolicyTests.swift`

**Interfaces:**
- Consumes: Task 1·2·3·4
- Produces:
  - 코디네이터가 `calibrationActive`를 어댑터 분리 시 해제하지 **않음** (`sample` / `reconcile` / `restore` 3곳)
  - `calibrationActive`가 정책 파일에 저장됨 (`persistPolicy`)
  - `BatteryControlCoordinator.capabilities`에 `.calibrationV1` 포함
  - `BatteryTopUpExpiry.decide(calibrationActive:)` 실배선
  - `BatteryControlPolicy.shouldReapply`가 데몬의 캘리브레이션을 보존

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/BatteryControlCoordinatorTests.swift` 닫는 `}` 앞:

```swift
    @Test func calibrationSurvivesAdapterDisconnect() {
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501,
            store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()),
            now: { 1000 })
        _ = coordinator.configure(
            .init(enabled: true, calibrationActive: true, calibrationTargetPercentage: 20),
            trigger: .clientConfiguration, currentSoC: 60, isPluggedIn: true)

        // Top Up·수동 방전은 어댑터가 빠지면 끝나지만 캘리브레이션은 살아남는다 —
        // 방전 단계는 자연 방전으로 이어지고, 재연결 후 절차가 그대로 이어져야 한다.
        _ = coordinator.sample(currentSoC: 59, isPluggedIn: false)
        #expect(coordinator.latestStatus.desiredConfiguration?.calibrationActive == true)
        _ = coordinator.reconcile(trigger: .adapterTransition, currentSoC: 58, isPluggedIn: false)
        #expect(coordinator.latestStatus.desiredConfiguration?.calibrationActive == true)
    }

    @Test func calibrationIsPersistedAndRestored() {
        let store = PolicyStoreSpy()
        let first = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()), now: { 1000 })
        _ = first.configure(
            .init(enabled: true, calibrationActive: true, calibrationTargetPercentage: 20),
            trigger: .clientConfiguration, currentSoC: 60, isPluggedIn: true)
        #expect(store.stored?.configuration.calibrationActive == true)

        let restarted = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()), now: { 2000 })
        let status = restarted.restore(currentSoC: 55, isPluggedIn: true)
        #expect(status.desiredConfiguration?.calibrationActive == true)
        #expect(status.desiredConfiguration?.calibrationTargetPercentage == 20)
    }

    @Test func calibrationExcludesManualDischarge() {
        let store = PolicyStoreSpy()
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()), now: { 1000 })
        let status = coordinator.configure(
            .init(enabled: true, manualDischargeActive: true, manualDischargeTarget: 60,
                  calibrationActive: true, calibrationTargetPercentage: 20),
            trigger: .clientConfiguration, currentSoC: 80, isPluggedIn: true)
        #expect(status.desiredConfiguration?.calibrationActive == true)
        #expect(status.desiredConfiguration?.manualDischargeActive == false)
    }

    @Test func coordinatorAdvertisesCalibrationCapability() {
        #expect(BatteryControlCoordinator.capabilities.contains(.calibrationV1))
    }

    @Test func topUpNeverExpiresDuringCalibration() {
        let store = PolicyStoreSpy()
        let clock = MutableClock(1000)
        let coordinator = BatteryControlCoordinator(
            ownerUID: 501, store: store,
            engine: BatteryControlEngine(hardware: MockBatteryHardware()),
            now: { clock.now })
        _ = coordinator.configure(
            .init(enabled: true, topUpActive: true, calibrationActive: true),
            trigger: .clientConfiguration, currentSoC: 100, isPluggedIn: true)
        clock.advance(by: BatteryTopUpExpiry.duration + 3600)
        _ = coordinator.sample(currentSoC: 100, isPluggedIn: true)
        #expect(coordinator.latestStatus.desiredConfiguration?.topUpActive == true)
        #expect(coordinator.latestStatus.lastMaintenance?.trigger != .topUpExpired)
    }
```

`WattlyTests/BatteryControlPolicyTests.swift` 닫는 `}` 앞:

```swift
    @Test func reconcilePreservesDaemonCalibration() {
        let daemon = BatteryControlConfiguration(
            enabled: true, limitPercentage: 80,
            calibrationActive: true, calibrationTargetPercentage: 20)
        let status = BatteryControlServiceStatus(
            mode: .inhibited, currentPercentage: 60, isPowerAdapterConnected: true,
            detail: "", updatedAt: 0,
            desiredConfiguration: daemon,
            capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1])
        // 저장된 선호값만으로 만든 요청에는 캘리브레이션이 없다. 그래도 재적용이
        // 필요하다고 판정하면 안 된다 — 60초마다 절차를 취소하는 write가 나간다.
        let requested = BatteryControlConfiguration(enabled: true, limitPercentage: 80)
        #expect(BatteryControlPolicy.shouldReapply(configuration: requested, status: status) == false)
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryControlCoordinatorTests -only-testing:WattlyTests/BatteryControlPolicyTests test
```
Expected: FAIL — `coordinatorAdvertisesCalibrationCapability`와 `reconcilePreservesDaemonCalibration`

- [ ] **Step 3: 구현**

`FanControlShared/BatteryControlCoordinator.swift`:

1. capabilities 목록에 추가:
```swift
    public static let capabilities: [BatteryControlCapability] = [
        .persistedPolicyV1,
        .hardwareGateReadbackV1,
        .systemPowerEventsV1,
        .calibrationV1,
    ]
```

2. `restore(...)`의 Top Up 자동 해제에 예외:
```swift
            if !isPluggedIn && desired.topUpActive && !desired.calibrationActive {
```

3. `sample(...)`의 수동 방전 자동 해제에 예외:
```swift
        if !isPluggedIn && engine.configuration.manualDischargeActive
            && !engine.configuration.calibrationActive {
```

4. `reconcile(...)`의 자동 종료에 예외 — 조건 전체를 교체:
```swift
        // 캘리브레이션 중에는 어댑터 분리가 종료 사유가 아니다. 방전 단계는 자연 방전으로
        // 이어지고, 충전 단계는 앱 FSM이 `paused(needsAdapter)`로 잡아 재연결을 기다린다.
        if !isPluggedIn && !engine.configuration.calibrationActive
            && (engine.configuration.topUpActive || engine.configuration.manualDischargeActive) {
```

5. `persistPolicy(...)`에서 캘리브레이션은 지우지 않는다 — `manualDischargeActive = false` 아래에 주석만 추가하고 `calibrationActive`는 손대지 않는다:
```swift
        var persisted = configuration
        persisted.manualDischargeActive = false
        // `calibrationActive`는 의도적으로 남긴다. 앱이 죽어도 엔진의 하한 가드가 살아 있어야
        // 최악이 "하한 도달 후 홀드"라는 설계된 안전 상태로 끝난다 (결정 #35).
```

6. `configure(...)`와 `configureWithoutPowerReading(...)`의 상호 배제 블록에 캘리브레이션을 추가한다. 두 함수 모두 `if normalized.manualDischargeActive { ... } else if normalized.topUpActive { ... }` 다음 줄에:
```swift
        // 캘리브레이션은 충전 단계에서 `topUpActive`를 빌려 쓰므로 그것과는 공존하지만,
        // 수동 방전과는 같은 CHIE를 다투므로 공존할 수 없다 (결정 #24).
        if normalized.calibrationActive {
            normalized.manualDischargeActive = false
        }
```

7. `evaluateTopUpExpiry(...)`의 `decide` 호출에 인자 추가:
```swift
        switch BatteryTopUpExpiry.decide(
            topUpActive: engine.configuration.topUpActive,
            isHoldingAtFull: status.detailReason?.kind == .topUpComplete,
            reachedFullAt: topUpReachedFullAt,
            now: now(),
            calibrationActive: engine.configuration.calibrationActive
        ) {
```
그리고 이 함수의 doc comment에서 "그 플래그는 아직 존재하지 않으므로 지금은 기본값(false)에 맡긴다" 문장을 "그 예외가 아래 `calibrationActive:` 인자다"로 교체한다.

`FanControlShared/BatteryTopUpExpiry.swift`의 `calibrationActive` 파라미터 doc에서 "그 플래그는 아직 코드베이스에 없으므로 항상 기본값 `false`로 호출된다"를 "`BatteryControlCoordinator`가 엔진 설정에서 읽어 넘긴다"로 교체한다.

`FanControlShared/BatteryControlPolicy.swift`의 `shouldReapply`에서 manual discharge 보존 블록 다음에 추가:

```swift
            // Background periodic reconciliation preserves an in-flight calibration
            if desired.calibrationActive && !configuration.calibrationActive {
                requested.calibrationActive = true
                requested.calibrationTargetPercentage = desired.calibrationTargetPercentage
            }
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryControlCoordinatorTests -only-testing:WattlyTests/BatteryControlPolicyTests -only-testing:WattlyTests/BatteryTopUpExpiryTests test
```
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add FanControlShared/ WattlyTests/ && git commit -m "feat(battery): keep calibration alive across adapter loss, restarts and top-up expiry"
```

---

## Task 6: 앱 순수 계층 — 절차 값 타입

**Files:**
- Create: `Wattly/Core/BatteryCalibrationState.swift`
- Test: `WattlyTests/BatteryCalibrationStateTests.swift`

**Interfaces:**
- Consumes: 없음 (앱 순수 계층의 첫 태스크)
- Produces: `CalibrationStep`(+`next`,`primitive`) · `CalibrationPrimitive` · `CalibrationPause`(+`consumesBudget`) · `CalibrationOutcome` · `CalibrationFailure` · `CalibrationTimers`(+`resetForNewStep()`) · `CalibrationSnapshot` · `CalibrationRunState`(+`appliedPrimitive`) · `CalibrationHistoryEntry`

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/BatteryCalibrationStateTests.swift` (신규):

```swift
import Foundation
import Testing
@testable import Wattly

struct BatteryCalibrationStateTests {
    @Test func stepChainVisitsEveryStepExactlyOnce() {
        var visited: [CalibrationStep] = []
        var cursor: CalibrationStep? = .preflight
        while let step = cursor {
            visited.append(step)
            cursor = step.next
        }
        #expect(visited == [.preflight, .chargeToFull, .dischargeToFloor,
                            .soakLow, .rechargeToFull, .soakFinal, .restoring])
        #expect(visited.count == CalibrationStep.allCases.count)
        #expect(CalibrationStep.restoring.next == nil)
    }

    @Test func stepsMapToTheirDaemonPrimitive() {
        #expect(CalibrationStep.preflight.primitive == .idle)
        #expect(CalibrationStep.chargeToFull.primitive == .chargeToFull)
        #expect(CalibrationStep.rechargeToFull.primitive == .chargeToFull)
        #expect(CalibrationStep.dischargeToFloor.primitive == .dischargeToFloor)
        #expect(CalibrationStep.soakLow.primitive == .holdAtFloor)
        #expect(CalibrationStep.soakFinal.primitive == .holdAtFull)
        #expect(CalibrationStep.restoring.primitive == .restore)
    }

    @Test func onlySystemSleepIsFreeOfThePauseBudget() {
        #expect(CalibrationPause.systemSleep.consumesBudget == false)
        for pause in CalibrationPause.allCases where pause != .systemSleep {
            #expect(pause.consumesBudget)
        }
    }

    @Test func newStepKeepsOnlyThePauseBudget() {
        var timers = CalibrationTimers()
        timers.stepActiveSeconds = 500
        timers.pausedTotalSeconds = 120
        timers.socUnchangedSeconds = 300
        timers.fullHoldSeconds = 30
        timers.chargeStalledSeconds = 60
        timers.lastSoC = 77

        let reset = timers.resetForNewStep()
        #expect(reset.pausedTotalSeconds == 120)
        #expect(reset.stepActiveSeconds == 0)
        #expect(reset.socUnchangedSeconds == 0)
        #expect(reset.fullHoldSeconds == 0)
        #expect(reset.chargeStalledSeconds == 0)
        #expect(reset.lastSoC == nil)
    }

    @Test func runStateRoundTripsThroughJSON() throws {
        let state = CalibrationRunState(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1000),
            step: .dischargeToFloor,
            timers: CalibrationTimers(),
            pause: .heatProtection,
            snapshot: CalibrationSnapshot(
                limitEnabled: true, limitPercentage: 80,
                sailingEnabled: false, sailingDelta: 5,
                heatProtectionEnabled: true, heatProtectionThresholdCelsius: 35,
                autoDischargeEnabled: true, manualDischargeTarget: 80),
            beginMaxCapacityMilliampHours: 6208,
            beginCycleCount: 112,
            lastProgressAt: Date(timeIntervalSince1970: 2000),
            lastTickAt: Date(timeIntervalSince1970: 2010),
            appliedPrimitive: .dischargeToFloor)
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(CalibrationRunState.self, from: data) == state)
    }

    @Test func historyEntryRoundTripsThroughJSON() throws {
        let entry = CalibrationHistoryEntry(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 37_800),
            outcome: .completed,
            failure: nil,
            beginMaxCapacityMilliampHours: 6208,
            endMaxCapacityMilliampHours: 6243,
            beginCycleCount: 112,
            endCycleCount: 113)
        let data = try JSONEncoder().encode(entry)
        #expect(try JSONDecoder().decode(CalibrationHistoryEntry.self, from: data) == entry)
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml && xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryCalibrationStateTests test
```
Expected: 컴파일 실패 — `cannot find type 'CalibrationStep' in scope`

- [ ] **Step 3: 값 타입 작성**

`Wattly/Core/BatteryCalibrationState.swift` (신규):

```swift
import Foundation

/// 캘리브레이션 절차의 단계.
///
/// 초안의 8단계에서 `soakHigh`(첫 완충 뒤 고잔량 안정화)가 빠져 7단계가 됐다. 테이퍼는
/// 99→100% 구간의 10분 꼬리에서 일어나고 100%에 닿는 순간 엔진이 게이트를 끊으므로,
/// 그 뒤에는 관측할 테이퍼가 남아 있지 않다 (실기 확인). 고잔량 체류만 1시간 늘릴 뿐이었다.
public enum CalibrationStep: String, Codable, Equatable, Sendable, CaseIterable {
    case preflight
    case chargeToFull
    case dischargeToFloor
    case soakLow
    case rechargeToFull
    case soakFinal
    case restoring

    public var next: CalibrationStep? {
        switch self {
        case .preflight: return .chargeToFull
        case .chargeToFull: return .dischargeToFloor
        case .dischargeToFloor: return .soakLow
        case .soakLow: return .rechargeToFull
        case .rechargeToFull: return .soakFinal
        case .soakFinal: return .restoring
        case .restoring: return nil
        }
    }

    /// 이 단계에서 데몬에 내려보낼 원시 명령. 데몬은 단계 개념을 모르고 이것만 안다.
    public var primitive: CalibrationPrimitive {
        switch self {
        case .preflight: return .idle
        case .chargeToFull, .rechargeToFull: return .chargeToFull
        case .dischargeToFloor: return .dischargeToFloor
        case .soakLow: return .holdAtFloor
        case .soakFinal: return .holdAtFull
        case .restoring: return .restore
        }
    }
}

/// 앱이 데몬에 내리는 원시 명령. 충전 계열은 기존 Top Up 경로를 그대로 빌려 쓴다.
public enum CalibrationPrimitive: String, Codable, Equatable, Sendable {
    /// 아무것도 내려보내지 않는다. `none`이라 부르지 않는 이유는 `Optional.none`과 이름이
    /// 겹쳐 `primitive != .none` 같은 비교가 조용히 다른 뜻이 되기 때문이다.
    case idle
    case chargeToFull
    case holdAtFull
    case dischargeToFloor
    case holdAtFloor
    case restore
}

public enum CalibrationPause: String, Codable, Equatable, Sendable, CaseIterable {
    case needsAdapter
    case heatProtection
    case helperUnavailable
    case systemSleep
    /// 어댑터도 붙어 있고 우리 게이트도 열렸는데 충전이 시작되지 않는다. 실기에서
    /// macOS "최적화된 배터리 충전"이 정확히 이 상태를 만들었다.
    case externalChargeBlock

    /// 시스템 잠자기는 2시간 일시정지 예산을 쓰지 않는다. 사용자가 뚜껑을 닫는 것을
    /// assertion으로 막을 수 없고, 12시간 무진행 자동 취소가 이미 안전망이기 때문이다.
    public var consumesBudget: Bool { self != .systemSleep }
}

public enum CalibrationOutcome: String, Codable, Equatable, Sendable {
    case completed
    case cancelled
    case expired
    case failed
}

public enum CalibrationFailure: String, Codable, Equatable, Sendable {
    case stepTimeout
    case pauseBudgetExhausted
    case helperLost
    case dischargeUnsupported
}

/// 절차가 누적하는 시간들. 전부 코디네이터가 tick마다 `BatteryCalibration.tick`으로
/// 갱신하며, 판정 함수는 이 값을 읽기만 한다.
public struct CalibrationTimers: Codable, Equatable, Sendable {
    /// 현재 단계에서 깨어 있고 일시정지도 아니었던 시간.
    public var stepActiveSeconds: TimeInterval
    /// 절차 전체에서 누적된 일시정지 시간(잠자기 제외). 유일하게 단계를 넘어 살아남는다.
    public var pausedTotalSeconds: TimeInterval
    /// SoC가 바뀌지 않은 채 흐른 깨어 있던 시간.
    public var socUnchangedSeconds: TimeInterval
    /// `soc >= 100 && !isCharging`이 유지된 시간.
    public var fullHoldSeconds: TimeInterval
    /// 충전 단계인데 충전 전류가 바닥인 채 흐른 시간.
    public var chargeStalledSeconds: TimeInterval
    public var lastSoC: Int?

    public init(
        stepActiveSeconds: TimeInterval = 0,
        pausedTotalSeconds: TimeInterval = 0,
        socUnchangedSeconds: TimeInterval = 0,
        fullHoldSeconds: TimeInterval = 0,
        chargeStalledSeconds: TimeInterval = 0,
        lastSoC: Int? = nil
    ) {
        self.stepActiveSeconds = stepActiveSeconds
        self.pausedTotalSeconds = pausedTotalSeconds
        self.socUnchangedSeconds = socUnchangedSeconds
        self.fullHoldSeconds = fullHoldSeconds
        self.chargeStalledSeconds = chargeStalledSeconds
        self.lastSoC = lastSoC
    }

    /// 단계가 바뀌면 관측 누적은 모두 버리고 일시정지 예산만 이어간다.
    public func resetForNewStep() -> CalibrationTimers {
        CalibrationTimers(pausedTotalSeconds: pausedTotalSeconds)
    }
}

/// 절차 시작 시점의 사용자 설정. 종료 사유와 무관하게 이걸 그대로 되돌린다.
public struct CalibrationSnapshot: Codable, Equatable, Sendable {
    public var limitEnabled: Bool
    public var limitPercentage: Int
    public var sailingEnabled: Bool
    public var sailingDelta: Int
    public var heatProtectionEnabled: Bool
    public var heatProtectionThresholdCelsius: Int
    public var autoDischargeEnabled: Bool
    public var manualDischargeTarget: Int

    public init(
        limitEnabled: Bool,
        limitPercentage: Int,
        sailingEnabled: Bool,
        sailingDelta: Int,
        heatProtectionEnabled: Bool,
        heatProtectionThresholdCelsius: Int,
        autoDischargeEnabled: Bool,
        manualDischargeTarget: Int
    ) {
        self.limitEnabled = limitEnabled
        self.limitPercentage = limitPercentage
        self.sailingEnabled = sailingEnabled
        self.sailingDelta = sailingDelta
        self.heatProtectionEnabled = heatProtectionEnabled
        self.heatProtectionThresholdCelsius = heatProtectionThresholdCelsius
        self.autoDischargeEnabled = autoDischargeEnabled
        self.manualDischargeTarget = manualDischargeTarget
    }
}

/// 지속 저장되는 실행 상태. 앱 메모리가 아니라 이 값이 절차의 진실이다.
public struct CalibrationRunState: Codable, Equatable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var step: CalibrationStep
    public var timers: CalibrationTimers
    public var pause: CalibrationPause?
    public var snapshot: CalibrationSnapshot
    public var beginMaxCapacityMilliampHours: Int?
    public var beginCycleCount: Int?
    /// SoC나 단계가 마지막으로 실제로 움직인 벽시계 시각. 12시간 무진행 취소의 기준이며,
    /// 잠자기 동안에도 흐른다 — 뚜껑을 밤새 닫아둔 절차를 끊는 것이 목적이기 때문이다.
    public var lastProgressAt: Date
    public var lastTickAt: Date
    /// 데몬에 마지막으로 실제로 내려보낸 원시 명령. 같은 명령을 10초마다 다시 쓰지 않기
    /// 위한 것이다 — 전이가 아닌 반복 write는 SMC 트래픽 규칙이 금지한다.
    public var appliedPrimitive: CalibrationPrimitive?

    public init(
        id: UUID,
        startedAt: Date,
        step: CalibrationStep,
        timers: CalibrationTimers,
        pause: CalibrationPause?,
        snapshot: CalibrationSnapshot,
        beginMaxCapacityMilliampHours: Int?,
        beginCycleCount: Int?,
        lastProgressAt: Date,
        lastTickAt: Date,
        appliedPrimitive: CalibrationPrimitive?
    ) {
        self.id = id
        self.startedAt = startedAt
        self.step = step
        self.timers = timers
        self.pause = pause
        self.snapshot = snapshot
        self.beginMaxCapacityMilliampHours = beginMaxCapacityMilliampHours
        self.beginCycleCount = beginCycleCount
        self.lastProgressAt = lastProgressAt
        self.lastTickAt = lastTickAt
        self.appliedPrimitive = appliedPrimitive
    }
}

public struct CalibrationHistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var finishedAt: Date
    public var outcome: CalibrationOutcome
    public var failure: CalibrationFailure?
    public var beginMaxCapacityMilliampHours: Int?
    public var endMaxCapacityMilliampHours: Int?
    public var beginCycleCount: Int?
    public var endCycleCount: Int?

    public init(
        id: UUID,
        startedAt: Date,
        finishedAt: Date,
        outcome: CalibrationOutcome,
        failure: CalibrationFailure?,
        beginMaxCapacityMilliampHours: Int?,
        endMaxCapacityMilliampHours: Int?,
        beginCycleCount: Int?,
        endCycleCount: Int?
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.failure = failure
        self.beginMaxCapacityMilliampHours = beginMaxCapacityMilliampHours
        self.endMaxCapacityMilliampHours = endMaxCapacityMilliampHours
        self.beginCycleCount = beginCycleCount
        self.endCycleCount = endCycleCount
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryCalibrationStateTests test
```
Expected: PASS (6개 테스트)

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Core/BatteryCalibrationState.swift WattlyTests/BatteryCalibrationStateTests.swift project.yml Wattly.xcodeproj && git commit -m "feat(battery): add pure value types for the calibration procedure"
```

---

## Task 7: 순수 타이머 누적 (`tick`) — 잠자기·일시정지 규칙

**Files:**
- Create: `Wattly/Core/BatteryCalibration.swift`
- Test: `WattlyTests/BatteryCalibrationTests.swift`

**Interfaces:**
- Consumes: Task 6의 `CalibrationTimers`
- Produces: `BatteryCalibration` 상수 전체 + `BatteryCalibration.tick(_:elapsed:isSleepGap:isPaused:soc:isFullSettled:isChargeStalled:) -> CalibrationTimers`

**설계 근거:** 이 함수가 이번 설계에서 실기 테스트가 잡아낸 유일한 논리 버그의 수정본이다. 원안의 "SoC 15분 무변화 → 하한 도달로 간주"는 **clamshell sleep과 정확히 같은 signature**를 만든다 — 60%에서 뚜껑을 20분 덮으면 FSM이 20% 대신 60%에서 방전을 끝낸다. 실측: sleep 602초 동안 SoC 변화 −0.01%p(깨어 있었으면 −2.37%p).

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/BatteryCalibrationTests.swift` (신규):

```swift
import Foundation
import Testing
@testable import Wattly

struct BatteryCalibrationTickTests {
    private func makeTimers(lastSoC: Int?) -> CalibrationTimers {
        CalibrationTimers(lastSoC: lastSoC)
    }

    @Test func activeTickAccumulatesStepTime() {
        let out = BatteryCalibration.tick(
            makeTimers(lastSoC: 60), elapsed: 10, isSleepGap: false, isPaused: false,
            soc: 59, isFullSettled: false, isChargeStalled: false)
        #expect(out.stepActiveSeconds == 10)
        #expect(out.pausedTotalSeconds == 0)
        #expect(out.socUnchangedSeconds == 0)   // SoC가 움직였으니 정체는 리셋
        #expect(out.lastSoC == 59)
    }

    @Test func unchangedSoCAccumulatesStallTime() {
        var timers = makeTimers(lastSoC: 60)
        for _ in 0..<3 {
            timers = BatteryCalibration.tick(
                timers, elapsed: 10, isSleepGap: false, isPaused: false,
                soc: 60, isFullSettled: false, isChargeStalled: false)
        }
        #expect(timers.socUnchangedSeconds == 30)
        #expect(timers.stepActiveSeconds == 30)
    }

    @Test func sleepGapFreezesEverythingAndDropsObservations() {
        var timers = makeTimers(lastSoC: 60)
        timers.stepActiveSeconds = 600
        timers.socUnchangedSeconds = 600
        timers.fullHoldSeconds = 40
        timers.chargeStalledSeconds = 120
        timers.pausedTotalSeconds = 300

        let out = BatteryCalibration.tick(
            timers, elapsed: 1200, isSleepGap: true, isPaused: false,
            soc: 60, isFullSettled: false, isChargeStalled: false)

        // 잠든 시간은 단계 시간에도, 일시정지 예산에도 들어가지 않는다.
        #expect(out.stepActiveSeconds == 600)
        #expect(out.pausedTotalSeconds == 300)
        // 잠들기 전에 쌓인 "무변화" 관측은 버린다 — 이게 clamshell 오작동을 막는 지점이다.
        #expect(out.socUnchangedSeconds == 0)
        #expect(out.fullHoldSeconds == 0)
        #expect(out.chargeStalledSeconds == 0)
        #expect(out.lastSoC == 60)
    }

    @Test func pausedTickSpendsBudgetAndFreezesStepTimer() {
        var timers = makeTimers(lastSoC: 60)
        timers.stepActiveSeconds = 100
        timers.socUnchangedSeconds = 100
        let out = BatteryCalibration.tick(
            timers, elapsed: 10, isSleepGap: false, isPaused: true,
            soc: 60, isFullSettled: false, isChargeStalled: false)
        #expect(out.pausedTotalSeconds == 10)
        #expect(out.stepActiveSeconds == 100)
        #expect(out.socUnchangedSeconds == 100)
    }

    @Test func fullHoldAndChargeStallResetWhenTheConditionBreaks() {
        var timers = makeTimers(lastSoC: 100)
        timers.fullHoldSeconds = 50
        timers.chargeStalledSeconds = 500
        let out = BatteryCalibration.tick(
            timers, elapsed: 10, isSleepGap: false, isPaused: false,
            soc: 100, isFullSettled: false, isChargeStalled: false)
        #expect(out.fullHoldSeconds == 0)
        #expect(out.chargeStalledSeconds == 0)
    }

    @Test func nonPositiveElapsedIsIgnored() {
        let timers = makeTimers(lastSoC: 60)
        let out = BatteryCalibration.tick(
            timers, elapsed: -5, isSleepGap: false, isPaused: false,
            soc: 10, isFullSettled: false, isChargeStalled: false)
        #expect(out == timers)
    }

    @Test func constantsMatchTheVerifiedDesign() {
        #expect(BatteryCalibration.floorPercentage == 20)
        #expect(BatteryCalibration.fullSettleSeconds == 60)
        #expect(BatteryCalibration.soakLowSeconds == 600)
        #expect(BatteryCalibration.soakFinalSeconds == 3600)
        #expect(BatteryCalibration.dischargeStallSeconds == 900)
        #expect(BatteryCalibration.sleepGapSeconds == 90)
        #expect(BatteryCalibration.chargePhaseTimeout == 6 * 3600)
        #expect(BatteryCalibration.dischargePhaseTimeout == 12 * 3600)
        #expect(BatteryCalibration.pauseBudgetSeconds == 2 * 3600)
        #expect(BatteryCalibration.staleAbandonSeconds == 12 * 3600)
        #expect(BatteryCalibration.cooldownDays == 90)
        #expect(BatteryCalibration.cooldownCycles == 40)
        #expect(BatteryCalibration.naturalCapacityDriftMilliampHours == 86)
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml && xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryCalibrationTickTests test
```
Expected: 컴파일 실패 — `cannot find 'BatteryCalibration' in scope`

- [ ] **Step 3: 상수와 `tick` 작성**

`Wattly/Core/BatteryCalibration.swift` (신규):

```swift
import Foundation

/// 캘리브레이션 절차의 모든 판단. SwiftUI도 I/O도 `Date()`도 없다 —
/// `BatteryControlPolicy` / `PollPolicy` / `BatterySectionPresentation`과 같은 방식으로,
/// 코디네이터가 내리던 결정을 테이블 테스트가 가능한 함수로 모아 둔 것이다.
///
/// 아래 상수들은 대부분 개발기(Mac17,2 / M5 / macOS 26.6.2) 실측에서 나왔다. 각 값의
/// 근거를 주석에 남기는 이유는, 웹 조사와 코드 독해만으로 세운 원안의 값 중 셋이 실기에서
/// 뒤집혔기 때문이다.
public enum BatteryCalibration {

    // MARK: - 상수

    /// 방전 하한. AlDente는 10~15%를 노리다 11% 부근의 펌웨어 벽에 막히는 중이고(issue #1784),
    /// 20%는 그 절벽 위에 안전 마진을 두고 앉는다. 사용자에게 노출하지 않는다.
    public static let floorPercentage = 20

    /// 완충 인정에 필요한 `soc >= 100 && !isCharging` 지속 시간.
    /// 임계 전력(W)을 두지 않는 이유: 테이퍼가 8.01W → 0.00W 한 스텝에 절벽처럼 떨어져
    /// 튜닝할 구간 자체가 없다. `FullyCharged` 플래그는 완충 후에도 `No`로 남아 못 쓴다.
    public static let fullSettleSeconds: TimeInterval = 60

    /// 저잔량 안정화. BMS가 하한 경계에서 재학습할 짧은 정지 구간.
    public static let soakLowSeconds: TimeInterval = 600
    /// 최종 완충 후 안정화. 캘리브레이션의 charge flag를 세우는 것이 이 구간이다.
    public static let soakFinalSeconds: TimeInterval = 3600

    /// 방전 정체 인정 시간. 펌웨어가 더 이상 내려주지 않는 지점을 실패로 부르면 절차가
    /// 영원히 끝나지 않는다 — 참조 구현의 대표적 행 사유가 이것이다.
    public static let dischargeStallSeconds: TimeInterval = 900

    /// tick 간격이 이보다 벌어지면 그 사이 Mac이 잤다고 본다. 코디네이터 tick은 10초라
    /// 90초는 넉넉한 여유이면서 clamshell sleep(최소 수십 초)을 놓치지 않는다.
    public static let sleepGapSeconds: TimeInterval = 90

    public static let chargePhaseTimeout: TimeInterval = 6 * 3600
    /// 방전은 실측 0.113~0.331 %p/분으로 부하에 따라 3배 흔들린다. 100→20%가 4~7시간이라
    /// 원안의 10시간으로는 여유가 부족했다.
    public static let dischargePhaseTimeout: TimeInterval = 12 * 3600

    /// 일시정지 누적 상한. 열보호를 끄지 않는 대가로 정지가 길어질 수 있어 상한이 필요하다.
    /// 잠자기는 여기에 들어가지 않는다 (`CalibrationPause.consumesBudget`).
    public static let pauseBudgetSeconds: TimeInterval = 2 * 3600

    /// 진행이 전혀 없는 채로 이만큼 지나면 조용히 취소하고 원설정을 되돌린다. 뚜껑을 밤새
    /// 닫아둔 절차가 영원히 매달리는 것을 끊는 유일한 장치다.
    public static let staleAbandonSeconds: TimeInterval = 12 * 3600

    /// Battery University: "once every three months **or after 40 partial cycles**".
    public static let cooldownDays = 90
    public static let cooldownCycles = 40

    /// 충전 정체 판정: 어댑터가 붙고 게이트도 열렸는데 충전 전류가 이 값 아래로 이만큼
    /// 지속되면 외부 요인이 막고 있는 것이다. 실기에서 "최적화된 배터리 충전"이 켜져 있을 때
    /// `ChargingCurrent`가 100 mA에 머물렀다.
    public static let chargeStallMilliamps = 300
    public static let chargeStallSeconds: TimeInterval = 600

    /// 캘리브레이션과 무관하게 하루 안에 관측된 `AppleRawMaxCapacity` 변동폭.
    /// 완료 리포트는 용량 숫자 옆에 이 값을 반드시 함께 적는다.
    public static let naturalCapacityDriftMilliampHours = 86

    /// ETA 기본값 (실측 중앙값). 관측값이 생기면 코디네이터가 그것으로 대체한다.
    public static let defaultChargeRatePercentPerMinute = 0.73
    public static let defaultDischargeRatePercentPerMinute = 0.22

    // MARK: - 타이머 누적

    /// 한 tick만큼 타이머를 전진시킨다.
    ///
    /// - Parameters:
    ///   - elapsed: 직전 tick 이후 흐른 벽시계 시간.
    ///   - isSleepGap: `elapsed > sleepGapSeconds`. 이 경우 관측 누적을 **버린다** —
    ///     clamshell sleep은 "SoC 무변화"와 signature가 같아서, 버리지 않으면 60%에서
    ///     뚜껑을 20분 덮은 것이 하한 도달로 오인된다.
    ///   - isPaused: 예산을 소모하는 일시정지인지 (`CalibrationPause.consumesBudget`).
    ///   - isFullSettled: `soc >= 100 && !isCharging`.
    ///   - isChargeStalled: 충전 단계인데 충전 전류가 `chargeStallMilliamps` 미만.
    public static func tick(
        _ timers: CalibrationTimers,
        elapsed: TimeInterval,
        isSleepGap: Bool,
        isPaused: Bool,
        soc: Int,
        isFullSettled: Bool,
        isChargeStalled: Bool
    ) -> CalibrationTimers {
        guard elapsed > 0 else { return timers }
        var next = timers

        if isSleepGap {
            next.socUnchangedSeconds = 0
            next.fullHoldSeconds = 0
            next.chargeStalledSeconds = 0
            next.lastSoC = soc
            return next
        }

        if isPaused {
            // 일시정지 중에는 안정화 타이머가 멈춘다 — 멈추지 않으면 "대기 60분"이 실제로는
            // 억제 상태로 흘러가 그 구간이 무의미해진다.
            next.pausedTotalSeconds += elapsed
            return next
        }

        next.stepActiveSeconds += elapsed
        next.socUnchangedSeconds = (next.lastSoC == soc) ? next.socUnchangedSeconds + elapsed : 0
        next.fullHoldSeconds = isFullSettled ? next.fullHoldSeconds + elapsed : 0
        next.chargeStalledSeconds = isChargeStalled ? next.chargeStalledSeconds + elapsed : 0
        next.lastSoC = soc
        return next
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryCalibrationTickTests test
```
Expected: PASS (7개 테스트)

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Core/BatteryCalibration.swift WattlyTests/BatteryCalibrationTests.swift Wattly.xcodeproj && git commit -m "feat(battery): add pure calibration timers that only count awake time"
```

---

## Task 8: 순수 상태 전이 (`decide`)

**Files:**
- Modify: `Wattly/Core/BatteryCalibration.swift`
- Test: `WattlyTests/BatteryCalibrationTests.swift`

**Interfaces:**
- Consumes: Task 6·7
- Produces:
  - `CalibrationInput` (step, timers, soc, isAdapterPresent, isHeatProtected, helperReady, dischargeSupported, isSleepGap, isChargeStalled, secondsSinceProgress)
  - `CalibrationDecision` (`.hold` / `.advance(to:primitive:)` / `.pause` / `.finish(_:failure:)`)
  - `BatteryCalibration.decide(_:) -> CalibrationDecision`
  - `BatteryCalibration.stepTimeout(for:) -> TimeInterval?`

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/BatteryCalibrationTests.swift` 파일 끝에 새 스위트를 추가:

```swift
struct BatteryCalibrationDecideTests {
    private func input(
        step: CalibrationStep = .chargeToFull,
        timers: CalibrationTimers = CalibrationTimers(),
        soc: Int = 50,
        isAdapterPresent: Bool = true,
        isHeatProtected: Bool = false,
        helperReady: Bool = true,
        dischargeSupported: Bool = true,
        isSleepGap: Bool = false,
        isChargeStalled: Bool = false,
        secondsSinceProgress: TimeInterval = 0
    ) -> CalibrationInput {
        CalibrationInput(
            step: step, timers: timers, soc: soc,
            isAdapterPresent: isAdapterPresent, isHeatProtected: isHeatProtected,
            helperReady: helperReady, dischargeSupported: dischargeSupported,
            isSleepGap: isSleepGap, isChargeStalled: isChargeStalled,
            secondsSinceProgress: secondsSinceProgress)
    }

    // MARK: 정상 전이

    @Test func preflightAdvancesIntoTheFirstCharge() {
        #expect(BatteryCalibration.decide(input(step: .preflight))
            == .advance(to: .chargeToFull, primitive: .chargeToFull))
    }

    @Test func chargeHoldsUntilFullIsSettledForAMinute() {
        var timers = CalibrationTimers()
        timers.fullHoldSeconds = 50
        #expect(BatteryCalibration.decide(input(step: .chargeToFull, timers: timers, soc: 100))
            == .hold(.chargeToFull))
        timers.fullHoldSeconds = 60
        #expect(BatteryCalibration.decide(input(step: .chargeToFull, timers: timers, soc: 100))
            == .advance(to: .dischargeToFloor, primitive: .dischargeToFloor))
    }

    @Test func dischargeAdvancesAtTheFloor() {
        #expect(BatteryCalibration.decide(
            input(step: .dischargeToFloor, soc: 21, isAdapterPresent: true))
            == .hold(.dischargeToFloor))
        #expect(BatteryCalibration.decide(
            input(step: .dischargeToFloor, soc: 20, isAdapterPresent: true))
            == .advance(to: .soakLow, primitive: .holdAtFloor))
    }

    @Test func dischargeStallCountsAsSuccessNotFailure() {
        var timers = CalibrationTimers()
        timers.socUnchangedSeconds = BatteryCalibration.dischargeStallSeconds
        // 펌웨어가 더 내려주지 않는 지점. 실패로 부르면 절차가 영원히 안 끝난다.
        #expect(BatteryCalibration.decide(input(step: .dischargeToFloor, timers: timers, soc: 24))
            == .advance(to: .soakLow, primitive: .holdAtFloor))
    }

    @Test func soakStepsAdvanceOnTheirOwnClock() {
        var timers = CalibrationTimers()
        timers.stepActiveSeconds = BatteryCalibration.soakLowSeconds - 1
        #expect(BatteryCalibration.decide(input(step: .soakLow, timers: timers, soc: 20))
            == .hold(.holdAtFloor))
        timers.stepActiveSeconds = BatteryCalibration.soakLowSeconds
        #expect(BatteryCalibration.decide(input(step: .soakLow, timers: timers, soc: 20))
            == .advance(to: .rechargeToFull, primitive: .chargeToFull))

        timers.stepActiveSeconds = BatteryCalibration.soakFinalSeconds
        #expect(BatteryCalibration.decide(input(step: .soakFinal, timers: timers, soc: 100))
            == .advance(to: .restoring, primitive: .restore))
    }

    @Test func restoringFinishesTheRun() {
        #expect(BatteryCalibration.decide(input(step: .restoring))
            == .finish(.completed, failure: nil))
    }

    // MARK: 일시정지

    @Test func sleepPausesWithoutSpendingTheBudget() {
        #expect(BatteryCalibration.decide(
            input(step: .dischargeToFloor, isSleepGap: true)) == .pause(.systemSleep))
        #expect(CalibrationPause.systemSleep.consumesBudget == false)
    }

    @Test func chargeStepsPauseWhenTheAdapterIsGoneButDischargeDoesNot() {
        #expect(BatteryCalibration.decide(input(step: .chargeToFull, isAdapterPresent: false))
            == .pause(.needsAdapter))
        #expect(BatteryCalibration.decide(input(step: .soakLow, soc: 20, isAdapterPresent: false))
            == .pause(.needsAdapter))
        // 방전 단계는 어댑터가 없어도 자연 방전이 목표에 기여한다.
        #expect(BatteryCalibration.decide(
            input(step: .dischargeToFloor, soc: 50, isAdapterPresent: false))
            == .hold(.dischargeToFloor))
    }

    @Test func heatProtectionPausesAndIsNeverDisabled() {
        #expect(BatteryCalibration.decide(input(step: .chargeToFull, isHeatProtected: true))
            == .pause(.heatProtection))
    }

    @Test func missingHelperPauses() {
        #expect(BatteryCalibration.decide(input(step: .soakFinal, helperReady: false))
            == .pause(.helperUnavailable))
    }

    @Test func sustainedChargeStallPausesWithAnActionableReason() {
        var timers = CalibrationTimers()
        timers.chargeStalledSeconds = BatteryCalibration.chargeStallSeconds
        #expect(BatteryCalibration.decide(
            input(step: .chargeToFull, timers: timers, soc: 80, isChargeStalled: true))
            == .pause(.externalChargeBlock))
        // 방전 단계에는 이 판정이 적용되지 않는다.
        #expect(BatteryCalibration.decide(
            input(step: .dischargeToFloor, timers: timers, soc: 50, isChargeStalled: true))
            == .hold(.dischargeToFloor))
    }

    // MARK: 종료

    @Test func twelveHoursWithoutProgressCancelsQuietly() {
        // 실패가 아니라 조용한 취소다 — 뚜껑을 밤새 닫아둔 사용자를 실패로 부를 이유가 없다.
        #expect(BatteryCalibration.decide(
            input(step: .dischargeToFloor,
                  secondsSinceProgress: BatteryCalibration.staleAbandonSeconds))
            == .finish(.expired, failure: nil))
    }

    @Test func exhaustedPauseBudgetFails() {
        var timers = CalibrationTimers()
        timers.pausedTotalSeconds = BatteryCalibration.pauseBudgetSeconds
        #expect(BatteryCalibration.decide(input(step: .chargeToFull, timers: timers))
            == .finish(.failed, failure: .pauseBudgetExhausted))
    }

    @Test func stepTimeoutsFail() {
        var timers = CalibrationTimers()
        timers.stepActiveSeconds = BatteryCalibration.chargePhaseTimeout
        #expect(BatteryCalibration.decide(input(step: .chargeToFull, timers: timers, soc: 80))
            == .finish(.failed, failure: .stepTimeout))

        timers.stepActiveSeconds = BatteryCalibration.dischargePhaseTimeout
        #expect(BatteryCalibration.decide(input(step: .dischargeToFloor, timers: timers, soc: 50))
            == .finish(.failed, failure: .stepTimeout))

        // 안정화 단계는 시간이 곧 완료 조건이라 타임아웃이 없다.
        #expect(BatteryCalibration.stepTimeout(for: .soakLow) == nil)
        #expect(BatteryCalibration.stepTimeout(for: .soakFinal) == nil)
    }

    @Test func lostDischargeHardwareFails() {
        #expect(BatteryCalibration.decide(
            input(step: .dischargeToFloor, dischargeSupported: false))
            == .finish(.failed, failure: .dischargeUnsupported))
    }

    // MARK: 우선순위

    @Test func expiryOutranksEverythingAndSleepOutranksPauses() {
        // 12시간 무진행은 잠자기·열보호보다 먼저 판정된다.
        #expect(BatteryCalibration.decide(
            input(step: .chargeToFull, isHeatProtected: true, isSleepGap: true,
                  secondsSinceProgress: BatteryCalibration.staleAbandonSeconds))
            == .finish(.expired, failure: nil))
        // 잠자기는 예산을 쓰는 일시정지들보다 먼저 판정된다 — 그래야 예산이 보호된다.
        #expect(BatteryCalibration.decide(
            input(step: .chargeToFull, isAdapterPresent: false,
                  isHeatProtected: true, isSleepGap: true))
            == .pause(.systemSleep))
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryCalibrationDecideTests test
```
Expected: 컴파일 실패 — `cannot find type 'CalibrationInput' in scope`

- [ ] **Step 3: `decide` 작성**

`Wattly/Core/BatteryCalibration.swift`의 `enum BatteryCalibration` **바깥**(파일 상단, enum 앞)에 입력·출력 타입을 추가:

```swift
/// `decide`의 전 입력. 시스템 접근이 전혀 없는 값 묶음이라 어떤 조합이든 테스트로 만들 수 있다.
public struct CalibrationInput: Equatable, Sendable {
    public var step: CalibrationStep
    public var timers: CalibrationTimers
    /// **데몬 `status.currentPercentage`(IOPS) 전용.** `BatterySample.percentage`를 넣으면
    /// 안 된다 — raw 비율은 98.99%가 천장이라 완충 단계가 영원히 끝나지 않는다.
    public var soc: Int
    /// **`AdapterDetails.Watts > 0`을 포함해 판정한 값.** CHIE 강제 방전 중에는
    /// `ExternalConnected`도 IOPS도 "배터리 전원"이라고 거짓말한다.
    public var isAdapterPresent: Bool
    public var isHeatProtected: Bool
    public var helperReady: Bool
    public var dischargeSupported: Bool
    public var isSleepGap: Bool
    public var isChargeStalled: Bool
    /// SoC나 단계가 마지막으로 움직인 뒤 흐른 벽시계 시간. 잠자기 동안에도 흐른다.
    public var secondsSinceProgress: TimeInterval

    public init(
        step: CalibrationStep,
        timers: CalibrationTimers,
        soc: Int,
        isAdapterPresent: Bool,
        isHeatProtected: Bool,
        helperReady: Bool,
        dischargeSupported: Bool,
        isSleepGap: Bool,
        isChargeStalled: Bool,
        secondsSinceProgress: TimeInterval
    ) {
        self.step = step
        self.timers = timers
        self.soc = soc
        self.isAdapterPresent = isAdapterPresent
        self.isHeatProtected = isHeatProtected
        self.helperReady = helperReady
        self.dischargeSupported = dischargeSupported
        self.isSleepGap = isSleepGap
        self.isChargeStalled = isChargeStalled
        self.secondsSinceProgress = secondsSinceProgress
    }
}

public enum CalibrationDecision: Equatable, Sendable {
    case hold(CalibrationPrimitive)
    case advance(to: CalibrationStep, primitive: CalibrationPrimitive)
    case pause(CalibrationPause)
    /// 실패에는 반드시 사유가 붙는다. 참조 구현들이 못 한 것이 정확히 이것이다 —
    /// 사용자가 "무엇 때문에 멈췄는지" 알 수 없으면 복구할 방법도 없다.
    case finish(CalibrationOutcome, failure: CalibrationFailure?)
}
```

`enum BatteryCalibration` 안, `tick` 다음에 추가:

```swift
    // MARK: - 상태 전이

    public static func stepTimeout(for step: CalibrationStep) -> TimeInterval? {
        switch step {
        case .chargeToFull, .rechargeToFull: return chargePhaseTimeout
        case .dischargeToFloor: return dischargePhaseTimeout
        case .preflight, .soakLow, .soakFinal, .restoring: return nil
        }
    }

    /// 이번 tick에 무엇을 할지. 판정 순서 자체가 설계이므로 함부로 재배열하지 말 것 —
    /// 특히 잠자기가 예산 소모 일시정지들보다 **먼저** 와야 예산이 보호된다.
    public static func decide(_ input: CalibrationInput) -> CalibrationDecision {
        // 0. 원복 단계는 조건 없이 끝난다. 실제 원복은 코디네이터가 이미 수행한 뒤다.
        if input.step == .restoring { return .finish(.completed, failure: nil) }

        // 1. 12시간 무진행. 뚜껑을 밤새 닫아둔 경우가 여기로 들어온다. 실패가 아니라
        //    조용한 취소로 끝내고 원설정을 되돌린다.
        if input.secondsSinceProgress >= staleAbandonSeconds {
            return .finish(.expired, failure: nil)
        }

        // 2. 잠자기. 예산을 쓰지 않고, 정체 관측은 `tick`이 이미 버렸다.
        if input.isSleepGap { return .pause(.systemSleep) }

        // 3. 헬퍼 부재. 하드웨어는 마지막 원시 상태를 그대로 들고 있다.
        if !input.helperReady { return .pause(.helperUnavailable) }

        // 4. CHIE가 없으면 절차 자체가 성립하지 않는다. preflight가 이미 막지만,
        //    실행 중 하드웨어 판정이 뒤집히는 경우까지 여기서 닫는다.
        if !input.dischargeSupported {
            return .finish(.failed, failure: .dischargeUnsupported)
        }

        // 5. 열보호는 절대 자동 비활성화하지 않는다. 발동하면 기다린다.
        if input.isHeatProtected { return .pause(.heatProtection) }

        // 6. 어댑터. 방전 단계만 어댑터 없이도 진행된다.
        if input.step != .dischargeToFloor && !input.isAdapterPresent {
            return .pause(.needsAdapter)
        }

        // 7. 일시정지 예산 소진.
        if input.timers.pausedTotalSeconds >= pauseBudgetSeconds {
            return .finish(.failed, failure: .pauseBudgetExhausted)
        }

        // 8. 단계 타임아웃.
        if let timeout = stepTimeout(for: input.step),
           input.timers.stepActiveSeconds >= timeout {
            return .finish(.failed, failure: .stepTimeout)
        }

        // 9. 외부 요인이 충전을 막고 있다. 실기에서 macOS "최적화된 배터리 충전"이 켜져
        //    있으면 우리가 게이트를 열어도 충전이 시작되지 않았다 — 막는 이유를 아무 레지스터도
        //    보고하지 않은 채로.
        if input.step.primitive == .chargeToFull,
           input.soc < 100,
           input.isChargeStalled,
           input.timers.chargeStalledSeconds >= chargeStallSeconds {
            return .pause(.externalChargeBlock)
        }

        // 10. 단계 완료 판정.
        if isStepComplete(input), let next = input.step.next {
            return .advance(to: next, primitive: next.primitive)
        }
        return .hold(input.step.primitive)
    }

    private static func isStepComplete(_ input: CalibrationInput) -> Bool {
        switch input.step {
        case .preflight:
            return true
        case .chargeToFull, .rechargeToFull:
            return input.timers.fullHoldSeconds >= fullSettleSeconds
        case .dischargeToFloor:
            // 목표 도달, 또는 정체. 정체를 성공으로 처리하지 않으면 펌웨어 벽에서 절차가
            // 영원히 끝나지 않는다.
            return input.soc <= floorPercentage
                || input.timers.socUnchangedSeconds >= dischargeStallSeconds
        case .soakLow:
            return input.timers.stepActiveSeconds >= soakLowSeconds
        case .soakFinal:
            return input.timers.stepActiveSeconds >= soakFinalSeconds
        case .restoring:
            return true
        }
    }
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryCalibrationDecideTests -only-testing:WattlyTests/BatteryCalibrationTickTests test
```
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Core/BatteryCalibration.swift WattlyTests/BatteryCalibrationTests.swift && git commit -m "feat(battery): add the pure calibration state machine"
```

---

## Task 9: preflight 차단·쿨다운·ETA·완료 리포트 문구

**Files:**
- Modify: `Wattly/Core/BatteryCalibration.swift`
- Test: `WattlyTests/BatteryCalibrationTests.swift`

**Interfaces:**
- Consumes: Task 6·7·8
- Produces:
  - `CalibrationBlocker` enum
  - `BatteryCalibration.preflightBlockers(...) -> [CalibrationBlocker]`
  - `BatteryCalibration.isWithinCooldown(lastCompletedAt:cycleCountAtLastCompletion:currentCycleCount:now:) -> Bool`
  - `BatteryCalibration.estimatedRemainingMinutes(step:soc:chargeRatePercentPerMinute:dischargeRatePercentPerMinute:) -> Int`
  - `BatteryCalibration.completionHeadline(locale:) -> String`
  - `BatteryCalibration.capacityNote(beginMilliampHours:endMilliampHours:locale:) -> String?`

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/BatteryCalibrationTests.swift` 파일 끝에 새 스위트를 추가:

```swift
struct BatteryCalibrationPreflightTests {
    private func blockers(
        helperMode: BatteryControlServiceMode = .charging,
        capabilities: [BatteryControlCapability]? = [.calibrationV1],
        isHardwareSupported: Bool? = true,
        isDischargeHardwareSupported: Bool? = true,
        isAdapterPresent: Bool = true,
        isHeatProtected: Bool = false,
        isTopUpActive: Bool = false,
        isManualDischargeActive: Bool = false,
        hasConfirmedOptimizedChargingOff: Bool = true,
        hasConfirmedDuration: Bool = true
    ) -> [CalibrationBlocker] {
        BatteryCalibration.preflightBlockers(
            helperMode: helperMode, capabilities: capabilities,
            isHardwareSupported: isHardwareSupported,
            isDischargeHardwareSupported: isDischargeHardwareSupported,
            isAdapterPresent: isAdapterPresent, isHeatProtected: isHeatProtected,
            isTopUpActive: isTopUpActive, isManualDischargeActive: isManualDischargeActive,
            hasConfirmedOptimizedChargingOff: hasConfirmedOptimizedChargingOff,
            hasConfirmedDuration: hasConfirmedDuration)
    }

    @Test func aReadyMachineHasNoBlockers() {
        #expect(blockers().isEmpty)
    }

    @Test func anOldHelperBlocksWithItsOwnReason() {
        // 응답은 잘 하지만 캘리브레이션을 모르는 헬퍼. 전역 `requiredCapabilities`를 건드리지
        // 않고 이 카드 안에서만 막는다.
        #expect(blockers(capabilities: [.persistedPolicyV1]) == [.helperTooOld])
        #expect(blockers(capabilities: nil) == [.helperTooOld])
        #expect(blockers(helperMode: .unavailable, capabilities: nil) == [.helperUnavailable])
    }

    @Test func hardwareAndDischargeSupportBlockSeparately() {
        #expect(blockers(isHardwareSupported: false).contains(.hardwareUnsupported))
        #expect(blockers(isDischargeHardwareSupported: false).contains(.dischargeUnsupported))
        // `nil`은 "모름"이라 막지 않는다.
        #expect(blockers(isHardwareSupported: nil, isDischargeHardwareSupported: nil).isEmpty)
    }

    @Test func runtimeConditionsBlock() {
        #expect(blockers(isAdapterPresent: false).contains(.adapterDisconnected))
        #expect(blockers(isHeatProtected: true).contains(.heatProtectionActive))
        #expect(blockers(isTopUpActive: true).contains(.otherActivityRunning))
        #expect(blockers(isManualDischargeActive: true).contains(.otherActivityRunning))
    }

    @Test func acknowledgementsAreBlockersUntilConfirmed() {
        // #25는 안내가 아니라 차단 조건이다 — 실기에서 "최적화된 배터리 충전"이 켜진 채로는
        // 우리가 게이트를 열어도 충전이 아예 시작되지 않았다.
        #expect(blockers(hasConfirmedOptimizedChargingOff: false)
            .contains(.optimizedChargingUnconfirmed))
        #expect(blockers(hasConfirmedDuration: false).contains(.durationUnconfirmed))
    }

    @Test func cooldownIsNinetyDaysOrFortyCycles() {
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        // 90일 이내 + 사이클 40회 미만 → 쿨다운 안
        #expect(BatteryCalibration.isWithinCooldown(
            lastCompletedAt: now.addingTimeInterval(-30 * 86_400),
            cycleCountAtLastCompletion: 100, currentCycleCount: 110, now: now))
        // 90일 경과 → 쿨다운 밖
        #expect(BatteryCalibration.isWithinCooldown(
            lastCompletedAt: now.addingTimeInterval(-91 * 86_400),
            cycleCountAtLastCompletion: 100, currentCycleCount: 101, now: now) == false)
        // 사이클 40회 → 쿨다운 밖
        #expect(BatteryCalibration.isWithinCooldown(
            lastCompletedAt: now.addingTimeInterval(-30 * 86_400),
            cycleCountAtLastCompletion: 100, currentCycleCount: 140, now: now) == false)
        // 한 번도 안 돌렸으면 쿨다운이 없다
        #expect(BatteryCalibration.isWithinCooldown(
            lastCompletedAt: nil, cycleCountAtLastCompletion: nil,
            currentCycleCount: 110, now: now) == false)
    }
}

struct BatteryCalibrationReportTests {
    @Test func estimateCoversEveryRemainingStep() {
        // 100%에서 시작: 방전 80%p + soakLow 10분 + 재충전 80%p + soakFinal 60분
        let fromDischarge = BatteryCalibration.estimatedRemainingMinutes(
            step: .dischargeToFloor, soc: 100,
            chargeRatePercentPerMinute: 0.73, dischargeRatePercentPerMinute: 0.22)
        let expected = Int((80.0 / 0.22 + 10 + 80.0 / 0.73 + 60).rounded())
        #expect(fromDischarge == expected)

        // 뒤로 갈수록 남은 시간이 줄어든다.
        #expect(BatteryCalibration.estimatedRemainingMinutes(step: .soakFinal, soc: 100) == 60)
        #expect(BatteryCalibration.estimatedRemainingMinutes(step: .restoring, soc: 100) == 0)
    }

    @Test func estimateGuardsAgainstAbsurdRates() {
        // 0으로 나누지 않는다.
        #expect(BatteryCalibration.estimatedRemainingMinutes(
            step: .chargeToFull, soc: 50,
            chargeRatePercentPerMinute: 0, dischargeRatePercentPerMinute: 0) > 0)
    }

    @Test func headlineNeverPromisesCapacityRecovery() {
        let ko = BatteryCalibration.completionHeadline(locale: Locale(identifier: "ko"))
        #expect(ko == "잔량 표시 보정 완료")
        #expect(ko.contains("회복") == false)
        #expect(ko.contains("수명") == false)
    }

    @Test func capacityNoteAlwaysCarriesTheNaturalDriftBand() {
        let note = BatteryCalibration.capacityNote(
            beginMilliampHours: 6208, endMilliampHours: 6243,
            locale: Locale(identifier: "ko"))
        #expect(note?.contains("6208") == true)
        #expect(note?.contains("6243") == true)
        // 변동폭을 감춘 채 숫자만 보여주면 사용자가 노이즈를 성과로 읽는다.
        #expect(note?.contains("86") == true)
        #expect(BatteryCalibration.capacityNote(
            beginMilliampHours: nil, endMilliampHours: 6243,
            locale: Locale(identifier: "ko")) == nil)
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryCalibrationPreflightTests test
```
Expected: 컴파일 실패 — `cannot find type 'CalibrationBlocker' in scope`

- [ ] **Step 3: 구현**

`Wattly/Core/BatteryCalibration.swift`의 `CalibrationDecision` 다음에 추가:

```swift
/// 시작 버튼을 막는 조건. 순서가 곧 화면에 뜨는 순서다.
public enum CalibrationBlocker: String, Equatable, Sendable, CaseIterable {
    case helperUnavailable
    /// 응답은 하지만 `calibration-v1`을 모르는 헬퍼. 그대로 두면 20% 방전 요청이 조용히
    /// 50%에서 멈춰 절차가 영원히 안 끝난다. 카드 안 인라인 업데이트 버튼으로 해소한다.
    case helperTooOld
    case hardwareUnsupported
    case dischargeUnsupported
    case adapterDisconnected
    case heatProtectionActive
    case otherActivityRunning
    /// macOS "최적화된 배터리 충전"을 껐다는 사용자 확인. 설정 키를 읽을 방법이 없어
    /// 확인으로 대신하지만, 켜져 있으면 절차가 6시간 타임아웃까지 갔다가 실패한다.
    case optimizedChargingUnconfirmed
    /// 약 10시간이 걸리고 방전 7시간 동안 뚜껑을 열어둬야 한다는 확인.
    case durationUnconfirmed
}
```

`enum BatteryCalibration` 안, `isStepComplete` 다음에 추가:

```swift
    // MARK: - Preflight

    public static func preflightBlockers(
        helperMode: BatteryControlServiceMode,
        capabilities: [BatteryControlCapability]?,
        isHardwareSupported: Bool?,
        isDischargeHardwareSupported: Bool?,
        isAdapterPresent: Bool,
        isHeatProtected: Bool,
        isTopUpActive: Bool,
        isManualDischargeActive: Bool,
        hasConfirmedOptimizedChargingOff: Bool,
        hasConfirmedDuration: Bool
    ) -> [CalibrationBlocker] {
        var blockers: [CalibrationBlocker] = []
        if helperMode == .unavailable {
            blockers.append(.helperUnavailable)
        } else if capabilities?.contains(.calibrationV1) != true {
            blockers.append(.helperTooOld)
        }
        // `nil`은 "모름"이지 "미지원"이 아니다. 모름으로 사용자를 막지 않는다.
        if isHardwareSupported == false { blockers.append(.hardwareUnsupported) }
        if isDischargeHardwareSupported == false { blockers.append(.dischargeUnsupported) }
        if !isAdapterPresent { blockers.append(.adapterDisconnected) }
        if isHeatProtected { blockers.append(.heatProtectionActive) }
        if isTopUpActive || isManualDischargeActive { blockers.append(.otherActivityRunning) }
        if !hasConfirmedOptimizedChargingOff { blockers.append(.optimizedChargingUnconfirmed) }
        if !hasConfirmedDuration { blockers.append(.durationUnconfirmed) }
        return blockers
    }

    /// 마지막 완료로부터 90일도, 사이클 40회도 지나지 않았는가. 둘 중 하나만 넘겨도
    /// 쿨다운은 끝난 것으로 본다 (Battery University의 "3개월 **또는** 40 부분 사이클").
    public static func isWithinCooldown(
        lastCompletedAt: Date?,
        cycleCountAtLastCompletion: Int?,
        currentCycleCount: Int?,
        now: Date
    ) -> Bool {
        guard let lastCompletedAt else { return false }
        let elapsedDays = now.timeIntervalSince(lastCompletedAt) / 86_400
        if elapsedDays >= Double(cooldownDays) { return false }
        if let before = cycleCountAtLastCompletion, let current = currentCycleCount,
           current - before >= cooldownCycles { return false }
        return true
    }

    // MARK: - 예상 시간

    /// 현재 단계부터 끝까지의 예상 분. 실측 방전 속도가 0.113~0.331 %p/분으로 3배 흔들리므로
    /// 고정 추정치를 쓰지 않고, 관측 속도가 있으면 그것을 받는다.
    public static func estimatedRemainingMinutes(
        step: CalibrationStep,
        soc: Int,
        chargeRatePercentPerMinute: Double? = nil,
        dischargeRatePercentPerMinute: Double? = nil
    ) -> Int {
        // 0에 가까운 속도는 무한대를 만든다. 바닥을 깔아 둔다.
        let chargeRate = max(0.05, chargeRatePercentPerMinute ?? defaultChargeRatePercentPerMinute)
        let dischargeRate = max(0.05, dischargeRatePercentPerMinute ?? defaultDischargeRatePercentPerMinute)
        var minutes = 0.0
        var projectedSoC = Double(soc)
        var cursor: CalibrationStep? = step
        while let current = cursor {
            switch current {
            case .preflight, .restoring:
                break
            case .chargeToFull, .rechargeToFull:
                minutes += max(0, 100 - projectedSoC) / chargeRate
                projectedSoC = 100
            case .dischargeToFloor:
                minutes += max(0, projectedSoC - Double(floorPercentage)) / dischargeRate
                projectedSoC = Double(floorPercentage)
            case .soakLow:
                minutes += soakLowSeconds / 60
            case .soakFinal:
                minutes += soakFinalSeconds / 60
            }
            cursor = current.next
        }
        return Int(minutes.rounded())
    }

    // MARK: - 완료 리포트

    /// 이 절차가 실제로 한 일. 셀 회복도 수명 연장도 아니다.
    public static func completionHeadline(locale: Locale) -> String {
        String(localized: "잔량 표시 보정 완료", locale: locale)
    }

    /// 용량 mAh는 참고값이다.
    ///
    /// 1회 사이클로 최대 용량 추정치가 움직이는지 실기로 확인했고, 관측된 변화(+35 mAh)는
    /// 같은 하루 안의 자연 변동폭(86 mAh)에 묻혔다. 게다가 최종값이 `DesignCapacity`와 정확히
    /// 일치한 순간이 있었던 것으로 보아 BMS가 상단을 클램프하는 듯하며, 건강한 배터리에서는
    /// "개선"이 구조적으로 표시될 수 없다. 그래서 숫자만 보여주면 사용자가 노이즈를 성과로
    /// 읽는다 — 변동폭을 반드시 함께 적는다.
    public static func capacityNote(
        beginMilliampHours: Int?,
        endMilliampHours: Int?,
        locale: Locale
    ) -> String? {
        guard let beginMilliampHours, let endMilliampHours else { return nil }
        return String(
            format: String(localized: "최대 용량 추정치 %lld → %lld mAh (참고값 · 자연 변동폭 %lld mAh)",
                           locale: locale),
            locale: locale,
            Int64(beginMilliampHours), Int64(endMilliampHours),
            Int64(naturalCapacityDriftMilliampHours))
    }
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryCalibrationPreflightTests -only-testing:WattlyTests/BatteryCalibrationReportTests test
```
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Core/BatteryCalibration.swift WattlyTests/BatteryCalibrationTests.swift && git commit -m "feat(battery): add calibration preflight, cooldown, ETA and report copy"
```

---

## Task 10: Sleep assertion (방전 단계 한정)

**Files:**
- Create: `Wattly/Core/SleepAssertion.swift`
- Test: `WattlyTests/SleepAssertionTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces: `SleepAssertion` (`init(create:release:)`, `acquire(reason:)`, `release()`, `isHeld`)

**설계 근거:** 실측 — clamshell sleep 602초 동안 SoC가 **−0.01%p** 움직였다(깨어 있었으면 −2.37%p). 강제 방전은 자면 완전히 멈춘다. 반대로 이 assertion으로 **뚜껑 닫힘은 막을 수 없다**(`caffeinate -i`로도 잠기는 것을 확인). 그래서 sleep은 "막는다"가 아니라 "감지해서 일시정지한다"이고, assertion은 idle sleep만 담당한다.

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/SleepAssertionTests.swift` (신규):

```swift
import Foundation
import Testing
@testable import Wattly

struct SleepAssertionTests {
    final class Spy: @unchecked Sendable {
        var created: [String] = []
        var released: [UInt32] = []
        var nextID: UInt32 = 7
        var shouldFail = false
    }

    private func makeAssertion(_ spy: Spy) -> SleepAssertion {
        SleepAssertion(
            create: { reason in
                spy.created.append(reason)
                return spy.shouldFail ? nil : spy.nextID
            },
            release: { spy.released.append($0) })
    }

    @Test func acquireIsIdempotent() {
        let spy = Spy()
        let assertion = makeAssertion(spy)
        assertion.acquire(reason: "calibration discharge")
        assertion.acquire(reason: "calibration discharge")
        #expect(spy.created.count == 1)
        #expect(assertion.isHeld)
    }

    @Test func releaseHandsTheAssertionBackExactlyOnce() {
        let spy = Spy()
        let assertion = makeAssertion(spy)
        assertion.acquire(reason: "x")
        assertion.release()
        assertion.release()
        #expect(spy.released == [7])
        #expect(assertion.isHeld == false)
    }

    @Test func aFailedCreateLeavesNothingHeld() {
        let spy = Spy()
        spy.shouldFail = true
        let assertion = makeAssertion(spy)
        assertion.acquire(reason: "x")
        #expect(assertion.isHeld == false)
        assertion.release()
        #expect(spy.released.isEmpty)
    }

    @Test func reacquireAfterReleaseCreatesANewAssertion() {
        let spy = Spy()
        let assertion = makeAssertion(spy)
        assertion.acquire(reason: "x")
        assertion.release()
        spy.nextID = 9
        assertion.acquire(reason: "x")
        #expect(spy.created.count == 2)
        assertion.release()
        #expect(spy.released == [7, 9])
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml && xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/SleepAssertionTests test
```
Expected: 컴파일 실패 — `cannot find 'SleepAssertion' in scope`

- [ ] **Step 3: 구현**

`Wattly/Core/SleepAssertion.swift` (신규):

```swift
import Foundation
import IOKit.pwr_mgt

/// idle sleep을 막는 `IOPMAssertion` RAII 래퍼. 캘리브레이션의 **방전 단계에서만** 잡는다.
///
/// 근거는 실측이다: clamshell sleep 602초 동안 SoC가 −0.01%p 움직였다 — 깨어 있었으면
/// −2.37%p였을 구간이다. 강제 방전은 자면 사실상 정지하므로, 7시간짜리 방전 단계는 깨워
/// 둬야 끝난다. 충전·안정화 단계는 자도 진행되므로(15분에 +11%p) 여기서 assertion을 잡지
/// 않는다 — 전 과정 sleep 차단은 참조 구현이 사용자 이탈을 겪은 지점이다.
///
/// **뚜껑 닫힘은 이걸로 못 막는다.** `PreventUserIdleSystemSleep`은 lid close를 막지 않고,
/// 실기에서 `caffeinate -i`가 살아 있는 채로도 뚜껑을 닫자 잠겼다. 그래서 FSM은 sleep을
/// 감지해 `paused(systemSleep)`로 전환하고, 안내 문구도 "화면은 꺼져도 되지만 방전 구간
/// 약 7시간 동안은 뚜껑을 열어 두세요"다.
///
/// 생성·해제를 주입받는 이유는 테스트 때문이다. `IOPMAssertionCreateWithName`은 단위
/// 테스트에서 실제 전원 관리 상태를 건드리므로 더블로 대체할 수 있어야 한다.
final class SleepAssertion: @unchecked Sendable {
    typealias Creator = @Sendable (String) -> UInt32?
    typealias Releaser = @Sendable (UInt32) -> Void

    private let create: Creator
    private let releaseAssertion: Releaser
    private let lock = NSLock()
    private var identifier: UInt32?

    init(
        create: @escaping Creator = SleepAssertion.systemCreate,
        release: @escaping Releaser = SleepAssertion.systemRelease
    ) {
        self.create = create
        self.releaseAssertion = release
    }

    var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return identifier != nil
    }

    func acquire(reason: String) {
        lock.lock(); defer { lock.unlock() }
        guard identifier == nil else { return }
        identifier = create(reason)
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        guard let identifier else { return }
        releaseAssertion(identifier)
        self.identifier = nil
    }

    deinit {
        // 잠금 없이 읽는다: deinit 시점에는 이 인스턴스를 참조하는 다른 스레드가 없다.
        if let identifier { releaseAssertion(identifier) }
    }

    static let systemCreate: Creator = { reason in
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id)
        guard result == kIOReturnSuccess else { return nil }
        return UInt32(id)
    }

    static let systemRelease: Releaser = { id in
        IOPMAssertionRelease(IOPMAssertionID(id))
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/SleepAssertionTests test
```
Expected: PASS (4개 테스트)

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Core/SleepAssertion.swift WattlyTests/SleepAssertionTests.swift Wattly.xcodeproj && git commit -m "feat(battery): add an injectable idle-sleep assertion wrapper"
```

---

## Task 11: 폴링과 무관한 자족적 배터리 판독

**Files:**
- Create: `Wattly/Core/AppleSmartBatteryReader.swift`
- Test: `WattlyTests/AppleSmartBatteryReaderTests.swift`

**Interfaces:**
- Consumes: `Wattly/Core/BatteryPower.swift`의 기존 순수 함수 (`smcDouble`, `netWatts`, `twosComplement`), `Wattly/Core/SMC.swift`의 `SMCConnection`
- Produces:
  - `CalibrationBatteryReading` (netWatts, isCharging, adapterWatts, chargingCurrentMilliamps, maxCapacityMilliampHours, designCapacityMilliampHours, cycleCount, `isAdapterPresent`)
  - `AppleSmartBatteryReader` actor with `func read() -> CalibrationBatteryReading`

**설계 근거:** 코디네이터는 앱의 폴링 파이프라인에 기댈 수 없다. 팝오버가 닫히고 메뉴바 라이브 콘텐츠가 꺼져 있으면 `PollPolicy.providerIntervals`가 `[:]`를 반환해 **모든 프로바이더가 멈춘다** — 야간 무인 실행이 정확히 그 조건이다. 데몬 status에는 전력 필드가 아예 없어 우회로도 없다.

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/AppleSmartBatteryReaderTests.swift` (신규):

```swift
import Foundation
import Testing
@testable import Wattly

struct AppleSmartBatteryReaderTests {
    @Test func adapterPresenceComesFromWattsNotFromExternalConnected() {
        // CHIE 강제 방전 중 실측: ExternalConnected=No, IOPS=Battery Power, Watts=68.
        // 어댑터 판정을 Watts로 하지 않으면 방전이 정상 작동하는 순간에 절차가 스스로
        // 일시정지한다.
        var reading = CalibrationBatteryReading()
        reading.adapterWatts = 68
        #expect(reading.isAdapterPresent)

        reading.adapterWatts = 0
        #expect(reading.isAdapterPresent == false)

        reading.adapterWatts = nil
        #expect(reading.isAdapterPresent == false)
    }

    @Test func chargeStallUsesTheMeasuredCurrentThreshold() {
        var reading = CalibrationBatteryReading()
        reading.adapterWatts = 68
        reading.chargingCurrentMilliamps = 100      // 실측: 최적화된 배터리 충전이 켜졌을 때
        #expect(reading.isChargeStalled)

        reading.chargingCurrentMilliamps = 2500
        #expect(reading.isChargeStalled == false)

        // 전류를 못 읽으면 정체라고 단정하지 않는다 — 판독 실패로 절차를 세우면 안 된다.
        reading.chargingCurrentMilliamps = nil
        #expect(reading.isChargeStalled == false)
    }

    @Test func liveReadEitherAnswersOrDegradesToNils() async {
        // 실제 하드웨어 판독은 CI 환경(배터리 없는 Mac 포함)에서 값이 달라진다. 검증할 수 있는
        // 계약은 "크래시하지 않고, 못 읽은 항목은 nil로 남는다" 하나다.
        let reading = await AppleSmartBatteryReader().read()
        if let cycles = reading.cycleCount { #expect(cycles >= 0) }
        if let capacity = reading.maxCapacityMilliampHours { #expect(capacity > 0) }
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml && xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/AppleSmartBatteryReaderTests test
```
Expected: 컴파일 실패 — `cannot find type 'CalibrationBatteryReading' in scope`

- [ ] **Step 3: 구현**

`Wattly/Core/AppleSmartBatteryReader.swift` (신규):

```swift
import Foundation
import IOKit

/// 캘리브레이션 코디네이터가 한 tick에 필요한 배터리 사실들.
struct CalibrationBatteryReading: Equatable, Sendable {
    /// SMC `B0AP` 기준 순전력(W). 양수 = 방전, 음수 = 충전. ETA 추정에만 쓴다 —
    /// 단계 전이 판정에는 쓰지 않는다(테이퍼가 절벽이라 임계값이 무의미하다).
    var netWatts: Double?
    /// 레지스트리 `IsCharging`. 완충 판정의 절반이다(`FullyCharged`는 완충 후에도 `No`).
    var isCharging: Bool?
    /// `AdapterDetails.Watts`. **어댑터 판정의 진실은 이 값 하나다** — CHIE 강제 방전 중
    /// `ExternalConnected`도 IOPS도 "배터리 전원"이라고 보고한다(실기 3회 재현).
    var adapterWatts: Int?
    /// `ChargingCurrent`. 외부 요인이 충전을 막고 있는지 판정한다.
    var chargingCurrentMilliamps: Int?
    var maxCapacityMilliampHours: Int?
    var designCapacityMilliampHours: Int?
    var cycleCount: Int?

    init(
        netWatts: Double? = nil,
        isCharging: Bool? = nil,
        adapterWatts: Int? = nil,
        chargingCurrentMilliamps: Int? = nil,
        maxCapacityMilliampHours: Int? = nil,
        designCapacityMilliampHours: Int? = nil,
        cycleCount: Int? = nil
    ) {
        self.netWatts = netWatts
        self.isCharging = isCharging
        self.adapterWatts = adapterWatts
        self.chargingCurrentMilliamps = chargingCurrentMilliamps
        self.maxCapacityMilliampHours = maxCapacityMilliampHours
        self.designCapacityMilliampHours = designCapacityMilliampHours
        self.cycleCount = cycleCount
    }

    var isAdapterPresent: Bool { (adapterWatts ?? 0) > 0 }

    /// 어댑터는 붙어 있는데 충전 전류가 바닥이다. 판독 실패(`nil`)는 정체가 아니다.
    var isChargeStalled: Bool {
        guard isAdapterPresent, let current = chargingCurrentMilliamps else { return false }
        return current < BatteryCalibration.chargeStallMilliamps
    }
}

/// 폴링 정책과 무관하게 배터리를 직접 읽는다.
///
/// `BatteryProvider`를 리팩터링해 공유하지 않는 이유: 순수 디코딩 함수(`BatteryPower.swift`)는
/// 이미 공유되고 있고 중복되는 것은 IOKit 배선뿐이다. 프로바이더를 건드리면 기존 배터리
/// 테스트 전체가 회귀 위험에 노출된다. SMC 연결은 읽기 전용이라 두 개가 공존해도 안전하다.
actor AppleSmartBatteryReader {
    private var smcAttempted = false
    private var smc: SMCConnection?

    func read() -> CalibrationBatteryReading {
        var reading = CalibrationBatteryReading()

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            reading.isCharging = bool(service, "IsCharging")
            reading.adapterWatts = (dict(service, "AdapterDetails")?["Watts"] as? NSNumber)?.intValue
            reading.chargingCurrentMilliamps = number(service, "ChargingCurrent")?.intValue
            reading.maxCapacityMilliampHours = number(service, "AppleRawMaxCapacity")?.intValue
            reading.designCapacityMilliampHours = number(service, "DesignCapacity")?.intValue
            reading.cycleCount = number(service, "CycleCount")?.intValue
        }

        if !smcAttempted { smcAttempted = true; smc = SMCConnection() }
        if let smc, let power = smc.read("B0AP") {
            let milliwatts = Int(smcDouble(power.bytes, type: power.type).rounded())
            reading.netWatts = netWatts(batteryMilliwatts: milliwatts)
        }
        return reading
    }

    private func number(_ service: io_service_t, _ key: String) -> NSNumber? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber
    }
    private func bool(_ service: io_service_t, _ key: String) -> Bool? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }
    private func dict(_ service: io_service_t, _ key: String) -> [String: Any]? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/AppleSmartBatteryReaderTests test
```
Expected: PASS (3개 테스트)

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Core/AppleSmartBatteryReader.swift WattlyTests/AppleSmartBatteryReaderTests.swift Wattly.xcodeproj && git commit -m "feat(battery): add a poll-independent battery reader for calibration"
```

---

## Task 12: 클라이언트 캘리브레이션 쓰기 경로와 단일 길목 보존

**Files:**
- Modify: `Wattly/Control/BatteryControlClient.swift`
- Test: `WattlyTests/BatteryControlClientTests.swift`

**Interfaces:**
- Consumes: Task 1(설정 필드), Task 6(`CalibrationPrimitive`, `CalibrationSnapshot`), Task 7(`BatteryCalibration.floorPercentage`)
- Produces:
  - `BatteryControlClient.apply(..., calibrationActive:calibrationTargetPercentage:isCalibrationWrite:)`
  - `BatteryControlClient.applyCalibration(primitive:snapshot:) async -> BatteryControlServiceStatus?`

**설계 근거 (#28):** 활동을 보존하지 않는 `apply()` 호출부가 **12곳**이다(스케줄 2 · Shortcuts 3 · 설정 8). 그중 하나라도 절차 중에 발화하면 `calibrationActive`가 기본값 `false`로 실려 나가 10시간짜리 절차가 조용히 취소된다. 12곳을 각각 막는 대신, **클라이언트라는 단 하나의 길목**에서 데몬의 캘리브레이션을 되살린다.

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/BatteryControlClientTests.swift` 닫는 `}` 앞:

```swift
    @MainActor @Test func anOrdinaryApplyCannotCancelARunningCalibration() async throws {
        let daemon = BatteryControlConfiguration(
            enabled: true, limitPercentage: 80, topUpActive: true,
            calibrationActive: true, calibrationTargetPercentage: 20)
        let running = BatteryControlServiceStatus(
            mode: .inhibited, currentPercentage: 100, isPowerAdapterConnected: true,
            detail: "", updatedAt: 1, desiredConfiguration: daemon)
        let recorder = ScriptRecorder()
        let client = BatteryControlClient { request in
            if case .configure(let data) = request,
               let decoded = try? BatteryControlCodec.decode(
                   BatteryControlConfigurationRequest.self, from: data) {
                await recorder.record(
                    "\(decoded.configuration.calibrationActive)-\(decoded.configuration.topUpActive)")
            }
            return (try? BatteryControlCodec.encode(running), nil)
        }
        await client.refreshStatus()

        // 설정창이 한도만 바꾸려고 부른 평범한 write.
        _ = await client.apply(enabled: true, limitPercentage: 85)
        #expect(await recorder.value == "true-true")
    }

    @MainActor @Test func theCoordinatorsOwnWriteCanTurnCalibrationOff() async throws {
        let daemon = BatteryControlConfiguration(
            enabled: true, limitPercentage: 80, calibrationActive: true)
        let running = BatteryControlServiceStatus(
            mode: .inhibited, currentPercentage: 20, isPowerAdapterConnected: true,
            detail: "", updatedAt: 1, desiredConfiguration: daemon)
        let recorder = ScriptRecorder()
        let client = BatteryControlClient { request in
            if case .configure(let data) = request,
               let decoded = try? BatteryControlCodec.decode(
                   BatteryControlConfigurationRequest.self, from: data) {
                await recorder.record("\(decoded.configuration.calibrationActive)")
            }
            return (try? BatteryControlCodec.encode(running), nil)
        }
        await client.refreshStatus()

        _ = await client.applyCalibration(
            primitive: .restore,
            snapshot: CalibrationSnapshot(
                limitEnabled: true, limitPercentage: 80,
                sailingEnabled: false, sailingDelta: 5,
                heatProtectionEnabled: true, heatProtectionThresholdCelsius: 35,
                autoDischargeEnabled: true, manualDischargeTarget: 80))
        #expect(await recorder.value == "false")
    }

    @MainActor @Test func calibrationPrimitivesMapToDaemonCommands() async throws {
        let recorder = ScriptRecorder()
        let idle = BatteryControlServiceStatus(
            mode: .charging, currentPercentage: 50, isPowerAdapterConnected: true,
            detail: "", updatedAt: 1)
        let client = BatteryControlClient { request in
            if case .configure(let data) = request,
               let decoded = try? BatteryControlCodec.decode(
                   BatteryControlConfigurationRequest.self, from: data) {
                let c = decoded.configuration
                await recorder.record(
                    "cal=\(c.calibrationActive) top=\(c.topUpActive) auto=\(c.autoDischargeEnabled) target=\(c.calibrationTargetPercentage)")
            }
            return (try? BatteryControlCodec.encode(idle), nil)
        }
        let snapshot = CalibrationSnapshot(
            limitEnabled: true, limitPercentage: 80,
            sailingEnabled: false, sailingDelta: 5,
            heatProtectionEnabled: true, heatProtectionThresholdCelsius: 35,
            autoDischargeEnabled: true, manualDischargeTarget: 80)

        _ = await client.applyCalibration(primitive: .chargeToFull, snapshot: snapshot)
        #expect(await recorder.value == "cal=true top=true auto=false target=20")

        _ = await client.applyCalibration(primitive: .dischargeToFloor, snapshot: snapshot)
        #expect(await recorder.value == "cal=true top=false auto=false target=20")

        _ = await client.applyCalibration(primitive: .holdAtFull, snapshot: snapshot)
        #expect(await recorder.value == "cal=true top=true auto=false target=20")

        // 원복은 스냅샷의 자동 방전 원값을 되살린다.
        _ = await client.applyCalibration(primitive: .restore, snapshot: snapshot)
        #expect(await recorder.value == "cal=false top=false auto=true target=20")
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryControlClientTests test
```
Expected: 컴파일 실패 — `value of type 'BatteryControlClient' has no member 'applyCalibration'`

- [ ] **Step 3: 구현**

`Wattly/Control/BatteryControlClient.swift`의 `apply(...)`를 교체:

```swift
    /// 데몬에 설정을 내려보내는 유일한 길목.
    ///
    /// `isCalibrationWrite`가 아닌 모든 호출은 데몬이 들고 있는 캘리브레이션을 **되살려서**
    /// 나간다. 활동을 보존하지 않는 호출부가 12곳(스케줄 2·Shortcuts 3·설정 8)이고, 그중
    /// 하나라도 절차 중에 발화하면 기본값 `false`가 실려 나가 10시간짜리 절차를 조용히
    /// 취소하기 때문이다. 12곳을 각각 고치는 대신 여기 한 곳에서 닫는다.
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
        commandGeneration &+= 1
        var config = BatteryControlConfiguration(
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
            calibrationTargetPercentage: calibrationTargetPercentage
        )
        if !isCalibrationWrite,
           let daemon = status.desiredConfiguration, daemon.calibrationActive {
            config.calibrationActive = true
            config.calibrationTargetPercentage = daemon.calibrationTargetPercentage
            // 어느 단계인지도 데몬이 안다. 충전 단계를 방전 단계로 바꿔 버리면 안 된다.
            config.topUpActive = daemon.topUpActive
            config.enabled = true
            config.manualDischargeActive = false
        }
        let request = BatteryControlConfigurationRequest(configuration: config, generation: commandGeneration)
        guard let data = try? BatteryControlCodec.encode(request) else {
            updateUnavailable("충전 제한 설정을 인코딩할 수 없음")
            return nil
        }
        return await send(.configure(data))
    }

    /// 캘리브레이션 코디네이터 전용 쓰기. 절차 중 자동 방전을 강제로 끄는 것이 여기다 —
    /// 두 정책이 같은 CHIE를 다투면 방전이 즉시 되돌려진다. 원값은 스냅샷이 들고 있다가
    /// 원복 때 되살린다.
    @discardableResult
    public func applyCalibration(
        primitive: CalibrationPrimitive,
        snapshot: CalibrationSnapshot
    ) async -> BatteryControlServiceStatus? {
        let isRunning = primitive != .restore && primitive != .idle
        let isChargingStep = primitive == .chargeToFull || primitive == .holdAtFull
        return await apply(
            enabled: isRunning ? true : snapshot.limitEnabled,
            limitPercentage: snapshot.limitPercentage,
            lowerHysteresisDelta: snapshot.sailingEnabled ? snapshot.sailingDelta : 2,
            heatProtectionEnabled: snapshot.heatProtectionEnabled,
            heatProtectionThresholdCelsius: snapshot.heatProtectionThresholdCelsius,
            topUpActive: isRunning && isChargingStep,
            autoDischargeEnabled: isRunning ? false : snapshot.autoDischargeEnabled,
            manualDischargeActive: false,
            manualDischargeTarget: snapshot.manualDischargeTarget,
            calibrationActive: isRunning,
            calibrationTargetPercentage: BatteryCalibration.floorPercentage,
            isCalibrationWrite: true)
    }
```

`reconcile(...)`에서도 데몬의 캘리브레이션을 이어간다. `let isTopUp = ...` 아래에 추가하고 `targetConfig`에 반영:

```swift
        let isCalibrating = status.desiredConfiguration?.calibrationActive == true
        let calibrationTarget = status.desiredConfiguration?.calibrationTargetPercentage
            ?? BatteryCalibration.floorPercentage
        // 절차 중에는 자동 방전을 세워 둔다. 엔진 우선순위상 이미 무력하지만, 저장된 선호값이
        // 매 분 되살아나면 로그와 status가 "자동 방전 켜짐"으로 보여 진단을 흐린다.
        let effectiveAutoDischarge = isCalibrating ? false : autoDischargeEnabled
```
`targetConfig`와 아래 `apply` 호출의 `autoDischargeEnabled:` 인자를 모두 `effectiveAutoDischarge`로 바꾼다.
```swift
        let effectiveEnabled = enabled || isTopUp || isManualDischarge || isCalibrating
```
`BatteryControlConfiguration(...)` 생성부 마지막에:
```swift
            manualDischargeTarget: dischargeTarget,
            calibrationActive: isCalibrating,
            calibrationTargetPercentage: calibrationTarget
        )
```
그리고 재적용 분기 조건과 `apply` 호출에도 반영:
```swift
        if enabled || heatProtectionEnabled || isTopUp || isManualDischarge || isCalibrating {
            await apply(
                ...
                manualDischargeTarget: dischargeTarget,
                calibrationActive: isCalibrating,
                calibrationTargetPercentage: calibrationTarget,
                isCalibrationWrite: true)
```
(여기서 `isCalibrationWrite: true`인 이유는 위에서 이미 데몬 값을 명시적으로 실었기 때문이다 — 이중 보존은 무의미하다.)

- [ ] **Step 4: 테스트 통과 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryControlClientTests test
```
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Control/BatteryControlClient.swift WattlyTests/BatteryControlClientTests.swift && git commit -m "feat(battery): route calibration writes through one client chokepoint"
```

---

## Task 13: 캘리브레이션 코디네이터

**Files:**
- Create: `Wattly/Core/BatteryCalibrationCoordinator.swift`
- Modify: `Wattly/Core/BatteryCalibration.swift` (관측 속도 혼합 함수)
- Modify: `Wattly/Settings/Settings.swift` (저장 키 2개 — Task 15가 `SettingsReset`을 잇는다)
- Modify: `Wattly/App/WattlyApp.swift` (생성·주입)
- Test: `WattlyTests/BatteryCalibrationCoordinatorTests.swift`

**Interfaces:**
- Consumes: Task 6~12 전부
- Produces:
  - `StorageKey.batteryCalibrationState` / `StorageKey.batteryCalibrationHistory` (+ `Defaults` 동명 상수, 둘 다 `""`)
  - `BatteryCalibration.blendedRate(previous:sample:) -> Double`
  - `BatteryCalibrationCoordinator`
    - `init(batteryControl:defaults:readBattery:sleepAssertion:clock:startsTimer:)`
    - `var run: CalibrationRunState?` / `var history: [CalibrationHistoryEntry]` / `var isRunning: Bool`
    - `var lastCompleted: CalibrationHistoryEntry?` / `var estimatedRemainingMinutes: Int?`
    - `func start() async` / `func cancel() async` / `func evaluate(at:) async` / `func handleAppLaunch() async`
    - `func currentSnapshot() -> CalibrationSnapshot`

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/BatteryCalibrationCoordinatorTests.swift` (신규):

```swift
import Foundation
import Testing
@testable import Wattly

@MainActor
struct BatteryCalibrationCoordinatorTests {
    private final class Fake: @unchecked Sendable {
        var status: BatteryControlServiceStatus
        var reading: CalibrationBatteryReading
        var writes: [BatteryControlConfiguration] = []

        init() {
            status = BatteryControlServiceStatus(
                mode: .charging, currentPercentage: 50, isPowerAdapterConnected: true,
                detail: "", updatedAt: 0,
                isHardwareSupported: true, isDischargeHardwareSupported: true,
                capabilities: [.calibrationV1])
            reading = CalibrationBatteryReading(
                isCharging: true, adapterWatts: 68, chargingCurrentMilliamps: 2500,
                maxCapacityMilliampHours: 6208, designCapacityMilliampHours: 6249,
                cycleCount: 112)
        }
    }

    private func makeSubject(
        _ fake: Fake,
        defaults: UserDefaults,
        clock: @escaping @Sendable () -> Date
    ) -> BatteryCalibrationCoordinator {
        let client = BatteryControlClient { request in
            if case .configure(let data) = request,
               let decoded = try? BatteryControlCodec.decode(
                   BatteryControlConfigurationRequest.self, from: data) {
                fake.writes.append(decoded.configuration)
                fake.status.desiredConfiguration = decoded.configuration
            }
            return (try? BatteryControlCodec.encode(fake.status), nil)
        }
        return BatteryCalibrationCoordinator(
            batteryControl: client,
            defaults: defaults,
            readBattery: { fake.reading },
            sleepAssertion: SleepAssertion(create: { _ in 1 }, release: { _ in }),
            notifyPause: { _ in },
            notifyFinished: { _ in },
            clock: clock,
            startsTimer: false)
    }

    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func startEntersTheFirstChargeStepAndRecordsTheBaseline() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.start")
        let subject = makeSubject(fake, defaults: defaults, clock: { Date(timeIntervalSince1970: 0) })

        await subject.start()

        #expect(subject.isRunning)
        #expect(subject.run?.step == .chargeToFull)
        #expect(subject.run?.beginMaxCapacityMilliampHours == 6208)
        #expect(subject.run?.beginCycleCount == 112)
        #expect(fake.writes.last?.calibrationActive == true)
        #expect(fake.writes.last?.topUpActive == true)
        // 절차 중에는 자동 방전을 세워 둔다 — 같은 CHIE를 다투면 방전이 되돌려진다.
        #expect(fake.writes.last?.autoDischargeEnabled == false)
    }

    @Test func aRepeatedTickDoesNotRewriteTheSamePrimitive() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.norewrite")
        var now = Date(timeIntervalSince1970: 0)
        let subject = makeSubject(fake, defaults: defaults, clock: { now })
        await subject.start()
        let afterStart = fake.writes.count

        now = now.addingTimeInterval(10)
        await subject.evaluate(at: now)
        now = now.addingTimeInterval(10)
        await subject.evaluate(at: now)

        // 전이가 아닌 반복 write는 SMC 트래픽 규칙이 금지한다.
        #expect(fake.writes.count == afterStart)
    }

    @Test func fullSettledForAMinuteAdvancesIntoDischarge() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.full")
        var now = Date(timeIntervalSince1970: 0)
        let subject = makeSubject(fake, defaults: defaults, clock: { now })
        await subject.start()

        fake.status.currentPercentage = 100
        fake.reading.isCharging = false
        for _ in 0..<7 {
            now = now.addingTimeInterval(10)
            await subject.evaluate(at: now)
        }

        #expect(subject.run?.step == .dischargeToFloor)
        #expect(fake.writes.last?.topUpActive == false)
        #expect(fake.writes.last?.calibrationActive == true)
    }

    @Test func adapterLossDuringChargePausesWithoutWriting() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.adapter")
        var now = Date(timeIntervalSince1970: 0)
        let subject = makeSubject(fake, defaults: defaults, clock: { now })
        await subject.start()
        let afterStart = fake.writes.count

        fake.reading.adapterWatts = 0
        fake.status.isPowerAdapterConnected = false
        now = now.addingTimeInterval(10)
        await subject.evaluate(at: now)

        #expect(subject.run?.pause == .needsAdapter)
        #expect(fake.writes.count == afterStart)
        #expect(subject.isRunning)
    }

    @Test func aLongGapBetweenTicksIsTreatedAsSleepNotAsAStall() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.sleep")
        var now = Date(timeIntervalSince1970: 0)
        let subject = makeSubject(fake, defaults: defaults, clock: { now })
        await subject.start()
        // 방전 단계로 강제 진입
        fake.status.currentPercentage = 100
        fake.reading.isCharging = false
        for _ in 0..<7 { now = now.addingTimeInterval(10); await subject.evaluate(at: now) }
        #expect(subject.run?.step == .dischargeToFloor)

        // 뚜껑을 20분 덮었다: SoC 무변화 + tick 공백. 정체로 오인하면 60%에서 절차가 끝난다.
        fake.status.currentPercentage = 60
        now = now.addingTimeInterval(1200)
        await subject.evaluate(at: now)

        #expect(subject.run?.pause == .systemSleep)
        #expect(subject.run?.timers.socUnchangedSeconds == 0)
        #expect(subject.run?.step == .dischargeToFloor)
    }

    @Test func cancelRestoresTheSnapshotAndRecordsHistory() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.cancel")
        defaults.set(true, forKey: StorageKey.batteryLimitEnabled)
        defaults.set(85, forKey: StorageKey.batteryLimitPercentage)
        defaults.set(true, forKey: StorageKey.batteryAutoDischargeEnabled)
        let subject = makeSubject(fake, defaults: defaults, clock: { Date(timeIntervalSince1970: 0) })
        await subject.start()

        await subject.cancel()

        #expect(subject.isRunning == false)
        #expect(fake.writes.last?.calibrationActive == false)
        #expect(fake.writes.last?.limitPercentage == 85)
        #expect(fake.writes.last?.autoDischargeEnabled == true)   // 원값 복원
        #expect(subject.history.first?.outcome == .cancelled)
    }

    @Test func stateAndHistorySurviveARelaunch() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.persist")
        let first = makeSubject(fake, defaults: defaults, clock: { Date(timeIntervalSince1970: 0) })
        await first.start()
        let runID = first.run?.id

        let second = makeSubject(fake, defaults: defaults, clock: { Date(timeIntervalSince1970: 30) })
        await second.handleAppLaunch()
        #expect(second.run?.id == runID)
        #expect(second.isRunning)
    }

    @Test func anOrphanedDaemonCalibrationIsReleasedOnLaunch() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.orphan")
        // 저장된 실행 상태는 없는데 데몬만 캘리브레이션을 들고 있다 — 무기한 충전 억제가
        // 남는 유일한 경로다.
        fake.status.desiredConfiguration = BatteryControlConfiguration(
            enabled: true, calibrationActive: true, calibrationTargetPercentage: 20)
        let subject = makeSubject(fake, defaults: defaults, clock: { Date(timeIntervalSince1970: 0) })

        await subject.handleAppLaunch()

        #expect(subject.isRunning == false)
        #expect(fake.writes.last?.calibrationActive == false)
    }

    @Test func historyKeepsAtMostFiveEntries() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.history")
        let subject = makeSubject(fake, defaults: defaults, clock: { Date(timeIntervalSince1970: 0) })
        for _ in 0..<7 {
            await subject.start()
            await subject.cancel()
        }
        #expect(subject.history.count == BatteryCalibrationCoordinator.maxHistoryCount)
    }
}

struct BatteryCalibrationRateTests {
    @Test func blendedRateFavoursHistoryButFollowsReality() {
        #expect(BatteryCalibration.blendedRate(previous: nil, sample: 0.3) == 0.3)
        let blended = BatteryCalibration.blendedRate(previous: 0.2, sample: 0.4)
        #expect(blended > 0.2 && blended < 0.4)
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml && xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryCalibrationCoordinatorTests test
```
Expected: 컴파일 실패 — `cannot find 'BatteryCalibrationCoordinator' in scope`

- [ ] **Step 3-a: 저장 키 추가**

`Wattly/Settings/Settings.swift`의 `Defaults`에서 `batteryScheduleNotificationsEnabled` 아래:

```swift
    static let batteryCalibrationState = ""
    static let batteryCalibrationHistory = ""
```

`StorageKey`의 같은 위치:

```swift
    static let batteryCalibrationState = "batteryCalibrationState"
    static let batteryCalibrationHistory = "batteryCalibrationHistory"
```

- [ ] **Step 3-b: 관측 속도 혼합 함수**

`Wattly/Core/BatteryCalibration.swift`의 `estimatedRemainingMinutes` 아래에 추가:

```swift
    /// 관측된 속도를 이전 추정치에 섞는다. 실측 방전 속도가 0.113~0.331 %p/분으로 흔들려
    /// 한 샘플을 그대로 쓰면 ETA가 튀고, 고정값을 쓰면 3배까지 틀린다.
    public static func blendedRate(previous: Double?, sample: Double) -> Double {
        guard let previous else { return sample }
        return previous * 0.7 + sample * 0.3
    }
```

- [ ] **Step 3-c: 코디네이터 작성**

`Wattly/Core/BatteryCalibrationCoordinator.swift` (신규):

```swift
import Foundation
import Observation

/// 캘리브레이션 절차를 소유하는 얇은 코디네이터.
///
/// 판단은 전부 `BatteryCalibration`(순수)에 있고 여기는 세 가지만 한다: 10초마다 사실을
/// 모으고, 결정을 XPC 호출로 번역하고, 상태를 디스크에 남긴다.
///
/// 데몬이 아니라 앱이 절차를 소유하는 이유: 데몬으로 옮기면 앱 없이도 완주하지만 root 코드에
/// 단계·타이머·정책 파일 schema v2가 들어간다. 앱 소유라면 root 변경이 필드 2개와 분기
/// 하나로 끝나고, 앱이 죽었을 때의 최악은 엔진 하한 가드가 만드는 "하한 도달 후 홀드"라는
/// 설계된 안전 상태다. 그 상태도 12시간 뒤에는 `handleAppLaunch`의 고아 처리나 데몬의 Top Up
/// 만료가 정리한다.
@MainActor
@Observable public final class BatteryCalibrationCoordinator {
    /// 10초. 5초짜리 데몬 샘플보다 성기게 두는 이유는, 이 루프가 10시간 동안 돌면서
    /// XPC 왕복과 IOKit 판독을 매 tick 수행하기 때문이다.
    public static let tickInterval: TimeInterval = 10
    public static let maxHistoryCount = 5

    public private(set) var run: CalibrationRunState?
    public private(set) var history: [CalibrationHistoryEntry] = []
    public private(set) var lastReading = CalibrationBatteryReading()

    private let batteryControl: BatteryControlClient
    private let defaults: UserDefaults
    private let readBattery: @Sendable () async -> CalibrationBatteryReading
    private let sleepAssertion: SleepAssertion
    /// 알림 호출을 주입받는 이유는 테스트다. `UNUserNotificationCenter`를 건드리면 단위
    /// 테스트가 실제 알림 권한 상태에 의존하게 된다.
    private let notifyPause: @MainActor (CalibrationPause) -> Void
    private let notifyFinished: @MainActor (CalibrationHistoryEntry) -> Void
    private let clock: @Sendable () -> Date
    private var observedDischargeRate: Double?
    nonisolated(unsafe) private var timerTask: Task<Void, Never>?

    public init(
        batteryControl: BatteryControlClient,
        defaults: UserDefaults = .standard,
        readBattery: (@Sendable () async -> CalibrationBatteryReading)? = nil,
        sleepAssertion: SleepAssertion = SleepAssertion(),
        notifyPause: @escaping @MainActor (CalibrationPause) -> Void
            = { BatteryNotificationManager.postCalibrationActionNeeded($0) },
        notifyFinished: @escaping @MainActor (CalibrationHistoryEntry) -> Void
            = { BatteryNotificationManager.postCalibrationFinished($0) },
        clock: @escaping @Sendable () -> Date = { Date() },
        startsTimer: Bool = true
    ) {
        self.batteryControl = batteryControl
        self.defaults = defaults
        let reader = AppleSmartBatteryReader()
        self.readBattery = readBattery ?? { await reader.read() }
        self.sleepAssertion = sleepAssertion
        self.notifyPause = notifyPause
        self.notifyFinished = notifyFinished
        self.clock = clock
        loadState()
        if startsTimer { startTimer() }
    }

    deinit { timerTask?.cancel() }

    public var isRunning: Bool { run != nil }

    /// 이력에서 유도한다 — 별도 키를 두면 두 값이 어긋날 수 있다.
    public var lastCompleted: CalibrationHistoryEntry? {
        history.first { $0.outcome == .completed }
    }

    public var estimatedRemainingMinutes: Int? {
        guard let run else { return nil }
        return BatteryCalibration.estimatedRemainingMinutes(
            step: run.step,
            soc: batteryControl.status.currentPercentage,
            chargeRatePercentPerMinute: nil,
            dischargeRatePercentPerMinute: observedDischargeRate)
    }

    public var isWithinCooldown: Bool {
        BatteryCalibration.isWithinCooldown(
            lastCompletedAt: lastCompleted?.finishedAt,
            cycleCountAtLastCompletion: lastCompleted?.endCycleCount,
            currentCycleCount: lastReading.cycleCount,
            now: clock())
    }

    // MARK: - 수명주기

    public func start() async {
        guard run == nil else { return }
        await batteryControl.refreshStatus()
        let reading = await readBattery()
        lastReading = reading
        let now = clock()
        run = CalibrationRunState(
            id: UUID(),
            startedAt: now,
            step: .preflight,
            timers: CalibrationTimers(),
            pause: nil,
            snapshot: currentSnapshot(),
            beginMaxCapacityMilliampHours: reading.maxCapacityMilliampHours,
            beginCycleCount: reading.cycleCount,
            lastProgressAt: now,
            lastTickAt: now,
            appliedPrimitive: nil)
        observedDischargeRate = nil
        saveState()
        // 첫 tick이 preflight → chargeToFull 전이를 수행한다.
        await evaluate(at: now)
    }

    public func cancel() async {
        guard run != nil else { return }
        await finish(outcome: .cancelled, failure: nil, at: clock())
    }

    /// 앱 시작 시 한 번. 저장 상태와 데몬 상태를 대조한다.
    public func handleAppLaunch() async {
        loadState()
        await batteryControl.refreshStatus()
        if run == nil {
            if batteryControl.status.desiredConfiguration?.calibrationActive == true {
                // 고아 상태. 저장된 절차 없이 데몬만 캘리브레이션을 들고 있으면 충전 억제가
                // 무기한 남는다 — 무조건 끊는다.
                await batteryControl.applyCalibration(
                    primitive: .restore, snapshot: currentSnapshot())
            }
            return
        }
        await evaluate(at: clock())
    }

    // MARK: - Tick

    public func evaluate(at now: Date) async {
        guard var state = run else { return }
        await batteryControl.refreshStatus()
        let status = batteryControl.status
        let reading = await readBattery()
        lastReading = reading

        let elapsed = now.timeIntervalSince(state.lastTickAt)
        let isSleepGap = elapsed > BatteryCalibration.sleepGapSeconds
        let soc = status.currentPercentage
        let previousSoC = state.timers.lastSoC
        let isFullSettled = soc >= 100 && reading.isCharging == false
        // 어댑터 판정에 `AdapterDetails.Watts`가 반드시 들어간다. CHIE 강제 방전 중에는
        // `isPowerAdapterConnected`가 거짓말한다.
        let adapterPresent = reading.isAdapterPresent || status.isPowerAdapterConnected

        if let previousSoC, previousSoC != soc {
            if state.step == .dischargeToFloor, previousSoC > soc,
               state.timers.socUnchangedSeconds + elapsed > 0, !isSleepGap {
                let minutes = (state.timers.socUnchangedSeconds + elapsed) / 60
                if minutes > 0 {
                    observedDischargeRate = BatteryCalibration.blendedRate(
                        previous: observedDischargeRate,
                        sample: Double(previousSoC - soc) / minutes)
                }
            }
            state.lastProgressAt = now
        }

        state.timers = BatteryCalibration.tick(
            state.timers,
            elapsed: elapsed,
            isSleepGap: isSleepGap,
            isPaused: state.pause?.consumesBudget == true,
            soc: soc,
            isFullSettled: isFullSettled,
            isChargeStalled: reading.isChargeStalled)
        state.lastTickAt = now

        let decision = BatteryCalibration.decide(CalibrationInput(
            step: state.step,
            timers: state.timers,
            soc: soc,
            isAdapterPresent: adapterPresent,
            isHeatProtected: status.activity == .heatProtection,
            helperReady: status.mode != .unavailable,
            dischargeSupported: status.isDischargeHardwareSupported != false,
            isSleepGap: isSleepGap,
            isChargeStalled: reading.isChargeStalled,
            secondsSinceProgress: now.timeIntervalSince(state.lastProgressAt)))

        switch decision {
        case .hold(let primitive):
            state.pause = nil
            run = state
            updateSleepAssertion(for: state.step)
            await applyIfChanged(primitive)

        case .advance(let next, let primitive):
            state.step = next
            state.timers = state.timers.resetForNewStep()
            state.pause = nil
            state.lastProgressAt = now
            run = state
            updateSleepAssertion(for: next)
            await applyIfChanged(primitive)

        case .pause(let reason):
            // 일시정지에서는 아무것도 쓰지 않는다. 데몬은 마지막 원시 명령을 그대로 들고
            // 있어야 하고, 재개는 다음 tick의 `.hold`가 처리한다.
            let isNewReason = state.pause != reason
            state.pause = reason
            run = state
            sleepAssertion.release()
            saveState()
            // 같은 사유로 매 tick 알리지 않는다. 10시간짜리 절차에서 그건 알림 폭탄이다.
            if isNewReason { notifyPause(reason) }

        case .finish(let outcome, let failure):
            run = state
            await finish(outcome: outcome, failure: failure, at: now)
        }
    }

    // MARK: - 내부

    /// 같은 원시 명령을 다시 쓰지 않는다. 전이가 아닌 반복 write는 SMC 트래픽 규칙이 금지하고,
    /// 헬퍼가 재시작해 상태를 잃는 경우는 `BatteryControlBridge`의 reconcile 루프가 고친다.
    private func applyIfChanged(_ primitive: CalibrationPrimitive) async {
        guard var state = run else { return }
        guard state.appliedPrimitive != primitive else { saveState(); return }
        await batteryControl.applyCalibration(primitive: primitive, snapshot: state.snapshot)
        state.appliedPrimitive = primitive
        run = state
        saveState()
    }

    private func finish(outcome: CalibrationOutcome, failure: CalibrationFailure?, at now: Date) async {
        guard let state = run else { return }
        sleepAssertion.release()
        await batteryControl.applyCalibration(primitive: .restore, snapshot: state.snapshot)
        let reading = await readBattery()
        lastReading = reading
        let entry = CalibrationHistoryEntry(
            id: state.id,
            startedAt: state.startedAt,
            finishedAt: now,
            outcome: outcome,
            failure: failure,
            beginMaxCapacityMilliampHours: state.beginMaxCapacityMilliampHours,
            endMaxCapacityMilliampHours: reading.maxCapacityMilliampHours,
            beginCycleCount: state.beginCycleCount,
            endCycleCount: reading.cycleCount)
        history.insert(entry, at: 0)
        history = Array(history.prefix(Self.maxHistoryCount))
        run = nil
        observedDischargeRate = nil
        saveState()
        notifyFinished(entry)
    }

    private func updateSleepAssertion(for step: CalibrationStep) {
        if step == .dischargeToFloor {
            sleepAssertion.acquire(reason: "Wattly battery calibration discharge")
        } else {
            sleepAssertion.release()
        }
    }

    private func startTimer() {
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(BatteryCalibrationCoordinator.tickInterval))
                guard !Task.isCancelled, let self else { return }
                await self.evaluate(at: self.clockNow())
            }
        }
    }

    private func clockNow() -> Date { clock() }

    // MARK: - 지속 저장

    /// 시작 시점의 사용자 설정. `defaults.integer(forKey:)`가 없는 키에 `0`을 돌려주므로
    /// 존재 여부를 먼저 확인한다 — `BatteryScheduleCoordinator`와 같은 이유다.
    public func currentSnapshot() -> CalibrationSnapshot {
        func int(_ key: String, _ fallback: Int) -> Int {
            defaults.object(forKey: key) != nil ? defaults.integer(forKey: key) : fallback
        }
        return CalibrationSnapshot(
            limitEnabled: defaults.bool(forKey: StorageKey.batteryLimitEnabled),
            limitPercentage: int(StorageKey.batteryLimitPercentage, Defaults.batteryLimitPercentage),
            sailingEnabled: defaults.bool(forKey: StorageKey.batterySailingEnabled),
            sailingDelta: int(StorageKey.batterySailingDelta, Defaults.batterySailingDelta),
            heatProtectionEnabled: defaults.bool(forKey: StorageKey.batteryHeatProtectionEnabled),
            heatProtectionThresholdCelsius: int(
                StorageKey.batteryHeatProtectionThreshold, Defaults.batteryHeatProtectionThreshold),
            autoDischargeEnabled: defaults.bool(forKey: StorageKey.batteryAutoDischargeEnabled),
            manualDischargeTarget: int(
                StorageKey.batteryManualDischargeTarget, Defaults.batteryManualDischargeTarget))
    }

    public func loadState() {
        run = decode(CalibrationRunState.self, forKey: StorageKey.batteryCalibrationState)
        history = decode([CalibrationHistoryEntry].self,
                         forKey: StorageKey.batteryCalibrationHistory) ?? []
    }

    private func saveState() {
        encode(run, forKey: StorageKey.batteryCalibrationState)
        encode(history, forKey: StorageKey.batteryCalibrationHistory)
    }

    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let raw = defaults.string(forKey: key), let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T?, forKey key: String) {
        guard let value,
              let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            defaults.set("", forKey: key)
            return
        }
        defaults.set(string, forKey: key)
    }
}
```

> **선행 조건:** 위 `init`의 기본 인자가 `BatteryNotificationManager.postCalibrationActionNeeded` / `postCalibrationFinished`를 참조한다. 두 함수는 Task 17 Step 3에서 추가되므로, **Task 17의 Step 3을 이 태스크보다 먼저 적용**하거나(권장) 기본 인자를 일시적으로 `{ _ in }`으로 두었다가 Task 17에서 되살린다.

- [ ] **Step 3-d: 앱에 배선**

`Wattly/App/WattlyApp.swift`:

```swift
    @State private var calibrationCoordinator: BatteryCalibrationCoordinator
```
`init()`의 `_scheduleCoordinator = ...` 다음:
```swift
        _calibrationCoordinator = State(
            initialValue: BatteryCalibrationCoordinator(batteryControl: bc))
```
`MenuBarLabel`의 `.background(BatteryControlBridge(...))` 다음:
```swift
                // 코디네이터는 자기 타이머로 돌지만, 앱 시작 시 저장 상태와 데몬 상태를
                // 대조하는 일은 뷰 수명주기에 걸어 둔다 — 라벨은 언마운트되지 않는다.
                .task { await calibrationCoordinator.handleAppLaunch() }
```
**이 태스크에서는 뷰 배선을 하지 않는다.** `SettingsView`로의 주입은 Task 15가, `PopoverContentView`로의 주입은 Task 19가 각각 자기 태스크 안에서 프로퍼티 추가와 함께 처리한다 — 그래야 각 태스크가 단독으로 컴파일된다. 여기서는 코디네이터 생성과 `handleAppLaunch` 훅까지만 한다.

- [ ] **Step 4: 테스트 통과 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryCalibrationCoordinatorTests -only-testing:WattlyTests/BatteryCalibrationRateTests test
```
Expected: PASS (10개 테스트)

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Core/BatteryCalibrationCoordinator.swift Wattly/Core/BatteryCalibration.swift Wattly/Settings/Settings.swift Wattly/App/WattlyApp.swift WattlyTests/BatteryCalibrationCoordinatorTests.swift Wattly.xcodeproj && git commit -m "feat(battery): add the app-owned calibration coordinator"
```

---

## Task 14: 브리지 — 활동 보존과 Top Up 만료 알림 억제

**Files:**
- Modify: `Wattly/Views/BatteryControlBridge.swift`
- Test: `WattlyTests/BatteryControlBridgeTests.swift`

**Interfaces:**
- Consumes: Task 1·12
- Produces: `BatteryControlBridge.preservingActivity`가 캘리브레이션 3필드(active·target·단계 표시용 topUp)를 보존

**설계 근거:** PR #97이 고친 버그와 정확히 같은 계열이다 — 저장 선호값으로만 만든 설정이 데몬의 활동을 매 분 덮어썼다. 캘리브레이션은 그 계약에 얹히는 세 번째 활동이다.

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/BatteryControlBridgeTests.swift` 닫는 `}` 앞:

```swift
    @Test func preservingActivityCarriesCalibrationForward() {
        let requested = BatteryControlConfiguration(enabled: false, limitPercentage: 80)
        let daemon = BatteryControlConfiguration(
            enabled: true, limitPercentage: 80, topUpActive: true,
            autoDischargeEnabled: true,
            calibrationActive: true, calibrationTargetPercentage: 20)

        let merged = BatteryControlBridge.preservingActivity(requested, daemon: daemon)

        #expect(merged.calibrationActive)
        #expect(merged.calibrationTargetPercentage == 20)
        // 어느 단계인지도 보존해야 한다 — 충전 단계를 방전 단계로 바꾸면 절차가 망가진다.
        #expect(merged.topUpActive)
        // 절차 중에는 정책이 활성이어야 하고 자동 방전은 서 있어야 한다.
        #expect(merged.enabled)
        #expect(merged.autoDischargeEnabled == false)
    }

    @Test func preservingActivityIsUnchangedWhenNoCalibrationRuns() {
        let requested = BatteryControlConfiguration(
            enabled: true, limitPercentage: 80, autoDischargeEnabled: true)
        let daemon = BatteryControlConfiguration(enabled: true, limitPercentage: 80)
        let merged = BatteryControlBridge.preservingActivity(requested, daemon: daemon)
        #expect(merged.calibrationActive == false)
        #expect(merged.autoDischargeEnabled)
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryControlBridgeTests test
```
Expected: FAIL — `merged.calibrationActive`가 `false`

- [ ] **Step 3: 구현**

`Wattly/Views/BatteryControlBridge.swift`의 `preservingActivity`에서 `if desired.manualDischargeActive { ... }` 다음에 추가:

```swift
        // 캘리브레이션은 세 번째 활동이다. `topUpActive`까지 함께 보존해야 하는 이유는,
        // 절차에서 그 플래그가 "지금이 충전 단계인지"를 뜻하기 때문이다 — 여기서 떨어뜨리면
        // 충전 중이던 절차가 방전 단계로 뒤집힌다.
        merged.calibrationActive = desired.calibrationActive
        if desired.calibrationActive {
            merged.calibrationTargetPercentage = desired.calibrationTargetPercentage
            merged.topUpActive = desired.topUpActive
            merged.manualDischargeActive = false
            merged.enabled = true
            merged.autoDischargeEnabled = false
        }
```

같은 파일의 `.onChange(of: client.status)`에서 Top Up 만료 알림을 절차 중에는 억제:

```swift
                // 캘리브레이션은 100% 홀드 단계에서 같은 `topUpActive`를 빌려 쓴다. 만료
                // 자체는 데몬이 막지만(`BatteryTopUpExpiry.decide(calibrationActive:)`),
                // 절차 직전에 남아 있던 레코드가 신선도 창 안에서 뒤늦게 뜨는 경우가 있다.
                // 감지기는 항상 돌려 레코드를 소비시키고, 알림만 건너뛴다.
                let didExpire = topUpExpiryDetector.update(
                    record: newStatus.lastMaintenance,
                    now: Date().timeIntervalSince1970)
                if didExpire, newStatus.desiredConfiguration?.calibrationActive != true {
                    BatteryNotificationManager.postTopUpExpiredNotification()
                }
```

> Top Up **완료** 알림(`topUpDetector`)은 손대지 않는다. 절차 중 reason은 `.calibrationCharging` / `.calibrationHolding`이라 `.topUpCharging → .topUpComplete` 전이가 아예 발생하지 않는다.

- [ ] **Step 4: 테스트 통과 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryControlBridgeTests test
```
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Views/BatteryControlBridge.swift WattlyTests/BatteryControlBridgeTests.swift && git commit -m "feat(battery): preserve calibration across bridge pushes and mute top-up expiry"
```

---

## Task 15: 초기화·삭제 순서 강제 (원복 → 키 제거)

**Files:**
- Modify: `Wattly/Core/SettingsReset.swift`
- Modify: `Wattly/Core/AppUninstaller.swift`
- Modify: `Wattly/Views/SettingsView.swift` (코디네이터 주입 + 두 호출부)
- Modify: `Wattly/App/WattlyApp.swift`
- Test: `WattlyTests/SettingsResetTests.swift`, `WattlyTests/AppUninstallerTests.swift`

**Interfaces:**
- Consumes: Task 13 (`StorageKey.batteryCalibration*`)
- Produces:
  - `SettingsReset.applyDefaults`가 캘리브레이션 키 2개를 초기화
  - `SettingsReset.resetEverything(into:login:maxFanRPM:stoppingCalibration:) async`
  - `AppUninstaller.cleanUserData(..., stopCalibration:)`

**설계 근거 (#33):** 순서가 없으면 저장된 실행 상태가 먼저 사라지고 데몬만 CHIE를 든 고아가 된다. 그 상태를 정리할 근거(`run` 상태)가 앱에서 사라졌으므로, 고아 처리 로직도 발동하지 않는다.

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/SettingsResetTests.swift` 닫는 `}` 앞:

```swift
    @Test func resetClearsCalibrationKeys() {
        let defaults = UserDefaults(suiteName: "reset.calibration")!
        defaults.removePersistentDomain(forName: "reset.calibration")
        defaults.set("{\"step\":\"soakLow\"}", forKey: StorageKey.batteryCalibrationState)
        defaults.set("[{}]", forKey: StorageKey.batteryCalibrationHistory)

        SettingsReset.applyDefaults(into: defaults)

        #expect(defaults.string(forKey: StorageKey.batteryCalibrationState) == "")
        #expect(defaults.string(forKey: StorageKey.batteryCalibrationHistory) == "")
    }

    @MainActor @Test func resetStopsTheCalibrationBeforeErasingItsState() async {
        final class Order: @unchecked Sendable { var values: [String] = [] }
        let order = Order()
        let name = "reset.calibration.order"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set("{}", forKey: StorageKey.batteryCalibrationState)

        await SettingsReset.resetEverything(
            into: defaults,
            stoppingCalibration: {
                // 이 시점에는 저장된 실행 상태가 아직 살아 있어야 한다 — 없으면 절차를
                // 되돌릴 근거가 사라진다.
                order.values.append(
                    defaults.string(forKey: StorageKey.batteryCalibrationState) == "{}"
                        ? "stop-with-state" : "stop-without-state")
            })

        order.values.append("erased")
        #expect(order.values == ["stop-with-state", "erased"])
        #expect(defaults.string(forKey: StorageKey.batteryCalibrationState) == "")
    }
```

`WattlyTests/AppUninstallerTests.swift` 닫는 `}` 앞:

```swift
    @MainActor @Test func uninstallStopsCalibrationBeforeReleasingTheLimit() async throws {
        final class Order: @unchecked Sendable { var values: [String] = [] }
        let order = Order()
        let name = "uninstall.calibration.order"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        try await AppUninstaller.cleanUserData(
            userDefaults: defaults,
            loginItem: MockLoginItem(),
            fileManager: .default,
            homeDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            bundleID: name,
            stopCalibration: { order.values.append("stop-calibration") },
            releaseBatteryLimit: { order.values.append("release-limit") },
            removeHelper: { order.values.append("remove-helper") })

        #expect(order.values == ["stop-calibration", "release-limit", "remove-helper"])
    }
```

> `MockLoginItem`은 `AppUninstallerTests` 안에 이미 있는 더블이다. `cleanUserData`의 인자 이름(`userDefaults` / `loginItem` / `fileManager` / `homeDirectory` / `bundleID`)은 현재 구현 그대로다.

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/SettingsResetTests -only-testing:WattlyTests/AppUninstallerTests test
```
Expected: 컴파일 실패 — `type 'SettingsReset' has no member 'resetEverything'`

- [ ] **Step 3: 구현**

`Wattly/Core/SettingsReset.swift`의 `applyDefaults`에서 `batteryScheduleNotificationsEnabled` 줄 아래에 추가:

```swift
        defaults.set(Defaults.batteryCalibrationState, forKey: StorageKey.batteryCalibrationState)
        defaults.set(Defaults.batteryCalibrationHistory, forKey: StorageKey.batteryCalibrationHistory)
```

같은 파일의 `enum SettingsReset` 안에 추가:

```swift
    /// "기본값으로 되돌리기"의 실제 진입점. 캘리브레이션이 돌고 있으면 **먼저 멈춘 뒤에**
    /// 키를 지운다. 순서가 뒤집히면 저장된 실행 상태가 사라진 채 데몬만 CHIE를 든 고아가
    /// 되고, 앱에는 그것을 정리할 근거가 남지 않는다.
    @MainActor
    static func resetEverything(
        into defaults: UserDefaults = .standard,
        login: LoginItemControlling? = nil,
        maxFanRPM: Double? = nil,
        stoppingCalibration stop: (@MainActor () async -> Void)? = nil
    ) async {
        await stop?()
        applyDefaults(into: defaults, login: login, maxFanRPM: maxFanRPM)
    }
```

**`Wattly/Views/SettingsView.swift` 배선.** 이 태스크가 `SettingsView`에 코디네이터를 들이는 **유일한** 지점이다 — Task 18은 이미 있는 프로퍼티를 쓰기만 한다. 세 곳을 함께 고쳐야 이 태스크만으로 앱 타깃이 컴파일된다.

1. 프로퍼티와 이니셜라이저 인자를 추가한다 ([SettingsView.swift:13](Wattly/Views/SettingsView.swift:13) 부근):
```swift
    var scheduleCoordinator: BatteryScheduleCoordinator? = nil
    let calibrationCoordinator: BatteryCalibrationCoordinator
```
```swift
    init(
        monitor: SystemMonitor,
        fanControl: FanControlClient,
        batteryControl: BatteryControlClient,
        scheduleCoordinator: BatteryScheduleCoordinator? = nil,
        calibrationCoordinator: BatteryCalibrationCoordinator
    ) {
        ...
        self.calibrationCoordinator = calibrationCoordinator
    }
```

2. "기본값으로 되돌리기" ([SettingsView.swift:388](Wattly/Views/SettingsView.swift:388)의 `applyDefaults()`)를 순서가 보장되는 경로로 바꾼다:
```swift
    private func applyDefaults() {
        Task {
            await SettingsReset.resetEverything(
                login: loginItem,
                maxFanRPM: monitor.hardwareMaxFanRPM,
                stoppingCalibration: { await calibrationCoordinator.cancel() })
            loginMirror = loginItem.isEnabled
        }
    }
```

3. "완전 삭제" 버튼 ([SettingsView.swift:68](Wattly/Views/SettingsView.swift:68))에도 같은 훅을 넘긴다. **기본값이 no-op이라 여기를 빠뜨리면 이 태스크 전체가 무의미해진다** — 삭제 경로가 절차를 멈추지 않은 채 저장 상태만 지우고, 데몬이 CHIE를 든 고아로 남는다:
```swift
                        try await AppUninstaller.uninstall(
                            stopCalibration: { await calibrationCoordinator.cancel() })
```

4. `Wattly/App/WattlyApp.swift`의 `SettingsView(...)` 호출에 `calibrationCoordinator: calibrationCoordinator`를 추가한다.

`Wattly/Core/AppUninstaller.swift`의 `cleanUserData`에 인자를 추가하고 **1번과 2번 사이**에 호출을 넣는다:

```swift
        stopCalibration: @MainActor () async -> Void = {},
        releaseBatteryLimit: @MainActor () async throws -> Void = {
```
```swift
        // 1.5. 캘리브레이션을 먼저 멈춘다. 아래 릴리스는 충전 게이트만 되돌리므로, 절차가
        // 살아 있으면 다음 tick이 다시 CHIE를 세운다.
        await stopCalibration()
```
`AppUninstaller.uninstall(...)`에도 같은 파라미터를 추가해 `cleanUserData`로 이어 준다 ([AppUninstaller.swift:130](Wattly/Core/AppUninstaller.swift:130)):

```swift
    static func uninstall(
        currentAppURL: URL = Bundle.main.bundleURL,
        userDefaults: UserDefaults = .standard,
        loginItem: LoginItemControlling = LoginItem(),
        fileManager: FileManager = .default,
        stopCalibration: @MainActor () async -> Void = {}
    ) async throws {
```
```swift
        try await cleanUserData(
            userDefaults: userDefaults,
            loginItem: loginItem,
            fileManager: fileManager,
            stopCalibration: stopCalibration
        )
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/SettingsResetTests -only-testing:WattlyTests/AppUninstallerTests test
```
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Core/SettingsReset.swift Wattly/Core/AppUninstaller.swift Wattly/Views/SettingsView.swift Wattly/App/WattlyApp.swift WattlyTests/ && git commit -m "feat(battery): stop a running calibration before reset or uninstall erases it"
```

---

## Task 16: 절차 중 충전 스케줄 건너뛰기

**Files:**
- Modify: `Wattly/Core/BatteryScheduleLogEntry.swift`
- Modify: `Wattly/Core/BatteryScheduleCoordinator.swift`
- Modify: `Wattly/App/WattlyApp.swift`
- Test: `WattlyTests/BatteryScheduleCoordinatorTests.swift`

**Interfaces:**
- Consumes: Task 13 (`BatteryCalibrationCoordinator.isRunning`)
- Produces:
  - `BatteryScheduleLogEntry.SkipReason.calibrationRunning`
  - `BatteryScheduleCoordinator.init(..., isCalibrationRunning: @escaping @MainActor () -> Bool = { false })`

**설계 근거 (#29):** `BatteryScheduleCoordinator.execute`는 `defaults.set(...)`으로 **사용자 설정 자체를 덮어쓴다**(`.setLimit`은 `batteryLimitPercentage`를, `.pauseCharging`은 50%를 쓴다). 절차 중에 발화하면 시작 시점 스냅샷이 가리키던 값과 실제 저장값이 갈라지고, 원복이 사용자 설정을 잘못된 값으로 되돌린다.

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/BatteryScheduleCoordinatorTests.swift` 닫는 `}` 앞:

```swift
    @MainActor @Test func schedulesAreSkippedAndLoggedWhileCalibrating() async {
        let name = "schedule.calibration"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(true, forKey: StorageKey.batteryLimitEnabled)
        defaults.set(80, forKey: StorageKey.batteryLimitPercentage)

        let client = BatteryControlClient { _ in (nil, nil) }
        let coordinator = BatteryScheduleCoordinator(
            batteryControl: client,
            defaults: defaults,
            isCalibrationRunning: { true })

        coordinator.addSchedule(BatteryChargingSchedule(
            name: "밤",
            isEnabled: true,
            time: ScheduleTime(hour: 3, minute: 0),
            repeatRule: .daily,
            action: .setLimit(percentage: 60)))

        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 30
        components.hour = 3; components.minute = 0
        let fireDate = Calendar.current.date(from: components)!
        await coordinator.evaluateSchedules(at: fireDate)

        // 스케줄이 사용자 설정을 덮어쓰면 절차 스냅샷과 저장값이 갈라진다.
        #expect(defaults.integer(forKey: StorageKey.batteryLimitPercentage) == 80)
        #expect(coordinator.history.first?.status == .skipped(reason: .calibrationRunning))
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryScheduleCoordinatorTests test
```
Expected: 컴파일 실패 — `extra argument 'isCalibrationRunning' in call`

- [ ] **Step 3: 구현**

`Wattly/Core/BatteryScheduleLogEntry.swift`의 `SkipReason`에 추가:

```swift
        case calibrationRunning = "배터리 캘리브레이션 진행 중"
```
`localizedDescription`에도:
```swift
            case .calibrationRunning:
                return String(localized: "배터리 캘리브레이션 진행 중")
```

`Wattly/Core/BatteryScheduleCoordinator.swift`:

```swift
    private let isCalibrationRunning: @MainActor () -> Bool
```
`init`에 파라미터 추가 (기본값 덕분에 기존 호출부는 그대로 컴파일된다):
```swift
        isCalibrationRunning: @escaping @MainActor () -> Bool = { false }
```
```swift
        self.isCalibrationRunning = isCalibrationRunning
```

`evaluateSchedules`의 `guard let winning = Self.resolveConflict(among: matching) else { return }` **다음**에 삽입:

```swift
        // 캘리브레이션 중에는 발화하지 않는다. `execute`가 `defaults.set`으로 사용자 설정
        // 자체를 덮어쓰기 때문에, 절차 시작 시점 스냅샷과 저장값이 갈라지고 원복이 잘못된
        // 값을 되돌린다. 조용히 넘기지 않고 사유를 이력에 남긴다.
        guard !isCalibrationRunning() else {
            recordLog(schedule: winning, status: .skipped(reason: .calibrationRunning),
                      timestamp: date)
            return
        }
```

`Wattly/App/WattlyApp.swift`의 `init()`에서 생성 순서를 캘리브레이션 코디네이터 먼저로 바꾸고 배선:

```swift
        let bc = BatteryControlClient()
        _batteryControl = State(initialValue: bc)
        let calibration = BatteryCalibrationCoordinator(batteryControl: bc)
        _calibrationCoordinator = State(initialValue: calibration)
        _scheduleCoordinator = State(initialValue: BatteryScheduleCoordinator(
            batteryControl: bc,
            isCalibrationRunning: { calibration.isRunning }))
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryScheduleCoordinatorTests test
```
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Core/BatteryScheduleLogEntry.swift Wattly/Core/BatteryScheduleCoordinator.swift Wattly/App/WattlyApp.swift WattlyTests/BatteryScheduleCoordinatorTests.swift && git commit -m "feat(battery): skip charging schedules while a calibration runs"
```

---

## Task 17: 알림 3종과 권한 선취득

**Files:**
- Modify: `Wattly/Core/BatteryNotificationManager.swift`
- Modify: `Wattly/Core/BatteryCalibrationCoordinator.swift` (일시정지 알림)
- Test: `WattlyTests/BatteryNotificationManagerTests.swift`

**Interfaces:**
- Consumes: Task 6·13
- Produces:
  - `BatteryNotificationManager.isActionableForNotification(_:) -> Bool`
  - `calibrationFinishedTitle(_:locale:)` / `calibrationFinishedBody(_:locale:)`
  - `calibrationActionNeededTitle(locale:)` / `calibrationActionNeededBody(_:locale:)`
  - `postCalibrationFinished(_:)` / `postCalibrationActionNeeded(_:)`

**설계 근거 (#14/#34):** 7단계 × 알림이면 야간에 알림 폭탄이라 3종만 둔다. 권한은 **시작 버튼에서 선취득**한다 — 현재는 `startTopUp`/`startManualDischarge` 진입 시에만 요청하므로, 그 경로를 타지 않는 절차는 10시간 뒤 완료 알림이 조용히 증발한다.

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/BatteryNotificationManagerTests.swift` 닫는 `}` 앞:

```swift
    @Test func onlyUserActionablePausesNotify() {
        // 열보호는 스스로 풀리고, 잠자기는 사용자가 이미 알고 한 일이다.
        #expect(BatteryNotificationManager.isActionableForNotification(.needsAdapter))
        #expect(BatteryNotificationManager.isActionableForNotification(.externalChargeBlock))
        #expect(BatteryNotificationManager.isActionableForNotification(.helperUnavailable))
        #expect(BatteryNotificationManager.isActionableForNotification(.heatProtection) == false)
        #expect(BatteryNotificationManager.isActionableForNotification(.systemSleep) == false)
    }

    @Test func finishedNotificationNeverPromisesCapacityRecovery() {
        let ko = Locale(identifier: "ko")
        let completed = CalibrationHistoryEntry(
            id: UUID(), startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 37_800),
            outcome: .completed, failure: nil,
            beginMaxCapacityMilliampHours: 6208, endMaxCapacityMilliampHours: 6243,
            beginCycleCount: 112, endCycleCount: 113)
        let title = BatteryNotificationManager.calibrationFinishedTitle(completed, locale: ko)
        #expect(title == "잔량 표시 보정 완료")
        #expect(title.contains("회복") == false)
    }

    @Test func failureNotificationNamesTheReason() {
        let ko = Locale(identifier: "ko")
        let failed = CalibrationHistoryEntry(
            id: UUID(), startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 100),
            outcome: .failed, failure: .stepTimeout,
            beginMaxCapacityMilliampHours: nil, endMaxCapacityMilliampHours: nil,
            beginCycleCount: nil, endCycleCount: nil)
        let body = BatteryNotificationManager.calibrationFinishedBody(failed, locale: ko)
        #expect(body.isEmpty == false)
        // 무엇 때문에 멈췄는지 말하지 않으면 사용자가 복구할 방법이 없다.
        #expect(body != BatteryNotificationManager.calibrationFinishedBody(
            CalibrationHistoryEntry(
                id: UUID(), startedAt: Date(timeIntervalSince1970: 0),
                finishedAt: Date(timeIntervalSince1970: 100),
                outcome: .failed, failure: .pauseBudgetExhausted,
                beginMaxCapacityMilliampHours: nil, endMaxCapacityMilliampHours: nil,
                beginCycleCount: nil, endCycleCount: nil),
            locale: ko))
    }

    @Test func actionNeededBodyDiffersPerPause() {
        let ko = Locale(identifier: "ko")
        #expect(BatteryNotificationManager.calibrationActionNeededBody(.needsAdapter, locale: ko)
            != BatteryNotificationManager.calibrationActionNeededBody(.externalChargeBlock, locale: ko))
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryNotificationManagerTests test
```
Expected: 컴파일 실패 — `type 'BatteryNotificationManager' has no member 'isActionableForNotification'`

- [ ] **Step 3: 구현**

`Wattly/Core/BatteryNotificationManager.swift`의 `enum BatteryNotificationManager` 안에 추가:

```swift
    // MARK: - 캘리브레이션

    /// 사용자가 실제로 할 일이 있는 일시정지만 알린다. 열보호는 식으면 스스로 풀리고,
    /// 잠자기는 사용자가 방금 뚜껑을 닫아서 생긴 상태다 — 둘 다 알림이 소음이다.
    public static func isActionableForNotification(_ pause: CalibrationPause) -> Bool {
        switch pause {
        case .needsAdapter, .externalChargeBlock, .helperUnavailable: return true
        case .heatProtection, .systemSleep: return false
        }
    }

    public static func calibrationFinishedTitle(
        _ entry: CalibrationHistoryEntry, locale: Locale
    ) -> String {
        switch entry.outcome {
        case .completed: return BatteryCalibration.completionHeadline(locale: locale)
        case .cancelled: return String(localized: "배터리 캘리브레이션 중지됨", locale: locale)
        case .expired: return String(localized: "배터리 캘리브레이션 자동 취소됨", locale: locale)
        case .failed: return String(localized: "배터리 캘리브레이션 실패", locale: locale)
        }
    }

    public static func calibrationFinishedBody(
        _ entry: CalibrationHistoryEntry, locale: Locale
    ) -> String {
        switch entry.outcome {
        case .completed:
            let note = BatteryCalibration.capacityNote(
                beginMilliampHours: entry.beginMaxCapacityMilliampHours,
                endMilliampHours: entry.endMaxCapacityMilliampHours,
                locale: locale)
            let base = String(localized: "원래 충전 설정으로 되돌렸습니다.", locale: locale)
            return note.map { "\(base) \($0)" } ?? base
        case .cancelled:
            return String(localized: "원래 충전 설정으로 되돌렸습니다.", locale: locale)
        case .expired:
            return String(localized: "12시간 동안 진행이 없어 자동으로 취소하고 원래 충전 설정으로 되돌렸습니다.", locale: locale)
        case .failed:
            let reason: String
            switch entry.failure {
            case .stepTimeout:
                reason = String(localized: "한 단계가 제한 시간을 넘겼습니다.", locale: locale)
            case .pauseBudgetExhausted:
                reason = String(localized: "일시정지가 2시간을 넘겼습니다.", locale: locale)
            case .helperLost:
                reason = String(localized: "도우미 연결이 끊겼습니다.", locale: locale)
            case .dischargeUnsupported:
                reason = String(localized: "이 Mac은 강제 방전을 지원하지 않습니다.", locale: locale)
            case .none:
                reason = String(localized: "알 수 없는 이유로 중단됐습니다.", locale: locale)
            }
            return "\(reason) \(String(localized: "원래 충전 설정으로 되돌렸습니다.", locale: locale))"
        }
    }

    public static func calibrationActionNeededTitle(locale: Locale) -> String {
        String(localized: "배터리 캘리브레이션에 조치가 필요합니다", locale: locale)
    }

    public static func calibrationActionNeededBody(
        _ pause: CalibrationPause, locale: Locale
    ) -> String {
        switch pause {
        case .needsAdapter:
            return String(localized: "전원 어댑터를 다시 연결하면 이어서 진행합니다.", locale: locale)
        case .externalChargeBlock:
            return String(localized: "충전이 시작되지 않습니다. 시스템 설정 › 배터리에서 \"최적화된 배터리 충전\"을 꺼 주세요.", locale: locale)
        case .helperUnavailable:
            return String(localized: "도우미 연결이 끊겼습니다. Wattly 설정에서 다시 연결해 주세요.", locale: locale)
        case .heatProtection, .systemSleep:
            return ""
        }
    }

    public static func postCalibrationFinished(_ entry: CalibrationHistoryEntry) {
        post(identifier: "dev.jjundev.Wattly.calibrationFinished") { locale in
            (calibrationFinishedTitle(entry, locale: locale),
             calibrationFinishedBody(entry, locale: locale))
        }
    }

    public static func postCalibrationActionNeeded(_ pause: CalibrationPause) {
        guard isActionableForNotification(pause) else { return }
        post(identifier: "dev.jjundev.Wattly.calibrationActionNeeded") { locale in
            (calibrationActionNeededTitle(locale: locale),
             calibrationActionNeededBody(pause, locale: locale))
        }
    }

    /// 기존 `postTopUp*` 세 함수가 똑같이 반복하던 권한 확인 · 로케일 해석 · 요청 생성을
    /// 한 곳으로 모은 것. 새 알림 3종이 그 반복을 한 번 더 늘리기 전에 뽑아 둔다.
    private static func post(
        identifier: String,
        content: @escaping (Locale) -> (title: String, body: String)
    ) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            let appLang = UserDefaults.standard.string(forKey: StorageKey.appLanguage)
                ?? Defaults.appLanguage
            let locale = AppLanguage.locale(for: appLang)
            let resolved = content(locale)
            let notification = UNMutableNotificationContent()
            notification.title = resolved.title
            notification.body = resolved.body
            notification.sound = .default
            center.add(UNNotificationRequest(
                identifier: identifier, content: notification, trigger: nil))
        }
    }
```

일시정지 알림은 코디네이터가 이미 주입된 `notifyPause`로 호출한다(Task 13). 여기서 남은 코디네이터 변경은 하나뿐이다 — `start()`의 맨 앞에 권한 선취득:

```swift
    public func start() async {
        guard run == nil else { return }
        // 10시간 뒤에 뜰 완료 알림의 권한을 지금 받아 둔다. 거부되면 카드에 명시적으로 안내한다.
        BatteryNotificationManager.requestAuthorization()
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryNotificationManagerTests -only-testing:WattlyTests/BatteryCalibrationCoordinatorTests test
```
Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Core/BatteryNotificationManager.swift Wattly/Core/BatteryCalibrationCoordinator.swift WattlyTests/BatteryNotificationManagerTests.swift && git commit -m "feat(battery): add calibration notifications and pre-acquire authorization"
```

---

## Task 18: 설정 화면 캘리브레이션 카드

**Files:**
- Modify: `Wattly/Core/BatteryCalibration.swift` (표시 문구 — 순수)
- Create: `Wattly/Views/Settings/SettingsBatteryCalibrationSection.swift`
- Modify: `Wattly/Views/SettingsView.swift`
- Test: `WattlyTests/BatteryCalibrationTests.swift`

**Interfaces:**
- Consumes: Task 9(`CalibrationBlocker`), Task 13(코디네이터)
- Produces:
  - `BatteryCalibration.stepLabel(_:locale:)` / `pauseText(_:locale:)` / `blockerText(_:locale:)`
  - `SettingsBatteryCalibrationSection(batteryControl:calibration:)`

**설계 근거 (#12/#2/B4):** 카드는 설정 › 배터리 **최하단**의 "고급 · 배터리 진단"에 둔다. 헬퍼 능력 게이팅은 **이 카드 안에서만** 한다 — `BatterySectionPresentation.maintenanceStatus`의 전역 `requiredCapabilities`에 `.calibrationV1`을 넣으면 캘리브레이션을 쓰지 않는 전 사용자가 "도우미 업데이트 필요" 상태가 된다. 그리고 기존 재설치 진입점이 `mode == .unavailable`에만 묶여 있어, **응답은 잘 하는 구버전 헬퍼는 영원히 교체되지 않는다**. 그래서 카드 안에 인라인 업데이트 버튼이 필요하다.

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/BatteryCalibrationTests.swift` 파일 끝에 추가:

```swift
struct BatteryCalibrationCopyTests {
    private let ko = Locale(identifier: "ko")

    @Test func everyStepHasALabel() {
        for step in CalibrationStep.allCases {
            #expect(BatteryCalibration.stepLabel(step, locale: ko).isEmpty == false)
        }
    }

    @Test func everyPauseHasAnExplanation() {
        for pause in CalibrationPause.allCases {
            #expect(BatteryCalibration.pauseText(pause, locale: ko).isEmpty == false)
        }
    }

    @Test func everyBlockerHasAnActionableSentence() {
        for blocker in CalibrationBlocker.allCases {
            #expect(BatteryCalibration.blockerText(blocker, locale: ko).isEmpty == false)
        }
    }

    @Test func theDurationConfirmationSpellsOutTheLidRequirement() {
        // #17의 조건이었다: 10.5시간을 감수하는 대신 안내가 솔직해야 한다.
        let text = BatteryCalibration.blockerText(.durationUnconfirmed, locale: ko)
        #expect(text.contains("뚜껑"))
        #expect(text.contains("10"))
    }

    @Test func theOptimizedChargingBlockerNamesTheSettingToTurnOff() {
        let text = BatteryCalibration.blockerText(.optimizedChargingUnconfirmed, locale: ko)
        #expect(text.contains("최적화된 배터리 충전"))
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryCalibrationCopyTests test
```
Expected: 컴파일 실패 — `type 'BatteryCalibration' has no member 'stepLabel'`

- [ ] **Step 3-a: 표시 문구 (순수)**

`Wattly/Core/BatteryCalibration.swift`의 `capacityNote` 아래에 추가:

```swift
    // MARK: - 표시 문구

    public static func stepLabel(_ step: CalibrationStep, locale: Locale) -> String {
        switch step {
        case .preflight: return String(localized: "시작 준비", locale: locale)
        case .chargeToFull: return String(localized: "100%까지 충전", locale: locale)
        case .dischargeToFloor: return String(localized: "20%까지 방전", locale: locale)
        case .soakLow: return String(localized: "저잔량 안정화 (10분)", locale: locale)
        case .rechargeToFull: return String(localized: "다시 100%까지 충전", locale: locale)
        case .soakFinal: return String(localized: "최종 안정화 (60분)", locale: locale)
        case .restoring: return String(localized: "원래 설정으로 복원", locale: locale)
        }
    }

    public static func pauseText(_ pause: CalibrationPause, locale: Locale) -> String {
        switch pause {
        case .needsAdapter:
            return String(localized: "일시정지: 전원 어댑터를 다시 연결해 주세요", locale: locale)
        case .heatProtection:
            return String(localized: "일시정지: 발열 보호 작동 중 (식으면 자동으로 이어집니다)", locale: locale)
        case .helperUnavailable:
            return String(localized: "일시정지: 도우미에 연결되지 않았습니다", locale: locale)
        case .systemSleep:
            return String(localized: "일시정지: 잠자기 상태입니다 (뚜껑을 열면 이어집니다)", locale: locale)
        case .externalChargeBlock:
            return String(localized: "일시정지: 충전이 시작되지 않습니다. \"최적화된 배터리 충전\"을 꺼 주세요", locale: locale)
        }
    }

    public static func blockerText(_ blocker: CalibrationBlocker, locale: Locale) -> String {
        switch blocker {
        case .helperUnavailable:
            return String(localized: "도우미가 설치되어 있지 않습니다.", locale: locale)
        case .helperTooOld:
            return String(localized: "설치된 도우미가 캘리브레이션을 지원하지 않습니다. 업데이트가 필요합니다.", locale: locale)
        case .hardwareUnsupported:
            return String(localized: "이 Mac은 충전 제어를 지원하지 않습니다.", locale: locale)
        case .dischargeUnsupported:
            return String(localized: "이 Mac은 강제 방전을 지원하지 않아 캘리브레이션을 할 수 없습니다.", locale: locale)
        case .adapterDisconnected:
            return String(localized: "전원 어댑터를 연결해 주세요.", locale: locale)
        case .heatProtectionActive:
            return String(localized: "발열 보호가 작동 중입니다. 배터리가 식은 뒤에 시작해 주세요.", locale: locale)
        case .otherActivityRunning:
            return String(localized: "한 번만 완충 또는 수동 방전이 진행 중입니다. 먼저 끝내 주세요.", locale: locale)
        case .optimizedChargingUnconfirmed:
            return String(localized: "시스템 설정 › 배터리에서 \"최적화된 배터리 충전\"을 껐습니다.", locale: locale)
        case .durationUnconfirmed:
            return String(localized: "약 10시간이 걸리며, 방전 구간 약 7시간 동안은 뚜껑을 열어 두어야 합니다. 화면은 꺼져도 됩니다.", locale: locale)
        }
    }
```

- [ ] **Step 3-b: 카드 뷰**

`Wattly/Views/Settings/SettingsBatteryCalibrationSection.swift` (신규):

```swift
import SwiftUI
import AppKit

/// 설정 › 배터리 최하단의 "고급 · 배터리 진단" 카드.
///
/// 헬퍼 능력 게이팅을 **이 카드 안에서만** 하는 것이 중요하다.
/// `BatterySectionPresentation.maintenanceStatus`의 전역 `requiredCapabilities`에
/// `.calibrationV1`을 넣으면, 캘리브레이션을 쓰지 않는 전 사용자가 "도우미 업데이트 필요"
/// 상태가 된다. 반대로 기존 재설치 버튼은 `mode == .unavailable`일 때만 뜨므로, 응답은 잘
/// 하는 구버전 헬퍼는 영원히 교체되지 않는다 — 그래서 여기에 인라인 업데이트 버튼을 둔다.
struct SettingsBatteryCalibrationSection: View {
    @Environment(\.tokens) private var t
    @Environment(\.locale) private var locale
    let batteryControl: BatteryControlClient
    let calibration: BatteryCalibrationCoordinator

    @State private var isExpanded = false
    @State private var confirmedOptimizedChargingOff = false
    @State private var confirmedDuration = false
    @State private var isCooldownConfirmationPresented = false
    @State private var isInstallFailedAlertPresented = false
    @State private var installErrorMessage = ""

    private var blockers: [CalibrationBlocker] {
        BatteryCalibration.preflightBlockers(
            helperMode: batteryControl.status.mode,
            capabilities: batteryControl.status.capabilities,
            isHardwareSupported: batteryControl.status.isHardwareSupported,
            isDischargeHardwareSupported: batteryControl.status.isDischargeHardwareSupported,
            isAdapterPresent: calibration.lastReading.isAdapterPresent
                || batteryControl.status.isPowerAdapterConnected,
            isHeatProtected: batteryControl.status.activity == .heatProtection,
            isTopUpActive: batteryControl.status.desiredConfiguration?.topUpActive == true,
            isManualDischargeActive:
                batteryControl.status.desiredConfiguration?.manualDischargeActive == true,
            hasConfirmedOptimizedChargingOff: confirmedOptimizedChargingOff,
            hasConfirmedDuration: confirmedDuration)
    }

    var body: some View {
        SettingsSection("고급 · 배터리 진단") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    if isExpanded {
                        Rectangle().fill(t.line).frame(height: 1)
                        if calibration.isRunning { progress } else { preflight }
                        if let entry = calibration.history.first { report(entry) }
                    }
                }
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
            }
        }
        .alert("도우미 업데이트에 실패했습니다", isPresented: $isInstallFailedAlertPresented) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(verbatim: installErrorMessage)
        }
        .confirmationDialog("최근에 캘리브레이션을 실행했습니다", isPresented: $isCooldownConfirmationPresented) {
            Button("그래도 실행", role: .destructive) { Task { await calibration.start() } }
            Button("취소", role: .cancel) {}
        } message: {
            Text("정상적인 배터리에 반복 실행은 권장하지 않습니다. 90일 또는 40 사이클마다 한 번이면 충분합니다.")
        }
    }

    private var header: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsRowTitle("배터리 캘리브레이션")
                    Text("배터리 셀을 회복시키는 기능이 아니라, 잔량 표시의 추정 오차를 보정하는 장시간 충·방전 절차입니다.")
                        .font(WattlyFont.at(10.5, weight: .regular))
                        .foregroundStyle(t.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(t.faint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var preflight: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("절차: 100% 충전 → 20% 방전 → 10분 대기 → 100% 재충전 → 60분 대기 → 원래 설정 복원")
                .font(WattlyFont.at(10.5, weight: .regular))
                .foregroundStyle(t.sub)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: estimateText)
                .font(WattlyFont.at(10.5, weight: .medium))
                .foregroundStyle(t.sub)

            Toggle(isOn: $confirmedDuration) {
                Text(verbatim: BatteryCalibration.blockerText(.durationUnconfirmed, locale: locale))
                    .font(WattlyFont.at(10.5, weight: .regular))
            }
            Toggle(isOn: $confirmedOptimizedChargingOff) {
                Text(verbatim: BatteryCalibration.blockerText(
                    .optimizedChargingUnconfirmed, locale: locale))
                    .font(WattlyFont.at(10.5, weight: .regular))
            }

            // 확인 항목이 아닌, 기계 상태에서 온 차단 사유만 목록으로 보여 준다.
            ForEach(blockers.filter {
                $0 != .durationUnconfirmed && $0 != .optimizedChargingUnconfirmed
            }, id: \.self) { blocker in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Tokens.statusOrange)
                    Text(verbatim: BatteryCalibration.blockerText(blocker, locale: locale))
                        .font(WattlyFont.at(10.5, weight: .regular))
                        .foregroundStyle(t.sub)
                        .fixedSize(horizontal: false, vertical: true)
                    if blocker == .helperTooOld {
                        Button("도우미 업데이트") { updateHelper() }
                            .buttonStyle(.plain)
                            .font(WattlyFont.at(10.5, weight: .semibold))
                            .foregroundStyle(Tokens.statusOrange)
                    }
                }
            }

            Text("macOS는 충전 제한을 쓰는 중에도 주기적으로 100%까지 충전해 잔량 추정을 유지합니다. macOS 26.4 이상의 기본 충전 제한을 쓰신다면 이 절차는 대개 불필요합니다.")
                .font(WattlyFont.at(10, weight: .regular))
                .foregroundStyle(t.faint)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                if calibration.isWithinCooldown {
                    isCooldownConfirmationPresented = true
                } else {
                    Task { await calibration.start() }
                }
            } label: {
                Text("캘리브레이션 시작")
                    .font(WattlyFont.at(11.5, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rowBorder, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!blockers.isEmpty)
        }
    }

    @ViewBuilder
    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(CalibrationStep.allCases.filter { $0 != .preflight }, id: \.self) { step in
                HStack(spacing: 6) {
                    Image(systemName: symbol(for: step))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(step == calibration.run?.step ? Tokens.statusOrange : t.faint)
                    Text(verbatim: BatteryCalibration.stepLabel(step, locale: locale))
                        .font(WattlyFont.at(10.5,
                              weight: step == calibration.run?.step ? .semibold : .regular))
                        .foregroundStyle(step == calibration.run?.step ? t.text : t.faint)
                }
            }
            if let pause = calibration.run?.pause {
                Text(verbatim: BatteryCalibration.pauseText(pause, locale: locale))
                    .font(WattlyFont.at(10.5, weight: .medium))
                    .foregroundStyle(Tokens.statusOrange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: estimateText)
                .font(WattlyFont.at(10.5, weight: .regular))
                .foregroundStyle(t.sub)

            Button {
                Task { await calibration.cancel() }
            } label: {
                Text("중지하고 원래 설정으로 되돌리기")
                    .font(WattlyFont.at(11.5, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rowBorder, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func report(_ entry: CalibrationHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(t.line).frame(height: 1)
            Text(verbatim: BatteryNotificationManager.calibrationFinishedTitle(entry, locale: locale))
                .font(WattlyFont.at(11, weight: .semibold))
            Text(verbatim: BatteryNotificationManager.calibrationFinishedBody(entry, locale: locale))
                .font(WattlyFont.at(10.5, weight: .regular))
                .foregroundStyle(t.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var estimateText: String {
        let minutes = calibration.estimatedRemainingMinutes
            ?? BatteryCalibration.estimatedRemainingMinutes(
                step: .chargeToFull, soc: batteryControl.status.currentPercentage)
        return String(
            format: String(localized: "예상 남은 시간 약 %@", locale: locale),
            locale: locale,
            BatterySectionPresentation.formatDuration(minutes: minutes, locale: locale))
    }

    private func symbol(for step: CalibrationStep) -> String {
        guard let current = calibration.run?.step else { return "circle" }
        if step == current { return "arrow.triangle.2.circlepath" }
        let order = CalibrationStep.allCases
        guard let a = order.firstIndex(of: step), let b = order.firstIndex(of: current) else {
            return "circle"
        }
        return a < b ? "checkmark.circle.fill" : "circle"
    }

    private func updateHelper() {
        let window = NSApp.keyWindow
        let defaults = UserDefaults.standard
        func int(_ key: String, _ fallback: Int) -> Int {
            defaults.object(forKey: key) != nil ? defaults.integer(forKey: key) : fallback
        }
        Task {
            // 기존 재설치 경로를 그대로 재사용한다. 설치된 헬퍼를 덮어쓰는 것이 정상 동작이며
            // 사용자에게 인증을 다시 묻는다.
            // `installAndApply`의 `autoDischargeEnabled` 기본값은 `true`다. 생략하면 도우미
            // 업데이트가 사용자의 자동 방전 설정을 몰래 켜 버린다 — 반드시 저장값을 넘긴다.
            if let failure = await batteryControl.installAndApply(
                enabled: defaults.bool(forKey: StorageKey.batteryLimitEnabled),
                limitPercentage: int(StorageKey.batteryLimitPercentage,
                                     Defaults.batteryLimitPercentage),
                heatProtectionEnabled: defaults.bool(
                    forKey: StorageKey.batteryHeatProtectionEnabled),
                heatProtectionThresholdCelsius: int(
                    StorageKey.batteryHeatProtectionThreshold,
                    Defaults.batteryHeatProtectionThreshold),
                autoDischargeEnabled: defaults.bool(
                    forKey: StorageKey.batteryAutoDischargeEnabled),
                manualDischargeTarget: int(StorageKey.batteryManualDischargeTarget,
                                           Defaults.batteryManualDischargeTarget),
                transferringOwnership: false,
                window: window) {
                installErrorMessage = SettingsBatterySection.message(for: failure, locale: locale)
                isInstallFailedAlertPresented = true
            }
            await batteryControl.refreshStatus()
        }
    }
}
```

> `SettingsBatterySection.message(for:locale:)`는 현재 `private static`이다([SettingsBatterySection.swift:949](Wattly/Views/Settings/SettingsBatterySection.swift:949)). 같은 로직을 복제하지 말고 `private`만 떼어 내부 접근으로 올린다.

- [ ] **Step 3-c: 설정 화면에 마운트**

`Wattly/Views/SettingsView.swift`의 `SettingsBatterySection(...)` 다음 줄에 한 줄만 추가한다. `calibrationCoordinator` 프로퍼티와 `WattlyApp` 배선은 **Task 15에서 이미 끝났다**:

```swift
                SettingsBatteryCalibrationSection(
                    batteryControl: batteryControl, calibration: calibrationCoordinator)
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryCalibrationCopyTests test && xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build
```
Expected: 테스트 PASS + 빌드 성공

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Core/BatteryCalibration.swift Wattly/Views/Settings/SettingsBatteryCalibrationSection.swift Wattly/Views/SettingsView.swift WattlyTests/BatteryCalibrationTests.swift Wattly.xcodeproj && git commit -m "feat(battery): add the calibration settings card with inline helper update"
```

---

## Task 19: 팝오버 배터리 카드 한 줄 요약과 상호 배제

**Files:**
- Modify: `Wattly/Views/CardExpandRegion.swift`
- Modify: `Wattly/Views/PopoverContentView.swift`
- Modify: `Wattly/App/WattlyApp.swift`
- Test: `WattlyTests/BatteryCalibrationTests.swift`

**Interfaces:**
- Consumes: Task 9·13·18
- Produces: `BatteryCalibration.summaryLine(step:pause:remainingMinutes:locale:) -> String`

**설계 근거 (#12/#24):** 팝오버에는 한 줄 요약만 붙인다 — 8시간짜리 절차의 조작면은 설정 화면이 소유한다. 동시에 절차 중에는 Top Up·수동 방전 행을 비활성화해야 한다. 두 정책이 같은 CHIE를 다투면 참조 구현에서 관측된 "시작 직후 되돌아감"이 재현된다.

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/BatteryCalibrationTests.swift`의 `BatteryCalibrationCopyTests` 안에 추가:

```swift
    @Test func summaryLineNamesTheStepAndTheRemainingTime() {
        let line = BatteryCalibration.summaryLine(
            step: .dischargeToFloor, pause: nil, remainingMinutes: 420, locale: ko)
        #expect(line.contains("20%까지 방전"))
        #expect(line.contains("7"))     // 7시간
    }

    @Test func summaryLinePrefersThePauseReason() {
        let line = BatteryCalibration.summaryLine(
            step: .chargeToFull, pause: .needsAdapter, remainingMinutes: 100, locale: ko)
        #expect(line.contains("어댑터"))
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryCalibrationCopyTests test
```
Expected: 컴파일 실패 — `type 'BatteryCalibration' has no member 'summaryLine'`

- [ ] **Step 3-a: 요약 문구 (순수)**

`Wattly/Core/BatteryCalibration.swift`의 `blockerText` 아래에 추가:

```swift
    /// 팝오버 배터리 카드에 붙는 한 줄. 일시정지 중이면 단계 대신 사유를 말한다 —
    /// 멈춘 이유가 남은 시간보다 먼저 알아야 할 정보다.
    public static func summaryLine(
        step: CalibrationStep,
        pause: CalibrationPause?,
        remainingMinutes: Int,
        locale: Locale
    ) -> String {
        if let pause { return pauseText(pause, locale: locale) }
        return String(
            format: String(localized: "캘리브레이션: %@ · 남은 시간 약 %@", locale: locale),
            locale: locale,
            stepLabel(step, locale: locale),
            BatterySectionPresentation.formatDuration(minutes: remainingMinutes, locale: locale))
    }
```

- [ ] **Step 3-b: 팝오버 배선**

`Wattly/Views/PopoverContentView.swift`에 `let calibration: BatteryCalibrationCoordinator` 프로퍼티를 추가하고, 배터리 카드의 확장 영역을 그리는 `CardExpandRegion` 호출에 그대로 넘긴다. `WattlyApp`의 `PopoverContentView(...)` 호출에도 `calibration: calibrationCoordinator`를 추가한다.

`Wattly/Views/CardExpandRegion.swift`:

1. `var calibration: BatteryCalibrationCoordinator? = nil` 프로퍼티를 추가한다(기본값 `nil`이라 다른 호출부는 그대로 컴파일된다).

2. 배터리 확장 영역에서 Top Up 행 **바로 위**에 요약 줄을 넣는다:

```swift
                if let calibration, let run = calibration.run {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Tokens.statusOrange)
                        Text(verbatim: BatteryCalibration.summaryLine(
                            step: run.step,
                            pause: run.pause,
                            remainingMinutes: calibration.estimatedRemainingMinutes ?? 0,
                            locale: locale))
                            .font(WattlyFont.at(10.5, weight: .medium))
                            .foregroundStyle(t.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
```

3. 두 버튼을 절차 중에 잠근다. 같은 CHIE를 다투는 정책이 둘이면 참조 구현에서 관측된 "시작 직후 되돌아감"이 재현되고, Task 12의 클라이언트 길목이 상태를 지켜 주더라도 **아무 일도 일어나지 않는 버튼**은 그 자체로 버그다.

   - **수동 방전 버튼**(`batteryDischargeRow`)에는 이미 `.disabled(!isDischarging && !canStartDischarge)`가 있다([CardExpandRegion.swift:520](Wattly/Views/CardExpandRegion.swift:520)). 조건을 확장한다:
     ```swift
     .disabled(calibration?.isRunning == true || (!isDischarging && !canStartDischarge))
     ```
   - **Top Up 버튼**(`batteryTopUpRow`, [CardExpandRegion.swift:377](Wattly/Views/CardExpandRegion.swift:377)~433)에는 `.disabled(...)`가 **아예 없다** — 지금은 무조건 눌리는 토글이다. `.buttonStyle(.plain)` 다음에 새로 붙인다:
     ```swift
     .disabled(calibration?.isRunning == true)
     ```

- [ ] **Step 4: 테스트 통과 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/BatteryCalibrationCopyTests test && xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO build
```
Expected: 테스트 PASS + 빌드 성공

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Core/BatteryCalibration.swift Wattly/Views/CardExpandRegion.swift Wattly/Views/PopoverContentView.swift Wattly/App/WattlyApp.swift WattlyTests/BatteryCalibrationTests.swift && git commit -m "feat(battery): show a calibration summary in the popover and lock competing actions"
```

---

## Task 20: 30개 로케일 번역 · 문서 · 전체 그린

**Files:**
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Modify: `docs/features/battery-management/11-calibration-mode.md`
- Test: `WattlyTests/LocalizationTests.swift`

**Interfaces:**
- Consumes: Task 1~19 전부
- Produces: 신규 문자열 전체의 30개 로케일 번역, 구현 상태를 반영한 기능 문서

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/LocalizationTests.swift`의 `stringCatalogTranslationsAcrossLocales` 안, 또는 새 `@Test`로:

```swift
    @Test func calibrationStringsAreTranslated() {
        #expect(String(localized: "배터리 캘리브레이션", locale: Locale(identifier: "en"))
                == "Battery Calibration")
        #expect(String(localized: "잔량 표시 보정 완료", locale: Locale(identifier: "en"))
                != "잔량 표시 보정 완료")
        #expect(String(localized: "캘리브레이션 시작", locale: Locale(identifier: "ja"))
                != "캘리브레이션 시작")
        #expect(String(localized: "20%까지 방전", locale: Locale(identifier: "de"))
                != "20%까지 방전")
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/LocalizationTests test
```
Expected: FAIL — 번역이 없어 키(한국어)가 그대로 반환됨

- [ ] **Step 3-a: 신규 키 목록 확인**

아래가 이 계획이 도입하는 신규 키 전체다. `en` 값은 확정안이고, 나머지 28개 로케일은 같은 원칙으로 옮긴다. 먼저 실제 diff와 대조해 빠진 키가 없는지 확인한다:

```bash
git diff main --unified=0 -- Wattly/ | grep -oE 'String\(localized: "[^"]*"' | sed 's/String(localized: "//; s/"$//' | sort -u
git diff main --unified=0 -- Wattly/Views/Settings/SettingsBatteryCalibrationSection.swift | grep -oE '(Text|Button|SettingsSection|SettingsRowTitle)\("[^"]*"' | sed 's/.*("//; s/"$//' | sort -u
```

| ko (키) | en |
|---|---|
| 고급 · 배터리 진단 | Advanced · Battery Diagnostics |
| 배터리 캘리브레이션 | Battery Calibration |
| 배터리 셀을 회복시키는 기능이 아니라, 잔량 표시의 추정 오차를 보정하는 장시간 충·방전 절차입니다. | This does not restore battery cells. It is a long charge/discharge procedure that recalibrates the reported charge level. |
| 절차: 100% 충전 → 20% 방전 → 10분 대기 → 100% 재충전 → 60분 대기 → 원래 설정 복원 | Steps: charge to 100% → discharge to 20% → wait 10 min → recharge to 100% → wait 60 min → restore your settings |
| 예상 남은 시간 약 %@ | About %@ remaining |
| macOS는 충전 제한을 쓰는 중에도 주기적으로 100%까지 충전해 잔량 추정을 유지합니다. macOS 26.4 이상의 기본 충전 제한을 쓰신다면 이 절차는 대개 불필요합니다. | macOS occasionally charges to 100% even while a charge limit is set, to keep its own estimate accurate. If you use the built-in charge limit on macOS 26.4 or later, this procedure is usually unnecessary. |
| 캘리브레이션 시작 | Start Calibration |
| 중지하고 원래 설정으로 되돌리기 | Stop and Restore My Settings |
| 도우미 업데이트에 실패했습니다 | Helper update failed |
| 최근에 캘리브레이션을 실행했습니다 | You calibrated recently |
| 그래도 실행 | Run Anyway |
| 정상적인 배터리에 반복 실행은 권장하지 않습니다. 90일 또는 40 사이클마다 한 번이면 충분합니다. | Repeating this on a healthy battery is not recommended. Once every 90 days or 40 cycles is enough. |
| 시작 준비 | Getting ready |
| 100%까지 충전 | Charge to 100% |
| 20%까지 방전 | Discharge to 20% |
| 저잔량 안정화 (10분) | Settle at low charge (10 min) |
| 다시 100%까지 충전 | Charge to 100% again |
| 최종 안정화 (60분) | Final settle (60 min) |
| 원래 설정으로 복원 | Restore your settings |
| 캘리브레이션: %@ · 남은 시간 약 %@ | Calibration: %@ · about %@ remaining |
| 일시정지: 전원 어댑터를 다시 연결해 주세요 | Paused: reconnect the power adapter |
| 일시정지: 발열 보호 작동 중 (식으면 자동으로 이어집니다) | Paused: heat protection is active (resumes once it cools) |
| 일시정지: 도우미에 연결되지 않았습니다 | Paused: not connected to the helper |
| 일시정지: 잠자기 상태입니다 (뚜껑을 열면 이어집니다) | Paused: the Mac is asleep (resumes when you open the lid) |
| 일시정지: 충전이 시작되지 않습니다. "최적화된 배터리 충전"을 꺼 주세요 | Paused: charging will not start. Turn off Optimized Battery Charging |
| 도우미가 설치되어 있지 않습니다. | The helper is not installed. |
| 설치된 도우미가 캘리브레이션을 지원하지 않습니다. 업데이트가 필요합니다. | The installed helper does not support calibration. It needs an update. |
| 이 Mac은 강제 방전을 지원하지 않아 캘리브레이션을 할 수 없습니다. | This Mac cannot force-discharge, so calibration is not possible. |
| 전원 어댑터를 연결해 주세요. | Connect the power adapter. |
| 발열 보호가 작동 중입니다. 배터리가 식은 뒤에 시작해 주세요. | Heat protection is active. Start once the battery has cooled. |
| 한 번만 완충 또는 수동 방전이 진행 중입니다. 먼저 끝내 주세요. | Top Up or manual discharge is running. Finish it first. |
| 시스템 설정 › 배터리에서 "최적화된 배터리 충전"을 껐습니다. | I turned off Optimized Battery Charging in System Settings › Battery. |
| 약 10시간이 걸리며, 방전 구간 약 7시간 동안은 뚜껑을 열어 두어야 합니다. 화면은 꺼져도 됩니다. | This takes about 10 hours, and the lid must stay open for the roughly 7-hour discharge. The display may sleep. |
| 배터리 캘리브레이션 중지됨 | Battery Calibration Stopped |
| 배터리 캘리브레이션 자동 취소됨 | Battery Calibration Cancelled |
| 배터리 캘리브레이션 실패 | Battery Calibration Failed |
| 원래 충전 설정으로 되돌렸습니다. | Your charging settings have been restored. |
| 12시간 동안 진행이 없어 자동으로 취소하고 원래 충전 설정으로 되돌렸습니다. | Nothing progressed for 12 hours, so it was cancelled and your charging settings were restored. |
| 한 단계가 제한 시간을 넘겼습니다. | A step exceeded its time limit. |
| 일시정지가 2시간을 넘겼습니다. | It stayed paused for more than 2 hours. |
| 도우미 연결이 끊겼습니다. | The helper connection was lost. |
| 이 Mac은 강제 방전을 지원하지 않습니다. | This Mac does not support force discharge. |
| 알 수 없는 이유로 중단됐습니다. | It stopped for an unknown reason. |
| 배터리 캘리브레이션에 조치가 필요합니다 | Battery Calibration Needs You |
| 전원 어댑터를 다시 연결하면 이어서 진행합니다. | Reconnect the power adapter and it will continue. |
| 충전이 시작되지 않습니다. 시스템 설정 › 배터리에서 "최적화된 배터리 충전"을 꺼 주세요. | Charging will not start. Turn off Optimized Battery Charging in System Settings › Battery. |
| 도우미 연결이 끊겼습니다. Wattly 설정에서 다시 연결해 주세요. | The helper connection was lost. Reconnect it in Wattly settings. |
| 배터리 캘리브레이션 진행 중 | Battery calibration in progress |
| 캘리브레이션: %lld%%까지 충전 중 | Calibration: charging to %lld%% |
| 캘리브레이션: %lld%%까지 방전 중 | Calibration: discharging to %lld%% |
| 캘리브레이션: %lld%% 유지 중 | Calibration: holding at %lld%% |

`"이 Mac은 충전 제어를 지원하지 않습니다."`와 `"확인"` / `"취소"` / `"도우미 업데이트"`는 카탈로그에 이미 있다 — 새로 추가하지 말고 그대로 재사용한다.

**어조 기준점 (ja · de).** 나머지 26개 로케일은 이 두 언어가 잡아 놓은 용어와 어조를 따른다. 특히 "회복/수명 연장" 회피가 번역 압력에 가장 쉽게 무너지는 지점이므로, 핵심 문장 네 개는 확정안을 둔다:

| ko | ja | de |
|---|---|---|
| 배터리 캘리브레이션 | バッテリーキャリブレーション | Batteriekalibrierung |
| 잔량 표시 보정 완료 | 残量表示の補正が完了しました | Ladeanzeige neu kalibriert |
| 배터리 셀을 회복시키는 기능이 아니라, 잔량 표시의 추정 오차를 보정하는 장시간 충·방전 절차입니다. | バッテリーセルを回復させる機能ではなく、残量表示の推定誤差を補正する長時間の充放電手順です。 | Dies stellt keine Akkuzellen wieder her. Es ist ein langer Lade-/Entladevorgang, der die angezeigte Ladung neu kalibriert. |
| 일시정지: 충전이 시작되지 않습니다. "최적화된 배터리 충전"을 꺼 주세요 | 一時停止: 充電が開始されません。「バッテリー充電の最適化」をオフにしてください | Pausiert: Der Ladevorgang startet nicht. Deaktiviere „Optimiertes Laden“ |

각 언어의 `"최적화된 배터리 충전"`은 위처럼 그 언어의 **실제 macOS 시스템 설정 문구**를 쓴다.

- [ ] **Step 3-a2: (참고) 추출 명령**

```bash
git diff main --unified=0 -- Wattly/ | grep -o 'String(localized: "[^"]*"' | sed 's/String(localized: "//; s/"$//' | sort -u > /tmp/calibration-keys.txt && wc -l /tmp/calibration-keys.txt && cat /tmp/calibration-keys.txt
```

이 목록에 더해 SwiftUI `Text("...")` / `LocalizedStringKey` 리터럴로 들어간 카드 문구도 포함해야 한다:

```bash
git diff main --unified=0 -- Wattly/Views/Settings/SettingsBatteryCalibrationSection.swift | grep -oE '(Text|Button|SettingsSection|SettingsRowTitle)\("[^"]*"' | sed 's/.*("//; s/"$//' | sort -u
```

- [ ] **Step 3-b: `Localizable.xcstrings`에 30개 로케일 채우기**

기존 항목과 동일한 구조를 따른다 (`"extractionState": "manual"`, 각 로케일이 `{"stringUnit": {"state": "translated", "value": "..."}}`). 로케일 코드는 정확히 이 30개다:

```
ar cs da de el en es fi fr he hi hu id it ja ko nb nl pl pt-BR pt-PT ro ru sv th tr uk vi zh-Hans zh-Hant
```

삽입은 손으로 JSON을 편집하지 말고 스크립트로 한다(항목 순서·이스케이프가 깨지기 쉽다):

```bash
python3 - <<'PY'
import json, collections
path = "Wattly/Resources/Localizable.xcstrings"
with open(path) as f:
    catalog = json.load(f, object_pairs_hook=collections.OrderedDict)

# key -> {locale: value}. 아래 표를 신규 키 전체로 채운다.
NEW = {
    "배터리 캘리브레이션": {"en": "Battery Calibration", "ja": "バッテリーキャリブレーション"},
    # ... 나머지 키
}

for key, translations in NEW.items():
    entry = catalog["strings"].setdefault(key, collections.OrderedDict())
    entry["extractionState"] = "manual"
    locs = entry.setdefault("localizations", collections.OrderedDict())
    for locale, value in translations.items():
        locs[locale] = {"stringUnit": {"state": "translated", "value": value}}

with open(path, "w") as f:
    json.dump(catalog, f, ensure_ascii=False, indent=2)
    f.write("\n")
print("keys:", len(catalog["strings"]))
PY
```

번역 시 지켜야 할 것:

- **"회복" / "수명 연장"에 해당하는 표현을 어떤 언어에서도 쓰지 않는다.** 이 기능은 셀을 회복시키지 않는다. 영어는 "recalibrates the reported charge level", 독일어는 "Ladeanzeige neu kalibriert" 계열로 간다.
- `%@` / `%lld` 자리표시자의 **개수와 순서**를 원문과 동일하게 유지한다.
- `"최적화된 배터리 충전"`은 각 언어의 **실제 macOS 시스템 설정 문구**를 쓴다 (en: "Optimized Battery Charging", ja: 「バッテリー充電の最適化」).

- [ ] **Step 3-c: 기능 문서 갱신**

`docs/features/battery-management/11-calibration-mode.md`를 구현된 사실로 교체한다:

- 상태: `기능 정의 초안` → `구현됨 (2026-08-30)`
- "최소 기능 범위"의 7단계를 실제 단계 이름(`preflight`/`chargeToFull`/`dischargeToFloor`/`soakLow`/`rechargeToFull`/`soakFinal`/`restoring`)과 각 단계의 완료 조건·타임아웃으로 대체
- "미결정 사항" 4개를 전부 해소된 결정으로 대체:
  - 방전 하한 = **20%** (CHIE가 11% 부근에서 듣지 않는다는 참조 구현 보고 위의 안전 마진)
  - 대기시간 = soakLow 10분 / soakFinal 60분, 단계 타임아웃 충전 6h · 방전 12h · 일시정지 예산 2h · 무진행 12h
  - 증상 없이도 실행 허용, 90일 **또는** 40 사이클 쿨다운 경고
  - macOS의 주기적 100% 보정 충전과 충돌하지 않음(Apple 지원문서 102338). 단 **"최적화된 배터리 충전"이 켜져 있으면 절차가 시작되지 않는다** — preflight 차단 + 런타임 정체 감지로 처리
- 실기 검증 요약 절을 추가한다: SoC 출처(raw 98.99% 천장) · 어댑터 판정(`AdapterDetails.Watts`) · 방전 중 sleep 정지 · 완충 테이퍼 절벽 · 용량 재추정 미검출(+35 mAh vs 자연 변동폭 86 mAh)

- [ ] **Step 4: 전체 테스트 그린 확인**

```bash
/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml && xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **` — 기존 320개 + 신규 약 60개가 모두 통과

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Resources/Localizable.xcstrings docs/features/battery-management/11-calibration-mode.md WattlyTests/LocalizationTests.swift && git commit -m "feat(battery): localize calibration copy and document the shipped procedure"
```

---

## 실기 검증 매트릭스 (구현 후, 별도 세션)

단위 테스트로는 닿지 않는 항목들이다. 대부분은 설계 단계에서 이미 실기로 확인했지만, **구현이 그 사실을 실제로 구현했는지**는 다시 봐야 한다.

| # | 확인할 것 | 방법 | 근거 |
|---|---|---|---|
| 1 | 절차 완주 (약 10.5시간) | 100% → 20% → 100% 전 구간 | `soakFinal` 60분 완주는 설계 검증 때 34분에서 중단돼 **미확인으로 남아 있다** |
| 2 | 방전 중 clamshell sleep → 재개 | 방전 단계에서 뚜껑 10분 덮었다 열기 | `paused(systemSleep)` 표시 + 정체 타이머 리셋 + 20%까지 계속 내려가는지 |
| 3 | 어댑터 분리 → 재연결 | 충전 단계에서 뽑았다 꽂기 | 데몬이 캘리브레이션을 해제하지 않고 `paused(needsAdapter)`로 대기하는지 |
| 4 | "최적화된 배터리 충전" 차단 | 켠 채로 시작 시도 | preflight 확인 토글이 막는지, 켜진 채 진행 시 10분 뒤 `externalChargeBlock`이 뜨는지 |
| 5 | 앱 강제 종료 → 재실행 | 방전 단계에서 앱 kill | 데몬은 하한 도달 후 홀드, 재실행 시 저장 상태로 재개 |
| 6 | 고아 상태 정리 | 앱 kill 후 저장 키 삭제 → 재실행 | 데몬만 `calibrationActive`인 상태가 즉시 원복되는지 |
| 7 | 헬퍼 `SIGKILL` | 방전 중 `kill -9` | KeepAlive 복원 후 정책 파일에서 캘리브레이션이 살아나는지 |
| 8 | 구버전 헬퍼 | 이전 헬퍼 설치 상태 | 카드가 `helperTooOld`로 막고, 인라인 업데이트 버튼이 실제로 교체하는지 |
| 9 | 스케줄 충돌 | 절차 중 발화하는 스케줄 등록 | 발화하지 않고 이력에 "배터리 캘리브레이션 진행 중"이 남는지 |
| 10 | 알림 3종 | 완료·조치필요·실패 | 시작 버튼에서 권한을 먼저 받는지, 절차 중 "Top Up 만료" 알림이 뜨지 않는지 |

로깅은 15초 간격 python3 스크립트를 쓴다 — `awk`는 64비트 정밀도 손실로 `InstantAmperage`의 부호가 깨진다. 기록 항목: `CurrentCapacity`, `AppleRawCurrentCapacity/MaxCapacity`, `IsCharging`, `ExternalConnected`, `AdapterDetails.Watts`, `ChargingCurrent`, `Temperature`.
