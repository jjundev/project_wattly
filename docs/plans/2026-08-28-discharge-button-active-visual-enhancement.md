# 배터리 수동 방전 시작 버튼 시각화 및 툴팁 개선 구현 계획서

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 배터리 수동 방전 카드의 "방전 시작(Start Discharge)" 버튼이 활성화되었을 때 프로토타입 스펙에 맞춰 오렌지 상태 틴트(오렌지 텍스트 + 반투명 오렌지 배경 + 오렌지 테두리)를 적용하고, 비활성화 시 명확한 딤 스타일 및 사유 툴팁(`.help`)을 제공하여 사용자에게 직관적인 시각적 피드백을 전달합니다.

**Architecture:** 
- `BatterySectionPresentation`에 수동 방전 비활성화 사유를 판별하고 다국어 문자열(ko/en)을 반환하는 순수 함수 `manualDischargeDisabledReason`를 추가합니다.
- `SettingsBatterySection`과 `CardExpandRegion`의 방전 시작 버튼 뷰에서 `canStartDischarge` 조건에 따라 동적으로 오렌지 틴트(`Tokens.statusOrange`)와 비활성 톤(`t.faint`, `t.segTrack`)을 분기 렌더링하고, 비활성 시 사유 툴팁(`.help`)을 바인딩합니다.

**Tech Stack:** Swift, SwiftUI, Design Tokens (`Tokens.statusOrange`), XCTest / Swift Testing

## Global Constraints

- 버튼 레이블 텍스트는 기존 `BatterySectionPresentation.startDischargeButtonText`("방전 시작" / "Start Discharge")를 유지합니다 (#7 사용자 결정).
- 방전 중지("방전 중지")의 기존 레드 상태 스타일(`Tokens.statusRed`)은 변경하지 않습니다.
- 모든 UI 컴포넌트는 다크 모드와 라이트 모드 모두에서 명확한 대비를 유지해야 합니다.
- 기존 단위 테스트(`BatterySectionPresentationTests`)를 100% 통과해야 합니다.

---

### Task 1: 수동 방전 비활성화 사유 도우미 함수 및 단위 테스트 추가

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift`
- Test: `WattlyTests/BatterySectionPresentationTests.swift`

**Interfaces:**
- Produces: `BatterySectionPresentation.manualDischargeDisabledReason(isPluggedIn: Bool, currentSoC: Int, targetSoC: Int, isHardwareSupported: Bool, isToggleEnabled: Bool, locale: Locale) -> String?`

- [ ] **Step 1: 실패하는 단위 테스트 작성**

`WattlyTests/BatterySectionPresentationTests.swift`에 `manualDischargeDisabledReason` 검증 테스트 추가:

```swift
@Test func manualDischargeDisabledReasonTests() {
    let ko = Locale(identifier: "ko")
    let en = Locale(identifier: "en")

    // 정상 시작 가능한 경우 (nil 반환)
    #expect(BatterySectionPresentation.manualDischargeDisabledReason(
        isPluggedIn: true, currentSoC: 80, targetSoC: 70, isHardwareSupported: true, isToggleEnabled: true, locale: ko
    ) == nil)

    // 전원 어댑터 미연결
    #expect(BatterySectionPresentation.manualDischargeDisabledReason(
        isPluggedIn: false, currentSoC: 80, targetSoC: 70, isHardwareSupported: true, isToggleEnabled: true, locale: ko
    ) == "전원 어댑터가 연결되어 있어야 방전할 수 있습니다.")
    #expect(BatterySectionPresentation.manualDischargeDisabledReason(
        isPluggedIn: false, currentSoC: 80, targetSoC: 70, isHardwareSupported: true, isToggleEnabled: true, locale: en
    ) == "Connect power adapter to start discharge.")

    // 현재 잔량이 목표 잔량 이하
    #expect(BatterySectionPresentation.manualDischargeDisabledReason(
        isPluggedIn: true, currentSoC: 70, targetSoC: 70, isHardwareSupported: true, isToggleEnabled: true, locale: ko
    ) == "현재 배터리 잔량이 목표 잔량 이하입니다.")
    #expect(BatterySectionPresentation.manualDischargeDisabledReason(
        isPluggedIn: true, currentSoC: 65, targetSoC: 70, isHardwareSupported: true, isToggleEnabled: true, locale: en
    ) == "Battery level is already at or below target.")

    // 충전 제어 비활성화 또는 미지원
    #expect(BatterySectionPresentation.manualDischargeDisabledReason(
        isPluggedIn: true, currentSoC: 80, targetSoC: 70, isHardwareSupported: true, isToggleEnabled: false, locale: ko
    ) == "배터리 충전 제어가 꺼져 있습니다.")
    #expect(BatterySectionPresentation.manualDischargeDisabledReason(
        isPluggedIn: true, currentSoC: 80, targetSoC: 70, isHardwareSupported: false, isToggleEnabled: true, locale: ko
    ) == "배터리 충전 제어가 꺼져 있습니다.")
}
```

- [ ] **Step 2: 테스트 실행 및 실패 확인**

Run: `swift test --filter BatterySectionPresentationTests`
Expected: 컴파일 에러 (`manualDischargeDisabledReason` 정의되지 않음)

- [ ] **Step 3: 최소 구현 작성**

`Wattly/Core/BatterySectionPresentation.swift`에 함수 구현 추가:

```swift
static func manualDischargeDisabledReason(
    isPluggedIn: Bool,
    currentSoC: Int,
    targetSoC: Int,
    isHardwareSupported: Bool = true,
    isToggleEnabled: Bool = true,
    locale: Locale = Locale(identifier: "ko")
) -> String? {
    guard isHardwareSupported && isToggleEnabled else {
        let isKo = locale.language.languageCode?.identifier == "ko"
        return isKo ? "배터리 충전 제어가 꺼져 있습니다." : "Battery charge control is disabled."
    }
    guard isPluggedIn else {
        let isKo = locale.language.languageCode?.identifier == "ko"
        return isKo ? "전원 어댑터가 연결되어 있어야 방전할 수 있습니다." : "Connect power adapter to start discharge."
    }
    guard currentSoC > targetSoC else {
        let isKo = locale.language.languageCode?.identifier == "ko"
        return isKo ? "현재 배터리 잔량이 목표 잔량 이하입니다." : "Battery level is already at or below target."
    }
    return nil
}
```

- [ ] **Step 4: 단위 테스트 실행 및 성공 확인**

Run: `swift test --filter BatterySectionPresentationTests`
Expected: 모든 테스트 PASS

- [ ] **Step 5: 변경사항 커밋**

```bash
git add Wattly/Core/BatterySectionPresentation.swift WattlyTests/BatterySectionPresentationTests.swift
git commit -m "feat(battery): add manual discharge disabled reason helper with tests"
```

---

### Task 2: 설정창(`SettingsBatterySection`) 방전 시작 버튼 시각화 및 툴팁 개선

**Files:**
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift:788-820`

**Interfaces:**
- Consumes: `BatterySectionPresentation.manualDischargeDisabledReason`

- [ ] **Step 1: 방전 시작 버튼 스타일 및 툴팁 모디파이어 업데이트**

`SettingsBatterySection.swift` 788-820 라인:
1. `disabledReason` 계산:
```swift
let disabledReason = BatterySectionPresentation.manualDischargeDisabledReason(
    isPluggedIn: isPluggedIn,
    currentSoC: currentSoC,
    targetSoC: manualDischargeTarget,
    isHardwareSupported: !isHardwareUnsupported,
    isToggleEnabled: isToggleEnabled,
    locale: locale
)
```
2. Button label 스타일 개선:
```swift
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
```
3. `.help(...)` 및 accessibility 설정:
```swift
.buttonStyle(.plain)
.disabled(!canStartDischarge)
.help(disabledReason ?? "")
.accessibilityLabel(Text(verbatim: BatterySectionPresentation.startDischargeButtonText(targetSoC: manualDischargeTarget, locale: locale)))
.accessibilityHint(Text(disabledReason ?? ""))
```

- [ ] **Step 2: 빌드 및 테스트 확인**

Run: `swift test`
Expected: 빌드 성공 및 전체 테스트 통과

- [ ] **Step 3: 변경사항 커밋**

```bash
git add Wattly/Views/Settings/SettingsBatterySection.swift
git commit -m "feat(ui): enhance manual discharge start button styling and tooltip in settings"
```

---

### Task 3: 메뉴바 팝오버(`CardExpandRegion`) 방전 시작 버튼 시각화 및 툴팁 개선

**Files:**
- Modify: `Wattly/Views/CardExpandRegion.swift:485-507`

**Interfaces:**
- Consumes: `BatterySectionPresentation.manualDischargeDisabledReason`

- [ ] **Step 1: 팝오버 확장 영역 방전 시작 버튼 스타일 및 툴팁 업데이트**

`CardExpandRegion.swift`의 `batteryDischargeRow` 함수:
1. `disabledReason` 계산:
```swift
let disabledReason = BatterySectionPresentation.manualDischargeDisabledReason(
    isPluggedIn: s.externalConnected,
    currentSoC: currentSoC,
    targetSoC: manualDischargeTarget,
    isHardwareSupported: true,
    isToggleEnabled: true,
    locale: locale
)
```
2. Button label 스타일 업데이트 (코너 반경 4, 패딩 H:6/V:2):
```swift
} else {
    Text(verbatim: BatterySectionPresentation.startDischargeButtonText(
        targetSoC: manualDischargeTarget,
        locale: locale))
        .font(WattlyFont.at(10.5, weight: .medium))
        .foregroundStyle(canStartDischarge ? Tokens.statusOrange : t.faint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(canStartDischarge ? Tokens.statusOrange.opacity(0.15) : t.segTrack)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(canStartDischarge ? Tokens.statusOrange.opacity(0.35) : t.rowBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
}
```
3. `.help(...)` 및 accessibility hint 추가:
```swift
.buttonStyle(.plain)
.disabled(!isDischarging && !canStartDischarge)
.help(isDischarging ? "" : (disabledReason ?? ""))
.accessibilityLabel(Text(LocalizedStringKey("수동 방전 (\(manualDischargeTarget)%)")))
.accessibilityValue(Text(verbatim: isDischarging
    ? String(localized: "방전 중지", locale: locale)
    : BatterySectionPresentation.startDischargeButtonText(
        targetSoC: manualDischargeTarget,
        locale: locale)))
.accessibilityHint(Text(isDischarging ? "" : (disabledReason ?? "")))
```

- [ ] **Step 2: 전체 빌드 및 테스트 검증**

Run: `swift test`
Expected: 모든 테스트 통과

- [ ] **Step 3: 변경사항 커밋**

```bash
git add Wattly/Views/CardExpandRegion.swift
git commit -m "feat(ui): enhance manual discharge start button styling and tooltip in popover"
```

---

## Verification Plan

### Automated Tests
- `swift test --filter BatterySectionPresentationTests`: 신규 헬퍼 함수 및 문자열 반환 검증
- `swift test`: 전체 테스트 스위트 회귀 검증

### Manual Verification
- 설정창 > 배터리 설정에서:
  1. 어댑터 연결 상태 & 배터리 82% & 목표 70% 설정 시: "방전 시작" 버튼이 선명한 오렌지 틴트(텍스트, 배경, 테두리)로 표시되는지 확인
  2. 목표를 85%로 변경하여 비활성화될 때: 버튼이 어두운 무채색(`t.faint` / `t.segTrack`)으로 전환되고 호버 시 툴팁("현재 배터리 잔량이 목표 잔량 이하입니다.")이 뜨는지 확인
  3. "방전 시작" 클릭 시: "수동 방전 진행 중" 배너 및 레드 "방전 중지" 버튼으로 정상 전환되는지 확인
- 메뉴바 팝오버 배터리 카드 확장 영역에서 동일하게 오렌지 틴트 및 툴팁이 작동하는지 확인
