# 배터리 설정 UI 수정 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 설정 › 배터리 화면에서 하드코딩된 가짜 수치를 실측값으로 바꾸고, 데몬 계약과 어긋난 게이팅·문구를 바로잡고, 배터리 설정을 최상위 그룹으로 승격한다.

**Architecture:** 세 단계로 나눈다. **P1**은 데이터 진실성 — 970줄짜리 `SettingsBatterySection`에서 방전 카드 두 장을 먼저 떼어낸 뒤, 설정 창이 열려 있는 동안만 배터리 provider를 2초로 깨우는 폴링 수요 게이트를 추가하고, 상수 `-18.4 W`와 `(SoC−target)×3`을 4초 EMA 실측값과 기존 순수 함수 `estimatedDischargeTimeMinutes`로 교체한다. **P2**는 게이팅·문구 — 발열 임계값을 저장 키에서 읽고(단축어 설정을 되돌리는 동작 버그 수정), 자동 방전을 충전 제한에, 수동 방전을 CHIE 지원 여부에 묶고, "한 번만 완충"을 토글로 바꾼다. **P3**는 정보 구조·접근성·다국어. 모든 변경은 앱 측이며 XPC/헬퍼 프로토콜을 건드리지 않으므로 **도우미 재설치가 필요 없다.**

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Swift Testing (`@Test`/`#expect`), XcodeGen, `Localizable.xcstrings` 30개 언어 카탈로그

## Global Constraints

- 배포 타깃 macOS 14.0, Swift 6 모드. 새 API는 14.0에서 사용 가능해야 한다.
- **XPC/헬퍼 프로토콜(`FanControlShared/BatteryControlProtocol.swift`)을 변경하지 않는다.** 변경하면 도우미 재설치가 유발되고 이 계획의 전제가 깨진다.
- **데몬 로직(`FanControlShared/BatteryControlEngine.swift`, `BatteryControlCoordinator.swift`)을 변경하지 않는다.**
- **신규 `StorageKey`를 만들지 않는다.** 만들면 `Defaults`·`SettingsReset`·`SettingsResetTests`가 함께 딸려온다.
- 사용자에게 보이는 모든 새 문자열은 `Localizable.xcstrings`에 30개 언어 전부를 채운다. 부분 번역은 `scripts/add_localizations.py`가 거부한다.
- 가짜 값·플레이스홀더 문구를 새로 만들지 않는다. 값이 없으면 **해당 요소를 숨긴다** — "측정 중", "계산 중" 같은 대체 문구를 쓰지 않는다.
- 순수 판정 로직은 `Wattly/Core/`의 순수 타입에 두고 뷰에서 분기하지 않는다. 색은 `@Environment(\.tokens)`가 필요하므로 뷰에 남는다.
- 파일을 추가·삭제하면 반드시 `xcodegen generate`를 다시 실행한다. `project.yml`은 디렉터리 글롭이라 편집할 필요는 없다.
- 테스트 실행은 `docs/assets/*.png`를 다시 쓴다(`SnapshotGeneratorTests`가 뷰를 실제로 렌더한다). 갱신된 PNG는 의도된 산출물이므로 커밋에 포함한다.

### 공통 명령

빌드:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath .build/dd build
```

전체 테스트:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test
```

단일 테스트:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/SuiteName
```

프로젝트 재생성:
```bash
/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml
```

> `.build/`는 `.gitignore`에 있다. 워크트리 체크아웃에서는 기본 DerivedData 경로가 asset-catalog 단계에서 권한 오류를 내므로 `-derivedDataPath .build/dd`가 필수다.

> **`-only-testing`은 스위트 단위까지만 쓴다.** 메서드까지 지정하면
> (`-only-testing:WattlyTests/SuiteName/testFunctionName`) 이 프로젝트의 Swift Testing
> (`@Test`) 테스트는 **하나도 실행되지 않은 채** `Executed 0 tests` / `** TEST SUCCEEDED **`가
>찍힌다. 실기로 확인했다. 통과했다고 착각하기 딱 좋으므로 GREEN 확인에는 절대 쓰지 않는다.
> (RED 단계에서 컴파일 실패를 확인하는 용도로는 무해하다 — 컴파일은 테스트 선택보다 먼저
> 실패하기 때문이다. 그래도 헷갈리지 않게 스위트 단위로 통일한다.)

---

## File Structure

| 파일 | 책임 | 단계 |
|---|---|---|
| `Wattly/Views/Settings/SettingsBatteryDischargeSection.swift` | **신규** — 자동/수동 방전 카드. 실측 W·ETA를 그리는 유일한 곳이므로 `monitor`를 받는다 | P1 T1 |
| `Wattly/Core/PollPolicy.swift` | 폴링 간격 순수 정책. 설정 창 전용 배터리 수요를 받는 래퍼 추가 | P1 T2 |
| `Wattly/Core/SystemMonitor.swift` | 그 수요를 켜고 끄는 배선 (`setBatteryLiveDemand`) | P1 T3 |
| `Wattly/Core/CardPresentation.swift` | 배터리 순전력 한 줄 표기 (`batteryNetWattText`) | P1 T4 |
| `Wattly/Core/BatterySectionPresentation.swift` | ETA 워밍업 게이트 · 발열 재개 온도 · 방전 차단 사유 · Top-Up 단계 문구 | P1 T5 · P2 |
| `Wattly/Views/Settings/SettingsBatterySection.swift` | 충전 제한 카드만 남는다. 발열·자동방전 게이팅·Top-Up 토글 | P2 |
| `Wattly/Views/SettingsView.swift` | 두 섹션을 형제로 렌더(P1) → 최상위 "배터리" 그룹으로 승격(P3) | P1 T1 · P3 T12 |
| `Wattly/Resources/Localizable.xcstrings` | 문자열 카탈로그 | 전 단계 |
| `scripts/i18n_additions/*.json` | 단계별 신규 키 번역 원문 | 전 단계 |

**분할을 P1 맨 앞에 두는 이유:** 실측 W가 필요한 곳은 수동 방전 카드 하나뿐이다. 분리를 뒤로 미루면 `monitor`를 `SettingsBatterySection`에 넣었다가 나중에 다시 빼는 왕복이 생기고, 그때마다 호출부 4곳을 두 번 고쳐야 한다. 먼저 쪼개면 `monitor`는 새 파일에만 들어가고 `SettingsBatterySection`의 생성자는 끝까지 그대로다.

---

# Phase P1 — 데이터 진실성

## Task 1: 방전 카드를 별도 섹션으로 분리한다

`SettingsBatterySection.swift`는 970줄이고, 이후 태스크가 그 안의 방전 패널을 크게 고친다. 먼저 떼어내야 뒤따르는 diff를 읽을 수 있다.

**Files:**
- Create: `Wattly/Views/Settings/SettingsBatteryDischargeSection.swift`
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift` (카드 2개 · onChange 2개 제거)
- Modify: `Wattly/Views/SettingsView.swift:384-388`
- Modify: `WattlyTests/SnapshotGeneratorTests.swift:703-707`

**Interfaces:**
- Consumes: `BatteryControlClient`
- Produces: `SettingsBatteryDischargeSection(batteryControl:)` — 자동 방전 카드와 수동 방전 카드를 담은 `View`. (`monitor`는 Task 6에서 추가된다.)

- [ ] **Step 1: 새 파일을 만든다**

`Wattly/Views/Settings/SettingsBatteryDischargeSection.swift`를 만든다. 아래 뼈대를 쓰고, 표시된 두 자리에 `SettingsBatterySection.swift`에서 **잘라낸** `autoDischargeCard`(현재 약 641-663행)와 `manualDischargeCard`(약 664-865행) 본문을 그대로 붙여 넣는다. 두 프로퍼티는 한 글자도 바꾸지 않는다 — 이 태스크는 순수 이동이다.

```swift
import SwiftUI

/// 설정 › 배터리의 방전 카드 두 장 — 자동 방전과 수동 방전.
///
/// 충전 제한 카드에서 떼어낸 이유는 두 가지다. `SettingsBatterySection`이 970줄까지 자라
/// 한 화면에 들고 읽기 어려워졌고, 방전은 충전 제한과 다른 하드웨어 축(CHIE,
/// `isDischargeHardwareSupported`)에 걸려 있어 게이팅 조건이 애초에 다르다.
struct SettingsBatteryDischargeSection: View {
    @Environment(\.tokens) private var t
    @Environment(\.locale) private var locale
    let batteryControl: BatteryControlClient

    // `SettingsBatterySection`과 같은 키를 읽는다. `@AppStorage`는 같은 저장소를 보므로
    // 두 뷰가 같은 값을 들고 있어도 어긋나지 않는다.
    @AppStorage(StorageKey.batteryLimitEnabled) private var batteryLimitEnabled = Defaults.batteryLimitEnabled
    @AppStorage(StorageKey.batteryLimitPercentage) private var batteryLimitPercentage = Defaults.batteryLimitPercentage
    @AppStorage(StorageKey.batterySailingEnabled) private var batterySailingEnabled = Defaults.batterySailingEnabled
    @AppStorage(StorageKey.batterySailingDelta) private var batterySailingDelta = Defaults.batterySailingDelta
    @AppStorage(StorageKey.batteryHeatProtectionEnabled) private var batteryHeatProtectionEnabled = Defaults.batteryHeatProtectionEnabled
    @AppStorage(StorageKey.batteryAutoDischargeEnabled) private var autoDischargeEnabled = Defaults.batteryAutoDischargeEnabled
    @AppStorage(StorageKey.batteryManualDischargeTarget) private var manualDischargeTarget = Defaults.batteryManualDischargeTarget

    private var effectiveDelta: Int {
        batterySailingEnabled ? batterySailingDelta : 2
    }

    private var isHardwareUnsupported: Bool {
        batteryControl.status.isHardwareSupported == false
    }

    private var showsConfigurationControls: Bool {
        BatterySectionPresentation.showsConfigurationControls(
            isHardwareSupported: batteryControl.status.isHardwareSupported)
    }

    private var isToggleEnabled: Bool {
        BatterySectionPresentation.isToggleEnabled(
            isHardwareSupported: batteryControl.status.isHardwareSupported,
            isLimitOn: batteryLimitEnabled,
            isHeatProtectionOn: batteryHeatProtectionEnabled)
    }

    private var isLimitPickerEnabled: Bool {
        BatterySectionPresentation.isLimitPickerEnabled(isLimitOn: batteryLimitEnabled)
    }

    var body: some View {
        if showsConfigurationControls {
            VStack(alignment: .leading, spacing: 9) {
                autoDischargeCard
                manualDischargeCard
            }
            .onChange(of: autoDischargeEnabled) { _, isAutoDischarge in
                Task {
                    await batteryControl.setAutoDischarge(
                        enabled: isAutoDischarge,
                        limitPercentage: batteryLimitPercentage,
                        lowerHysteresisDelta: effectiveDelta,
                        heatProtectionEnabled: batteryHeatProtectionEnabled,
                        heatProtectionThresholdCelsius: Defaults.batteryHeatProtectionThreshold,
                        limitEnabled: batteryLimitEnabled,
                        manualDischargeTarget: manualDischargeTarget
                    )
                }
            }
            .onChange(of: manualDischargeTarget) { _, newTarget in
                guard batteryLimitEnabled || batteryHeatProtectionEnabled
                    || batteryControl.status.desiredConfiguration?.manualDischargeActive == true
                else { return }
                Task {
                    await batteryControl.reconcile(
                        enabled: batteryLimitEnabled,
                        limitPercentage: batteryLimitPercentage,
                        lowerHysteresisDelta: effectiveDelta,
                        heatProtectionEnabled: batteryHeatProtectionEnabled,
                        heatProtectionThresholdCelsius: Defaults.batteryHeatProtectionThreshold,
                        autoDischargeEnabled: autoDischargeEnabled,
                        manualDischargeActive: batteryControl.status.desiredConfiguration?.manualDischargeActive == true,
                        manualDischargeTarget: newTarget
                    )
                }
            }
        }
    }

    // ↓ 여기에 SettingsBatterySection.swift에서 잘라낸 `autoDischargeCard` 전체를 붙여 넣는다.

    // ↓ 이어서 잘라낸 `manualDischargeCard` 전체를 붙여 넣는다.
}
```

- [ ] **Step 2: 원본에서 잘라낸 자리를 정리한다**

`Wattly/Views/Settings/SettingsBatterySection.swift`에서 다음을 삭제한다:

1. `if showsConfigurationControls { autoDischargeCard; manualDischargeCard }` 블록 (약 437-440행)
2. `.onChange(of: autoDischargeEnabled) { ... }` 수정자 전체 (약 404-417행)
3. `.onChange(of: manualDischargeTarget) { ... }` 수정자 전체 (약 418-433행)
4. `autoDischargeCard` · `manualDischargeCard` 두 계산 프로퍼티 (Step 1에서 잘라낸 것)

`@AppStorage`와 `effectiveDelta`·`isToggleEnabled` 등의 헬퍼는 **남겨 둔다** — 충전 제한 카드도 쓴다.

- [ ] **Step 3: SettingsView가 두 섹션을 형제로 렌더하게 한다**

`Wattly/Views/SettingsView.swift:384-388`을 교체:

```swift
            if monitor.isPresent(.battery) {
                SettingsBatterySection(batteryControl: batteryControl, scheduleCoordinator: scheduleCoordinator)
                SettingsBatteryDischargeSection(batteryControl: batteryControl)
                SettingsBatteryCalibrationSection(
                    batteryControl: batteryControl, calibration: calibrationCoordinator)
            }
```

- [ ] **Step 4: 스냅샷이 방전 카드를 계속 담게 한다**

`WattlyTests/SnapshotGeneratorTests.swift:703-707`의 `VStack` 내부를 교체:

```swift
            VStack(spacing: 9) {
                SettingsBatterySection(batteryControl: batteryControlClient, scheduleCoordinator: scheduleCoordinator)
                SettingsBatteryDischargeSection(batteryControl: batteryControlClient)
            }
```

- [ ] **Step 5: 프로젝트를 재생성한다**

```bash
/Users/hyunjun_macbook_pro/bin/xcodegen generate --spec project.yml
```

Expected: `No "base" settings found` 경고만 나오고 성공

- [ ] **Step 6: 빌드하고 전체 테스트를 돌린다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test
```

Expected: PASS. 순수 이동이므로 동작 변화가 없어야 한다.

- [ ] **Step 7: 스냅샷을 눈으로 확인한다**

`docs/assets/settings-battery.png`를 열어 자동 방전·수동 방전 카드가 분리 전과 같은 모습으로 남아 있는지 확인한다.

- [ ] **Step 8: 커밋**

```bash
git add Wattly/Views/Settings/ Wattly/Views/SettingsView.swift WattlyTests/SnapshotGeneratorTests.swift \
        Wattly.xcodeproj docs/assets/settings-battery.png
git commit -m "refactor(settings): split the battery discharge cards into their own section"
```

---

## Task 2: 폴링 정책에 설정 창 전용 배터리 수요 추가

팝오버가 닫히면 기본(eco) 모드에서 배터리 provider는 **전혀** 폴링되지 않는다(`PollPolicy.swift:99`, 기본 메뉴바 지표는 power 단독). performance 모드에서도 닫힌 팝오버는 5–10초라 방전 추적에는 너무 느리다.

**Files:**
- Modify: `Wattly/Core/PollPolicy.swift:35-42`
- Test: `WattlyTests/PollPolicyTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces: `providerIntervals(mode:setting:panelVisible:menubarLiveContentEnabled:active:menubarNeeds:heroCard:isACConnected:settingsBatteryLive:) -> [ProviderKind: Duration]` — 마지막 인자는 `Bool = false`

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`WattlyTests/PollPolicyTests.swift`의 `fixedPolicyKeepsEveryActiveProviderAtChosenInterval` 테스트 바로 뒤에 추가:

```swift
    @Test func settingsBatteryDemandKeepsBatteryPolledWhilePanelClosed() {
        let all = Set(ProviderKind.allCases)

        // 기준: 팝오버가 닫히고 메뉴바가 배터리를 쓰지 않으면 배터리는 아예 폴링되지 않는다.
        #expect(providerIntervals(mode: .eco, setting: .auto, panelVisible: false,
                                  menubarLiveContentEnabled: true, active: all,
                                  menubarNeeds: [.cpu]) == [.cpu: .seconds(2)])

        // 설정 창이 요구하면 배터리가 2초로 합류한다.
        #expect(providerIntervals(mode: .eco, setting: .auto, panelVisible: false,
                                  menubarLiveContentEnabled: true, active: all,
                                  menubarNeeds: [.cpu],
                                  settingsBatteryLive: true)
                == [.cpu: .seconds(2), .battery: .seconds(2)])

        // 배터리 카드를 숨겨 `active`에서 빠져 있어도 삽입된다 — 설정 화면은 카드 표시와 무관하다.
        #expect(providerIntervals(mode: .eco, setting: .auto, panelVisible: false,
                                  menubarLiveContentEnabled: false, active: [.cpu],
                                  menubarNeeds: [],
                                  settingsBatteryLive: true) == [.battery: .seconds(2)])

        // 이미 더 빠른 간격이 잡혀 있으면 느리게 만들지 않는다.
        let open = providerIntervals(mode: .eco, setting: .auto, panelVisible: true,
                                     menubarLiveContentEnabled: false, active: all,
                                     menubarNeeds: [], heroCard: .battery,
                                     settingsBatteryLive: true)
        #expect(open[.battery] == .seconds(1))

        // 고정 간격 설정이 2초보다 느리면 끌어올린다.
        // `active`에 `.battery`를 반드시 넣는다 — 고정 간격 분기는 `active`에 있는 provider만
        // 결과에 넣으므로, `[.cpu]`만 주면 `.battery` 키가 아예 없어서 위의 "없으면 삽입"
        // 분기를 한 번 더 타게 되고 `min` 경로는 검증되지 않은 채로 남는다.
        #expect(providerIntervals(mode: .eco, setting: .s5, panelVisible: false,
                                  menubarLiveContentEnabled: false, active: [.cpu, .battery],
                                  menubarNeeds: [],
                                  settingsBatteryLive: true)
                == [.cpu: .seconds(5), .battery: .seconds(2)])
    }
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/PollPolicyTests
```

Expected: 컴파일 실패 — `extra argument 'settingsBatteryLive' in call`

- [ ] **Step 3: 기존 함수를 이름만 바꾼다**

`Wattly/Core/PollPolicy.swift:35`의 선언 한 줄만 바꾼다 (본문은 그대로):

```swift
private func baseProviderIntervals(mode: PowerMode,
                                   setting: PollInterval,
                                   panelVisible: Bool,
                                   menubarLiveContentEnabled: Bool,
                                   active: Set<ProviderKind>,
                                   menubarNeeds: Set<CardKind>,
                                   heroCard: CardKind? = nil,
                                   isACConnected: Bool = false) -> [ProviderKind: Duration] {
```

- [ ] **Step 4: 래퍼를 추가한다**

`baseProviderIntervals`의 닫는 중괄호 바로 뒤에 삽입:

```swift
/// 폴링 간격의 공개 진입점. `baseProviderIntervals`의 결과에 설정 창의 수요를 겹쳐 놓는다.
///
/// 설정 › 배터리는 강제 방전 중 실측 전력을 보여준다. 그런데 팝오버가 닫힌 기본(eco) 상태에서
/// 배터리 provider는 메뉴바가 배터리를 쓰지 않는 한 **한 번도 읽히지 않는다** — 그대로 화면에
/// 올리면 몇 시간 묵은 표본을 실시간이라고 부르게 된다. performance 모드에서도 닫힌 팝오버는
/// 5–10초라 방전 추적에는 너무 느리다.
///
/// `active`에 `.battery`가 없어도 넣는 이유는, 배터리 **카드**를 숨긴 사용자도 설정 화면은 열기
/// 때문이다. 카드 표시 여부와 이 화면의 필요는 별개다. 이미 더 빠른 간격이 잡혀 있으면
/// (팝오버가 함께 열려 있는 경우) 그쪽을 존중한다.
func providerIntervals(mode: PowerMode,
                       setting: PollInterval,
                       panelVisible: Bool,
                       menubarLiveContentEnabled: Bool,
                       active: Set<ProviderKind>,
                       menubarNeeds: Set<CardKind>,
                       heroCard: CardKind? = nil,
                       isACConnected: Bool = false,
                       settingsBatteryLive: Bool = false) -> [ProviderKind: Duration] {
    var result = baseProviderIntervals(mode: mode, setting: setting, panelVisible: panelVisible,
                                       menubarLiveContentEnabled: menubarLiveContentEnabled,
                                       active: active, menubarNeeds: menubarNeeds,
                                       heroCard: heroCard, isACConnected: isACConnected)
    guard settingsBatteryLive else { return result }
    let demand = Duration.seconds(2)
    result[.battery] = result[.battery].map { min($0, demand) } ?? demand
    return result
}
```

- [ ] **Step 5: 테스트가 통과하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/PollPolicyTests
```

Expected: PASS (기존 PollPolicyTests 전부 포함 — 래퍼가 기존 호출부와 시그니처 호환이므로 수정 불필요)

- [ ] **Step 6: 커밋**

```bash
git add Wattly/Core/PollPolicy.swift WattlyTests/PollPolicyTests.swift
git commit -m "feat(poll): add a settings-window battery demand to provider intervals"
```

---

## Task 3: SystemMonitor에 수요 배선

**Files:**
- Modify: `Wattly/Core/SystemMonitor.swift` (프로퍼티 · `currentProviderIntervals` · 신규 메서드)
- Test: `WattlyTests/SystemMonitorTests.swift`

**Interfaces:**
- Consumes: Task 2의 `providerIntervals(..., settingsBatteryLive:)`
- Produces: `SystemMonitor.setBatteryLiveDemand(_ on: Bool)` (`@MainActor`), `SystemMonitor.isBatteryLiveDemanded: Bool`

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`WattlyTests/SystemMonitorTests.swift`의 **기존 `SystemMonitorTests` 스위트 안**, 마지막
`@Test` 뒤(파일 끝의 닫는 `}` 앞)에 추가한다. 이 스위트는 이미 `@MainActor`이고 중첩
`ScriptedProvider`를 들고 있어 새 픽스처를 만들 필요가 없다:

```swift
    @Test func batteryLiveDemandIsIdempotentAndReversible() {
        let battery = ScriptedProvider(kind: .battery, [.pending])
        let monitor = SystemMonitor(providers: [battery], clock: ManualClock())
        #expect(monitor.isBatteryLiveDemanded == false)
        monitor.setBatteryLiveDemand(true)
        #expect(monitor.isBatteryLiveDemanded == true)
        // 같은 값을 다시 넣어도 상태가 흔들리지 않는다.
        monitor.setBatteryLiveDemand(true)
        #expect(monitor.isBatteryLiveDemanded == true)
        monitor.setBatteryLiveDemand(false)
        #expect(monitor.isBatteryLiveDemanded == false)
    }
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/SystemMonitorTests
```

Expected: 컴파일 실패 — `value of type 'SystemMonitor' has no member 'setBatteryLiveDemand'`

- [ ] **Step 3: 프로퍼티를 추가한다**

`Wattly/Core/SystemMonitor.swift:103` (`private var heroCard: CardKind?` 바로 아래)에 추가:

```swift
    /// 설정 › 배터리 방전 섹션이 화면에 있는 동안만 켜지는 수요. 팝오버 가시성과 별개다 —
    /// 설정 창은 팝오버가 닫힌 채로 열리기 때문이다. 배터리 하나만 끌어올리므로 CPU/GPU/온도를
    /// 1초로 돌리는 `setPanelVisible(true)`와 달리 자기전력 비용이 거의 없다.
    private var settingsBatteryLive = false
    var isBatteryLiveDemanded: Bool { settingsBatteryLive }
```

- [ ] **Step 4: 간격 계산에 반영한다**

`Wattly/Core/SystemMonitor.swift:137-142`의 `currentProviderIntervals`를 교체:

```swift
    private var currentProviderIntervals: [ProviderKind: Duration] {
        return providerIntervals(mode: powerMode, setting: pollSetting, panelVisible: panelVisible,
                                 menubarLiveContentEnabled: !currentMenubarNeeds.isEmpty,
                                 active: activeProviderKinds, menubarNeeds: currentMenubarNeeds,
                                 heroCard: heroCard, isACConnected: isACConnected,
                                 settingsBatteryLive: settingsBatteryLive)
    }
```

- [ ] **Step 5: 토글 메서드를 추가한다**

`Wattly/Core/SystemMonitor.swift`의 `setPanelVisible(_:)` (약 192-209행) 바로 아래에 추가:

```swift
    /// 설정 › 배터리 방전 섹션이 나타나고 사라질 때 호출한다. `setPanelVisible`과 같은
    /// before/after 비교 후 재스케줄 패턴을 따른다 — 새로 합류한 provider만 강제로 즉시 읽어
    /// 첫 화면이 빈 상태로 뜨지 않게 한다.
    func setBatteryLiveDemand(_ on: Bool) {
        guard on != settingsBatteryLive else { return }
        let before = currentProviderIntervals
        settingsBatteryLive = on
        let after = currentProviderIntervals
        guard after != before else { return }
        let forced = on ? Set(after.keys).subtracting(before.keys) : []
        reschedule(forceProviders: forced)
    }
```

- [ ] **Step 6: 테스트가 통과하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/SystemMonitorTests
```

Expected: PASS

- [ ] **Step 7: 커밋**

```bash
git add Wattly/Core/SystemMonitor.swift WattlyTests/SystemMonitorTests.swift
git commit -m "feat(monitor): expose setBatteryLiveDemand for the settings window"
```

---

## Task 4: 배터리 순전력 표기 함수

**Files:**
- Modify: `Wattly/Core/CardPresentation.swift` (`batteryAverage1mText` 아래, 약 300행)
- Test: `WattlyTests/CardPresentationTests.swift`

**Interfaces:**
- Consumes: 기존 `CardPresentation.batterySign(netW:charging:)`, `CardPresentation.f1(_:)`
- Produces: `CardPresentation.batteryNetWattText(_ s: BatterySample) -> String` — 예: `"−18.4 W"`, `"+30.0 W"`, `"0.0 W"`

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`WattlyTests/CardPresentationTests.swift`의 `batterySignDropsAtZeroMagnitude` 테스트 바로 뒤에 추가:

```swift
    @Test func batteryNetWattTextFollowsTheSharedSignRule() {
        func sample(netW: Double, charging: Bool) -> BatterySample {
            BatterySample(netW: netW, milliamps: 0, volts: 12.0,
                          charging: charging, externalConnected: true)
        }
        #expect(CardPresentation.batteryNetWattText(sample(netW: 18.4, charging: false))
                == "\(minus)18.4 W")
        #expect(CardPresentation.batteryNetWattText(sample(netW: -30.0, charging: true))
                == "+30.0 W")
        // |x| < 0.05 → 부호를 떼는 #17 규칙을 그대로 상속한다.
        #expect(CardPresentation.batteryNetWattText(sample(netW: 0.02, charging: false))
                == "0.0 W")
    }
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/CardPresentationTests
```

Expected: 컴파일 실패 — `type 'CardPresentation' has no member 'batteryNetWattText'`

- [ ] **Step 3: 함수를 구현한다**

`Wattly/Core/CardPresentation.swift`의 `batteryAverage1mText` 함수 바로 아래에 추가:

```swift
    /// 순간 배터리 순전력 한 줄 표기. 부호는 `batterySign`이 단독으로 정하므로 이 함수는
    /// 크기와 단위만 붙인다 — 헤드라인 값·평균 표기와 규칙이 갈라지지 않게 하기 위해서다.
    static func batteryNetWattText(_ s: BatterySample) -> String {
        "\(batterySign(netW: s.netW, charging: s.charging))\(f1(abs(s.netW))) W"
    }
```

- [ ] **Step 4: 테스트가 통과하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/CardPresentationTests
```

Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Core/CardPresentation.swift WattlyTests/CardPresentationTests.swift
git commit -m "feat(presentation): add batteryNetWattText sharing the #17 sign rule"
```

---

## Task 5: ETA 워밍업 게이트

4초 EMA는 방전이 시작되는 순간 직전 홀드 상태(≈0 W)에서 출발한다. 2초 폴링·τ=4초에서 첫 표본은 실제의 약 39%, 두 번째 63%, 10초 지점에서 약 92%다. 워밍업 구간에 계산한 예상 시간은 두 배 이상 과대 추정되므로 그 구간에는 예상 시간을 숨긴다. (실시간 W는 처음부터 보여준다 — 부호와 자릿수는 첫 표본부터 맞다.)

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift` (`estimatedDischargeTime` 아래, 약 441행)
- Test: `WattlyTests/BatterySectionPresentationTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces: `BatterySectionPresentation.shouldShowDischargeEstimate(secondsSinceStart:warmUpSeconds:) -> Bool` — `warmUpSeconds`는 `Double = 10`

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`WattlyTests/BatterySectionPresentationTests.swift` 파일의 마지막 `}` 앞에 추가:

```swift
    @Test func dischargeEstimateStaysHiddenUntilTheEmaWarmsUp() {
        // 방전을 막 시작한 순간 — 4초 EMA는 아직 직전 홀드 상태의 값에 가깝다.
        #expect(BatterySectionPresentation.shouldShowDischargeEstimate(secondsSinceStart: 0) == false)
        #expect(BatterySectionPresentation.shouldShowDischargeEstimate(secondsSinceStart: 9.9) == false)
        // 경계 포함.
        #expect(BatterySectionPresentation.shouldShowDischargeEstimate(secondsSinceStart: 10) == true)
        #expect(BatterySectionPresentation.shouldShowDischargeEstimate(secondsSinceStart: 3_600) == true)
        // 창을 여는 순간 이미 방전 중이던 경우는 아주 큰 경과 시간으로 들어온다.
        #expect(BatterySectionPresentation.shouldShowDischargeEstimate(
            secondsSinceStart: .greatestFiniteMagnitude) == true)
        // 임계값은 주입 가능하다.
        #expect(BatterySectionPresentation.shouldShowDischargeEstimate(
            secondsSinceStart: 3, warmUpSeconds: 2) == true)
    }
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/BatterySectionPresentationTests
```

Expected: 컴파일 실패 — `type 'BatterySectionPresentation' has no member 'shouldShowDischargeEstimate'`

- [ ] **Step 3: 함수를 구현한다**

`Wattly/Core/BatterySectionPresentation.swift`의 `estimatedDischargeTime(...)` 함수 바로 아래에 추가:

```swift
    /// 강제 방전이 막 시작된 구간에서는 예상 완료 시간을 숨긴다.
    ///
    /// 표시에 쓰는 4초 EMA는 방전 직전의 홀드 상태(≈0 W)에서 출발한다. 2초 폴링·τ=4초에서
    /// 첫 표본은 실제 방전 전력의 약 39%, 두 번째 63%, 10초 지점에서 약 92%다. 워밍업 중에
    /// 나눗셈을 하면 예상 시간이 두 배 넘게 과대 추정되므로, 숫자를 하나 더 만들어 내기보다
    /// 그 구간에는 아예 내보내지 않는다. 실시간 소모(W)는 처음부터 표시한다 — 부호와 자릿수는
    /// 첫 표본부터 맞기 때문이다.
    ///
    /// 1분 EMA(`BatterySample.average1mW`)를 쓰지 않는 이유는 따로 있다. 그 EMA는 어댑터 연결
    /// 변화에만 리셋되는데(`BatteryTelemetryPipeline`), 강제 방전은 어댑터를 꽂은 채 시작하므로
    /// 리셋되지 않아 1분 내내 어긋난다.
    static func shouldShowDischargeEstimate(secondsSinceStart: Double,
                                            warmUpSeconds: Double = 10) -> Bool {
        secondsSinceStart >= warmUpSeconds
    }
```

- [ ] **Step 4: 테스트가 통과하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/BatterySectionPresentationTests
```

Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Core/BatterySectionPresentation.swift WattlyTests/BatterySectionPresentationTests.swift
git commit -m "feat(presentation): gate the discharge ETA behind an EMA warm-up window"
```

---

## Task 6: 가짜 값을 실측값으로 교체한다

**Files:**
- Modify: `Wattly/Views/Settings/SettingsBatteryDischargeSection.swift`
- Modify: `Wattly/Views/SettingsView.swift` (`monitor` 전달)
- Modify: `WattlyTests/SnapshotGeneratorTests.swift` (`monitor` 전달)
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Create: `scripts/i18n_additions/battery_settings_live_discharge.json`

**Interfaces:**
- Consumes: `SystemMonitor.setBatteryLiveDemand(_:)` (T3), `CardPresentation.batteryNetWattText(_:)` (T4), `BatterySectionPresentation.shouldShowDischargeEstimate(secondsSinceStart:)` (T5), 기존 `estimatedDischargeTimeMinutes(currentSoC:targetSoC:netWatts:capacityWh:)`, `formatDuration(minutes:locale:)`
- Produces: `SettingsBatteryDischargeSection(monitor:batteryControl:)` — `monitor`가 첫 번째 인자

- [ ] **Step 1: 신규 카탈로그 키를 추가한다**

`scripts/i18n_additions/battery_settings_live_discharge.json` 생성:

```json
{
  "실시간 소모: %@": {
    "ko": "실시간 소모: %@",
    "en": "Live Draw: %@",
    "ja": "リアルタイム消費: %@",
    "zh-Hans": "实时功耗：%@",
    "zh-Hant": "即時功耗：%@",
    "de": "Aktuelle Entnahme: %@",
    "fr": "Consommation en direct : %@",
    "es": "Consumo en vivo: %@",
    "it": "Consumo attuale: %@",
    "pt-BR": "Consumo ao vivo: %@",
    "pt-PT": "Consumo em direto: %@",
    "ru": "Текущий расход: %@",
    "nl": "Actueel verbruik: %@",
    "pl": "Bieżący pobór: %@",
    "tr": "Anlık Tüketim: %@",
    "sv": "Aktuellt uttag: %@",
    "da": "Aktuelt forbrug: %@",
    "nb": "Sanntidsforbruk: %@",
    "fi": "Reaaliaikainen kulutus: %@",
    "cs": "Aktuální odběr: %@",
    "hu": "Aktuális fogyasztás: %@",
    "ro": "Consum curent: %@",
    "el": "Τρέχουσα κατανάλωση: %@",
    "uk": "Поточне споживання: %@",
    "th": "การใช้พลังงานสด: %@",
    "vi": "Mức tiêu thụ hiện tại: %@",
    "id": "Konsumsi Langsung: %@",
    "hi": "लाइव खपत: %@",
    "ar": "الاستهلاك الحالي: %@",
    "he": "צריכה בזמן אמת: %@"
  }
}
```

```bash
python3 scripts/add_localizations.py scripts/i18n_additions/battery_settings_live_discharge.json
```

Expected: 오류 없이 종료

- [ ] **Step 2: 가짜 키를 카탈로그에서 삭제한다**

`add_localizations.py`는 추가 전용이므로 삭제는 직접 한다. 먼저 스크립트가 쓰는 직렬화 옵션을 확인한다:

```bash
grep -n "json.dumps" scripts/add_localizations.py
```

확인된 옵션은 `json.dumps(catalog, ensure_ascii=False, indent=2)`이다 — **`sort_keys`가 없다.**
`sort_keys=True`로 다시 쓰면 카탈로그 전체가 재정렬되어 diff가 파일 전체로 번진다. 아래 스니펫은
그 옵션에 맞춰져 있다:

```bash
python3 - <<'EOF'
import json, pathlib
p = pathlib.Path("Wattly/Resources/Localizable.xcstrings")
cat = json.loads(p.read_text())
removed = cat["strings"].pop("실시간 소모: -18.4 W", None)
assert removed is not None, "키가 이미 없습니다 — 이미 삭제되었는지 확인하세요"
# `add_localizations.py`와 같은 직렬화 옵션 — `sort_keys`를 넣으면 카탈로그가 통째로 재정렬된다.
p.write_text(json.dumps(cat, ensure_ascii=False, indent=2) + "\n")
print("removed")
EOF
```

Expected: `removed`, 그리고 `git diff --stat Wattly/Resources/Localizable.xcstrings`가 작은 변경만 보여야 한다(파일 전체가 바뀌면 옵션이 어긋난 것이다).

- [ ] **Step 3: 섹션에 `monitor`와 방전 시계를 추가한다**

`Wattly/Views/Settings/SettingsBatteryDischargeSection.swift`의 프로퍼티 선언부를 수정:

```swift
    let monitor: SystemMonitor
    let batteryControl: BatteryControlClient

    /// 강제 방전이 시작된 벽시계 시각. 4초 EMA가 실제 방전 전력까지 오르는 데 걸리는 구간을
    /// 재기 위한 표시 전용 시계다 — Top Up의 12시간 만료처럼 데몬이 소유해야 하는 판정이
    /// 아니므로 뷰가 들고 있어도 진실의 출처가 갈라지지 않는다.
    @State private var dischargeStartedAt: Date?
```

- [ ] **Step 4: 실측 헬퍼를 추가한다**

같은 파일의 `isLimitPickerEnabled` 프로퍼티 아래에 추가:

```swift
    /// 강제 방전이 진행 중인지 — 데몬이 보고한 활동과 원하는 설정 둘 다 본다.
    private var isManualDischargeActive: Bool {
        batteryControl.status.activity == .discharging
            || batteryControl.status.desiredConfiguration?.manualDischargeActive == true
    }

    /// 4초 EMA를 거친 배터리 표본. 표본이 30초 넘게 끊겼다가 재개되면 EMA가 원시값으로
    /// 재시드되므로(`PowerSmoothing.emaStep`의 `maxGap`), 설정 창을 방전 도중에 열었을 때는
    /// 첫 표본부터 곧바로 정확하다.
    private var liveBatterySample: BatterySample? {
        guard case .value(.battery(let s)) = monitor.cardState(.battery, smoothed: true) else {
            return nil
        }
        return s
    }

    private var dischargeElapsedSeconds: Double {
        guard let dischargeStartedAt else { return 0 }
        return Date().timeIntervalSince(dischargeStartedAt)
    }

    /// "예상 완료: 약 34분 후". 표본·용량·워밍업 중 하나라도 없으면 `nil`을 돌려 줄을 통째로
    /// 숨긴다 — 자리를 채우려고 근사치를 지어내지 않는다.
    private func dischargeEstimateText(currentSoC: Int, targetSoC: Int) -> String? {
        guard BatterySectionPresentation.shouldShowDischargeEstimate(
                secondsSinceStart: dischargeElapsedSeconds),
              let sample = liveBatterySample,
              let capacityWh = sample.maxWh,
              let minutes = BatterySectionPresentation.estimatedDischargeTimeMinutes(
                  currentSoC: currentSoC,
                  targetSoC: targetSoC,
                  netWatts: sample.netW,
                  capacityWh: capacityWh)
        else { return nil }
        let duration = BatterySectionPresentation.formatDuration(minutes: minutes, locale: locale)
        return String(format: String(localized: "예상 완료: 약 %@ 후", locale: locale),
                      locale: locale, duration)
    }
```

- [ ] **Step 5: 가짜 값을 교체한다**

`manualDischargeCard`의 방전 진행 패널에서 다음 블록을 찾는다:

```swift
                        HStack {
                            let estMin = max(1, (currentSoC - target) * 3)
                            Text("실시간 소모: -18.4 W")
                                .font(WattlyFont.at(10.5, weight: .regular))
                                .foregroundStyle(t.sub)
                            Spacer()
                            let durationStr = BatterySectionPresentation.formatDuration(minutes: estMin, locale: locale)
                            Text(String(format: String(localized: "예상 완료: 약 %@ 후", locale: locale), durationStr))
                                .font(WattlyFont.at(10.5, weight: .regular))
                                .foregroundStyle(t.sub)
                        }
```

전체를 다음으로 교체한다:

```swift
                        HStack {
                            if let sample = liveBatterySample {
                                Text(verbatim: String(
                                    format: String(localized: "실시간 소모: %@", locale: locale),
                                    locale: locale,
                                    CardPresentation.batteryNetWattText(sample)))
                                    .font(WattlyFont.at(10.5, weight: .regular))
                                    .foregroundStyle(t.sub)
                            }
                            Spacer()
                            if let eta = dischargeEstimateText(currentSoC: currentSoC,
                                                               targetSoC: target) {
                                Text(verbatim: eta)
                                    .font(WattlyFont.at(10.5, weight: .regular))
                                    .foregroundStyle(t.sub)
                            }
                        }
```

- [ ] **Step 6: 수요와 시계를 생명주기에 건다**

`body`의 구조는 Task 1 리뷰 이후 이렇게 되어 있다 — 바깥 `Group`에 데몬 재조정
`.onChange` 두 개가, 안쪽 `VStack`에 카드가 붙는다:

```swift
Group {
    if showsConfigurationControls {
        VStack(alignment: .leading, spacing: 9) { autoDischargeCard; manualDischargeCard }
    }
}
.onChange(of: autoDischargeEnabled) { ... }   // 무조건 배선 — 건드리지 않는다
.onChange(of: manualDischargeTarget) { ... }  // 무조건 배선 — 건드리지 않는다
```

아래 세 수정자는 **안쪽 `VStack`에** 붙인다 (바깥 `Group`이 아니다). 실측 표시가 존재하는
동안에만 필요한 것들이라, 방전 UI가 아예 없는 하드웨어에서까지 배터리 provider를 2초로
깨울 이유가 없기 때문이다. 반대로 위 `.onChange` 두 개는 무조건 배선이 계약이므로
`Group`에 그대로 둔다:

```swift
            .task {
                // 설정 창이 열려 있는 동안만 배터리를 2초로 깨운다. 팝오버가 닫힌 기본 상태에서
                // 배터리 provider는 아예 읽히지 않으므로, 이게 없으면 위 실측값이 묵은 표본이 된다.
                monitor.setBatteryLiveDemand(true)
                // 창을 여는 순간 이미 방전 중이면 EMA는 방금 원시값으로 재시드된 상태다 —
                // 워밍업을 기다릴 이유가 없으므로 게이트를 통과시킨다.
                dischargeStartedAt = isManualDischargeActive ? .distantPast : nil
            }
            .onDisappear { monitor.setBatteryLiveDemand(false) }
            .onChange(of: isManualDischargeActive) { _, active in
                dischargeStartedAt = active ? Date() : nil
            }
```

- [ ] **Step 7: 호출부 2곳을 고친다**

`Wattly/Views/SettingsView.swift`:

```swift
                SettingsBatteryDischargeSection(monitor: monitor, batteryControl: batteryControl)
```

`WattlyTests/SnapshotGeneratorTests.swift`:

```swift
                SettingsBatteryDischargeSection(monitor: monitor, batteryControl: batteryControlClient)
```

> 스냅샷 파일은 400행에서 `let monitor = SystemMonitor(providers: providers)`를 만들어 두었으므로 그대로 쓴다.

- [ ] **Step 8: 빌드하고 전체 테스트를 돌린다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test
```

Expected: PASS

- [ ] **Step 9: 스냅샷을 눈으로 확인한다**

`docs/assets/settings-battery.png`를 연다. 스냅샷은 방전 중이 아닌 상태를 그리므로 실시간 소모 줄이 **나오지 않는 것이 정상**이다. 카드 레이아웃이 깨지지 않았는지만 본다.

- [ ] **Step 10: 커밋**

```bash
git add Wattly/Views/Settings/SettingsBatteryDischargeSection.swift Wattly/Views/SettingsView.swift \
        WattlyTests/SnapshotGeneratorTests.swift Wattly/Resources/Localizable.xcstrings \
        scripts/i18n_additions/battery_settings_live_discharge.json docs/assets/settings-battery.png
git commit -m "fix(settings): replace the hardcoded -18.4 W and 3-min-per-percent ETA with live telemetry"
```

---

# Phase P2 — 게이팅과 문구

## Task 7: 발열 임계값을 저장 키에서 읽는다

**동작 버그다.** 단축어가 `StorageKey.batteryHeatProtectionThreshold`에 40을 쓰고 데몬에 적용해도(`BatteryIntentBridge.swift:306`), 사용자가 설정 화면에서 아무 토글이나 건드리면 상수 35가 데몬으로 나가 단축어 설정을 조용히 되돌린다.

**Files:**
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift` (16곳)
- Modify: `Wattly/Views/Settings/SettingsBatteryDischargeSection.swift` (Task 1에서 옮겨온 곳들)
- Test: `WattlyTests/SettingsBatterySectionTests.swift`

**Interfaces:**
- Consumes: 기존 `StorageKey.batteryHeatProtectionThreshold`
- Produces: `SettingsBatterySection.heatProtectionThresholdForTesting: Int` (테스트 전용 읽기 창구)

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`WattlyTests/SettingsBatterySectionTests.swift`의 마지막 `}` 앞에 추가:

```swift
    @Test @MainActor func heatThresholdIsReadFromStorageNotTheConstant() {
        let d = UserDefaults.standard
        let original = d.object(forKey: StorageKey.batteryHeatProtectionThreshold)
        defer {
            if let original { d.set(original, forKey: StorageKey.batteryHeatProtectionThreshold) }
            else { d.removeObject(forKey: StorageKey.batteryHeatProtectionThreshold) }
        }

        // 단축어가 임계값을 40으로 바꾼 상황을 재현한다.
        d.set(40, forKey: StorageKey.batteryHeatProtectionThreshold)

        let client = BatteryControlClient()
        let view = SettingsBatterySection(batteryControl: client)
        // 섹션은 상수 35가 아니라 저장된 40을 들고 있어야 한다.
        #expect(view.heatProtectionThresholdForTesting == 40)
    }
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/SettingsBatterySectionTests
```

Expected: 컴파일 실패 — `value of type 'SettingsBatterySection' has no member 'heatProtectionThresholdForTesting'`

- [ ] **Step 3: 먼저 상수 사용을 치환한다**

**순서가 중요하다.** 치환을 먼저 하고 선언을 나중에 추가한다. 반대로 하면 `sed`가 방금 추가한
`@AppStorage` 선언줄의 기본값(`= Defaults.batteryHeatProtectionThreshold`)까지 바꿔서
`heatProtectionThreshold = heatProtectionThreshold`라는 자기참조 줄을 만들고, 그걸 손으로
되돌리는 취약한 단계가 하나 더 생긴다. 지금은 두 파일에 선언이 아직 없으므로 치환이 안전하다.

먼저 현재 개수를 기록해 둔다 (치환 뒤 검증에 쓴다):

```bash
grep -c "Defaults.batteryHeatProtectionThreshold" \
  Wattly/Views/Settings/SettingsBatterySection.swift \
  Wattly/Views/Settings/SettingsBatteryDischargeSection.swift
```

Expected: `SettingsBatterySection.swift:12`, `SettingsBatteryDischargeSection.swift:4` (합 16)

```bash
sed -i '' 's/Defaults\.batteryHeatProtectionThreshold/heatProtectionThreshold/g' \
  Wattly/Views/Settings/SettingsBatterySection.swift \
  Wattly/Views/Settings/SettingsBatteryDischargeSection.swift
```

확인 — 두 파일 모두 `Defaults.batteryHeatProtectionThreshold`가 **0개**여야 한다:

```bash
grep -c "Defaults.batteryHeatProtectionThreshold" \
  Wattly/Views/Settings/SettingsBatterySection.swift \
  Wattly/Views/Settings/SettingsBatteryDischargeSection.swift
```

Expected: 둘 다 `0`. 이 시점에서는 아직 컴파일되지 않는다 — 선언이 없기 때문이며, 다음 단계가 고친다.

- [ ] **Step 4: 두 파일에 @AppStorage 선언을 추가한다**

`Wattly/Views/Settings/SettingsBatterySection.swift`의 `@AppStorage` 묶음 마지막
(`manualDischargeTarget` 아래)에 추가:

```swift
    /// 저장된 발열 임계값. **상수 `Defaults`를 직접 보내면 안 된다** — 단축어가 이 키에 쓰기
    /// 때문에(`BatteryIntentBridge`), 상수를 보내는 순간 사용자가 단축어로 지정한 값을 되돌린다.
    @AppStorage(StorageKey.batteryHeatProtectionThreshold) private var heatProtectionThreshold = Defaults.batteryHeatProtectionThreshold

    /// 테스트가 `@AppStorage` 결선을 확인하기 위한 읽기 전용 창구.
    var heatProtectionThresholdForTesting: Int { heatProtectionThreshold }
```

`Wattly/Views/Settings/SettingsBatteryDischargeSection.swift`의 `@AppStorage` 묶음에도 같은
프로퍼티를 추가한다 (테스트 창구는 불필요):

```swift
    /// `SettingsBatterySection`과 같은 이유로 상수가 아니라 저장 키를 읽는다.
    @AppStorage(StorageKey.batteryHeatProtectionThreshold) private var heatProtectionThreshold = Defaults.batteryHeatProtectionThreshold
```

최종 확인 — 각 파일에 `Defaults.batteryHeatProtectionThreshold`가 `@AppStorage` 기본값
**한 곳씩만** 남는다:

```bash
grep -c "Defaults.batteryHeatProtectionThreshold" \
  Wattly/Views/Settings/SettingsBatterySection.swift \
  Wattly/Views/Settings/SettingsBatteryDischargeSection.swift
```

Expected: 두 파일 모두 `1`

- [ ] **Step 5: 테스트가 통과하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/PollPolicyTests
```

Expected: PASS (기존 PollPolicyTests 전부 포함 — 래퍼가 기존 호출부와 시그니처 호환이므로 수정 불필요)

- [ ] **Step 6: 커밋**

```bash
git add Wattly/Core/PollPolicy.swift WattlyTests/PollPolicyTests.swift
git commit -m "feat(poll): add a settings-window battery demand to provider intervals"
```

---

## Task 3: SystemMonitor에 수요 배선

**Files:**
- Modify: `Wattly/Core/SystemMonitor.swift` (프로퍼티 · `currentProviderIntervals` · 신규 메서드)
- Test: `WattlyTests/SystemMonitorTests.swift`

**Interfaces:**
- Consumes: Task 2의 `providerIntervals(..., settingsBatteryLive:)`
- Produces: `SystemMonitor.setBatteryLiveDemand(_ on: Bool)` (`@MainActor`), `SystemMonitor.isBatteryLiveDemanded: Bool`

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`WattlyTests/SystemMonitorTests.swift`의 **기존 `SystemMonitorTests` 스위트 안**, 마지막
`@Test` 뒤(파일 끝의 닫는 `}` 앞)에 추가한다. 이 스위트는 이미 `@MainActor`이고 중첩
`ScriptedProvider`를 들고 있어 새 픽스처를 만들 필요가 없다:

```swift
    @Test func batteryLiveDemandIsIdempotentAndReversible() {
        let battery = ScriptedProvider(kind: .battery, [.pending])
        let monitor = SystemMonitor(providers: [battery], clock: ManualClock())
        #expect(monitor.isBatteryLiveDemanded == false)
        monitor.setBatteryLiveDemand(true)
        #expect(monitor.isBatteryLiveDemanded == true)
        // 같은 값을 다시 넣어도 상태가 흔들리지 않는다.
        monitor.setBatteryLiveDemand(true)
        #expect(monitor.isBatteryLiveDemanded == true)
        monitor.setBatteryLiveDemand(false)
        #expect(monitor.isBatteryLiveDemanded == false)
    }
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/SystemMonitorTests
```

Expected: 컴파일 실패 — `value of type 'SystemMonitor' has no member 'setBatteryLiveDemand'`

- [ ] **Step 3: 프로퍼티를 추가한다**

`Wattly/Core/SystemMonitor.swift:103` (`private var heroCard: CardKind?` 바로 아래)에 추가:

```swift
    /// 설정 › 배터리 방전 섹션이 화면에 있는 동안만 켜지는 수요. 팝오버 가시성과 별개다 —
    /// 설정 창은 팝오버가 닫힌 채로 열리기 때문이다. 배터리 하나만 끌어올리므로 CPU/GPU/온도를
    /// 1초로 돌리는 `setPanelVisible(true)`와 달리 자기전력 비용이 거의 없다.
    private var settingsBatteryLive = false
    var isBatteryLiveDemanded: Bool { settingsBatteryLive }
```

- [ ] **Step 4: 간격 계산에 반영한다**

`Wattly/Core/SystemMonitor.swift:137-142`의 `currentProviderIntervals`를 교체:

```swift
    private var currentProviderIntervals: [ProviderKind: Duration] {
        return providerIntervals(mode: powerMode, setting: pollSetting, panelVisible: panelVisible,
                                 menubarLiveContentEnabled: !currentMenubarNeeds.isEmpty,
                                 active: activeProviderKinds, menubarNeeds: currentMenubarNeeds,
                                 heroCard: heroCard, isACConnected: isACConnected,
                                 settingsBatteryLive: settingsBatteryLive)
    }
```

- [ ] **Step 5: 토글 메서드를 추가한다**

`Wattly/Core/SystemMonitor.swift`의 `setPanelVisible(_:)` (약 192-209행) 바로 아래에 추가:

```swift
    /// 설정 › 배터리 방전 섹션이 나타나고 사라질 때 호출한다. `setPanelVisible`과 같은
    /// before/after 비교 후 재스케줄 패턴을 따른다 — 새로 합류한 provider만 강제로 즉시 읽어
    /// 첫 화면이 빈 상태로 뜨지 않게 한다.
    func setBatteryLiveDemand(_ on: Bool) {
        guard on != settingsBatteryLive else { return }
        let before = currentProviderIntervals
        settingsBatteryLive = on
        let after = currentProviderIntervals
        guard after != before else { return }
        let forced = on ? Set(after.keys).subtracting(before.keys) : []
        reschedule(forceProviders: forced)
    }
```

- [ ] **Step 6: 테스트가 통과하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/SystemMonitorTests
```

Expected: PASS

- [ ] **Step 7: 커밋**

```bash
git add Wattly/Core/SystemMonitor.swift WattlyTests/SystemMonitorTests.swift
git commit -m "feat(monitor): expose setBatteryLiveDemand for the settings window"
```

---

## Task 4: 배터리 순전력 표기 함수

**Files:**
- Modify: `Wattly/Core/CardPresentation.swift` (`batteryAverage1mText` 아래, 약 300행)
- Test: `WattlyTests/CardPresentationTests.swift`

**Interfaces:**
- Consumes: 기존 `CardPresentation.batterySign(netW:charging:)`, `CardPresentation.f1(_:)`
- Produces: `CardPresentation.batteryNetWattText(_ s: BatterySample) -> String` — 예: `"−18.4 W"`, `"+30.0 W"`, `"0.0 W"`

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`WattlyTests/CardPresentationTests.swift`의 `batterySignDropsAtZeroMagnitude` 테스트 바로 뒤에 추가:

```swift
    @Test func batteryNetWattTextFollowsTheSharedSignRule() {
        func sample(netW: Double, charging: Bool) -> BatterySample {
            BatterySample(netW: netW, milliamps: 0, volts: 12.0,
                          charging: charging, externalConnected: true)
        }
        #expect(CardPresentation.batteryNetWattText(sample(netW: 18.4, charging: false))
                == "\(minus)18.4 W")
        #expect(CardPresentation.batteryNetWattText(sample(netW: -30.0, charging: true))
                == "+30.0 W")
        // |x| < 0.05 → 부호를 떼는 #17 규칙을 그대로 상속한다.
        #expect(CardPresentation.batteryNetWattText(sample(netW: 0.02, charging: false))
                == "0.0 W")
    }
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/CardPresentationTests
```

Expected: 컴파일 실패 — `type 'CardPresentation' has no member 'batteryNetWattText'`

- [ ] **Step 3: 함수를 구현한다**

`Wattly/Core/CardPresentation.swift`의 `batteryAverage1mText` 함수 바로 아래에 추가:

```swift
    /// 순간 배터리 순전력 한 줄 표기. 부호는 `batterySign`이 단독으로 정하므로 이 함수는
    /// 크기와 단위만 붙인다 — 헤드라인 값·평균 표기와 규칙이 갈라지지 않게 하기 위해서다.
    static func batteryNetWattText(_ s: BatterySample) -> String {
        "\(batterySign(netW: s.netW, charging: s.charging))\(f1(abs(s.netW))) W"
    }
```

- [ ] **Step 4: 테스트가 통과하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/CardPresentationTests
```

Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Core/CardPresentation.swift WattlyTests/CardPresentationTests.swift
git commit -m "feat(presentation): add batteryNetWattText sharing the #17 sign rule"
```

---

## Task 5: ETA 워밍업 게이트

4초 EMA는 방전이 시작되는 순간 직전 홀드 상태(≈0 W)에서 출발한다. 2초 폴링·τ=4초에서 첫 표본은 실제의 약 39%, 두 번째 63%, 10초 지점에서 약 92%다. 워밍업 구간에 계산한 예상 시간은 두 배 이상 과대 추정되므로 그 구간에는 예상 시간을 숨긴다. (실시간 W는 처음부터 보여준다 — 부호와 자릿수는 첫 표본부터 맞다.)

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift` (`estimatedDischargeTime` 아래, 약 441행)
- Test: `WattlyTests/BatterySectionPresentationTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces: `BatterySectionPresentation.shouldShowDischargeEstimate(secondsSinceStart:warmUpSeconds:) -> Bool` — `warmUpSeconds`는 `Double = 10`

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`WattlyTests/BatterySectionPresentationTests.swift` 파일의 마지막 `}` 앞에 추가:

```swift
    @Test func dischargeEstimateStaysHiddenUntilTheEmaWarmsUp() {
        // 방전을 막 시작한 순간 — 4초 EMA는 아직 직전 홀드 상태의 값에 가깝다.
        #expect(BatterySectionPresentation.shouldShowDischargeEstimate(secondsSinceStart: 0) == false)
        #expect(BatterySectionPresentation.shouldShowDischargeEstimate(secondsSinceStart: 9.9) == false)
        // 경계 포함.
        #expect(BatterySectionPresentation.shouldShowDischargeEstimate(secondsSinceStart: 10) == true)
        #expect(BatterySectionPresentation.shouldShowDischargeEstimate(secondsSinceStart: 3_600) == true)
        // 창을 여는 순간 이미 방전 중이던 경우는 아주 큰 경과 시간으로 들어온다.
        #expect(BatterySectionPresentation.shouldShowDischargeEstimate(
            secondsSinceStart: .greatestFiniteMagnitude) == true)
        // 임계값은 주입 가능하다.
        #expect(BatterySectionPresentation.shouldShowDischargeEstimate(
            secondsSinceStart: 3, warmUpSeconds: 2) == true)
    }
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/BatterySectionPresentationTests
```

Expected: 컴파일 실패 — `type 'BatterySectionPresentation' has no member 'shouldShowDischargeEstimate'`

- [ ] **Step 3: 함수를 구현한다**

`Wattly/Core/BatterySectionPresentation.swift`의 `estimatedDischargeTime(...)` 함수 바로 아래에 추가:

```swift
    /// 강제 방전이 막 시작된 구간에서는 예상 완료 시간을 숨긴다.
    ///
    /// 표시에 쓰는 4초 EMA는 방전 직전의 홀드 상태(≈0 W)에서 출발한다. 2초 폴링·τ=4초에서
    /// 첫 표본은 실제 방전 전력의 약 39%, 두 번째 63%, 10초 지점에서 약 92%다. 워밍업 중에
    /// 나눗셈을 하면 예상 시간이 두 배 넘게 과대 추정되므로, 숫자를 하나 더 만들어 내기보다
    /// 그 구간에는 아예 내보내지 않는다. 실시간 소모(W)는 처음부터 표시한다 — 부호와 자릿수는
    /// 첫 표본부터 맞기 때문이다.
    ///
    /// 1분 EMA(`BatterySample.average1mW`)를 쓰지 않는 이유는 따로 있다. 그 EMA는 어댑터 연결
    /// 변화에만 리셋되는데(`BatteryTelemetryPipeline`), 강제 방전은 어댑터를 꽂은 채 시작하므로
    /// 리셋되지 않아 1분 내내 어긋난다.
    static func shouldShowDischargeEstimate(secondsSinceStart: Double,
                                            warmUpSeconds: Double = 10) -> Bool {
        secondsSinceStart >= warmUpSeconds
    }
```

- [ ] **Step 4: 테스트가 통과하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/BatterySectionPresentationTests
```

Expected: PASS

- [ ] **Step 5: 커밋**

```bash
git add Wattly/Core/BatterySectionPresentation.swift WattlyTests/BatterySectionPresentationTests.swift
git commit -m "feat(presentation): gate the discharge ETA behind an EMA warm-up window"
```

---

## Task 6: 가짜 값을 실측값으로 교체한다

**Files:**
- Modify: `Wattly/Views/Settings/SettingsBatteryDischargeSection.swift`
- Modify: `Wattly/Views/SettingsView.swift` (`monitor` 전달)
- Modify: `WattlyTests/SnapshotGeneratorTests.swift` (`monitor` 전달)
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Create: `scripts/i18n_additions/battery_settings_live_discharge.json`

**Interfaces:**
- Consumes: `SystemMonitor.setBatteryLiveDemand(_:)` (T3), `CardPresentation.batteryNetWattText(_:)` (T4), `BatterySectionPresentation.shouldShowDischargeEstimate(secondsSinceStart:)` (T5), 기존 `estimatedDischargeTimeMinutes(currentSoC:targetSoC:netWatts:capacityWh:)`, `formatDuration(minutes:locale:)`
- Produces: `SettingsBatteryDischargeSection(monitor:batteryControl:)` — `monitor`가 첫 번째 인자

- [ ] **Step 1: 신규 카탈로그 키를 추가한다**

`scripts/i18n_additions/battery_settings_live_discharge.json` 생성:

```json
{
  "실시간 소모: %@": {
    "ko": "실시간 소모: %@",
    "en": "Live Draw: %@",
    "ja": "リアルタイム消費: %@",
    "zh-Hans": "实时功耗：%@",
    "zh-Hant": "即時功耗：%@",
    "de": "Aktuelle Entnahme: %@",
    "fr": "Consommation en direct : %@",
    "es": "Consumo en vivo: %@",
    "it": "Consumo attuale: %@",
    "pt-BR": "Consumo ao vivo: %@",
    "pt-PT": "Consumo em direto: %@",
    "ru": "Текущий расход: %@",
    "nl": "Actueel verbruik: %@",
    "pl": "Bieżący pobór: %@",
    "tr": "Anlık Tüketim: %@",
    "sv": "Aktuellt uttag: %@",
    "da": "Aktuelt forbrug: %@",
    "nb": "Sanntidsforbruk: %@",
    "fi": "Reaaliaikainen kulutus: %@",
    "cs": "Aktuální odběr: %@",
    "hu": "Aktuális fogyasztás: %@",
    "ro": "Consum curent: %@",
    "el": "Τρέχουσα κατανάλωση: %@",
    "uk": "Поточне споживання: %@",
    "th": "การใช้พลังงานสด: %@",
    "vi": "Mức tiêu thụ hiện tại: %@",
    "id": "Konsumsi Langsung: %@",
    "hi": "लाइव खपत: %@",
    "ar": "الاستهلاك الحالي: %@",
    "he": "צריכה בזמן אמת: %@"
  }
}
```

```bash
python3 scripts/add_localizations.py scripts/i18n_additions/battery_settings_live_discharge.json
```

Expected: 오류 없이 종료

- [ ] **Step 2: 가짜 키를 카탈로그에서 삭제한다**

`add_localizations.py`는 추가 전용이므로 삭제는 직접 한다. 먼저 스크립트가 쓰는 직렬화 옵션을 확인한다:

```bash
grep -n "json.dumps" scripts/add_localizations.py
```

확인된 옵션은 `json.dumps(catalog, ensure_ascii=False, indent=2)`이다 — **`sort_keys`가 없다.**
`sort_keys=True`로 다시 쓰면 카탈로그 전체가 재정렬되어 diff가 파일 전체로 번진다. 아래 스니펫은
그 옵션에 맞춰져 있다:

```bash
python3 - <<'EOF'
import json, pathlib
p = pathlib.Path("Wattly/Resources/Localizable.xcstrings")
cat = json.loads(p.read_text())
removed = cat["strings"].pop("실시간 소모: -18.4 W", None)
assert removed is not None, "키가 이미 없습니다 — 이미 삭제되었는지 확인하세요"
# `add_localizations.py`와 같은 직렬화 옵션 — `sort_keys`를 넣으면 카탈로그가 통째로 재정렬된다.
p.write_text(json.dumps(cat, ensure_ascii=False, indent=2) + "\n")
print("removed")
EOF
```

Expected: `removed`, 그리고 `git diff --stat Wattly/Resources/Localizable.xcstrings`가 작은 변경만 보여야 한다(파일 전체가 바뀌면 옵션이 어긋난 것이다).

- [ ] **Step 3: 섹션에 `monitor`와 방전 시계를 추가한다**

`Wattly/Views/Settings/SettingsBatteryDischargeSection.swift`의 프로퍼티 선언부를 수정:

```swift
    let monitor: SystemMonitor
    let batteryControl: BatteryControlClient

    /// 강제 방전이 시작된 벽시계 시각. 4초 EMA가 실제 방전 전력까지 오르는 데 걸리는 구간을
    /// 재기 위한 표시 전용 시계다 — Top Up의 12시간 만료처럼 데몬이 소유해야 하는 판정이
    /// 아니므로 뷰가 들고 있어도 진실의 출처가 갈라지지 않는다.
    @State private var dischargeStartedAt: Date?
```

- [ ] **Step 4: 실측 헬퍼를 추가한다**

같은 파일의 `isLimitPickerEnabled` 프로퍼티 아래에 추가:

```swift
    /// 강제 방전이 진행 중인지 — 데몬이 보고한 활동과 원하는 설정 둘 다 본다.
    private var isManualDischargeActive: Bool {
        batteryControl.status.activity == .discharging
            || batteryControl.status.desiredConfiguration?.manualDischargeActive == true
    }

    /// 4초 EMA를 거친 배터리 표본. 표본이 30초 넘게 끊겼다가 재개되면 EMA가 원시값으로
    /// 재시드되므로(`PowerSmoothing.emaStep`의 `maxGap`), 설정 창을 방전 도중에 열었을 때는
    /// 첫 표본부터 곧바로 정확하다.
    private var liveBatterySample: BatterySample? {
        guard case .value(.battery(let s)) = monitor.cardState(.battery, smoothed: true) else {
            return nil
        }
        return s
    }

    private var dischargeElapsedSeconds: Double {
        guard let dischargeStartedAt else { return 0 }
        return Date().timeIntervalSince(dischargeStartedAt)
    }

    /// "예상 완료: 약 34분 후". 표본·용량·워밍업 중 하나라도 없으면 `nil`을 돌려 줄을 통째로
    /// 숨긴다 — 자리를 채우려고 근사치를 지어내지 않는다.
    private func dischargeEstimateText(currentSoC: Int, targetSoC: Int) -> String? {
        guard BatterySectionPresentation.shouldShowDischargeEstimate(
                secondsSinceStart: dischargeElapsedSeconds),
              let sample = liveBatterySample,
              let capacityWh = sample.maxWh,
              let minutes = BatterySectionPresentation.estimatedDischargeTimeMinutes(
                  currentSoC: currentSoC,
                  targetSoC: targetSoC,
                  netWatts: sample.netW,
                  capacityWh: capacityWh)
        else { return nil }
        let duration = BatterySectionPresentation.formatDuration(minutes: minutes, locale: locale)
        return String(format: String(localized: "예상 완료: 약 %@ 후", locale: locale),
                      locale: locale, duration)
    }
```

- [ ] **Step 5: 가짜 값을 교체한다**

`manualDischargeCard`의 방전 진행 패널에서 다음 블록을 찾는다:

```swift
                        HStack {
                            let estMin = max(1, (currentSoC - target) * 3)
                            Text("실시간 소모: -18.4 W")
                                .font(WattlyFont.at(10.5, weight: .regular))
                                .foregroundStyle(t.sub)
                            Spacer()
                            let durationStr = BatterySectionPresentation.formatDuration(minutes: estMin, locale: locale)
                            Text(String(format: String(localized: "예상 완료: 약 %@ 후", locale: locale), durationStr))
                                .font(WattlyFont.at(10.5, weight: .regular))
                                .foregroundStyle(t.sub)
                        }
```

전체를 다음으로 교체한다:

```swift
                        HStack {
                            if let sample = liveBatterySample {
                                Text(verbatim: String(
                                    format: String(localized: "실시간 소모: %@", locale: locale),
                                    locale: locale,
                                    CardPresentation.batteryNetWattText(sample)))
                                    .font(WattlyFont.at(10.5, weight: .regular))
                                    .foregroundStyle(t.sub)
                            }
                            Spacer()
                            if let eta = dischargeEstimateText(currentSoC: currentSoC,
                                                               targetSoC: target) {
                                Text(verbatim: eta)
                                    .font(WattlyFont.at(10.5, weight: .regular))
                                    .foregroundStyle(t.sub)
                            }
                        }
```

- [ ] **Step 6: 수요와 시계를 생명주기에 건다**

`body`의 구조는 Task 1 리뷰 이후 이렇게 되어 있다 — 바깥 `Group`에 데몬 재조정
`.onChange` 두 개가, 안쪽 `VStack`에 카드가 붙는다:

```swift
Group {
    if showsConfigurationControls {
        VStack(alignment: .leading, spacing: 9) { autoDischargeCard; manualDischargeCard }
    }
}
.onChange(of: autoDischargeEnabled) { ... }   // 무조건 배선 — 건드리지 않는다
.onChange(of: manualDischargeTarget) { ... }  // 무조건 배선 — 건드리지 않는다
```

아래 세 수정자는 **안쪽 `VStack`에** 붙인다 (바깥 `Group`이 아니다). 실측 표시가 존재하는
동안에만 필요한 것들이라, 방전 UI가 아예 없는 하드웨어에서까지 배터리 provider를 2초로
깨울 이유가 없기 때문이다. 반대로 위 `.onChange` 두 개는 무조건 배선이 계약이므로
`Group`에 그대로 둔다:

```swift
            .task {
                // 설정 창이 열려 있는 동안만 배터리를 2초로 깨운다. 팝오버가 닫힌 기본 상태에서
                // 배터리 provider는 아예 읽히지 않으므로, 이게 없으면 위 실측값이 묵은 표본이 된다.
                monitor.setBatteryLiveDemand(true)
                // 창을 여는 순간 이미 방전 중이면 EMA는 방금 원시값으로 재시드된 상태다 —
                // 워밍업을 기다릴 이유가 없으므로 게이트를 통과시킨다.
                dischargeStartedAt = isManualDischargeActive ? .distantPast : nil
            }
            .onDisappear { monitor.setBatteryLiveDemand(false) }
            .onChange(of: isManualDischargeActive) { _, active in
                dischargeStartedAt = active ? Date() : nil
            }
```

- [ ] **Step 7: 호출부 2곳을 고친다**

`Wattly/Views/SettingsView.swift`:

```swift
                SettingsBatteryDischargeSection(monitor: monitor, batteryControl: batteryControl)
```

`WattlyTests/SnapshotGeneratorTests.swift`:

```swift
                SettingsBatteryDischargeSection(monitor: monitor, batteryControl: batteryControlClient)
```

> 스냅샷 파일은 400행에서 `let monitor = SystemMonitor(providers: providers)`를 만들어 두었으므로 그대로 쓴다.

- [ ] **Step 8: 빌드하고 전체 테스트를 돌린다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test
```

Expected: PASS

- [ ] **Step 9: 스냅샷을 눈으로 확인한다**

`docs/assets/settings-battery.png`를 연다. 스냅샷은 방전 중이 아닌 상태를 그리므로 실시간 소모 줄이 **나오지 않는 것이 정상**이다. 카드 레이아웃이 깨지지 않았는지만 본다.

- [ ] **Step 10: 커밋**

```bash
git add Wattly/Views/Settings/SettingsBatteryDischargeSection.swift Wattly/Views/SettingsView.swift \
        WattlyTests/SnapshotGeneratorTests.swift Wattly/Resources/Localizable.xcstrings \
        scripts/i18n_additions/battery_settings_live_discharge.json docs/assets/settings-battery.png
git commit -m "fix(settings): replace the hardcoded -18.4 W and 3-min-per-percent ETA with live telemetry"
```

---

# Phase P2 — 게이팅과 문구

## Task 7: 발열 임계값을 저장 키에서 읽는다

**동작 버그다.** 단축어가 `StorageKey.batteryHeatProtectionThreshold`에 40을 쓰고 데몬에 적용해도(`BatteryIntentBridge.swift:306`), 사용자가 설정 화면에서 아무 토글이나 건드리면 상수 35가 데몬으로 나가 단축어 설정을 조용히 되돌린다.

**Files:**
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift` (16곳)
- Modify: `Wattly/Views/Settings/SettingsBatteryDischargeSection.swift` (Task 1에서 옮겨온 곳들)
- Test: `WattlyTests/SettingsBatterySectionTests.swift`

**Interfaces:**
- Consumes: 기존 `StorageKey.batteryHeatProtectionThreshold`
- Produces: `SettingsBatterySection.heatProtectionThresholdForTesting: Int` (테스트 전용 읽기 창구)

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`WattlyTests/SettingsBatterySectionTests.swift`의 마지막 `}` 앞에 추가:

```swift
    @Test @MainActor func heatThresholdIsReadFromStorageNotTheConstant() {
        let d = UserDefaults.standard
        let original = d.object(forKey: StorageKey.batteryHeatProtectionThreshold)
        defer {
            if let original { d.set(original, forKey: StorageKey.batteryHeatProtectionThreshold) }
            else { d.removeObject(forKey: StorageKey.batteryHeatProtectionThreshold) }
        }

        // 단축어가 임계값을 40으로 바꾼 상황을 재현한다.
        d.set(40, forKey: StorageKey.batteryHeatProtectionThreshold)

        let client = BatteryControlClient()
        let view = SettingsBatterySection(batteryControl: client)
        // 섹션은 상수 35가 아니라 저장된 40을 들고 있어야 한다.
        #expect(view.heatProtectionThresholdForTesting == 40)
    }
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/SettingsBatterySectionTests
```

Expected: 컴파일 실패 — `value of type 'SettingsBatterySection' has no member 'heatProtectionThresholdForTesting'`

- [ ] **Step 3: 두 파일에 @AppStorage를 추가한다**

`Wattly/Views/Settings/SettingsBatterySection.swift`의 `@AppStorage` 묶음 마지막(18행 `manualDischargeTarget` 아래)에 추가:

```swift
    /// 저장된 발열 임계값. **상수 `Defaults`를 직접 보내면 안 된다** — 단축어가 이 키에 쓰기
    /// 때문에(`BatteryIntentBridge`), 상수를 보내는 순간 사용자가 단축어로 지정한 값을 되돌린다.
    @AppStorage(StorageKey.batteryHeatProtectionThreshold) private var heatProtectionThreshold = Defaults.batteryHeatProtectionThreshold

    /// 테스트가 `@AppStorage` 결선을 확인하기 위한 읽기 전용 창구.
    var heatProtectionThresholdForTesting: Int { heatProtectionThreshold }
```

`Wattly/Views/Settings/SettingsBatteryDischargeSection.swift`의 `@AppStorage` 묶음에도 같은 프로퍼티를 추가한다 (테스트 창구는 불필요):

```swift
    /// `SettingsBatterySection`과 같은 이유로 상수가 아니라 저장 키를 읽는다.
    @AppStorage(StorageKey.batteryHeatProtectionThreshold) private var heatProtectionThreshold = Defaults.batteryHeatProtectionThreshold
```

- [ ] **Step 4: 두 파일에서 상수 사용을 치환한다**

```bash
sed -i '' 's/Defaults\.batteryHeatProtectionThreshold/heatProtectionThreshold/g' \
  Wattly/Views/Settings/SettingsBatterySection.swift \
  Wattly/Views/Settings/SettingsBatteryDischargeSection.swift
```

`sed`가 `@AppStorage` 선언줄의 기본값도 바꿔 버리므로 되돌린다. 두 파일에서 다음 패턴을 찾아:

```bash
grep -n "heatProtectionThreshold = heatProtectionThreshold" \
  Wattly/Views/Settings/SettingsBatterySection.swift \
  Wattly/Views/Settings/SettingsBatteryDischargeSection.swift
```

나온 줄을 각각 이렇게 고친다:

```swift
    @AppStorage(StorageKey.batteryHeatProtectionThreshold) private var heatProtectionThreshold = Defaults.batteryHeatProtectionThreshold
```

결과를 확인한다:

```bash
grep -c "Defaults.batteryHeatProtectionThreshold" \
  Wattly/Views/Settings/SettingsBatterySection.swift \
  Wattly/Views/Settings/SettingsBatteryDischargeSection.swift
```

Expected: 두 파일 모두 `1` (`@AppStorage` 기본값 한 곳만 남는다)

- [ ] **Step 5: 테스트가 통과하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test
```

Expected: PASS

- [ ] **Step 6: 커밋**

```bash
git add Wattly/Views/Settings/ WattlyTests/SettingsBatterySectionTests.swift
git commit -m "fix(settings): stop overwriting the Shortcuts-set heat protection threshold"
```

---

## Task 8: 발열 보호 문구를 실제 임계값으로 만들고 비활성 사유를 붙인다

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift`
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift:151-157`
- Modify: `WattlyTests/LocalizationTests.swift:298-301`
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Create: `scripts/i18n_additions/battery_heat_dynamic_copy.json`
- Test: `WattlyTests/BatterySectionPresentationTests.swift`

**Interfaces:**
- Consumes: `BatteryControlConfiguration` (FanControlShared)
- Produces: `BatterySectionPresentation.heatProtectionResumeCelsius(threshold: Int) -> Int`

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`WattlyTests/BatterySectionPresentationTests.swift` 마지막 `}` 앞에 추가:

```swift
    @Test func heatProtectionResumeTemperatureMatchesTheDaemonContract() {
        // 데몬 기본 델타는 2°C이고 하한은 20°C다(BatteryControlConfiguration.resumeTemperatureCelsius).
        #expect(BatterySectionPresentation.heatProtectionResumeCelsius(threshold: 35) == 33)
        #expect(BatterySectionPresentation.heatProtectionResumeCelsius(threshold: 40) == 38)
        // 아주 낮은 임계값을 넣어도, 계약 타입 자체가 임계값 하한을 30°C로 걸어 두므로
        // (BatteryControlConfiguration.clampThreshold = max(30, min(45, v))) 재개 온도는
        // 30 - 2 = 28°C 아래로 내려가지 않는다 — resumeTemperatureCelsius 안의 20°C 바닥은
        // 이 경로로는 닿지 않는다.
        #expect(BatterySectionPresentation.heatProtectionResumeCelsius(threshold: 21) == 28)
    }
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/BatterySectionPresentationTests
```

Expected: 컴파일 실패 — `type 'BatterySectionPresentation' has no member 'heatProtectionResumeCelsius'`

- [ ] **Step 3: 함수를 구현한다**

`Wattly/Core/BatterySectionPresentation.swift`의 `topUpDescription(hours:locale:)` 바로 위에 추가:

```swift
    /// 발열 보호가 충전을 재개하는 온도. 델타와 하한을 여기서 다시 쓰지 않고 데몬이 쓰는
    /// 계약 타입에 물어본다 — 앱은 재개 델타를 전송하지 않으므로 데몬은 언제나
    /// `BatteryControlConfiguration`의 기본값을 쓰고, 두 값이 갈라질 여지를 남기지 않는다.
    static func heatProtectionResumeCelsius(threshold: Int) -> Int {
        BatteryControlConfiguration(heatProtectionThresholdCelsius: threshold)
            .resumeTemperatureCelsius
    }
```

빌드 오류가 나면 파일 상단에 `import FanControlShared`를 추가한다.

- [ ] **Step 4: 테스트가 통과하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/BatterySectionPresentationTests
```

Expected: PASS

- [ ] **Step 5: 신규 카탈로그 키를 추가한다**

`scripts/i18n_additions/battery_heat_dynamic_copy.json` 생성:

```json
{
  "배터리 온도가 %lld°C를 초과하면 충전을 일시 중단하고, %lld°C 이하로 냉각되면 재개합니다.": {
    "ko": "배터리 온도가 %lld°C를 초과하면 충전을 일시 중단하고, %lld°C 이하로 냉각되면 재개합니다.",
    "en": "Pauses charging when the battery exceeds %lld°C and resumes once it cools to %lld°C or below.",
    "ja": "バッテリー温度が%lld°Cを超えると充電を一時停止し、%lld°C以下に冷えると再開します。",
    "zh-Hans": "电池温度超过 %lld°C 时暂停充电，冷却到 %lld°C 及以下时恢复。",
    "zh-Hant": "電池溫度超過 %lld°C 時暫停充電，冷卻到 %lld°C 及以下時恢復。",
    "de": "Pausiert das Laden bei über %lld °C und setzt es fort, sobald die Batterie auf %lld °C oder darunter abgekühlt ist.",
    "fr": "Suspend la charge au-delà de %lld °C et la reprend une fois redescendue à %lld °C ou moins.",
    "es": "Pausa la carga cuando la batería supera los %lld°C y la reanuda al bajar a %lld°C o menos.",
    "it": "Sospende la ricarica oltre %lld°C e la riprende quando scende a %lld°C o meno.",
    "pt-BR": "Pausa o carregamento acima de %lld°C e retoma ao esfriar para %lld°C ou menos.",
    "pt-PT": "Suspende o carregamento acima de %lld°C e retoma ao arrefecer para %lld°C ou menos.",
    "ru": "Приостанавливает зарядку при температуре выше %lld°C и возобновляет при охлаждении до %lld°C и ниже.",
    "nl": "Pauzeert het opladen boven %lld°C en hervat zodra de batterij is afgekoeld tot %lld°C of lager.",
    "pl": "Wstrzymuje ładowanie powyżej %lld°C i wznawia po ochłodzeniu do %lld°C lub mniej.",
    "tr": "Pil %lld°C üzerine çıkınca şarjı duraklatır, %lld°C ve altına düşünce sürdürür.",
    "sv": "Pausar laddningen över %lld°C och återupptar när batteriet svalnat till %lld°C eller lägre.",
    "da": "Sætter opladning på pause over %lld°C og genoptager, når batteriet er kølet til %lld°C eller derunder.",
    "nb": "Setter ladingen på pause over %lld°C og gjenopptar når batteriet er kjølt til %lld°C eller lavere.",
    "fi": "Keskeyttää latauksen yli %lld°C:ssa ja jatkaa, kun akku on jäähtynyt %lld°C:seen tai alle.",
    "cs": "Pozastaví nabíjení nad %lld°C a obnoví je po vychladnutí na %lld°C nebo méně.",
    "hu": "%lld°C fölött szünetelteti a töltést, és %lld°C-ra vagy az alá hűlve folytatja.",
    "ro": "Suspendă încărcarea peste %lld°C și o reia când coboară la %lld°C sau mai puțin.",
    "el": "Διακόπτει τη φόρτιση πάνω από %lld°C και τη συνεχίζει όταν πέσει στους %lld°C ή χαμηλότερα.",
    "uk": "Призупиняє заряджання вище %lld°C і відновлює після охолодження до %lld°C або нижче.",
    "th": "หยุดชาร์จชั่วคราวเมื่อแบตเตอรี่เกิน %lld°C และชาร์จต่อเมื่อเย็นลงถึง %lld°C หรือต่ำกว่า",
    "vi": "Tạm dừng sạc khi pin vượt %lld°C và tiếp tục khi nguội xuống %lld°C hoặc thấp hơn.",
    "id": "Menjeda pengisian saat baterai melebihi %lld°C dan melanjutkan setelah turun ke %lld°C atau kurang.",
    "hi": "बैटरी %lld°C से ऊपर जाने पर चार्जिंग रोकता है और %lld°C या उससे नीचे ठंडा होने पर फिर शुरू करता है।",
    "ar": "يوقف الشحن مؤقتًا عند تجاوز %lld°C ويستأنفه عند التبريد إلى %lld°C أو أقل.",
    "he": "משהה טעינה מעל %lld°C ומחדש אותה כשהסוללה מתקררת ל-%lld°C או פחות."
  }
}
```

```bash
python3 scripts/add_localizations.py scripts/i18n_additions/battery_heat_dynamic_copy.json
```

- [ ] **Step 6: 발열 토글 행을 교체한다**

`Wattly/Views/Settings/SettingsBatterySection.swift:150-157`의 `SettingsToggleRow` 전체를 교체 (문구 동적화 + 누락된 비활성 사유):

```swift
                    SettingsToggleRow(isOn: $batteryHeatProtectionEnabled,
                                      divider: false,
                                      isEnabled: isToggleEnabled,
                                      // 충전 제한 토글에는 있는데 여기만 빠져 있었다 —
                                      // 미지원 기기에서 이유 없이 흐려진 행이 된다.
                                      disabledReason: isToggleEnabled ? nil : "이 Mac은 충전 제어를 지원하지 않습니다") {
                        VStack(alignment: .leading, spacing: 2) {
                            SettingsRowTitle("발열 보호")
                            Text(verbatim: String(
                                format: String(localized: "배터리 온도가 %lld°C를 초과하면 충전을 일시 중단하고, %lld°C 이하로 냉각되면 재개합니다.", locale: locale),
                                locale: locale,
                                Int64(heatProtectionThreshold),
                                Int64(BatterySectionPresentation.heatProtectionResumeCelsius(
                                    threshold: heatProtectionThreshold))))
                                .font(WattlyFont.at(10.5, weight: .regular))
                                .foregroundStyle(t.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
```

- [ ] **Step 7: 낡은 문구를 고정하던 테스트를 갱신한다**

`WattlyTests/LocalizationTests.swift:298-301`의 `heatProtectionTranslationsAcrossLocales`를 교체:

```swift
    @Test func heatProtectionTranslationsAcrossLocales() {
        #expect(String(localized: "발열 보호", locale: Locale(identifier: "en")) == "Heat Protection")
        // 임계값이 문장에 박히지 않고 인자로 들어간다 — 단축어가 임계값을 바꿔도 문구가 따라간다.
        let en = Locale(identifier: "en")
        let text = String(format: String(localized: "배터리 온도가 %lld°C를 초과하면 충전을 일시 중단하고, %lld°C 이하로 냉각되면 재개합니다.", locale: en),
                          locale: en, Int64(40), Int64(38))
        #expect(text.contains("40"))
        #expect(text.contains("38"))
    }
```

- [ ] **Step 8: 낡은 카탈로그 키를 삭제한다**

```bash
python3 - <<'EOF'
import json, pathlib
p = pathlib.Path("Wattly/Resources/Localizable.xcstrings")
cat = json.loads(p.read_text())
removed = cat["strings"].pop("배터리 온도가 35°C를 초과하면 충전을 일시 중단하고, 33°C 이하로 냉각되면 재개합니다.", None)
assert removed is not None, "키가 이미 없습니다"
# `add_localizations.py`와 같은 직렬화 옵션 — `sort_keys`를 넣으면 카탈로그가 통째로 재정렬된다.
p.write_text(json.dumps(cat, ensure_ascii=False, indent=2) + "\n")
print("removed")
EOF
```

- [ ] **Step 9: 전체 테스트를 돌린다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test
```

Expected: PASS

- [ ] **Step 10: 커밋**

```bash
git add Wattly/Core/BatterySectionPresentation.swift Wattly/Views/Settings/SettingsBatterySection.swift \
        WattlyTests/BatterySectionPresentationTests.swift WattlyTests/LocalizationTests.swift \
        Wattly/Resources/Localizable.xcstrings scripts/i18n_additions/battery_heat_dynamic_copy.json \
        docs/assets/settings-battery.png
git commit -m "fix(settings): derive heat protection copy from the stored threshold and explain the disabled row"
```

---

## Task 9: 자동 방전을 충전 제한에 묶는다

데몬은 `config.enabled && config.autoDischargeEnabled`를 요구한다(`BatteryControlEngine.swift:355`). 충전 제한이 꺼져 있으면 자동 방전 토글은 아무 일도 하지 않는 스위치다. Sailing 모드는 이미 같은 게이트를 쓰고 있다.

**Files:**
- Modify: `Wattly/Views/Settings/SettingsBatteryDischargeSection.swift` (`autoDischargeCard`)

**Interfaces:**
- Consumes: 기존 `isLimitPickerEnabled`, `BatterySectionPresentation.limitPickerDisabledReason(isLimitOn:)`
- Produces: 없음

- [ ] **Step 1: 게이트를 바꾼다**

`autoDischargeCard`의 `SettingsToggleRow` 인자 4줄을 교체:

```swift
            SettingsToggleRow(
                isOn: $autoDischargeEnabled,
                divider: false,
                // 데몬은 `config.enabled && config.autoDischargeEnabled`일 때만 자동 방전을
                // 돌린다(BatteryControlEngine). 충전 제한이 꺼져 있는데 켤 수 있게 두면
                // 아무 일도 하지 않는 스위치가 된다 — Sailing 모드와 같은 게이트를 쓴다.
                isEnabled: isLimitPickerEnabled,
                disabledReason: BatterySectionPresentation
                    .limitPickerDisabledReason(isLimitOn: batteryLimitEnabled)
            ) {
```

- [ ] **Step 2: 빌드하고 테스트한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test
```

Expected: PASS

- [ ] **Step 3: 커밋**

```bash
git add Wattly/Views/Settings/SettingsBatteryDischargeSection.swift docs/assets/settings-battery.png
git commit -m "fix(settings): gate auto-discharge on the charge limit as the daemon requires"
```

---

## Task 10: 수동 방전 하드웨어 게이팅 · 차단 사유 정정 · 슬라이더 상한

네 가지를 함께 고친다. 전부 수동 방전 카드 한 곳에 모여 있고, 사유 문구 함수를 한 번만 손대면 되기 때문이다.

1. CHIE 강제 방전을 지원하지 않는 Mac에서 "방전 시작"이 활성으로 보인다 — 캘리브레이션은 이미 `isDischargeHardwareSupported`로 차단하는데 수동 방전만 무방비다.
2. 사유 문구의 첫 분기가 조건과 불일치한다("충전 제어가 꺼져 있습니다" ← 실제 조건은 하드웨어 미지원). 게다가 ko/en 두 갈래만 코드에 박혀 있어 나머지 28개 언어 사용자에게 영어가 나간다.
3. 슬라이더 상한 100%는 `currentSoC > target`이 성립할 수 없어 영구 비활성이다.
4. 비활성 사유가 `.help()` 툴팁으로만 노출돼 실제로는 보이지 않는다(macOS는 disabled 컨트롤에 툴팁을 띄우지 않는다).

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift:474-493`
- Modify: `Wattly/Views/Settings/SettingsBatteryDischargeSection.swift`
- Modify: `WattlyTests/BatterySectionPresentationTests.swift:996-1028`
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Create: `scripts/i18n_additions/battery_discharge_reasons.json`

**Interfaces:**
- Consumes: `BatteryControlServiceStatus.isDischargeHardwareSupported`
- Produces: `BatterySectionPresentation.manualDischargeDisabledReason(isPluggedIn:currentSoC:targetSoC:isHardwareSupported:isDischargeHardwareSupported:isToggleEnabled:locale:) -> String?` — `isDischargeHardwareSupported`는 `Bool = true`로 `isHardwareSupported`와 `isToggleEnabled` **사이**에 들어간다

- [ ] **Step 1: 기존 테스트를 새 계약으로 고쳐 쓴다**

`WattlyTests/BatterySectionPresentationTests.swift:996-1028`의 "2. Hardware unsupported..." 주석과 그 아래 `#expect` 4개를 다음으로 교체:

```swift
        // 2. 하드웨어 미지원 또는 토글 비활성 -> 조건과 일치하는 문구를 쓴다.
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true, currentSoC: 80, targetSoC: 70,
            isHardwareSupported: false, isToggleEnabled: true, locale: ko
        ) == "이 Mac은 충전 제어를 지원하지 않습니다")
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true, currentSoC: 80, targetSoC: 70,
            isHardwareSupported: false, isToggleEnabled: true, locale: en
        ) == "This Mac does not support charge control")
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true, currentSoC: 80, targetSoC: 70,
            isHardwareSupported: true, isToggleEnabled: false, locale: ko
        ) == "이 Mac은 충전 제어를 지원하지 않습니다")
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true, currentSoC: 80, targetSoC: 70,
            isHardwareSupported: true, isToggleEnabled: false, locale: en
        ) == "This Mac does not support charge control")

        // 2-b. 충전 제어는 되지만 CHIE 강제 방전을 지원하지 않는 Mac.
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true, currentSoC: 80, targetSoC: 70,
            isHardwareSupported: true, isDischargeHardwareSupported: false,
            isToggleEnabled: true, locale: ko
        ) == "이 Mac은 강제 방전을 지원하지 않습니다.")
        #expect(BatterySectionPresentation.manualDischargeDisabledReason(
            isPluggedIn: true, currentSoC: 80, targetSoC: 70,
            isHardwareSupported: true, isDischargeHardwareSupported: false,
            isToggleEnabled: true, locale: en
        ) == "This Mac does not support force discharge.")
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/BatterySectionPresentationTests
```

Expected: 컴파일 실패 — `extra argument 'isDischargeHardwareSupported' in call`

- [ ] **Step 3: 신규 카탈로그 키를 추가한다**

`scripts/i18n_additions/battery_discharge_reasons.json` 생성:

> **`이 Mac은 강제 방전을 지원하지 않습니다.`는 넣지 않는다.** 이미 카탈로그에 30개 언어로
> 존재하고 `BatteryNotificationManager.swift:257`이 쓰고 있다. `add_localizations.py`는
> 기존 키를 덮어쓰므로 다시 넣으면 이미 출하된 30개 언어 문구가 조용히 바뀐다.
> 영어 원문도 `"This Mac does not support force discharge."`(forced 아님)이므로 테스트는
> 그 값을 기대해야 한다. 아래 JSON에는 **없는 키 두 개만** 담는다.

```json
{
  "전원 어댑터가 연결되어 있어야 방전할 수 있습니다.": {
    "ko": "전원 어댑터가 연결되어 있어야 방전할 수 있습니다.",
    "en": "Connect power adapter to start discharge.",
    "ja": "放電するには電源アダプタを接続してください。",
    "zh-Hans": "请连接电源适配器后再开始放电。",
    "zh-Hant": "請連接電源轉接器後再開始放電。",
    "de": "Schließe das Netzteil an, um die Entladung zu starten.",
    "fr": "Branchez l’adaptateur secteur pour lancer la décharge.",
    "es": "Conecta el adaptador de corriente para iniciar la descarga.",
    "it": "Collega l’alimentatore per avviare la scarica.",
    "pt-BR": "Conecte o adaptador de energia para iniciar a descarga.",
    "pt-PT": "Ligue o adaptador de corrente para iniciar a descarga.",
    "ru": "Подключите адаптер питания, чтобы начать разрядку.",
    "nl": "Sluit de lichtnetadapter aan om te ontladen.",
    "pl": "Podłącz zasilacz, aby rozpocząć rozładowanie.",
    "tr": "Deşarjı başlatmak için güç adaptörünü bağlayın.",
    "sv": "Anslut nätadaptern för att starta urladdningen.",
    "da": "Tilslut strømforsyningen for at starte afladningen.",
    "nb": "Koble til strømadapteren for å starte utladingen.",
    "fi": "Kytke verkkolaite purkauksen aloittamiseksi.",
    "cs": "Připojte napájecí adaptér a spusťte vybíjení.",
    "hu": "A kisütés indításához csatlakoztasd a hálózati adaptert.",
    "ro": "Conectează adaptorul de alimentare pentru a începe descărcarea.",
    "el": "Συνδέστε το τροφοδοτικό για να ξεκινήσει η εκφόρτιση.",
    "uk": "Підключіть адаптер живлення, щоб почати розрядку.",
    "th": "เชื่อมต่ออะแดปเตอร์ไฟเพื่อเริ่มการคายประจุ",
    "vi": "Kết nối bộ đổi nguồn để bắt đầu xả.",
    "id": "Sambungkan adaptor daya untuk memulai pengosongan.",
    "hi": "डिस्चार्ज शुरू करने के लिए पावर अडैप्टर कनेक्ट करें।",
    "ar": "وصّل محول الطاقة لبدء التفريغ.",
    "he": "חבר את מתאם החשמל כדי להתחיל בפריקה."
  },
  "현재 배터리 잔량이 목표 잔량 이하입니다.": {
    "ko": "현재 배터리 잔량이 목표 잔량 이하입니다.",
    "en": "Battery level is already at or below target.",
    "ja": "バッテリー残量がすでに目標値以下です。",
    "zh-Hans": "电池电量已达到或低于目标值。",
    "zh-Hant": "電池電量已達到或低於目標值。",
    "de": "Der Batteriestand liegt bereits auf oder unter dem Ziel.",
    "fr": "Le niveau de la batterie est déjà au niveau cible ou en dessous.",
    "es": "El nivel de la batería ya está en el objetivo o por debajo.",
    "it": "Il livello della batteria è già pari o inferiore all’obiettivo.",
    "pt-BR": "O nível da bateria já está no alvo ou abaixo dele.",
    "pt-PT": "O nível da bateria já está no alvo ou abaixo dele.",
    "ru": "Уровень заряда уже равен целевому или ниже.",
    "nl": "Het batterijniveau is al gelijk aan of lager dan het doel.",
    "pl": "Poziom baterii jest już na poziomie docelowym lub niższy.",
    "tr": "Pil düzeyi zaten hedefte veya altında.",
    "sv": "Batterinivån är redan på eller under målet.",
    "da": "Batteriniveauet er allerede på eller under målet.",
    "nb": "Batterinivået er allerede på eller under målet.",
    "fi": "Akun varaus on jo tavoitteessa tai sen alle.",
    "cs": "Úroveň baterie je již na cílové hodnotě nebo pod ní.",
    "hu": "Az akkumulátor szintje már eléri a célt vagy alatta van.",
    "ro": "Nivelul bateriei este deja la țintă sau sub aceasta.",
    "el": "Η στάθμη της μπαταρίας είναι ήδη στον στόχο ή χαμηλότερα.",
    "uk": "Рівень заряду вже дорівнює цільовому або нижчий.",
    "th": "ระดับแบตเตอรี่อยู่ที่หรือต่ำกว่าเป้าหมายแล้ว",
    "vi": "Mức pin đã bằng hoặc thấp hơn mục tiêu.",
    "id": "Tingkat baterai sudah pada atau di bawah target.",
    "hi": "बैटरी स्तर पहले से ही लक्ष्य पर या उससे नीचे है।",
    "ar": "مستوى البطارية بالفعل عند الهدف أو أقل منه.",
    "he": "רמת הסוללה כבר ביעד או מתחתיו."
  }
}
```

```bash
python3 scripts/add_localizations.py scripts/i18n_additions/battery_discharge_reasons.json
```

- [ ] **Step 4: 사유 함수를 다시 쓴다**

`Wattly/Core/BatterySectionPresentation.swift:474-493`의 `manualDischargeDisabledReason` 전체를 교체:

```swift
    /// 수동 방전을 시작할 수 없는 이유. 없으면 `nil`.
    ///
    /// 분기 순서가 곧 우선순위다 — 하드웨어가 아예 못 하는 일이 가장 먼저 나오고, 사용자가
    /// 지금 고칠 수 있는 이유(어댑터·목표치)가 뒤에 온다. 문구는 전부 카탈로그 키다.
    /// 이전 구현은 ko/en 두 갈래를 코드에 박아 두어 나머지 28개 언어 사용자에게 영어가 나갔고,
    /// 첫 분기 문구가 조건과 맞지 않았다("충전 제어가 꺼져 있습니다" ← 실제 조건은 미지원 하드웨어).
    static func manualDischargeDisabledReason(
        isPluggedIn: Bool,
        currentSoC: Int,
        targetSoC: Int,
        isHardwareSupported: Bool = true,
        isDischargeHardwareSupported: Bool = true,
        isToggleEnabled: Bool = true,
        locale: Locale = Locale(identifier: "ko")
    ) -> String? {
        guard isHardwareSupported, isToggleEnabled else {
            return String(localized: "이 Mac은 충전 제어를 지원하지 않습니다", locale: locale)
        }
        guard isDischargeHardwareSupported else {
            return String(localized: "이 Mac은 강제 방전을 지원하지 않습니다.", locale: locale)
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

- [ ] **Step 5: 테스트가 통과하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/BatterySectionPresentationTests
```

Expected: PASS

- [ ] **Step 6: 뷰에 방전 하드웨어 게이트를 추가한다**

`Wattly/Views/Settings/SettingsBatteryDischargeSection.swift`의 `isHardwareUnsupported` 프로퍼티 아래에 추가:

```swift
    /// CHIE 강제 방전 미지원. `nil`은 이 필드를 모르는 구버전 헬퍼이며 "미지원"이 아니라
    /// "모름"이므로 차단하지 않는다.
    private var isDischargeUnsupported: Bool {
        batteryControl.status.isDischargeHardwareSupported == false
    }

    /// 수동 방전 컨트롤을 조작할 수 있는지. 하드웨어 두 축을 모두 통과해야 한다.
    private var isManualDischargeActionable: Bool {
        isToggleEnabled && !isHardwareUnsupported && !isDischargeUnsupported
    }
```

- [ ] **Step 7: 슬라이더 상한과 딤 처리를 고친다**

`manualDischargeCard`의 목표 잔량 `VStack` 전체를 교체:

```swift
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("목표 방전 잔량")
                            .font(WattlyFont.at(11.5, weight: .medium))
                            .foregroundStyle(t.sub)
                        Spacer()
                        Text("\(manualDischargeTarget)%")
                            .font(WattlyFont.at(13, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Tokens.statusOrange)
                    }
                    // 다른 섹션과 같은 방식으로 헤더까지 함께 흐려져야 "지금은 못 만진다"가
                    // 한 덩어리로 읽힌다.
                    .opacity(isManualDischargeActionable ? 1 : 0.5)

                    Slider(
                        value: Binding(
                            // 상한을 95로 낮추기 전에 100을 저장한 사용자가 있다. 슬라이더가
                            // 범위 밖 값을 받으면 엄지 위치가 어긋나므로 읽을 때 좁혀 준다.
                            get: { Double(min(max(manualDischargeTarget, 50), 95)) },
                            set: { manualDischargeTarget = Int($0.rounded()) }
                        ),
                        // 100%는 `현재 잔량 > 목표`가 성립할 수 없어 영구 비활성이다 —
                        // 고를 수 있는 값은 전부 실행 가능한 값이어야 한다.
                        in: 50...95,
                        step: 1
                    )
                    .tint(Tokens.statusOrange)
                    .disabled(!isManualDischargeActionable)

                    HStack {
                        Text("50%")
                        Spacer()
                        Text("60%")
                        Spacer()
                        Text("70%")
                        Spacer()
                        Text("80%")
                        Spacer()
                        Text("90%")
                        Spacer()
                        Text("95%")
                    }
                    .font(WattlyFont.at(10, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(t.faint)
                }
                .padding(EdgeInsets(top: 0, leading: 14, bottom: 8, trailing: 14))
```

- [ ] **Step 8: 시작 조건을 고친다**

`manualDischargeCard`의 `canStartDischarge` 정의를 교체:

```swift
                let canStartDischarge = isManualDischargeActionable && isPluggedIn
                    && currentSoC > manualDischargeTarget
```

- [ ] **Step 9: 사유를 본문으로 내보낸다**

`else` 분기(방전 중이 아닐 때) 블록 전체를 다음으로 교체:

```swift
                } else {
                    let disabledReason = BatterySectionPresentation.manualDischargeDisabledReason(
                        isPluggedIn: isPluggedIn,
                        currentSoC: currentSoC,
                        targetSoC: manualDischargeTarget,
                        isHardwareSupported: !isHardwareUnsupported,
                        isDischargeHardwareSupported: !isDischargeUnsupported,
                        isToggleEnabled: isToggleEnabled,
                        locale: locale
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            HStack(spacing: 4) {
                                Text("현재 잔량:")
                                    .font(WattlyFont.at(11, weight: .regular))
                                    .foregroundStyle(t.faint)
                                Text("\(currentSoC)%")
                                    .font(WattlyFont.at(11, weight: .semibold))
                                    .foregroundStyle(t.text)
                            }
                            Spacer()
                            Button {
                                Task {
                                    await batteryControl.startManualDischarge(
                                        target: manualDischargeTarget,
                                        limitPercentage: batteryLimitPercentage,
                                        lowerHysteresisDelta: effectiveDelta,
                                        heatProtectionEnabled: batteryHeatProtectionEnabled,
                                        heatProtectionThresholdCelsius: heatProtectionThreshold,
                                        autoDischargeEnabled: autoDischargeEnabled
                                    )
                                }
                            } label: {
                                Text(verbatim: BatterySectionPresentation.startDischargeButtonText(
                                    targetSoC: manualDischargeTarget,
                                    locale: locale))
                                    .font(WattlyFont.at(11.5, weight: .semibold))
                                    .foregroundStyle(canStartDischarge ? Tokens.statusOrange : t.faint)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(canStartDischarge ? Tokens.statusOrange.opacity(0.15) : t.segTrack)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(canStartDischarge ? Tokens.statusOrange.opacity(0.35) : t.rowBorder, lineWidth: 1)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!canStartDischarge)
                            .accessibilityLabel(Text(verbatim: BatterySectionPresentation.startDischargeButtonText(targetSoC: manualDischargeTarget, locale: locale)))
                            .accessibilityHint(Text(verbatim: disabledReason ?? ""))
                        }
                        // macOS는 disabled 컨트롤에 `.help()` 툴팁을 띄우지 않는다. 사유를
                        // 툴팁에만 걸어 두면 정작 필요한 순간에 보이지 않으므로 본문으로 낸다.
                        if let disabledReason, !canStartDischarge {
                            Text(verbatim: disabledReason)
                                .font(WattlyFont.at(10.5, weight: .regular))
                                .foregroundStyle(t.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(EdgeInsets(top: 0, leading: 14, bottom: 14, trailing: 14))
                }
```

- [ ] **Step 10: 전체 테스트를 돌린다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test
```

Expected: PASS

- [ ] **Step 11: 커밋**

```bash
git add Wattly/Core/BatterySectionPresentation.swift Wattly/Views/Settings/SettingsBatteryDischargeSection.swift \
        WattlyTests/BatterySectionPresentationTests.swift Wattly/Resources/Localizable.xcstrings \
        scripts/i18n_additions/battery_discharge_reasons.json docs/assets/settings-battery.png
git commit -m "fix(settings): gate manual discharge on CHIE support and surface the real reason"
```

---

## Task 11: "한 번만 완충"을 토글로 바꾸고 단계 부문구를 붙인다

현재는 레이블이 상태값(`활성화됨`/`비활성화됨`)인 버튼이라 누르면 무엇이 되는지 알 수 없다. 앱의 다른 설정은 전부 `WattlyToggle`이다.

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift`
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift:157-219`
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Create: `scripts/i18n_additions/battery_top_up_toggle.json`
- Test: `WattlyTests/BatterySectionPresentationTests.swift`

**Interfaces:**
- Consumes: `BatteryControlStatusReason.Kind`, 기존 `topUpDescription(hours:locale:)`, `BatteryTopUpExpiry.durationHours`
- Produces: `BatterySectionPresentation.topUpStatusText(kind:isOn:hours:locale:) -> String`

- [ ] **Step 1: 실패하는 테스트를 작성한다**

`WattlyTests/BatterySectionPresentationTests.swift` 마지막 `}` 앞에 추가:

```swift
    @Test func topUpStatusTextReflectsTheDaemonStage() {
        let ko = Locale(identifier: "ko")
        let off = BatterySectionPresentation.topUpDescription(hours: 12, locale: ko)

        // 꺼져 있으면 기존 설명문 그대로.
        #expect(BatterySectionPresentation.topUpStatusText(
            kind: nil, isOn: false, hours: 12, locale: ko) == off)
        #expect(BatterySectionPresentation.topUpStatusText(
            kind: .topUpCharging, isOn: false, hours: 12, locale: ko) == off)

        // 켜져서 100%로 올라가는 중.
        #expect(BatterySectionPresentation.topUpStatusText(
            kind: .topUpCharging, isOn: true, hours: 12, locale: ko) == "100%까지 충전 중")

        // 완충 유지 — 만료 시간 수가 문장에 들어간다.
        #expect(BatterySectionPresentation.topUpStatusText(
            kind: .topUpComplete, isOn: true, hours: 12, locale: ko)
            == "완충 유지 중 · 12시간 후 자동 해제")
        // `.topUpHeldAtMax`는 현재 엔진이 만들지 않지만, 만들게 되어도 같은 칸에 들어간다.
        #expect(BatterySectionPresentation.topUpStatusText(
            kind: .topUpHeldAtMax, isOn: true, hours: 12, locale: ko)
            == "완충 유지 중 · 12시간 후 자동 해제")

        // 켜져 있는데 reason이 없는 구버전 헬퍼는 기존 설명문으로 안전하게 떨어진다.
        #expect(BatterySectionPresentation.topUpStatusText(
            kind: nil, isOn: true, hours: 12, locale: ko) == off)
    }
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/BatterySectionPresentationTests
```

Expected: 컴파일 실패 — `type 'BatterySectionPresentation' has no member 'topUpStatusText'`

- [ ] **Step 3: 신규 카탈로그 키를 추가한다**

`scripts/i18n_additions/battery_top_up_toggle.json` 생성:

```json
{
  "100%까지 충전 중": {
    "ko": "100%까지 충전 중", "en": "Charging to 100%", "ja": "100%まで充電中",
    "zh-Hans": "正在充电至 100%", "zh-Hant": "正在充電至 100%",
    "de": "Lädt auf 100 %", "fr": "Charge jusqu’à 100 %", "es": "Cargando al 100 %",
    "it": "In carica al 100%", "pt-BR": "Carregando até 100%", "pt-PT": "A carregar até 100%",
    "ru": "Зарядка до 100%", "nl": "Opladen tot 100%", "pl": "Ładowanie do 100%",
    "tr": "%100’e şarj oluyor", "sv": "Laddar till 100 %", "da": "Oplader til 100 %",
    "nb": "Lader til 100 %", "fi": "Ladataan 100 %:iin", "cs": "Nabíjí se na 100 %",
    "hu": "Töltés 100%-ig", "ro": "Se încarcă până la 100%", "el": "Φόρτιση στο 100%",
    "uk": "Заряджання до 100%", "th": "กำลังชาร์จถึง 100%", "vi": "Đang sạc đến 100%",
    "id": "Mengisi hingga 100%", "hi": "100% तक चार्ज हो रहा है",
    "ar": "جارٍ الشحن حتى 100%", "he": "טוען ל-100%"
  },
  "완충 유지 중 · %lld시간 후 자동 해제": {
    "ko": "완충 유지 중 · %lld시간 후 자동 해제",
    "en": "Holding at full · auto-ends in %lld h",
    "ja": "満充電を維持中・%lld時間後に自動解除",
    "zh-Hans": "保持满电 · %lld 小时后自动结束",
    "zh-Hant": "保持滿電 · %lld 小時後自動結束",
    "de": "Bleibt voll · endet automatisch in %lld Std.",
    "fr": "Maintien à 100 % · fin automatique dans %lld h",
    "es": "Manteniendo al 100 % · finaliza en %lld h",
    "it": "Mantiene la carica · termina tra %lld h",
    "pt-BR": "Mantendo carga total · encerra em %lld h",
    "pt-PT": "A manter carga total · termina em %lld h",
    "ru": "Удержание 100% · авто-отключение через %lld ч",
    "nl": "Blijft vol · stopt automatisch over %lld u",
    "pl": "Utrzymanie 100% · koniec za %lld godz.",
    "tr": "Tam doluda tutuluyor · %lld sa sonra biter",
    "sv": "Håller full laddning · avslutas om %lld tim",
    "da": "Holder fuld · slutter om %lld t",
    "nb": "Holder fullt · avsluttes om %lld t",
    "fi": "Pidetään täynnä · päättyy %lld t kuluttua",
    "cs": "Drží plné nabití · skončí za %lld h",
    "hu": "Teljes töltés tartása · %lld óra múlva véget ér",
    "ro": "Menține 100% · se încheie în %lld h",
    "el": "Διατήρηση στο 100% · λήγει σε %lld ώρες",
    "uk": "Утримання 100% · завершиться через %lld год",
    "th": "คงระดับเต็ม · สิ้นสุดอัตโนมัติใน %lld ชม.",
    "vi": "Giữ đầy · tự kết thúc sau %lld giờ",
    "id": "Menahan penuh · berakhir dalam %lld jam",
    "hi": "फुल पर बनाए रखा · %lld घंटे में स्वतः समाप्त",
    "ar": "الإبقاء على الشحن الكامل · ينتهي خلال %lld ساعة",
    "he": "שמירה על טעינה מלאה · יסתיים בעוד %lld שעות"
  },
  "전원 어댑터가 연결되어 있어야 합니다": {
    "ko": "전원 어댑터가 연결되어 있어야 합니다",
    "en": "Requires a connected power adapter",
    "ja": "電源アダプタの接続が必要です",
    "zh-Hans": "需要连接电源适配器", "zh-Hant": "需要連接電源轉接器",
    "de": "Erfordert ein angeschlossenes Netzteil",
    "fr": "Nécessite un adaptateur secteur branché",
    "es": "Requiere un adaptador de corriente conectado",
    "it": "Richiede un alimentatore collegato",
    "pt-BR": "Requer um adaptador de energia conectado",
    "pt-PT": "Requer um adaptador de corrente ligado",
    "ru": "Требуется подключённый адаптер питания",
    "nl": "Vereist een aangesloten lichtnetadapter",
    "pl": "Wymaga podłączonego zasilacza",
    "tr": "Bağlı bir güç adaptörü gerekir",
    "sv": "Kräver en ansluten nätadapter",
    "da": "Kræver en tilsluttet strømforsyning",
    "nb": "Krever tilkoblet strømadapter",
    "fi": "Vaatii kytketyn verkkolaitteen",
    "cs": "Vyžaduje připojený napájecí adaptér",
    "hu": "Csatlakoztatott hálózati adaptert igényel",
    "ro": "Necesită un adaptor de alimentare conectat",
    "el": "Απαιτεί συνδεδεμένο τροφοδοτικό",
    "uk": "Потрібен підключений адаптер живлення",
    "th": "ต้องเชื่อมต่ออะแดปเตอร์ไฟ",
    "vi": "Cần kết nối bộ đổi nguồn",
    "id": "Memerlukan adaptor daya yang tersambung",
    "hi": "कनेक्टेड पावर अडैप्टर आवश्यक है",
    "ar": "يتطلب توصيل محول الطاقة",
    "he": "נדרש מתאם חשמל מחובר"
  }
}
```

```bash
python3 scripts/add_localizations.py scripts/i18n_additions/battery_top_up_toggle.json
```

- [ ] **Step 4: 부문구 함수를 구현한다**

`Wattly/Core/BatterySectionPresentation.swift`의 `topUpDescription(hours:locale:)` 바로 아래에 추가:

```swift
    /// "한 번만 완충" 토글 아래에 붙는 부문구. 데몬이 이미 보내는 `detailReason.kind`로
    /// 충전 중과 완충 유지 중을 가른다.
    ///
    /// 정확한 잔여 시간은 여기서 만들 수 없다 — 만료 시계(`topUpReachedFullAt`)는
    /// `BatteryControlCoordinator`가 소유하고 XPC 상태에 실리지 않는다. 그 값을 실으려면
    /// 헬퍼 프로토콜을 바꿔야 하고, 그러면 사용자가 도우미를 다시 설치해야 한다. 그 대가를
    /// 치를 만큼 필요한 정보라는 근거가 생기기 전까지는 시간 수만 문장에 넣는다.
    static func topUpStatusText(kind: BatteryControlStatusReason.Kind?,
                                isOn: Bool,
                                hours: Int,
                                locale: Locale = Locale(identifier: "ko")) -> String {
        guard isOn else { return topUpDescription(hours: hours, locale: locale) }
        switch kind {
        case .topUpCharging:
            return String(localized: "100%까지 충전 중", locale: locale)
        case .topUpComplete, .topUpHeldAtMax:
            return String(format: String(localized: "완충 유지 중 · %lld시간 후 자동 해제",
                                         locale: locale),
                          locale: locale, Int64(hours))
        default:
            // 구버전 헬퍼는 `detailReason`을 보내지 않는다. 켜져 있다는 사실만 아는 상태이므로
            // 단계를 지어내지 않고 원래 설명문으로 떨어진다.
            return topUpDescription(hours: hours, locale: locale)
        }
    }
```

- [ ] **Step 5: 테스트가 통과하는 것을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test -only-testing:WattlyTests/BatterySectionPresentationTests
```

Expected: PASS

- [ ] **Step 6: 상태 프로퍼티와 바인딩을 추가한다**

`Wattly/Views/Settings/SettingsBatterySection.swift`의 `isHardwareUnsupported` 프로퍼티 위에 추가:

```swift
    /// Top Up이 실제로 걸려 있는지. 어댑터가 빠지면 데몬이 스스로 해제하므로 연결 여부를 함께 본다.
    private var isTopUpActive: Bool {
        batteryControl.status.isPowerAdapterConnected
            && (batteryControl.status.desiredConfiguration?.topUpActive == true
                || batteryControl.status.activity == .topUp)
    }

    /// 토글 ↔ 데몬 명령. 저장되는 설정이 아니라 데몬이 들고 있는 활동이므로 `@AppStorage`가
    /// 아니라 상태에서 읽고 명령으로 쓴다.
    private var topUpBinding: Binding<Bool> {
        Binding(
            get: { isTopUpActive },
            set: { want in
                let limit = batteryLimitPercentage
                let delta = effectiveDelta
                let heatEnabled = batteryHeatProtectionEnabled
                let heatThreshold = heatProtectionThreshold
                let autoDischarge = autoDischargeEnabled
                let manualTarget = manualDischargeTarget
                Task {
                    if want {
                        await batteryControl.startTopUp(
                            limitPercentage: limit,
                            lowerHysteresisDelta: delta,
                            heatProtectionEnabled: heatEnabled,
                            heatProtectionThresholdCelsius: heatThreshold,
                            autoDischargeEnabled: autoDischarge,
                            manualDischargeTarget: manualTarget)
                    } else {
                        await batteryControl.cancelTopUp(
                            limitPercentage: limit,
                            lowerHysteresisDelta: delta,
                            heatProtectionEnabled: heatEnabled,
                            heatProtectionThresholdCelsius: heatThreshold,
                            autoDischargeEnabled: autoDischarge,
                            manualDischargeTarget: manualTarget)
                    }
                }
            }
        )
    }
```

- [ ] **Step 7: 버튼 행을 토글 행으로 교체한다**

`Wattly/Views/Settings/SettingsBatterySection.swift:157-219`의 `HStack { ... }` 블록 전체(구분선 다음 "한 번만 완충" 행, `.padding(EdgeInsets(top: 10, leading: 14, bottom: 14, trailing: 14))`까지)를 다음으로 교체:

```swift
                    SettingsToggleRow(
                        isOn: topUpBinding,
                        divider: false,
                        isEnabled: isToggleEnabled && !isHardwareUnsupported
                            && batteryControl.status.isPowerAdapterConnected,
                        disabledReason: batteryControl.status.isPowerAdapterConnected
                            ? nil : "전원 어댑터가 연결되어 있어야 합니다"
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            SettingsRowTitle("한 번만 완충")
                            Text(verbatim: BatterySectionPresentation.topUpStatusText(
                                kind: batteryControl.status.detailReason?.kind,
                                isOn: isTopUpActive,
                                hours: BatteryTopUpExpiry.durationHours,
                                locale: locale))
                                .font(WattlyFont.at(10.5, weight: .regular))
                                .foregroundStyle(t.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
```

> `SettingsToggleRow`가 켜짐/꺼짐을 VoiceOver 값으로 직접 읽으므로, 삭제된 버튼에 달려 있던 `.accessibilityLabel`/`.accessibilityValue` 수동 배선은 함께 사라진다.

- [ ] **Step 8: 전체 테스트를 돌리고 스냅샷을 확인한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test
```

Expected: PASS. `docs/assets/settings-battery.png`에서 "한 번만 완충"이 토글로 렌더되는지 눈으로 확인한다.

- [ ] **Step 9: 커밋**

```bash
git add Wattly/Core/BatterySectionPresentation.swift Wattly/Views/Settings/SettingsBatterySection.swift \
        WattlyTests/BatterySectionPresentationTests.swift Wattly/Resources/Localizable.xcstrings \
        scripts/i18n_additions/battery_top_up_toggle.json docs/assets/settings-battery.png
git commit -m "feat(settings): turn Top Up into a toggle with a daemon-driven stage sub-line"
```

---

# Phase P3 — 정보 구조 · 접근성 · 다국어

## Task 12: 최상위 "배터리" 그룹을 만든다

**Files:**
- Modify: `Wattly/Views/SettingsView.swift:41-49`, `:377-390`
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift:34` (캡션 · 예약 카드 래핑)
- Modify: `Wattly/Views/Settings/SettingsBatteryDischargeSection.swift` (캡션)
- Modify: `Wattly/Views/Settings/SettingsBatteryCalibrationSection.swift:41` (캡션)
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Create: `scripts/i18n_additions/battery_settings_ia.json`

**Interfaces:**
- Consumes: `SettingsGroupHeader`, `SettingsSection`
- Produces: 없음

- [ ] **Step 1: 신규 캡션 키를 추가한다**

`배터리`(Battery)와 `예약 충전`(Scheduled Charging)은 이미 카탈로그에 있다. `방전`도 있지만 영어가 "Discharging"(진행형)이라 섹션 제목으로 쓸 수 없으므로 새 키 `방전 제어`를 만든다.

`scripts/i18n_additions/battery_settings_ia.json` 생성:

```json
{
  "충전 제한": {
    "ko": "충전 제한", "en": "Charge Limit", "ja": "充電上限",
    "zh-Hans": "充电上限", "zh-Hant": "充電上限",
    "de": "Ladelimit", "fr": "Limite de charge", "es": "Límite de carga",
    "it": "Limite di ricarica", "pt-BR": "Limite de carga", "pt-PT": "Limite de carga",
    "ru": "Лимит заряда", "nl": "Oplaadlimiet", "pl": "Limit ładowania",
    "tr": "Şarj Sınırı", "sv": "Laddningsgräns", "da": "Opladningsgrænse",
    "nb": "Ladegrense", "fi": "Latausraja", "cs": "Limit nabíjení",
    "hu": "Töltési korlát", "ro": "Limită de încărcare", "el": "Όριο φόρτισης",
    "uk": "Ліміт заряду", "th": "ขีดจำกัดการชาร์จ", "vi": "Giới hạn sạc",
    "id": "Batas Pengisian", "hi": "चार्ज सीमा", "ar": "حد الشحن", "he": "מגבלת טעינה"
  },
  "방전 제어": {
    "ko": "방전 제어", "en": "Discharge Control", "ja": "放電制御",
    "zh-Hans": "放电控制", "zh-Hant": "放電控制",
    "de": "Entladesteuerung", "fr": "Contrôle de décharge", "es": "Control de descarga",
    "it": "Controllo della scarica", "pt-BR": "Controle de descarga", "pt-PT": "Controlo de descarga",
    "ru": "Управление разрядкой", "nl": "Ontlaadregeling", "pl": "Sterowanie rozładowaniem",
    "tr": "Deşarj Denetimi", "sv": "Urladdningskontroll", "da": "Afladningsstyring",
    "nb": "Utladingskontroll", "fi": "Purkauksen hallinta", "cs": "Řízení vybíjení",
    "hu": "Kisütés vezérlése", "ro": "Control descărcare", "el": "Έλεγχος εκφόρτισης",
    "uk": "Керування розрядкою", "th": "การควบคุมการคายประจุ", "vi": "Điều khiển xả",
    "id": "Kontrol Pengosongan", "hi": "डिस्चार्ज नियंत्रण", "ar": "التحكم في التفريغ", "he": "בקרת פריקה"
  },
  "진단": {
    "ko": "진단", "en": "Diagnostics", "ja": "診断",
    "zh-Hans": "诊断", "zh-Hant": "診斷",
    "de": "Diagnose", "fr": "Diagnostics", "es": "Diagnóstico",
    "it": "Diagnostica", "pt-BR": "Diagnóstico", "pt-PT": "Diagnóstico",
    "ru": "Диагностика", "nl": "Diagnostiek", "pl": "Diagnostyka",
    "tr": "Tanılama", "sv": "Diagnostik", "da": "Diagnostik",
    "nb": "Diagnostikk", "fi": "Diagnostiikka", "cs": "Diagnostika",
    "hu": "Diagnosztika", "ro": "Diagnostice", "el": "Διαγνωστικά",
    "uk": "Діагностика", "th": "การวินิจฉัย", "vi": "Chẩn đoán",
    "id": "Diagnostik", "hi": "निदान", "ar": "التشخيص", "he": "אבחון"
  }
}
```

```bash
python3 scripts/add_localizations.py scripts/i18n_additions/battery_settings_ia.json
```

- [ ] **Step 2: 그룹을 추가한다**

`Wattly/Views/SettingsView.swift:43-49`의 `VStack`을 수정:

```swift
            VStack(alignment: .leading, spacing: 18) {
                generalGroup
                displayGroup
                menuBarGroup
                behaviorGroup
                batteryGroup
                advancedGroup
            }
```

- [ ] **Step 3: 고급 그룹에서 배터리를 떼어낸다**

`Wattly/Views/SettingsView.swift:375-390`의 `advancedGroup` 전체를 다음 두 프로퍼티로 교체:

```swift
    // MARK: - 배터리 그룹

    @ViewBuilder
    private var batteryGroup: some View {
        if monitor.isPresent(.battery) {
            VStack(alignment: .leading, spacing: 18) {
                SettingsGroupHeader(title: "배터리")
                SettingsBatterySection(batteryControl: batteryControl,
                                       scheduleCoordinator: scheduleCoordinator)
                SettingsBatteryDischargeSection(monitor: monitor, batteryControl: batteryControl)
                SettingsBatteryCalibrationSection(
                    batteryControl: batteryControl, calibration: calibrationCoordinator)
            }
        }
    }

    // MARK: - 고급 그룹

    private var advancedGroup: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroupHeader(title: "고급")
            SettingsThresholdSection(showsFan: monitor.isPresent(.fan))
            if monitor.isPresent(.fan) {
                SettingsFanCurveSection(monitor: monitor, fanControl: fanControl)
            }
        }
    }
```

- [ ] **Step 4: 캡션을 정리한다**

`Wattly/Views/Settings/SettingsBatterySection.swift:34`:

```swift
        SettingsSection(title: "충전 제한") {
```

같은 파일에서 예약 충전 카드가 캡션 없이 충전 제한 밑에 붙어 있으므로 감싼다:

```swift
            if showsConfigurationControls, let scheduleCoordinator {
                SettingsSection("예약 충전") {
                    SettingsScheduleCard(coordinator: scheduleCoordinator)
                }
            }
```

`Wattly/Views/Settings/SettingsBatteryDischargeSection.swift`의 `body`에서 **안쪽** `VStack(alignment: .leading, spacing: 9)`을 `SettingsSection`으로 바꾼다. 바깥 `Group`은 그대로 둔다:

```swift
            SettingsSection("방전 제어") {
                autoDischargeCard
                manualDischargeCard
            }
```

> 수정자는 두 층에 나뉘어 있고 **어느 것도 옮기지 않는다.** 바깥 `Group`에는 데몬 재조정
> `.onChange` 두 개가(무조건 배선 — Task 1 리뷰가 잡은 계약이다), 안쪽에는 Task 6이 붙인
> `.task` / `.onDisappear` / `.onChange(of: isManualDischargeActive)` 세 개가 있다. 안쪽 세 개는
> 붙는 대상이 `VStack`에서 `SettingsSection`으로 바뀔 뿐 동작이 같다.

`Wattly/Views/Settings/SettingsBatteryCalibrationSection.swift:41` — "고급" 그룹 안에 있지 않게 되었으므로 중복 표현을 없앤다:

```swift
        SettingsSection("진단") {
```

- [ ] **Step 5: 낡은 캡션을 고정하던 테스트를 갱신한다**

`WattlyTests/LocalizationTests.swift:245-248`이 `배터리 충전 제어`의 번역을 4개 언어로 못박아
두었다. Step 6에서 그 키를 지우면 `String(localized:)`가 키 자체를 돌려주므로 네 줄 모두
실패한다. 새 캡션 키를 검증하도록 바꾼다:

```swift
        #expect(String(localized: "충전 제한", locale: Locale(identifier: "en")) == "Charge Limit")
        #expect(String(localized: "충전 제한", locale: Locale(identifier: "ja")) == "充電上限")
        #expect(String(localized: "충전 제한", locale: Locale(identifier: "de")) == "Ladelimit")
        #expect(String(localized: "충전 제한", locale: Locale(identifier: "zh-Hans")) == "充电上限")
```

`LocalizationTests.swift:475`의 `이 Mac은 배터리 충전 제어를 지원하지 않는 하드웨어입니다.`는
**다른 키**이며 그대로 둔다 — 이번에 지우는 키가 아니다.

또한 `Wattly/Views/Settings/SettingsBatteryCalibrationSection.swift:4`의 문서 주석이 이 카드를
`"고급 · 배터리 진단"`이라고 부른다. 캡션이 `진단`으로 바뀌므로 주석도 함께 고친다.

- [ ] **Step 6: 낡은 캡션 키를 삭제한다**

```bash
python3 - <<'EOF'
import json, pathlib
p = pathlib.Path("Wattly/Resources/Localizable.xcstrings")
cat = json.loads(p.read_text())
for key in ["배터리 충전 제어", "고급 · 배터리 진단"]:
    cat["strings"].pop(key, None)
# `add_localizations.py`와 같은 직렬화 옵션 — `sort_keys`를 넣으면 카탈로그가 통째로 재정렬된다.
p.write_text(json.dumps(cat, ensure_ascii=False, indent=2) + "\n")
print("removed")
EOF
```

- [ ] **Step 7: 빌드하고 테스트한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test
```

Expected: PASS

- [ ] **Step 8: 커밋**

```bash
git add Wattly/Views/ WattlyTests/LocalizationTests.swift Wattly/Resources/Localizable.xcstrings \
        scripts/i18n_additions/battery_settings_ia.json docs/assets/settings-battery.png
git commit -m "refactor(settings): promote battery to a top-level settings group"
```

---

## Task 13: 접근성 결손 3종

**Files:**
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift` (`batteryStatusRow`)
- Modify: `Wattly/Views/Settings/SettingsBatteryDischargeSection.swift` (슬라이더 · 눈금)
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Create: `scripts/i18n_additions/battery_a11y.json`

**Interfaces:**
- Consumes: 없음
- Produces: 없음

- [ ] **Step 1: 신규 키를 추가한다**

`scripts/i18n_additions/battery_a11y.json` 생성:

```json
{
  "유지보수 상태 보기": {
    "ko": "유지보수 상태 보기", "en": "View maintenance status", "ja": "メンテナンス状況を表示",
    "zh-Hans": "查看维护状态", "zh-Hant": "查看維護狀態",
    "de": "Wartungsstatus anzeigen", "fr": "Afficher l’état de maintenance",
    "es": "Ver estado de mantenimiento", "it": "Mostra stato di manutenzione",
    "pt-BR": "Ver status de manutenção", "pt-PT": "Ver estado de manutenção",
    "ru": "Показать состояние обслуживания", "nl": "Onderhoudsstatus tonen",
    "pl": "Pokaż stan konserwacji", "tr": "Bakım durumunu görüntüle",
    "sv": "Visa underhållsstatus", "da": "Vis vedligeholdelsesstatus",
    "nb": "Vis vedlikeholdsstatus", "fi": "Näytä ylläpidon tila",
    "cs": "Zobrazit stav údržby", "hu": "Karbantartási állapot megtekintése",
    "ro": "Afișează starea de întreținere", "el": "Προβολή κατάστασης συντήρησης",
    "uk": "Показати стан обслуговування", "th": "ดูสถานะการบำรุงรักษา",
    "vi": "Xem trạng thái bảo trì", "id": "Lihat status pemeliharaan",
    "hi": "रखरखाव स्थिति देखें", "ar": "عرض حالة الصيانة", "he": "הצג מצב תחזוקה"
  }
}
```

```bash
python3 scripts/add_localizations.py scripts/i18n_additions/battery_a11y.json
```

- [ ] **Step 2: 상태 행의 결합 범위를 좁힌다**

`Wattly/Views/Settings/SettingsBatterySection.swift`의 `batteryStatusRow`에서 함수 끝의 `.accessibilityElement(children: .combine)` 한 줄을 **삭제**하고, 아이콘과 텍스트만 별도 `HStack`으로 묶는다. 함수 앞부분을 다음으로 교체:

```swift
    private func batteryStatusRow(_ resolved: BatterySectionPresentation.Status) -> some View {
        HStack(spacing: 8) {
            // 아이콘 + 문장만 하나의 VoiceOver 요소로 묶는다. 행 전체를 `.combine` 하면
            // 아래 `?` 버튼과 "도우미 설치" 버튼이 그 요소 안으로 흡수되어 VoiceOver로
            // 도달할 수 없게 된다 — `SettingsToggleRow`가 같은 상황에서 별도
            // `.accessibilityAction`으로 우회한 것과 같은 함정이다.
            HStack(spacing: 8) {
                Image(systemName: resolved.indicator.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor(for: resolved.indicator.tone))
                    // 지역화된 문장이 의미를 담으므로, 장식용 SF Symbol 이름을 영어로 먼저
                    // 읽지 않게 감춘다.
                    .accessibilityHidden(true)
                Text(verbatim: resolved.text)
                    .font(WattlyFont.at(11, weight: .regular))
                    .foregroundStyle(t.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
```

나머지(`?` 버튼 · `Spacer()` · 도우미 설치 버튼 · 닫는 괄호)는 그대로 두고, 함수 마지막의 `.accessibilityElement(children: .combine)`만 지운다. `.padding(.vertical, 2)`는 남긴다.

- [ ] **Step 3: `?` 버튼의 레이블을 고친다**

같은 함수 안 `?` 버튼의 `.accessibilityLabel(...)` 한 줄을 두 줄로 교체:

```swift
            .accessibilityLabel(Text(LocalizedStringKey("유지보수 상태 보기")))
            .accessibilityValue(Text(verbatim: BatterySectionPresentation.maintenancePopoverText(
                resolvedMaintenanceStatus, locale: locale)))
```

- [ ] **Step 4: 슬라이더와 눈금을 고친다**

`Wattly/Views/Settings/SettingsBatteryDischargeSection.swift`의 `Slider(...)` 뒤 `.disabled(!isManualDischargeActionable)` 아래에 추가:

```swift
                    .accessibilityLabel(Text(LocalizedStringKey("목표 방전 잔량")))
                    // 화면에 보이는 헤더와 같은 `effectiveManualDischargeTarget`을 읽는다.
                    // 원시 저장값을 읽으면 상한 이전에 100을 저장한 사용자에게 엄지는 95%,
                    // 눈에 보이는 숫자는 95%인데 VoiceOver만 "100%"라고 말한다.
                    .accessibilityValue(Text(verbatim: "\(effectiveManualDischargeTarget)%"))
```

눈금 `HStack`의 `.foregroundStyle(t.faint)` 아래에 추가:

```swift
                    // 슬라이더 값이 이미 읽히므로 눈금은 VoiceOver 정지점이 될 이유가 없다.
                    .accessibilityHidden(true)
```

- [ ] **Step 5: 빌드하고 테스트한다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test
```

Expected: PASS

- [ ] **Step 6: 커밋**

```bash
git add Wattly/Views/Settings/ Wattly/Resources/Localizable.xcstrings \
        scripts/i18n_additions/battery_a11y.json docs/assets/settings-battery.png
git commit -m "fix(a11y): keep the status row buttons reachable and name the discharge slider"
```

---

## Task 14: 남은 하드코딩 제거와 아이콘 정리

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift:378-386`
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift:73` (도움말 아이콘), `batteryStatusRow`(유지보수 버튼)
- Modify: `Wattly/Views/Settings/SettingsScheduleCard.swift:100-105`
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Create: `scripts/i18n_additions/battery_schedule_i18n.json`

**Interfaces:**
- Consumes: 없음
- Produces: `BatterySectionPresentation.upcomingScheduleText(schedule:triggerDate:locale:) -> String?` — `locale` 인자 추가

- [ ] **Step 1: 신규 키를 추가한다**

`scripts/i18n_additions/battery_schedule_i18n.json` 생성:

```json
{
  "다음: %@ %@": {
    "ko": "다음: %@ %@", "en": "Next: %@ %@", "ja": "次回: %@ %@",
    "zh-Hans": "下次：%@ %@", "zh-Hant": "下次：%@ %@",
    "de": "Nächste: %@ %@", "fr": "Suivant : %@ %@", "es": "Siguiente: %@ %@",
    "it": "Prossimo: %@ %@", "pt-BR": "Próximo: %@ %@", "pt-PT": "Seguinte: %@ %@",
    "ru": "Далее: %@ %@", "nl": "Volgende: %@ %@", "pl": "Następne: %@ %@",
    "tr": "Sonraki: %@ %@", "sv": "Nästa: %@ %@", "da": "Næste: %@ %@",
    "nb": "Neste: %@ %@", "fi": "Seuraava: %@ %@", "cs": "Další: %@ %@",
    "hu": "Következő: %@ %@", "ro": "Următorul: %@ %@", "el": "Επόμενο: %@ %@",
    "uk": "Далі: %@ %@", "th": "ถัดไป: %@ %@", "vi": "Tiếp theo: %@ %@",
    "id": "Berikutnya: %@ %@", "hi": "अगला: %@ %@", "ar": "التالي: %@ %@", "he": "הבא: %@ %@"
  }
}
```

```bash
python3 scripts/add_localizations.py scripts/i18n_additions/battery_schedule_i18n.json
```

- [ ] **Step 2: 예약 문구를 카탈로그로 옮긴다**

`Wattly/Core/BatterySectionPresentation.swift:378-386`을 교체:

```swift
    public static func upcomingScheduleText(
        schedule: BatteryChargingSchedule?,
        triggerDate: Date?,
        locale: Locale = Locale(identifier: "ko")
    ) -> String? {
        guard let schedule, triggerDate != nil else { return nil }
        return String(format: String(localized: "다음: %@ %@", locale: locale),
                      locale: locale,
                      schedule.time.formattedText,
                      schedule.action.summary(locale: locale))
    }
```

호출부는 하나뿐이다. `Wattly/Views/CardExpandRegion.swift:319`를 교체:

```swift
                if let upcomingText = BatterySectionPresentation.upcomingScheduleText(schedule: upcoming.schedule, triggerDate: upcoming.triggerDate, locale: locale) {
```

`WattlyTests/BatterySectionPresentationTests.swift:714`, `:723`, `:724`의 호출은 **고치지 않는다** — `locale`이 한국어 기본값을 갖고, 그 테스트는 `text?.contains("완충")`처럼 한국어 결과를 기대하므로 그대로 통과한다.

- [ ] **Step 3: 도움말 아이콘 의미를 바로잡는다**

`Wattly/Views/Settings/SettingsBatterySection.swift:73` — 도움말인데 경고 아이콘을 쓰고 있다:

```swift
                                Image(systemName: "questionmark.circle")
```

- [ ] **Step 4: 유지보수 버튼을 정상 상태에서 숨긴다**

`batteryStatusRow`의 `?` 버튼 블록 전체(Task 13에서 레이블을 고친 그 버튼)를 다음으로 교체:

```swift
            // 아이콘을 실제 tone에 맞춘다. `maintenanceStatus`는 **절대 nil을 돌려주지 않고
            // `.green`도 내보내지 않는다** — 성공했을 때조차 `.faint`("마지막 확인 · 성공")다.
            // 그래서 "정상이면 숨긴다"는 애초에 성립하지 않고, `.green` 외 전부를 경고 아이콘으로
            // 두면 정상 상태에 경고 삼각형이 뜬다(지금의 물음표보다 나쁘다). 문제를 알리는 톤
            // (`.red`/`.orange`)일 때만 경고를 쓰고, 정보성 톤은 물음표를 유지한다.
            // `if let`은 그대로 둔다 — 지금은 항상 통과하지만, 나중에 nil 경로가 생기면 옳다.
            if let maintenance = resolvedMaintenanceStatus {
                Button {
                    isMaintenanceHelpPopoverPresented = true
                } label: {
                    Image(systemName: maintenance.tone == .red || maintenance.tone == .orange
                          ? "exclamationmark.triangle.fill" : "questionmark.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(statusColor(for: maintenance.tone))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringKey("유지보수 상태 보기")))
                .accessibilityValue(Text(verbatim: BatterySectionPresentation
                    .maintenancePopoverText(maintenance, locale: locale)))
                .popover(isPresented: $isMaintenanceHelpPopoverPresented, arrowEdge: .bottom) {
                    maintenanceStatusHelpPopover(maintenance)
                }
            }
```

- [ ] **Step 5: Task 12가 낡게 만든 문서 주석 두 개를 고친다**

`Wattly/Views/SettingsView.swift:6`의 그룹 열거 주석은 최상위 그룹을 다섯 개로 적고 있는데
Task 12가 여섯 개로 바꿨다. `배터리` 그룹을 넣는다:

```swift
/// Groups: 일반(자동 실행·언어·되돌리기) · 표시(테마·레이아웃·표시 지표·카드 펼침 목록) · 메뉴바(아이콘·텍스트) · 동작(백그라운드 갱신·전력 표시 안정화) · 배터리(충전 제한·예약 충전·방전 제어·진단) · 고급(상태 경고 기준·팬 커브).
```

`Wattly/Core/BatterySectionPresentation.swift:3`은 이제 없는 캡션 이름(`배터리 충전 제어`)을
그대로 쓰고 있다. 첫 줄만 고친다:

```swift
/// 설정 › 배터리 섹션들의 순수 표시 판단. SwiftUI도 I/O도 없다 —
```

- [ ] **Step 6: 예약 카드 스위치를 앱 스타일로 통일한다**

`Wattly/Views/Settings/SettingsScheduleCard.swift:100-105`의 스케줄 행 스위치를 교체:

```swift
            WattlyToggle(
                isOn: Binding(
                    get: { schedule.isEnabled },
                    set: { coordinator.toggleSchedule(id: schedule.id, isEnabled: $0) }
                ),
                isEnabled: true
            )
            .frame(width: 38)
```

`:61`의 "예약 실행 완료 시 알림" 체크박스는 macOS 설정 관용에 맞으므로 그대로 둔다.

- [ ] **Step 7: 빌드하고 전체 테스트를 돌린다**

```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/dd test
```

Expected: PASS

- [ ] **Step 8: 스냅샷을 눈으로 확인한다**

`docs/assets/settings-battery.png`를 열어 캡션·아이콘·토글이 의도대로 보이는지 확인한다.

- [ ] **Step 9: 커밋**

```bash
git add Wattly/Core/BatterySectionPresentation.swift Wattly/Views/ \
        Wattly/Resources/Localizable.xcstrings scripts/i18n_additions/battery_schedule_i18n.json \
        docs/assets/settings-battery.png
git commit -m "fix(settings): localize the schedule summary and correct the help/maintenance icons"
```

---

## 구현 후 검증 (P1~P3 완료 뒤 1회)

- [ ] **실제 강제 방전 1회 관측**

앱을 실행하고 설정 › 배터리 › 방전 제어에서 "방전 시작"을 누른 뒤 관찰한다:

1. "실시간 소모"가 첫 2~4초 안에 음수 두 자릿수 W로 올라오는가
2. "예상 완료"가 약 10초 뒤에 나타나며, 그 값이 (남은 % × 배터리 용량 ÷ 실측 W)로 손계산한 값과 대략 맞는가

수렴이 10초보다 확실히 빠르면 `shouldShowDischargeEstimate`의 `warmUpSeconds` 기본값을 낮춰도 된다 — 순수 함수 하나와 그 테스트만 고치면 되는 국소 변경이다. 수렴이 15초를 넘으면 기본값을 올린다.

- [ ] **단축어 되돌림 회귀 확인**

단축어로 발열 임계값을 40°C로 설정 → 설정 창에서 아무 토글이나 껐다 켜기 → 다시 단축어로 현재 임계값 조회. **40이 유지되어야 한다** (수정 전에는 35로 되돌아갔다).

---

## Termination

전체 14개 태스크. P1(Task 1–6)만으로도 가짜 값이 사라진 상태로 출하 가능하고, P2(7–11)와 P3(12–14)는 각각 독립적으로 되돌릴 수 있다. 어느 단계도 헬퍼 재설치를 유발하지 않는다.
