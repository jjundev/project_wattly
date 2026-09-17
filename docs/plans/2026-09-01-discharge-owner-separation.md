# 자동/수동 방전 주인 판별 분리 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 자동 방전과 수동 방전이 엔진에서는 분리돼 있는데 상태 보고에서 하나로 접혀 UI가 자동 방전을 "수동 방전 진행 중"으로 표시하고 그 위의 "방전 중지" 버튼이 아무것도 멈추지 못하는 문제를 없앤다.

**Architecture:** 판별을 `BatterySectionPresentation`의 순수 함수 한 곳(`dischargeOwner`)으로 모으고, 뷰 4곳이 각자 적던 조건을 그 함수로 교체한다. 판별 신호는 이미 도우미가 보내고 있는 `detailReason.kind`(`.dischargingManual` vs `.dischargingToTarget`)와 `desiredConfiguration.manualDischargeActive`이므로 IPC 계약 변경도 도우미 재설치도 필요 없다. 여기에 두 방전의 동시 활성을 막는 불변식을 `BatteryControlConfiguration.normalized`에 박고, UI에서 상호배제 게이트를 걸며, 죽어 있던 방전 완료 알림을 배선한다.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Test` / `#expect`), macOS, IOKit/SMC(간접), String Catalog(`.xcstrings`).

## Global Constraints

- 작업 위치: `/Users/hyunjun_macbook_pro/Documents/Project/project_wattly` (branch `main`에서 분기).
- **신규 소스 파일을 만들지 않는다.** 모든 변경은 기존 파일 편집이다. `Wattly.xcodeproj/project.pbxproj`가 git 추적 대상이라 `xcodegen generate`는 추적 파일을 변경하므로 실행하지 않는다.
- 테스트 명령은 항상 `xcodegen` 없이: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS'`. 시작 시점 baseline은 green(exit 0, 약 30초)이다.
- 도우미(`/Library/PrivilegedHelperTools/dev.jjundev.WattlyFanDaemon`)는 앱 업데이트로 교체되지 않는다. `FanControlShared/`는 앱과 데몬 양쪽 타깃에 **소스 폴더로** 포함되므로(`project.yml:38,76`), 그 변경은 앱 측에서 즉시, 설치된 데몬 측에서는 사용자가 재설치할 때 유효해진다.
- 문자열은 `Wattly/Resources/Localizable.xcstrings`에 넣는다. `sourceLanguage: ko`, 로케일 30개(`ar,cs,da,de,el,en,es,fi,fr,he,hi,hu,id,it,ja,ko,nb,nl,pl,pt-BR,pt-PT,ro,ru,sv,th,tr,uk,vi,zh-Hans,zh-Hant`), 기존 592개 키가 전부 30개 로케일 완비 + `extractionState: "manual"`. **신규 문자열도 30개 로케일을 전부 채운다.**
- 기존 수동 방전 UI가 지금 보여 주는 것은 그대로 둔다. 이번 변경으로 달라지는 것은 **자동 방전일 때의 표시**와 **상호배제 게이트**뿐이다.
- 커밋 메시지는 저장소 관례(`feat(scope):` / `fix(scope):` / `refactor(scope):`)를 따르고 다음 줄로 끝낸다:
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`
- Task 1~8은 한 PR(앱), Task 9는 별도 PR(도우미)이다. Task 9는 설치된 도우미가 교체되기 전까지 동작에 영향이 없다.

---

## File Structure

| 파일 | 이번 변경에서의 책임 |
|---|---|
| `Wattly/Core/BatterySectionPresentation.swift` | **판별의 유일한 출처.** `DischargeOwner`, `dischargeOwner`, `isForcedDischargeRunning`, 자동 방전 사유가 추가된 `manualDischargeDisabledReason`, 자동 토글 게이트 2종, owner별 `forcedDischargeText` |
| `FanControlShared/BatteryControlProtocol.swift` | 설정 계약의 불변식 — `manualDischargeActive ⇒ !autoDischargeEnabled` |
| `FanControlShared/BatteryControlPolicy.swift` | `shouldReapply`가 활동 보존 뒤 불변식을 다시 적용 |
| `Wattly/Control/BatteryControlClient.swift` | 전송 길목(`revivedConfiguration`)이 정규화된 설정을 내보냄 |
| `Wattly/Views/Settings/SettingsBatteryDischargeSection.swift` | 설정 방전 카드 배선 — owner 판별, 상호배제 게이트, 자동 방전 진행 배지 |
| `Wattly/Views/CardExpandRegion.swift` | 팝오버 배선 3곳 — 전원 소스 문구, Top Up 상호배제, 수동 방전 행 |
| `Wattly/Core/BatteryNotificationManager.swift` | `BatteryDischargeTransitionDetector` 재작성(목표 도달만 잡음) + 스케줄 알림에 note 추가 |
| `Wattly/Views/BatteryControlBridge.swift` | 방전 완료 알림 배선 |
| `Wattly/Core/BatteryScheduleCoordinator.swift` | `pauseChargingLimitPercentage` 상수 + `autoDischargeWarning` 순수 함수 + 알림 note 전달 |
| `Wattly/Views/Settings/ScheduleEditorSheet.swift` | "충전 일시 정지" 선택 시 자동 방전 경고 |
| `Wattly/Resources/Localizable.xcstrings` | 신규 문자열 5개 × 30 로케일 |
| `FanControlShared/BatteryControlEngine.swift` | (별도 PR) `statusForCurrentBelief`/`reassertHardwareState`의 우선순위를 `update`에 맞춤 |

**변경하지 않는 곳** (자동 방전에서도 참인 사실이라 지금 코드가 이미 옳다 — 리뷰어가 누락으로 오인하지 않도록 명시):
- `Wattly/Views/MetricCardView.swift:225` `isDischarging` — 주황 스파크라인. "지금 배터리에서 전류가 빠진다"는 물리적 사실이고 자동 방전에서도 참이다.
- `Wattly/Views/Settings/SettingsBatterySection.swift:234-235` 폴링 게이트 — `manualActive || activity == .discharging`은 이미 "수동 세션 또는 임의의 강제 방전"이라 두 주인 모두에 대해 옳다.
- `BatterySectionPresentation.shouldShowPowerSupplySection` / `shouldShowBatteryControlRows` — 자동 방전 중에도 어댑터가 연결돼 있어 다른 조건으로 이미 참이다.
- `Wattly/Core/CardPresentation.swift:265` `powerSourceText`의 `.activeDischarge` 분기 — 유일한 호출자(`CardExpandRegion.swift:272`)가 `!isDischarging`일 때만 부르므로 방전 중에는 도달하지 않는다.

---

### Task 1: 강제 방전 주인 판별 (순수 함수)

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift` (파일 끝, `shouldShowBatteryControlSection` 뒤 · 닫는 `}` 앞)
- Test: `WattlyTests/BatterySectionPresentationTests.swift` (파일 끝, 닫는 `}` 앞)

**Interfaces:**
- Consumes: `BatteryControlStatusReason.Kind`, `BatteryControlActivity` (둘 다 `FanControlShared`, 이미 존재)
- Produces:
  - `BatterySectionPresentation.DischargeOwner` — `case idle, manual, automatic` (`Equatable`)
  - `BatterySectionPresentation.dischargeOwner(manualDischargeActive: Bool?, reasonKind: BatteryControlStatusReason.Kind?, activity: BatteryControlActivity?) -> DischargeOwner`
  - `BatterySectionPresentation.isForcedDischargeRunning(reasonKind: BatteryControlStatusReason.Kind?, activity: BatteryControlActivity?) -> Bool`
  - Task 2, 4, 5가 이 셋을 쓴다.

> 케이스 이름을 `none`이 아니라 `idle`로 둔 이유: `DischargeOwner.none`은 `Optional.none`과 `== .none` 자리에서 충돌해 컴파일러가 잘못된 쪽을 고를 수 있다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`WattlyTests/BatterySectionPresentationTests.swift`의 마지막 `}` **앞에** 추가:

```swift
    // MARK: - 강제 방전의 주인

    @Test func manualSessionOwnsDischargeEvenWhileHoldingAtTarget() {
        // 목표 도달 후: 전류는 멈췄지만 세션은 열려 있다. 이 구간에도 "방전 중지" 버튼이
        // 남아 있어야 하므로 `.manual`이어야 한다.
        #expect(BatterySectionPresentation.dischargeOwner(
            manualDischargeActive: true,
            reasonKind: .inhibitedAtLimit,
            activity: .holdingAtLimit) == .manual)
    }

    @Test func autoDischargeIsNotReportedAsManual() {
        #expect(BatterySectionPresentation.dischargeOwner(
            manualDischargeActive: false,
            reasonKind: .dischargingToTarget,
            activity: .discharging) == .automatic)
    }

    @Test func legacyHelperWithoutDesiredConfigurationFallsBackToReason() {
        #expect(BatterySectionPresentation.dischargeOwner(
            manualDischargeActive: nil,
            reasonKind: .dischargingManual,
            activity: .discharging) == .manual)
        #expect(BatterySectionPresentation.dischargeOwner(
            manualDischargeActive: nil,
            reasonKind: .dischargingToTarget,
            activity: .discharging) == .automatic)
        // reason조차 없는 아주 오래된 도우미에는 두 방전을 가를 신호가 아예 없다.
        // 예전 동작(방전 = 수동)을 그대로 둔다.
        #expect(BatterySectionPresentation.dischargeOwner(
            manualDischargeActive: nil,
            reasonKind: nil,
            activity: .discharging) == .manual)
    }

    @Test func idleStateHasNoDischargeOwner() {
        #expect(BatterySectionPresentation.dischargeOwner(
            manualDischargeActive: false,
            reasonKind: .inhibitedAtLimit,
            activity: .holdingAtLimit) == .idle)
        #expect(BatterySectionPresentation.dischargeOwner(
            manualDischargeActive: nil,
            reasonKind: nil,
            activity: nil) == .idle)
    }

    @Test func forcedDischargeRunningIsTrueForBothOwnersAndFalseAtHold() {
        #expect(BatterySectionPresentation.isForcedDischargeRunning(
            reasonKind: .dischargingManual, activity: .discharging))
        #expect(BatterySectionPresentation.isForcedDischargeRunning(
            reasonKind: .dischargingToTarget, activity: .discharging))
        // 수동 방전이 목표에 도달해 홀드로 넘어가면 전류가 멈춘다.
        #expect(!BatterySectionPresentation.isForcedDischargeRunning(
            reasonKind: .inhibitedAtLimit, activity: .holdingAtLimit))
        #expect(!BatterySectionPresentation.isForcedDischargeRunning(
            reasonKind: nil, activity: nil))
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatterySectionPresentationTests 2>&1 | tail -20
```
Expected: 컴파일 실패 — `type 'BatterySectionPresentation' has no member 'dischargeOwner'`

- [ ] **Step 3: 최소 구현을 넣는다**

`Wattly/Core/BatterySectionPresentation.swift`의 마지막 `}` **앞에** 추가:

```swift
    // MARK: - 강제 방전의 주인

    /// 강제 방전(CHIE)을 지금 누가 소유하고 있는지.
    ///
    /// 엔진은 자동 방전과 수동 방전을 별개 분기로 돌리지만, 둘 다 `activity == .discharging`
    /// 하나로 접혀서 나온다(`BatteryControlEngine`의 `activity: .inferred(from: reason)`).
    /// 뷰가 그것만 보고 "수동 방전 중"이라고 읽으면 자동 방전이 수동 방전으로 표시되고,
    /// 그 위에 뜬 "방전 중지"는 자동 방전 옵트인을 끄지 못해 눌러도 아무 일이 없는 버튼이
    /// 된다. 판별은 여기 한 곳에서만 한다 — 예전에는 뷰 네 곳이 조건을 각자 적고 있었다.
    enum DischargeOwner: Equatable {
        /// 강제 방전이 걸려 있지 않다.
        case idle
        /// 사용자가 연 수동 방전 세션. 목표에 도달해 전류가 멈춘 뒤에도 사용자가 중지하기
        /// 전까지는 계속 `.manual`이다 — 그 구간에 "방전 중지" 버튼이 남아 있어야 한다.
        case manual
        /// 충전 한도 정책이 스스로 돌리는 자동 방전.
        case automatic
    }

    /// `manualDischargeActive`에는 `status.desiredConfiguration?.manualDischargeActive`를 그대로
    /// 넘긴다. `nil`은 `desiredConfiguration`을 보내지 않는 구버전 도우미이며 "미지원"이 아니라
    /// "모름"이다 — 현행 도우미는 모든 응답에 이 필드를 채운다
    /// (`BatteryControlCoordinator`의 `sample`/`publish`).
    static func dischargeOwner(
        manualDischargeActive: Bool?,
        reasonKind: BatteryControlStatusReason.Kind?,
        activity: BatteryControlActivity?
    ) -> DischargeOwner {
        if manualDischargeActive == true { return .manual }
        if reasonKind == .dischargingManual { return .manual }
        if reasonKind == .dischargingToTarget { return .automatic }
        guard manualDischargeActive == nil else { return .idle }
        // 여기까지 왔다는 것은 `desiredConfiguration`도 알아볼 수 있는 reason도 없다는 뜻이다.
        // 그 도우미에는 두 방전을 가를 신호 자체가 없으므로 예전 동작을 유지한다.
        return activity == .discharging ? .manual : .idle
    }

    /// 지금 실제로 배터리에서 전류가 빠지고 있는지 — 주인이 누구든 참이다. "물리적으로 방전
    /// 중"만 알면 되는 자리(주황 스파크라인, 전원 공급 섹션 노출)에 쓴다. 수동 방전이 목표에
    /// 도달해 홀드로 넘어가면 거짓이 된다.
    static func isForcedDischargeRunning(
        reasonKind: BatteryControlStatusReason.Kind?,
        activity: BatteryControlActivity?
    ) -> Bool {
        reasonKind == .dischargingManual
            || reasonKind == .dischargingToTarget
            || activity == .discharging
    }
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatterySectionPresentationTests 2>&1 | tail -20
```
Expected: exit 0, 실패 0

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Core/BatterySectionPresentation.swift WattlyTests/BatterySectionPresentationTests.swift
git commit -m "$(cat <<'MSG'
feat(battery): 강제 방전의 주인을 판별하는 순수 함수를 추가한다

자동 방전과 수동 방전이 같은 activity 값으로 접혀 나오는 탓에 뷰 네 곳이
자동 방전을 수동 방전으로 읽고 있었다. 판별을 한 곳으로 모은다.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

### Task 2: 자동 방전 사유와 자동 토글 게이트 (순수 함수)

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift:563-601` (`manualDischargeDisabledReason`, `isManualDischargeActionable`) + Task 1이 추가한 블록 뒤
- Test: `WattlyTests/BatterySectionPresentationTests.swift`

**Interfaces:**
- Consumes: Task 1의 `DischargeOwner`; 기존 `limitPickerDisabledReason(isLimitOn:) -> String?`
- Produces:
  - `manualDischargeDisabledReason(isPluggedIn:currentSoC:targetSoC:isHardwareSupported:isDischargeHardwareSupported:isToggleEnabled:isAutoDischargeEnabled:locale:) -> String?` — `isAutoDischargeEnabled: Bool = false` 인자가 `isToggleEnabled`와 `locale` **사이에** 추가된다(기본값이 있어 기존 호출부 4곳은 그대로 컴파일된다)
  - `isManualDischargeActionable(...)` — 같은 인자가 같은 위치에 추가된다
  - `isAutoDischargeToggleEnabled(isLimitOn: Bool, dischargeOwner: DischargeOwner) -> Bool`
  - `autoDischargeToggleDisabledReason(isLimitOn: Bool, dischargeOwner: DischargeOwner, locale: Locale) -> String?`
  - Task 4, 5가 이들을 쓴다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`WattlyTests/BatterySectionPresentationTests.swift`의 마지막 `}` **앞에** 추가:

```swift
    // MARK: - 자동/수동 방전 상호배제 사유

    @Test func autoDischargeBlocksManualDischargeWithItsOwnReason() {
        let reason = BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true,
            currentSoC: 95,
            targetSoC: 80,
            isAutoDischargeEnabled: true,
            locale: ko)
        #expect(reason == "자동 방전이 켜져 있어 수동 방전을 사용할 수 없습니다.")
        #expect(!BatterySectionPresentation.isManualDischargeActionable(
            isPluggedIn: true,
            currentSoC: 95,
            targetSoC: 80,
            isAutoDischargeEnabled: true))
    }

    @Test func autoDischargeReasonOutranksAdapterAndSoCReasons() {
        // 어댑터도 빠져 있고 잔량도 목표 이하지만, 먼저 고쳐야 할 것은 자동 방전이다.
        // 어댑터를 꽂아도 잔량을 낮춰도 수동 방전은 시작되지 않는다.
        let reason = BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: false,
            currentSoC: 70,
            targetSoC: 80,
            isAutoDischargeEnabled: true,
            locale: ko)
        #expect(reason == "자동 방전이 켜져 있어 수동 방전을 사용할 수 없습니다.")
    }

    @Test func hardwareReasonsStillOutrankAutoDischarge() {
        let reason = BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true,
            currentSoC: 95,
            targetSoC: 80,
            isDischargeHardwareSupported: false,
            isAutoDischargeEnabled: true,
            locale: ko)
        #expect(reason == "이 Mac은 강제 방전을 지원하지 않습니다.")
    }

    @Test func autoDischargeOffLeavesTheExistingReasonsUntouched() {
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: false,
            currentSoC: 95,
            targetSoC: 80,
            locale: ko) == "전원 어댑터가 연결되어 있어야 방전할 수 있습니다.")
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true,
            currentSoC: 95,
            targetSoC: 80,
            locale: ko) == nil)
    }

    @Test func autoDischargeToggleIsLockedWhileAManualSessionIsOpen() {
        #expect(!BatterySectionPresentation.isAutoDischargeToggleEnabled(
            isLimitOn: true, dischargeOwner: .manual))
        #expect(BatterySectionPresentation.autoDischargeToggleDisabledReason(
            isLimitOn: true, dischargeOwner: .manual, locale: ko)
            == "수동 방전이 진행 중입니다.")
    }

    @Test func autoDischargeToggleKeepsTheChargeLimitGate() {
        #expect(!BatterySectionPresentation.isAutoDischargeToggleEnabled(
            isLimitOn: false, dischargeOwner: .idle))
        #expect(BatterySectionPresentation.autoDischargeToggleDisabledReason(
            isLimitOn: false, dischargeOwner: .idle, locale: ko)
            == "충전 제한을 켜면 한도를 조절할 수 있습니다.")
        // 자동 방전이 돌고 있는 것은 토글을 잠글 이유가 아니다 — 그게 유일한 끄는 방법이다.
        #expect(BatterySectionPresentation.isAutoDischargeToggleEnabled(
            isLimitOn: true, dischargeOwner: .automatic))
        #expect(BatterySectionPresentation.autoDischargeToggleDisabledReason(
            isLimitOn: true, dischargeOwner: .automatic, locale: ko) == nil)
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatterySectionPresentationTests 2>&1 | tail -20
```
Expected: 컴파일 실패 — `extra argument 'isAutoDischargeEnabled' in call`

- [ ] **Step 3: 구현한다**

3-1. `Wattly/Core/BatterySectionPresentation.swift:563-585`의 `manualDischargeDisabledReason`을 아래로 교체 (인자 하나 추가 + `guard` 하나 추가):

```swift
    static func manualDischargeDisabledReason(
        isPluggedIn: Bool,
        currentSoC: Int,
        targetSoC: Int,
        isHardwareSupported: Bool = true,
        isDischargeHardwareSupported: Bool = true,
        isToggleEnabled: Bool = true,
        isAutoDischargeEnabled: Bool = false,
        locale: Locale = Locale(identifier: "ko")
    ) -> String? {
        guard isHardwareSupported, isToggleEnabled else {
            return String(localized: "이 Mac은 충전 제어를 지원하지 않습니다", locale: locale)
        }
        guard isDischargeHardwareSupported else {
            return String(localized: "이 Mac은 강제 방전을 지원하지 않습니다.", locale: locale)
        }
        // 하드웨어 두 축 다음, 어댑터·잔량보다 앞에 둔다. 자동 방전이 켜져 있으면 어댑터를
        // 꽂아도 잔량을 낮춰도 수동 방전은 시작되지 않으므로, 그 사유가 먼저 보여야 사용자가
        // 헛수고를 하지 않는다.
        guard !isAutoDischargeEnabled else {
            return String(localized: "자동 방전이 켜져 있어 수동 방전을 사용할 수 없습니다.", locale: locale)
        }
        guard isPluggedIn else {
            return String(localized: "전원 어댑터가 연결되어 있어야 방전할 수 있습니다.", locale: locale)
        }
        guard currentSoC > targetSoC else {
            return String(localized: "현재 배터리 잔량이 목표 잔량 이하입니다.", locale: locale)
        }
        return nil
    }
```

3-2. 같은 파일 `isManualDischargeActionable`(:591-601)을 아래로 교체:

```swift
    static func isManualDischargeActionable(
        isPluggedIn: Bool,
        currentSoC: Int,
        targetSoC: Int,
        isHardwareSupported: Bool = true,
        isDischargeHardwareSupported: Bool = true,
        isToggleEnabled: Bool = true,
        isAutoDischargeEnabled: Bool = false
    ) -> Bool {
        manualDischargeDisabledReason(
            isPluggedIn: isPluggedIn,
            currentSoC: currentSoC,
            targetSoC: targetSoC,
            isHardwareSupported: isHardwareSupported,
            isDischargeHardwareSupported: isDischargeHardwareSupported,
            isToggleEnabled: isToggleEnabled,
            isAutoDischargeEnabled: isAutoDischargeEnabled) == nil
    }
```

3-3. Task 1이 추가한 블록 **뒤에** 자동 토글 게이트를 추가:

```swift
    /// 자동 방전 토글을 만질 수 있는지.
    ///
    /// 두 조건이다. 충전 한도가 켜져 있어야 하고(꺼져 있으면 데몬이 자동 방전을 돌리지 않아
    /// 아무 일도 하지 않는 스위치가 된다), 수동 방전 세션이 열려 있지 않아야 한다. 후자는
    /// 자동 방전이 수동 방전을 이어받아 사용자가 고른 목표를 지나쳐 버리기 때문이다.
    /// 자동 방전이 **돌고 있는 것**은 잠글 이유가 아니다 — 이 토글이 그것을 끄는 유일한 길이다.
    static func isAutoDischargeToggleEnabled(
        isLimitOn: Bool,
        dischargeOwner: DischargeOwner
    ) -> Bool {
        isLimitOn && dischargeOwner != .manual
    }

    /// 위 게이트가 거짓일 때의 사유. 활성일 때는 `nil`.
    static func autoDischargeToggleDisabledReason(
        isLimitOn: Bool,
        dischargeOwner: DischargeOwner,
        locale: Locale = Locale(identifier: "ko")
    ) -> String? {
        if dischargeOwner == .manual {
            return String(localized: "수동 방전이 진행 중입니다.", locale: locale)
        }
        return limitPickerDisabledReason(isLimitOn: isLimitOn)
    }
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatterySectionPresentationTests 2>&1 | tail -20
```
Expected: exit 0, 실패 0

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Core/BatterySectionPresentation.swift WattlyTests/BatterySectionPresentationTests.swift
git commit -m "$(cat <<'MSG'
feat(battery): 자동/수동 방전 상호배제 사유와 자동 토글 게이트를 순수 함수로 넣는다

자동 방전은 plugged & SoC>한도+1이면 항상 한도까지 내리는 연속 불변식이라,
어떤 수동 방전 목표든 종료 즉시 취소된다. 조건이 아니라 사유로 표현한다.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

### Task 3: 설정 계약에 상호배제 불변식을 박는다

**Files:**
- Modify: `FanControlShared/BatteryControlProtocol.swift:82-96` (`normalized`)
- Modify: `FanControlShared/BatteryControlPolicy.swift:77` (`shouldReapply`의 반환식)
- Modify: `Wattly/Control/BatteryControlClient.swift:126-151` (`revivedConfiguration`의 반환)
- Test: `WattlyTests/BatteryControlProtocolTests.swift`, `WattlyTests/BatteryControlPolicyTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces: `BatteryControlConfiguration.normalized`가 `manualDischargeActive == true`일 때 `autoDischargeEnabled`를 `false`로 만든다. Task 4~9의 어떤 것도 이 계약을 다시 적지 않는다.

> `FanControlShared/`는 앱과 데몬 양쪽에 소스로 포함되므로 데몬의 코디네이터(`configure`/`configureWithoutPowerReading`가 `requested.normalized`를 쓴다)도 같은 불변식을 얻는다 — 별도 미러 코드는 필요 없다. 다만 **설치된** 데몬 바이너리는 사용자가 재설치할 때 교체된다.
>
> 코디네이터의 기존 상호배제 블록은 플래그를 끄기만 하므로(`manual → false`, `topUp → false`) 이 불변식을 깰 수 없다. 재정규화를 덧붙이지 않는 이유가 그것이다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`WattlyTests/BatteryControlProtocolTests.swift`의 마지막 `}` **앞에** 추가:

```swift
    @Test func normalizingClearsAutoDischargeWhileManualDischargeIsActive() {
        let running = BatteryControlConfiguration(
            enabled: true,
            limitPercentage: 80,
            autoDischargeEnabled: true,
            manualDischargeActive: true,
            manualDischargeTarget: 90)
        #expect(running.normalized.autoDischargeEnabled == false)
        #expect(running.normalized.manualDischargeActive == true)

        // 수동 방전이 없으면 사용자의 자동 방전 옵트인은 그대로 살아 있어야 한다.
        var idle = running
        idle.manualDischargeActive = false
        #expect(idle.normalized.autoDischargeEnabled == true)
    }

    @Test func normalizationIsIdempotent() {
        let config = BatteryControlConfiguration(
            enabled: true,
            autoDischargeEnabled: true,
            manualDischargeActive: true)
        #expect(config.normalized.normalized == config.normalized)
    }
```

`WattlyTests/BatteryControlPolicyTests.swift`의 마지막 `}` **앞에** 추가:

```swift
    @Test func reapplyDoesNotChaseAPreservedManualDischargeForever() {
        // 데몬은 수동 방전 중이고 불변식 때문에 자동 방전은 꺼져 있다. 앱의 저장된 선호는
        // 자동 방전 켜짐이다. 활동을 보존한 뒤 재정규화하지 않으면 요청과 실제가 어긋난
        // 채로 남아 앱을 켤 때마다 불필요한 재전송이 한 번씩 나간다.
        let daemon = BatteryControlConfiguration(
            enabled: true,
            limitPercentage: 80,
            autoDischargeEnabled: false,
            manualDischargeActive: true,
            manualDischargeTarget: 90)
        let status = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 92,
            isPowerAdapterConnected: true,
            detail: "",
            updatedAt: 1,
            isHardwareSupported: true,
            desiredConfiguration: daemon,
            actualGate: .inhibited(appliedLimitPercentage: 90),
            capabilities: [.persistedPolicyV1, .hardwareGateReadbackV1, .systemPowerEventsV1])
        let stored = BatteryControlConfiguration(
            enabled: true,
            limitPercentage: 80,
            autoDischargeEnabled: true,
            manualDischargeActive: false,
            manualDischargeTarget: 90)

        #expect(BatteryControlPolicy.shouldReapply(configuration: stored, status: status) == false)
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlProtocolTests -only-testing:WattlyTests/BatteryControlPolicyTests 2>&1 | tail -25
```
Expected: FAIL — `normalizingClearsAutoDischargeWhileManualDischargeIsActive`에서 `autoDischargeEnabled == false` 실패, `reapplyDoesNotChaseAPreservedManualDischargeForever`에서 `false` 기대에 `true`

- [ ] **Step 3: 구현한다**

3-1. `FanControlShared/BatteryControlProtocol.swift`의 `normalized` 안, `copy.calibrationTargetPercentage = ...` 줄과 `return copy` 사이에 삽입:

```swift
        // 수동 방전과 자동 방전은 같은 CHIE를 다투는데 목적지가 서로 다르다 — 수동은
        // `manualDischargeTarget`, 자동은 `limitPercentage`. 둘이 함께 켜지면 수동 방전이
        // 끝나는 순간 자동 방전이 이어받아 사용자가 고른 목표를 지나쳐 계속 방전한다.
        // UI 게이트가 1차 방어선이고, 이 불변식은 그 게이트를 지나지 않는 경로(스케줄,
        // 재조정 루프의 활동 보존)와 게이트 회귀에 대한 방어선이다.
        if copy.manualDischargeActive { copy.autoDischargeEnabled = false }
```

3-2. `FanControlShared/BatteryControlPolicy.swift`의 `shouldReapply` 안, 활동 보존 세 블록 다음 줄을 교체:

```swift
            // 위 세 블록은 정규화가 끝난 뒤에 활동을 되살린다. 되살린 `manualDischargeActive`에는
            // `normalized`의 수동/자동 상호배제가 아직 적용되지 않았으므로 한 번 더 통과시킨다.
            return desired.normalized != requested.normalized
```
(교체 대상: `            return desired.normalized != requested`)

3-3. `Wattly/Control/BatteryControlClient.swift`의 `revivedConfiguration` 마지막 줄 `return config`를 교체:

```swift
        // 마지막에 한 번 정규화한다. 전송값과 `shouldReapply`/`accepted`의 비교값이 같은 규칙을
        // 쓰게 만드는 것이 목적이다 — 특히 `normalized`의 수동/자동 방전 상호배제는 여기를
        // 지나야 실제로 데몬에 도달한다. 나머지 클램프는 데몬이 수신 시 어차피 적용하는 것과
        // 같은 값이므로, 이 호출로 달라지는 동작은 그 불변식 하나뿐이다.
        return config.normalized
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run (해당 스위트 → 전체 회귀):
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlProtocolTests -only-testing:WattlyTests/BatteryControlPolicyTests 2>&1 | tail -20
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 | tail -20
```
Expected: 둘 다 exit 0, 실패 0

- [ ] **Step 5: 커밋**

```bash
git add FanControlShared/BatteryControlProtocol.swift FanControlShared/BatteryControlPolicy.swift Wattly/Control/BatteryControlClient.swift WattlyTests/BatteryControlProtocolTests.swift WattlyTests/BatteryControlPolicyTests.swift
git commit -m "$(cat <<'MSG'
fix(battery): 수동 방전 중에는 자동 방전을 설정 계약에서 끈다

두 방전은 같은 CHIE를 다투면서 목적지가 다르다. 함께 켜지면 수동 방전이
끝나는 순간 자동 방전이 이어받아 사용자가 고른 목표를 지나쳐 계속 내려간다.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

### Task 4: 설정 방전 카드 배선

**Files:**
- Modify: `Wattly/Views/Settings/SettingsBatteryDischargeSection.swift:89-93` (`isManualDischargeActive`), `:187-200` (`autoDischargeCard`), `:293-300` 부근 (`canStartDischarge`), `:330-340` 부근 (`disabledReason`)

**Interfaces:**
- Consumes: Task 1의 `dischargeOwner`, Task 2의 `isAutoDischargeToggleEnabled` / `autoDischargeToggleDisabledReason` / `manualDischargeDisabledReason(isAutoDischargeEnabled:)` / `isManualDischargeActionable(isAutoDischargeEnabled:)`
- Produces: 없음 (뷰 배선)

- [ ] **Step 1: `dischargeOwner` 프로퍼티를 넣고 `isManualDischargeActive`를 그 위에 다시 세운다**

`SettingsBatteryDischargeSection.swift:89-93`을 교체:

```swift
    /// 강제 방전을 지금 누가 소유하고 있는지. 판별은 `BatterySectionPresentation`에만 있다 —
    /// 예전에는 이 뷰가 `activity == .discharging`을 직접 읽어서 자동 방전이 "수동 방전
    /// 진행 중" 배너와 "방전 중지" 버튼으로 표시됐고, 그 버튼은 자동 방전을 끄지 못했다.
    private var dischargeOwner: BatterySectionPresentation.DischargeOwner {
        BatterySectionPresentation.dischargeOwner(
            manualDischargeActive: batteryControl.status.desiredConfiguration?.manualDischargeActive,
            reasonKind: batteryControl.status.detailReason?.kind,
            activity: batteryControl.status.activity)
    }

    /// 사용자가 연 수동 방전 세션이 열려 있는지 — 목표 도달 후 홀드 구간도 포함한다.
    private var isManualDischargeActive: Bool { dischargeOwner == .manual }
```

- [ ] **Step 2: 자동 방전 카드에 게이트와 진행 배지를 넣는다**

`autoDischargeCard`의 `SettingsToggleRow` 블록을 교체:

```swift
    @ViewBuilder
    private var autoDischargeCard: some View {
        SettingsCard {
            SettingsToggleRow(
                isOn: $autoDischargeEnabled,
                divider: false,
                // 게이트 두 축은 `BatterySectionPresentation`이 정의한다. 충전 한도가 꺼져
                // 있으면 데몬이 자동 방전을 돌리지 않아 아무 일도 하지 않는 스위치가 되고,
                // 수동 방전 세션 중에는 자동 방전이 그것을 이어받아 버리므로 잠근다.
                isEnabled: BatterySectionPresentation.isAutoDischargeToggleEnabled(
                    isLimitOn: batteryLimitEnabled,
                    dischargeOwner: dischargeOwner),
                disabledReason: BatterySectionPresentation.autoDischargeToggleDisabledReason(
                    isLimitOn: batteryLimitEnabled,
                    dischargeOwner: dischargeOwner,
                    locale: locale)
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        SettingsRowTitle("자동 방전")
                        // 자동 방전에는 지금까지 자기 표시가 없어서, 진행 중인 것이 수동
                        // 방전 카드의 배너로 잘못 나타났다.
                        if dischargeOwner == .automatic {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Tokens.statusOrange)
                                    .frame(width: 6, height: 6)
                                Text(LocalizedStringKey("자동 방전 진행 중"))
                                    .font(WattlyFont.at(10, weight: .semibold))
                                    .foregroundStyle(Tokens.statusOrange)
                            }
                        }
                    }
                    Text("충전 한도를 현재 잔량보다 낮게 변경하면 별도 조작 없이 자동으로 한도까지 방전합니다.")
                        .font(WattlyFont.at(10.5, weight: .regular))
                        .foregroundStyle(t.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
```

- [ ] **Step 3: 시작 버튼의 판정과 사유에 자동 방전을 넘긴다**

같은 파일에서 `canStartDischarge`를 계산하는 곳(`Rectangle().fill(t.line)` 다음의 `let canStartDischarge = ...`)과 `else` 분기의 `disabledReason = ...`에 인자를 추가한다. 두 호출 모두 `isToggleEnabled:` 뒤에 한 줄을 넣는다:

```swift
                let canStartDischarge = BatterySectionPresentation.isManualDischargeActionable(
                    isPluggedIn: isPluggedIn,
                    currentSoC: currentSoC,
                    targetSoC: dischargeTarget,
                    isHardwareSupported: !isHardwareUnsupported,
                    isDischargeHardwareSupported: !isDischargeUnsupported,
                    isToggleEnabled: isToggleEnabled,
                    isAutoDischargeEnabled: autoDischargeEnabled)
```

```swift
                    let disabledReason = BatterySectionPresentation.manualDischargeDisabledReason(
                        isPluggedIn: isPluggedIn,
                        currentSoC: currentSoC,
                        targetSoC: dischargeTarget,
                        isHardwareSupported: !isHardwareUnsupported,
                        isDischargeHardwareSupported: !isDischargeUnsupported,
                        isToggleEnabled: isToggleEnabled,
                        isAutoDischargeEnabled: autoDischargeEnabled,
                        locale: locale
                    )
```

- [ ] **Step 4: 빌드와 전체 회귀를 확인한다**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 | tail -20
```
Expected: exit 0, 실패 0

수동 확인(앱 실행 후 설정 › 배터리 › 방전 제어):
- 충전 한도 ON + 자동 방전 OFF → 자동 방전 토글 활성, 수동 방전 "방전 시작" 활성(잔량 > 목표일 때)
- 자동 방전 ON → "방전 시작"이 비활성이고 그 아래에 "자동 방전이 켜져 있어 수동 방전을 사용할 수 없습니다."가 보인다
- 수동 방전 진행 중 → 자동 방전 토글이 비활성이고 사유가 "수동 방전이 진행 중입니다."

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Views/Settings/SettingsBatteryDischargeSection.swift
git commit -m "$(cat <<'MSG'
fix(settings): 방전 카드가 자동 방전과 수동 방전을 구분하게 한다

자동 방전이 돌 때 "수동 방전 진행 중" 배너와 누를 수 없는 "방전 중지"가
뜨던 것을 없애고, 자동 방전에 자기 진행 배지를 준다.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

### Task 5: 팝오버 배선

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift:527-529` (`forcedDischargeText`)
- Modify: `Wattly/Views/CardExpandRegion.swift` — `dischargeOwner` 프로퍼티 추가, `:253-258`, `:351-352`, `:462-463`, `:466-478`
- Test: `WattlyTests/BatterySectionPresentationTests.swift:796` 부근

**Interfaces:**
- Consumes: Task 1의 `dischargeOwner` / `DischargeOwner`, Task 2의 `manualDischargeDisabledReason(isAutoDischargeEnabled:)` / `isManualDischargeActionable(isAutoDischargeEnabled:)`
- Produces: `forcedDischargeText(owner: DischargeOwner = .manual, locale: Locale = ...) -> String` — 기존 호출부 2곳(`CardPresentation.swift:265`, `CardExpandRegion.swift:271`)은 기본값 덕에 그대로 컴파일된다

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`WattlyTests/BatterySectionPresentationTests.swift:796` 부근의 기존 `forcedDischargeText` 기대 옆에 추가:

```swift
    @Test func forcedDischargeTextNamesTheOwner() {
        #expect(BatterySectionPresentation.forcedDischargeText(owner: .manual, locale: ko)
            == "배터리 (수동 방전 중)")
        #expect(BatterySectionPresentation.forcedDischargeText(owner: .automatic, locale: ko)
            == "배터리 (자동 방전 중)")
        #expect(BatterySectionPresentation.forcedDischargeText(owner: .automatic, locale: en)
            == "Battery (Auto Discharge)")
        // 인자를 주지 않는 기존 호출부는 수동 문구를 그대로 받는다.
        #expect(BatterySectionPresentation.forcedDischargeText(locale: ko)
            == "배터리 (수동 방전 중)")
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatterySectionPresentationTests 2>&1 | tail -20
```
Expected: 컴파일 실패 — `extra argument 'owner' in call`

- [ ] **Step 3: 구현한다**

3-1. `Wattly/Core/BatterySectionPresentation.swift:527-529`를 교체:

```swift
    /// 강제 방전 중 전원 소스 값. 자동 방전과 수동 방전은 물리적으로 같은 상태지만 사용자가
    /// 할 수 있는 일이 다르므로(수동은 이 화면의 중지 버튼, 자동은 설정의 토글) 문구를 나눈다.
    static func forcedDischargeText(
        owner: DischargeOwner = .manual,
        locale: Locale = Locale(identifier: "ko")
    ) -> String {
        owner == .automatic
            ? String(localized: "배터리 (자동 방전 중)", locale: locale)
            : String(localized: "배터리 (수동 방전 중)", locale: locale)
    }
```

3-2. `Wattly/Views/CardExpandRegion.swift`의 `private var dischargeTarget` 정의 **바로 뒤**(:34 다음)에 추가:

```swift
    /// 강제 방전을 지금 누가 소유하고 있는지. 세 자리(전원 소스 문구, Top Up 상호배제,
    /// 수동 방전 행)가 조건을 각자 적어서 자동 방전이 수동 방전으로 표시됐다 — 한 곳으로 모은다.
    /// `batteryControl`이 `nil`이면 판별 근거가 없으므로 `.idle`이 나온다.
    private var dischargeOwner: BatterySectionPresentation.DischargeOwner {
        BatterySectionPresentation.dischargeOwner(
            manualDischargeActive: batteryControl?.status.desiredConfiguration?.manualDischargeActive,
            reasonKind: batteryControl?.status.detailReason?.kind,
            activity: batteryControl?.status.activity)
    }
```

3-3. `CardExpandRegion.swift:253-258`을 교체. 수동일 때의 동작은 그대로다 — `isForcedDischargeRunning`은 오늘의 `activity == .discharging`의 상위집합이고(reason이 방전이면 activity도 방전이다), 달라지는 것은 판정을 activity 하나가 아니라 reason에서 직접 읽는다는 점뿐이다:

```swift
                let activity = batteryControl?.status.activity
                let owner = dischargeOwner
                let manualDischargeActive = owner == .manual
                let isDischarging = BatterySectionPresentation.isForcedDischargeRunning(
                    reasonKind: batteryControl?.status.detailReason?.kind,
                    activity: activity)
                    || manualDischargeActive
                    || flow.scenario == .activeDischarge
```

3-4. 같은 파일 `:271`의 `powerSourceValue`를 교체:

```swift
                    let powerSourceValue = isDischarging
                        ? BatterySectionPresentation.forcedDischargeText(owner: owner, locale: locale)
                        : CardPresentation.powerSourceText(flow.scenario, locale: locale)
```

3-5. `:351-352`를 교체 (Top Up 상호배제는 수동 방전에만 걸린다 — 엔진 우선순위상 Top Up이 자동 방전보다 위라 자동과는 배타가 아니다):

```swift
                let isDischargeActive = dischargeOwner == .manual
```

3-6. `:462-463`을 교체:

```swift
        let isDischarging = dischargeOwner == .manual
```

3-7. 같은 함수의 `canStartDischarge`와 `disabledReason` 두 호출에 인자를 추가:

```swift
        let canStartDischarge = BatterySectionPresentation.isManualDischargeActionable(
            isPluggedIn: s.externalConnected,
            currentSoC: currentSoC,
            targetSoC: dischargeTarget,
            isHardwareSupported: isHardwareSupported,
            isDischargeHardwareSupported: isDischargeHardwareSupported,
            isAutoDischargeEnabled: batteryAutoDischargeEnabled
        )
        let disabledReason = BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: s.externalConnected,
            currentSoC: currentSoC,
            targetSoC: dischargeTarget,
            isHardwareSupported: isHardwareSupported,
            isDischargeHardwareSupported: isDischargeHardwareSupported,
            isAutoDischargeEnabled: batteryAutoDischargeEnabled,
            locale: locale
        )
```

- [ ] **Step 4: 테스트와 전체 회귀를 확인한다**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 | tail -20
```
Expected: exit 0, 실패 0

수동 확인(메뉴바 팝오버 › 배터리 카드 펼침):
- 자동 방전 진행 중 → "수동 방전 (N%)" 행에 주황 점이 **뜨지 않고** 버튼이 "방전 시작"(비활성)이며 그 아래 사유가 보인다. 전원 공급원은 "배터리 (자동 방전 중)". Top Up 행이 **보인다**.
- 수동 방전 진행 중 → 예전 그대로: 주황 점 + "방전 중지", 전원 공급원 "배터리 (수동 방전 중)", Top Up 행 숨김.

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Core/BatterySectionPresentation.swift Wattly/Views/CardExpandRegion.swift WattlyTests/BatterySectionPresentationTests.swift
git commit -m "$(cat <<'MSG'
fix(battery): 팝오버가 자동 방전을 수동 방전으로 표시하지 않게 한다

자동 방전 중에 뜨던 "방전 중지"(눌러도 멈추지 않는 버튼)와 Top Up 행
숨김이 사라지고, 전원 공급원 문구가 주인을 따른다.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

### Task 6: 방전 완료 알림 배선

**Files:**
- Modify: `Wattly/Core/BatteryNotificationManager.swift:43-80` (`BatteryDischargeTransitionDetector` 전체 교체)
- Modify: `Wattly/Views/BatteryControlBridge.swift:24-25` (상태 추가), `:341-345` (배선)
- Test: `WattlyTests/BatteryNotificationManagerTests.swift:108-171` (기존 세 테스트 교체)

**Interfaces:**
- Consumes: `BatteryControlServiceStatus`, `BatteryControlStatusReason.Kind`
- Produces: `BatteryDischargeTransitionDetector.update(status:) -> Int?` — 목표 도달이면 알릴 목표 잔량(%), 아니면 `nil`. 기존 `update(reasonKind:) -> Bool`과 `update(activity:) -> Bool` 오버로드는 **삭제**된다(프로덕션 호출자가 없었다).

> 엔진은 수동 방전 목표 도달 시 평범한 `.inhibitedAtLimit`을 낸다(`BatteryControlEngineTests.manualDischargeTransitionsToTargetAndHoldsAtLimit`가 고정). 일반 한도 홀드와 문자열이 같아 reason만으로는 구분되지 않으므로 세션 플래그를 함께 본다. 사용자가 "방전 중지"를 누르면 같은 틱에 그 플래그가 내려가므로 자연히 걸러진다.

- [ ] **Step 1: 기존 세 테스트를 새 계약으로 교체한다**

`WattlyTests/BatteryNotificationManagerTests.swift`에서 `BatteryDischargeTransitionDetector`를 쓰는 테스트 세 개(약 :108-171)를 삭제하고 아래로 대체:

```swift
    private static func dischargeStatus(
        kind: BatteryControlStatusReason.Kind,
        target: Int,
        sessionOpen: Bool
    ) -> BatteryControlServiceStatus {
        BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: target,
            isPowerAdapterConnected: true,
            detail: "",
            updatedAt: 1,
            detailReason: .init(kind: kind, limitPercentage: target),
            desiredConfiguration: BatteryControlConfiguration(
                enabled: true,
                limitPercentage: 80,
                manualDischargeActive: sessionOpen,
                manualDischargeTarget: target))
    }

    @Test func dischargeCompletionFiresOnceWhenTheManualSessionReachesItsTarget() {
        var detector = BatteryDischargeTransitionDetector()
        let running = Self.dischargeStatus(kind: .dischargingManual, target: 70, sessionOpen: true)
        let reached = Self.dischargeStatus(kind: .inhibitedAtLimit, target: 70, sessionOpen: true)

        #expect(detector.update(status: running) == nil)
        #expect(detector.update(status: reached) == 70)
        // 같은 상태가 반복돼도 다시 알리지 않는다.
        #expect(detector.update(status: reached) == nil)
    }

    @Test func userStoppingTheDischargeDoesNotAnnounceCompletion() {
        var detector = BatteryDischargeTransitionDetector()
        let running = Self.dischargeStatus(kind: .dischargingManual, target: 70, sessionOpen: true)
        // "방전 중지"를 누르면 세션 플래그가 같은 틱에 내려간다.
        let stopped = Self.dischargeStatus(kind: .inhibitedAtLimit, target: 80, sessionOpen: false)

        #expect(detector.update(status: running) == nil)
        #expect(detector.update(status: stopped) == nil)
    }

    @Test func autoDischargeReachingTheLimitIsNotAnnounced() {
        var detector = BatteryDischargeTransitionDetector()
        let running = Self.dischargeStatus(kind: .dischargingToTarget, target: 80, sessionOpen: false)
        let reached = Self.dischargeStatus(kind: .inhibitedAtLimit, target: 80, sessionOpen: false)

        #expect(detector.update(status: running) == nil)
        #expect(detector.update(status: reached) == nil)
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryNotificationManagerTests 2>&1 | tail -20
```
Expected: 컴파일 실패 — `cannot convert value of type 'Bool' to 'Int?'`

- [ ] **Step 3: 디텍터를 다시 쓴다**

`Wattly/Core/BatteryNotificationManager.swift`의 `BatteryDischargeTransitionDetector` 전체(:43-80)를 교체:

```swift
/// 수동 방전이 **목표에 도달**한 순간만 잡는다.
///
/// 엔진은 목표 도달 시 평범한 `inhibitedAtLimit`을 내므로 reason만으로는 일반 한도 홀드와
/// 구분되지 않는다. 세션이 아직 열려 있는지(`desiredConfiguration.manualDischargeActive`)를
/// 함께 봐야 한다 — 사용자가 "방전 중지"를 누른 경우에는 같은 틱에 그 플래그가 내려가므로
/// 걸러진다. 자동 방전은 배경 정책이라 알리지 않는다.
public struct BatteryDischargeTransitionDetector: Sendable {
    private var wasDischargingManually = false

    public init() {}

    /// 목표 도달이면 알릴 목표 잔량(%), 아니면 `nil`.
    public mutating func update(status: BatteryControlServiceStatus) -> Int? {
        let isDischargingManually = status.detailReason?.kind == .dischargingManual
        defer { wasDischargingManually = isDischargingManually }
        guard wasDischargingManually,
              !isDischargingManually,
              status.desiredConfiguration?.manualDischargeActive == true
        else { return nil }
        return status.detailReason?.limitPercentage
            ?? status.desiredConfiguration?.manualDischargeTarget
    }
}
```

- [ ] **Step 4: 브리지에 배선한다**

`Wattly/Views/BatteryControlBridge.swift:25`(`topUpExpiryDetector` 선언) 다음 줄에 추가:

```swift
    @State private var dischargeDetector = BatteryDischargeTransitionDetector()
```

같은 파일 `.onChange(of: client.status)` 블록 안, Top Up 만료 처리 뒤에 추가:

```swift
                // 수동 방전이 목표에 도달한 순간에만 값이 나온다. 자동 방전과 사용자 중지는
                // 디텍터가 걸러낸다. 이 배선이 없어서 "방전 완료" 알림은 만들어져 있는데
                // 한 번도 뜨지 않았다.
                if let target = dischargeDetector.update(status: newStatus) {
                    BatteryNotificationManager.notifyDischargeCompleted(target: target)
                }
```

- [ ] **Step 5: 테스트가 통과하는지 확인한다**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 | tail -20
```
Expected: exit 0, 실패 0

- [ ] **Step 6: 커밋**

```bash
git add Wattly/Core/BatteryNotificationManager.swift Wattly/Views/BatteryControlBridge.swift WattlyTests/BatteryNotificationManagerTests.swift
git commit -m "$(cat <<'MSG'
fix(battery): 죽어 있던 방전 완료 알림을 배선한다

디텍터와 알림 함수는 있었지만 호출하는 곳이 없었다. 목표 도달과 사용자
중지를 세션 플래그로 가르고, 자동 방전은 알리지 않는다.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

### Task 7: 스케줄 "충전 일시 정지"의 자동 방전 경고

**Files:**
- Modify: `Wattly/Core/BatteryScheduleCoordinator.swift:238-250` (상수화), 클래스 상단(상수·순수 함수 추가), `:268-275` (알림에 note 전달)
- Modify: `Wattly/Core/BatteryNotificationManager.swift:192-214` (`postScheduleTriggeredNotification`에 `note:` 추가)
- Modify: `Wattly/Views/Settings/ScheduleEditorSheet.swift:16` 부근(@AppStorage 추가), `:91` 부근(경고 표시)
- Test: `WattlyTests/BatteryScheduleCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ScheduleAction`(`Equatable`), `StorageKey.batteryAutoDischargeEnabled`
- Produces:
  - `BatteryScheduleCoordinator.pauseChargingLimitPercentage: Int` (= 50)
  - `BatteryScheduleCoordinator.autoDischargeWarning(action:isAutoDischargeEnabled:locale:) -> String?`
  - `BatteryNotificationManager.postScheduleTriggeredNotification(scheduleName:actionSummary:locale:note:)` — `note: String? = nil` 추가

> 동작은 바꾸지 않는다. "충전 일시 정지"는 한도를 50%로 내리는 것으로 구현돼 있고, 자동 방전이 켜져 있으면 그 한도 변경이 곧 강제 방전 명령이 된다. 라벨만 보고 "충전만 멈춘다"고 읽지 않도록 편집기와 실행 알림 양쪽에 사실을 적는다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`WattlyTests/BatteryScheduleCoordinatorTests.swift`의 마지막 `}` **앞에** 추가:

```swift
    @Test func pauseChargingWarnsWhenAutoDischargeWouldTurnItIntoADischarge() {
        let ko = Locale(identifier: "ko")
        #expect(BatteryScheduleCoordinator.autoDischargeWarning(
            action: .pauseCharging, isAutoDischargeEnabled: true, locale: ko)
            == "자동 방전이 켜져 있어 이 스케줄은 배터리를 50%까지 방전합니다.")
    }

    @Test func autoDischargeWarningIsSilentWhenItDoesNotApply() {
        let ko = Locale(identifier: "ko")
        #expect(BatteryScheduleCoordinator.autoDischargeWarning(
            action: .pauseCharging, isAutoDischargeEnabled: false, locale: ko) == nil)
        #expect(BatteryScheduleCoordinator.autoDischargeWarning(
            action: .setLimit(percentage: 80), isAutoDischargeEnabled: true, locale: ko) == nil)
        #expect(BatteryScheduleCoordinator.autoDischargeWarning(
            action: .startTopUp, isAutoDischargeEnabled: true, locale: ko) == nil)
    }

    @Test func pauseChargingLimitIsTheOneTheWarningQuotes() {
        #expect(BatteryScheduleCoordinator.pauseChargingLimitPercentage == 50)
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryScheduleCoordinatorTests 2>&1 | tail -20
```
Expected: 컴파일 실패 — `type 'BatteryScheduleCoordinator' has no member 'autoDischargeWarning'`

- [ ] **Step 3: 코디네이터에 상수와 순수 함수를 넣는다**

`Wattly/Core/BatteryScheduleCoordinator.swift`의 `effectiveManualDischargeTarget` 선언 **앞에** 추가:

```swift
    /// "충전 일시 정지"가 내리는 한도. 편집기의 경고 문구와 실제 실행이 같은 숫자를 봐야 하므로
    /// 리터럴로 두지 않는다.
    public static let pauseChargingLimitPercentage = 50

    /// "충전 일시 정지"는 한도를 낮추는 것으로 구현돼 있어서, 자동 방전이 켜져 있으면 그
    /// 한도 변경이 곧 강제 방전 명령이 된다. 라벨은 "정지"인데 실제로는 배터리를 태워 내리는
    /// 셈이므로 편집기와 실행 알림 양쪽에서 같은 문장으로 알린다. 동작 자체는 바꾸지 않는다.
    public static func autoDischargeWarning(
        action: ScheduleAction,
        isAutoDischargeEnabled: Bool,
        locale: Locale
    ) -> String? {
        guard action == .pauseCharging, isAutoDischargeEnabled else { return nil }
        return String(
            format: String(localized: "자동 방전이 켜져 있어 이 스케줄은 배터리를 %lld%%까지 방전합니다.", locale: locale),
            locale: locale,
            Int64(pauseChargingLimitPercentage))
    }
```

같은 파일 `case .pauseCharging:` 블록의 리터럴 `50` 두 곳을 상수로 바꾼다:

```swift
        case .pauseCharging:
            defaults.set(true, forKey: StorageKey.batteryLimitEnabled)
            defaults.set(Self.pauseChargingLimitPercentage, forKey: StorageKey.batteryLimitPercentage)
            let status = await batteryControl.apply(
                enabled: true,
                limitPercentage: Self.pauseChargingLimitPercentage,
```

그리고 알림 전송부를 교체:

```swift
        // Send notification if enabled
        if defaults.bool(forKey: StorageKey.batteryScheduleNotificationsEnabled) {
            let locale = activeLocale
            BatteryNotificationManager.postScheduleTriggeredNotification(
                scheduleName: schedule.name,
                actionSummary: schedule.action.summary(locale: locale),
                locale: locale,
                // 편집기 경고를 못 보고 저장한 스케줄도 있을 수 있으므로 실행 시점에 한 번 더 알린다.
                note: Self.autoDischargeWarning(
                    action: schedule.action,
                    isAutoDischargeEnabled: defaults.bool(forKey: StorageKey.batteryAutoDischargeEnabled),
                    locale: locale)
            )
        }
```

- [ ] **Step 4: 알림 함수에 note를 받고 편집기에 경고를 띄운다**

4-1. `Wattly/Core/BatteryNotificationManager.swift`의 `postScheduleTriggeredNotification`을 교체:

```swift
    public static func postScheduleTriggeredNotification(
        scheduleName: String,
        actionSummary: String,
        locale: Locale? = nil,
        note: String? = nil
    ) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let locale = locale ?? AppLanguage.locale(
                for: UserDefaults.standard.string(forKey: StorageKey.appLanguage) ?? Defaults.appLanguage)
            let content = UNMutableNotificationContent()
            content.title = scheduleTriggeredTitle(scheduleName: scheduleName, actionSummary: actionSummary, locale: locale)
            var body = scheduleTriggeredBody(scheduleName: scheduleName, actionSummary: actionSummary, locale: locale)
            // 라벨만으로는 알 수 없는 부작용을 한 줄 덧붙인다 (예: 자동 방전이 켜진 상태의 "충전 일시 정지").
            if let note { body += "\n" + note }
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "dev.jjundev.Wattly.scheduleTriggered.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }
```

4-2. `Wattly/Views/Settings/ScheduleEditorSheet.swift`의 `@State private var catchUpMinutes: Int = 30` 다음 줄에 추가:

```swift
    @AppStorage(StorageKey.batteryAutoDischargeEnabled) private var autoDischargeEnabled = Defaults.batteryAutoDischargeEnabled
```

4-3. 같은 파일에서 동작 `WattlySegment` 뒤, `if actionType == 0 {` 블록 **앞에** 추가:

```swift
                // "충전 일시 정지"는 한도를 내리는 것으로 구현돼 있어서, 자동 방전이 켜져
                // 있으면 그 한도 변경이 곧 강제 방전이 된다. 저장하기 전에 알린다.
                // 어떤 동작이 경고 대상인지는 코디네이터가 정한다 — 이 뷰는 선택된 동작을
                // 그대로 넘기기만 한다.
                let selectedAction: ScheduleAction = switch actionType {
                case 1: .startTopUp
                case 2: .pauseCharging
                default: .setLimit(percentage: targetLimit)
                }
                if let warning = BatteryScheduleCoordinator.autoDischargeWarning(
                    action: selectedAction,
                    isAutoDischargeEnabled: autoDischargeEnabled,
                    locale: locale) {
                    Text(verbatim: warning)
                        .font(WattlyFont.at(10.5, weight: .regular))
                        .foregroundStyle(Tokens.statusOrange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
```

- [ ] **Step 5: 테스트가 통과하는지 확인한다**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 | tail -20
```
Expected: exit 0, 실패 0

수동 확인: 설정 › 배터리 › 예약 › 새 스케줄 › 동작 "충전 일시 정지" 선택. 자동 방전이 켜져 있으면 주황 경고 한 줄이 뜨고, 꺼져 있으면 뜨지 않는다.

- [ ] **Step 6: 커밋**

```bash
git add Wattly/Core/BatteryScheduleCoordinator.swift Wattly/Core/BatteryNotificationManager.swift Wattly/Views/Settings/ScheduleEditorSheet.swift WattlyTests/BatteryScheduleCoordinatorTests.swift
git commit -m "$(cat <<'MSG'
fix(settings): "충전 일시 정지"가 자동 방전과 만나면 그 사실을 알린다

한도를 50%로 내리는 구현이라 자동 방전이 켜져 있으면 실제로는 배터리를
50%까지 태워 내린다. 동작은 그대로 두고 편집기와 알림에 명시한다.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

### Task 8: 신규 문자열 30개 로케일 번역

**Files:**
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Test: `WattlyTests/LocalizationTests.swift`

**Interfaces:**
- Consumes: Task 2·4·5·7이 도입한 5개 소스 문자열
- Produces: 없음 (데이터)

> `json.dumps(d, ensure_ascii=False, indent=2) + "\n"`이 현재 파일과 **바이트 단위로 동일**함을 확인했다. 따라서 아래 스크립트의 diff는 추가된 키에만 국한된다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`WattlyTests/LocalizationTests.swift`의 `stringCatalogTranslationsAcrossLocales` 안, 마지막 `#expect` 뒤에 추가:

```swift
        #expect(String(localized: "배터리 (자동 방전 중)", locale: Locale(identifier: "en")) == "Battery (Auto Discharge)")
        #expect(String(localized: "배터리 (자동 방전 중)", locale: Locale(identifier: "ja")) == "バッテリー（自動放電中）")
        #expect(String(localized: "자동 방전 진행 중", locale: Locale(identifier: "en")) == "Auto discharge in progress")
        #expect(String(localized: "자동 방전 진행 중", locale: Locale(identifier: "de")) == "Automatisches Entladen läuft")
        #expect(String(localized: "자동 방전이 켜져 있어 수동 방전을 사용할 수 없습니다.", locale: Locale(identifier: "en")) == "Manual discharge is unavailable while auto discharge is on.")
        #expect(String(localized: "수동 방전이 진행 중입니다.", locale: Locale(identifier: "en")) == "Manual discharge is in progress.")
        #expect(String(localized: "자동 방전이 켜져 있어 이 스케줄은 배터리를 %lld%%까지 방전합니다.", locale: Locale(identifier: "en")) == "Auto discharge is on, so this schedule will discharge the battery to %lld%%.")
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/LocalizationTests 2>&1 | tail -20
```
Expected: FAIL — 번역이 없어 한국어 키가 그대로 반환된다

- [ ] **Step 3: 카탈로그에 5개 키를 추가한다**

저장소 루트에서 실행:

```bash
python3 - <<'PY'
import json, collections

PATH = 'Wattly/Resources/Localizable.xcstrings'

T = {
"배터리 (자동 방전 중)": {
 "ar":"البطارية (قيد التفريغ التلقائي)","cs":"Baterie (automatické vybíjení)","da":"Batteri (automatisk afladning i gang)",
 "de":"Batterie (Automatisches Entladen läuft)","el":"Μπαταρία (αυτόματη εκφόρτιση σε εξέλιξη)","en":"Battery (Auto Discharge)",
 "es":"Batería (descarga automática en curso)","fi":"Akku (automaattinen purku käynnissä)","fr":"Batterie (décharge automatique en cours)",
 "he":"סוללה (פריקה אוטומטית מתבצעת)","hi":"बैटरी (ऑटो डिस्चार्ज जारी)","hu":"Akkumulátor (automatikus lemerítés folyamatban)",
 "id":"Baterai (Pengosongan Otomatis Berlangsung)","it":"Batteria (scarica automatica in corso)","ja":"バッテリー（自動放電中）",
 "ko":"배터리 (자동 방전 중)","nb":"Batteri (automatisk utlading pågår)","nl":"Batterij (automatisch ontladen bezig)",
 "pl":"Bateria (automatyczne rozładowywanie w toku)","pt-BR":"Bateria (Descarga Automática em Andamento)",
 "pt-PT":"Bateria (descarga automática em curso)","ro":"Baterie (descărcare automată în curs)","ru":"Аккумулятор (авторазрядка)",
 "sv":"Batteri (automatisk urladdning pågår)","th":"แบตเตอรี่ (กำลังคายประจุอัตโนมัติ)","tr":"Pil (Otomatik Deşarj Sürüyor)",
 "uk":"Акумулятор (авторозряджання)","vi":"Pin (Đang tự động xả)","zh-Hans":"电池 (自动放电中)","zh-Hant":"電池 (自動放電中)"},

"자동 방전 진행 중": {
 "ar":"التفريغ التلقائي قيد التقدم","cs":"Probíhá automatické vybíjení","da":"Automatisk afladning i gang",
 "de":"Automatisches Entladen läuft","el":"Αυτόματη εκφόρτιση σε εξέλιξη","en":"Auto discharge in progress",
 "es":"Descarga automática en curso","fi":"Automaattinen purku käynnissä","fr":"Décharge automatique en cours",
 "he":"פריקה אוטומטית מתבצעת","hi":"ऑटो डिस्चार्ज जारी है","hu":"Automatikus lemerítés folyamatban",
 "id":"Pengosongan otomatis sedang berlangsung","it":"Scarica automatica in corso","ja":"自動放電進行中",
 "ko":"자동 방전 진행 중","nb":"Automatisk utlading pågår","nl":"Automatisch ontladen bezig",
 "pl":"Automatyczne rozładowywanie w toku","pt-BR":"Descarga automática em andamento","pt-PT":"Descarga automática em curso",
 "ro":"Descărcare automată în curs","ru":"Авторазрядка выполняется","sv":"Automatisk urladdning pågår",
 "th":"กำลังดำเนินการคายประจุอัตโนมัติ","tr":"Otomatik deşarj sürüyor","uk":"Триває авторозряджання",
 "vi":"Đang tự động xả pin","zh-Hans":"自动放电进行中","zh-Hant":"自動放電進行中"},

"자동 방전이 켜져 있어 수동 방전을 사용할 수 없습니다.": {
 "ar":"التفريغ اليدوي غير متاح أثناء تشغيل التفريغ التلقائي.","cs":"Ruční vybíjení není dostupné, když je zapnuté automatické vybíjení.",
 "da":"Manuel afladning er ikke tilgængelig, når automatisk afladning er slået til.",
 "de":"Manuelles Entladen ist nicht verfügbar, solange automatisches Entladen aktiv ist.",
 "el":"Η χειροκίνητη εκφόρτιση δεν είναι διαθέσιμη όσο είναι ενεργή η αυτόματη εκφόρτιση.",
 "en":"Manual discharge is unavailable while auto discharge is on.",
 "es":"La descarga manual no está disponible mientras la descarga automática esté activada.",
 "fi":"Manuaalinen purku ei ole käytettävissä, kun automaattinen purku on käytössä.",
 "fr":"La décharge manuelle est indisponible tant que la décharge automatique est activée.",
 "he":"פריקה ידנית אינה זמינה כאשר פריקה אוטומטית מופעלת.","hi":"ऑटो डिस्चार्ज चालू होने पर मैन्युअल डिस्चार्ज उपलब्ध नहीं है।",
 "hu":"A kézi lemerítés nem érhető el, amíg az automatikus lemerítés be van kapcsolva.",
 "id":"Pengosongan manual tidak tersedia saat pengosongan otomatis aktif.",
 "it":"La scarica manuale non è disponibile mentre la scarica automatica è attiva.",
 "ja":"自動放電が有効なため、手動放電は使用できません。","ko":"자동 방전이 켜져 있어 수동 방전을 사용할 수 없습니다.",
 "nb":"Manuell utlading er ikke tilgjengelig når automatisk utlading er på.",
 "nl":"Handmatig ontladen is niet beschikbaar zolang automatisch ontladen aanstaat.",
 "pl":"Ręczne rozładowywanie jest niedostępne, gdy włączone jest automatyczne rozładowywanie.",
 "pt-BR":"A descarga manual fica indisponível enquanto a descarga automática estiver ativada.",
 "pt-PT":"A descarga manual não está disponível enquanto a descarga automática estiver ativada.",
 "ro":"Descărcarea manuală nu este disponibilă cât timp descărcarea automată este activată.",
 "ru":"Ручная разрядка недоступна, пока включена авторазрядка.",
 "sv":"Manuell urladdning är inte tillgänglig när automatisk urladdning är på.",
 "th":"เมื่อเปิดการคายประจุอัตโนมัติ จะไม่สามารถใช้การคายประจุด้วยตนเองได้",
 "tr":"Otomatik deşarj açıkken manuel deşarj kullanılamaz.","uk":"Ручне розряджання недоступне, доки увімкнено авторозряджання.",
 "vi":"Không thể dùng xả thủ công khi tự động xả pin đang bật.","zh-Hans":"自动放电已开启，无法使用手动放电。","zh-Hant":"自動放電已開啟，無法使用手動放電。"},

"수동 방전이 진행 중입니다.": {
 "ar":"التفريغ اليدوي قيد التقدم.","cs":"Probíhá ruční vybíjení.","da":"Manuel afladning er i gang.",
 "de":"Manuelles Entladen läuft.","el":"Χειροκίνητη εκφόρτιση σε εξέλιξη.","en":"Manual discharge is in progress.",
 "es":"Hay una descarga manual en curso.","fi":"Manuaalinen purku on käynnissä.","fr":"Une décharge manuelle est en cours.",
 "he":"פריקה ידנית מתבצעת.","hi":"मैन्युअल डिस्चार्ज जारी है।","hu":"Kézi lemerítés van folyamatban.",
 "id":"Pengosongan manual sedang berlangsung.","it":"È in corso una scarica manuale.","ja":"手動放電が進行中です。",
 "ko":"수동 방전이 진행 중입니다.","nb":"Manuell utlading pågår.","nl":"Handmatig ontladen is bezig.",
 "pl":"Trwa ręczne rozładowywanie.","pt-BR":"Há uma descarga manual em andamento.","pt-PT":"Está em curso uma descarga manual.",
 "ro":"O descărcare manuală este în curs.","ru":"Выполняется ручная разрядка.","sv":"Manuell urladdning pågår.",
 "th":"กำลังดำเนินการคายประจุด้วยตนเอง","tr":"Manuel deşarj sürüyor.","uk":"Триває ручне розряджання.",
 "vi":"Đang tiến hành xả pin thủ công.","zh-Hans":"手动放电进行中。","zh-Hant":"手動放電進行中。"},

"자동 방전이 켜져 있어 이 스케줄은 배터리를 %lld%%까지 방전합니다.": {
 "ar":"التفريغ التلقائي مفعّل، لذا سيفرّغ هذا الجدول البطارية حتى %lld%%.",
 "cs":"Automatické vybíjení je zapnuté, takže tento plán vybije baterii na %lld%%.",
 "da":"Automatisk afladning er slået til, så denne tidsplan aflader batteriet til %lld%%.",
 "de":"Automatisches Entladen ist aktiv, daher entlädt dieser Zeitplan den Akku auf %lld%%.",
 "el":"Η αυτόματη εκφόρτιση είναι ενεργή, οπότε αυτό το πρόγραμμα θα εκφορτίσει την μπαταρία στο %lld%%.",
 "en":"Auto discharge is on, so this schedule will discharge the battery to %lld%%.",
 "es":"La descarga automática está activada, por lo que esta programación descargará la batería hasta el %lld%%.",
 "fi":"Automaattinen purku on käytössä, joten tämä ajastus purkaa akun tasolle %lld%%.",
 "fr":"La décharge automatique est activée : cette planification déchargera la batterie jusqu'à %lld%%.",
 "he":"פריקה אוטומטית מופעלת, ולכן לוח זמנים זה יפרוק את הסוללה עד %lld%%.",
 "hi":"ऑटो डिस्चार्ज चालू है, इसलिए यह शेड्यूल बैटरी को %lld%% तक डिस्चार्ज करेगा।",
 "hu":"Az automatikus lemerítés be van kapcsolva, ezért ez az ütemezés %lld%%-ra meríti az akkumulátort.",
 "id":"Pengosongan otomatis aktif, jadi jadwal ini akan mengosongkan baterai hingga %lld%%.",
 "it":"La scarica automatica è attiva, quindi questa pianificazione scaricherà la batteria fino al %lld%%.",
 "ja":"自動放電が有効なため、このスケジュールはバッテリーを %lld%% まで放電します。",
 "ko":"자동 방전이 켜져 있어 이 스케줄은 배터리를 %lld%%까지 방전합니다.",
 "nb":"Automatisk utlading er på, så denne tidsplanen lader ut batteriet til %lld%%.",
 "nl":"Automatisch ontladen staat aan, dus dit schema ontlaadt de batterij tot %lld%%.",
 "pl":"Automatyczne rozładowywanie jest włączone, więc ten harmonogram rozładuje baterię do %lld%%.",
 "pt-BR":"A descarga automática está ativada, então este agendamento descarregará a bateria até %lld%%.",
 "pt-PT":"A descarga automática está ativada, pelo que este agendamento vai descarregar a bateria até %lld%%.",
 "ro":"Descărcarea automată este activată, deci această programare va descărca bateria până la %lld%%.",
 "ru":"Авторазрядка включена, поэтому это расписание разрядит аккумулятор до %lld%%.",
 "sv":"Automatisk urladdning är på, så det här schemat laddar ur batteriet till %lld%%.",
 "th":"การคายประจุอัตโนมัติเปิดอยู่ กำหนดการนี้จะคายประจุแบตเตอรี่จนถึง %lld%%",
 "tr":"Otomatik deşarj açık olduğundan bu zamanlama pili %lld%% seviyesine kadar deşarj eder.",
 "uk":"Авторозряджання ввімкнено, тож цей розклад розрядить акумулятор до %lld%%.",
 "vi":"Tự động xả pin đang bật, nên lịch này sẽ xả pin xuống %lld%%.",
 "zh-Hans":"自动放电已开启，此日程会将电池放电至 %lld%%。","zh-Hant":"自動放電已開啟，此排程會將電池放電至 %lld%%。"},
}

raw = open(PATH, encoding='utf-8').read()
d = json.loads(raw, object_pairs_hook=collections.OrderedDict)
expected = sorted((d['strings']['자동 방전']['localizations']).keys())

for key, table in T.items():
    assert key not in d['strings'], f'이미 있는 키: {key}'
    assert sorted(table.keys()) == expected, f'로케일 누락/초과: {key}'
    d['strings'][key] = collections.OrderedDict([
        ('extractionState', 'manual'),
        ('localizations', collections.OrderedDict(
            (loc, {'stringUnit': {'state': 'translated', 'value': table[loc]}})
            for loc in expected)),
    ])

open(PATH, 'w', encoding='utf-8').write(
    json.dumps(d, ensure_ascii=False, indent=2) + '\n')
print('added', len(T), 'keys x', len(expected), 'locales')
PY
```

Expected: `added 5 keys x 30 locales`

- [ ] **Step 4: diff가 추가분에만 국한됐는지와 테스트를 확인한다**

Run:
```bash
git diff --numstat Wattly/Resources/Localizable.xcstrings
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 | tail -20
```
Expected: numstat의 삭제 열이 `0`(추가만 있음), 테스트 exit 0 · 실패 0

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Resources/Localizable.xcstrings WattlyTests/LocalizationTests.swift
git commit -m "$(cat <<'MSG'
feat(i18n): 자동/수동 방전 구분에 필요한 문자열 5개를 30개 로케일에 넣는다

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

### Task 9: [별도 PR] 엔진 내부 우선순위 표 정합

**Files:**
- Modify: `FanControlShared/BatteryControlEngine.swift:88-97` (`statusForCurrentBelief`), `:215-219` (`reassertHardwareState`)
- Test: `WattlyTests/BatteryControlEngineTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces: 없음 (동작 정합)

> `update()`는 캘리브레이션 → **수동 방전** → Top Up 순으로 보는데(`:331`, `:344`), `statusForCurrentBelief`와 `reassertHardwareState`는 캘리브레이션 → **Top Up** → 수동 방전 순으로 본다. 계획 문서(`docs/plans/2026-08-25-manual-automatic-discharge.md:15`)가 정한 순서는 manual > Top Up이다. 오늘은 코디네이터의 상호배제(`BatteryControlCoordinator.swift:164-169`)가 두 플래그의 동시 활성을 막아 도달 불가지만, 그 상호배제가 한 번이라도 새면 상태가 하드웨어와 다른 목표를 말한다. **이 PR은 설치된 도우미가 교체되기 전까지 동작에 영향이 없다.**

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`WattlyTests/BatteryControlEngineTests.swift`의 마지막 `}` **앞에** 추가:

```swift
    @Test func believedStatusPrefersManualDischargeOverTopUpLikeUpdateDoes() {
        let mockHardware = MockBatteryHardware()
        let engine = BatteryControlEngine(hardware: mockHardware)
        // 코디네이터의 상호배제가 정상적으로는 막는 모순 입력이다. `update`는 수동 방전을
        // 먼저 보는데 `statusForCurrentBelief`는 Top Up을 먼저 봤다 — 두 곳이 갈라져 있으면
        // 상호배제가 새는 날 상태 표시와 하드웨어가 서로 다른 목표를 말한다.
        engine.configure(BatteryControlConfiguration(
            enabled: true,
            limitPercentage: 80,
            topUpActive: true,
            manualDischargeActive: true,
            manualDischargeTarget: 70))

        let believed = engine.statusForCurrentBelief(currentSoC: 90, isPluggedIn: true)
        #expect(believed.detailReason?.limitPercentage == 70)
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인한다**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/BatteryControlEngineTests 2>&1 | tail -20
```
Expected: FAIL — `limitPercentage`가 100 (Top Up 목표)

- [ ] **Step 3: 두 곳의 순서를 `update()`에 맞춘다**

3-1. `FanControlShared/BatteryControlEngine.swift`의 `statusForCurrentBelief` 안 `let target: Int` 블록을 교체:

```swift
        let target: Int
        if config.calibrationActive {
            target = config.topUpActive ? 100 : config.clampedCalibrationTarget
        } else if config.manualDischargeActive {
            // `update`와 같은 순서다 (수동 방전 > Top Up). 두 곳이 갈라져 있으면 코디네이터의
            // 상호배제가 한 번이라도 새는 날, 상태가 하드웨어와 다른 목표를 말한다.
            target = config.clampedManualDischargeTarget
        } else if config.topUpActive {
            target = 100
        } else {
            target = config.clampedLimitPercentage
        }
```

3-2. `reassertHardwareState` 안 `let target = ...` 식을 교체:

```swift
            // `update`·`statusForCurrentBelief`와 같은 우선순위 체계를 쓴다
            // (캘리브레이션 > 수동 방전 > Top Up > 한도). 이 함수는 프로덕션 호출자가 없다(테스트 전용).
            let target = config.calibrationActive
                ? (config.topUpActive ? 100 : config.clampedCalibrationTarget)
                : (config.manualDischargeActive
                    ? config.clampedManualDischargeTarget
                    : (config.topUpActive ? 100 : config.clampedLimitPercentage))
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run:
```bash
xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' 2>&1 | tail -20
```
Expected: exit 0, 실패 0

- [ ] **Step 5: 커밋**

```bash
git add FanControlShared/BatteryControlEngine.swift WattlyTests/BatteryControlEngineTests.swift
git commit -m "$(cat <<'MSG'
fix(engine): 상태 계산의 방전 우선순위를 update()에 맞춘다

update는 수동 방전을 Top Up보다 먼저 보는데 statusForCurrentBelief와
reassertHardwareState는 반대였다. 상호배제가 새는 날의 지뢰를 제거한다.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
MSG
)"
```

---

## 범위 밖 (별도 건으로 남긴다)

- **Shortcuts/App Intents가 진행 중인 활동을 취소한다.** `BatteryIntentBridge`는 `manualDischargeActive`를 아예 참조하지 않아 `apply`의 기본값 `false`가 나간다. 그래서 수동 방전 중에 아무 Shortcut을 실행하면 방전이 조용히 취소된다. Top Up도 같은 문제를 갖는다 — `revivedConfiguration`이 캘리브레이션만 되살리기 때문이며, 자동/수동 분리 고유의 결함이 아니다. Task 3의 불변식은 이 경로를 막지 못한다(취소하는 쓰기는 `manualDischargeActive: false`를 싣고 나간다).
- **수동 방전의 데몬 재시작 생존.** `manualDischargeActive`는 의도적으로 영속되지 않는다. Task 3·4의 상호배제 덕에 재시작 후 자동 방전이 이어받을 수 없으므로 최악이 "방전 중단 후 한도 홀드"라는 안전 상태로 끝난다.

## 검증 잔여 항목 (구현 후)

- 자동 방전을 실제로 돌려(충전 한도 80 + 자동 방전 ON + 잔량 90% 이상, 어댑터 연결) 설정 카드와 팝오버를 눈으로 확인한다. 이번 계획의 UI 주장은 코드 경로 연역이며 실기 확인은 아직 수행되지 않았다.
- 수동 방전을 목표까지 돌려 "방전 완료 (목표 도달)" 알림이 실제로 뜨는지 확인한다(알림 권한 필요).
