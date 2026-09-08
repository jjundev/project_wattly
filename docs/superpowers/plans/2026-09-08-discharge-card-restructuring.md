# 방전 제어 카드 통합 및 덮개 방전 카드 분리 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 설정 › 배터리 화면에서 "자동 방전"과 "수동 방전"을 하나의 통합 카드로 묶고, 수동 방전 카드 하단에 부속되어 있던 "덮개를 닫아도 방전 계속"을 동일한 서식의 독립 카드로 분리한다.

**Architecture:** `SettingsBatteryDischargeSection.swift`의 UI 카드 구조를 재구성한다.
- 기존 `autoDischargeCard`와 `manualDischargeCard` 구조를 `dischargeControlCard`(자동 방전 토글 + 1px 구분선 + 수동 방전 제어)로 통합한다.
- 수동 방전 카드 맨 아래에 들어있던 덮개 방전 토글을 `clamshellDischargeCard` 독립 `SettingsCard`로 분리하여 다른 단독 설정 카드들과 동일한 서식/여백을 확보한다.
- StorageKey, 바인딩, 데몬 연동, Presentation 순수 함수는 100% 보존되며 UI 레이아웃만 안전하게 변경된다.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing (`@Test`/`#expect`), Xcode

## Global Constraints

- 배포 타깃 macOS 14.0, Swift 6 strict concurrency 준수.
- **XPC / 헬퍼 프로토콜 / 데몬 로직은 일체 변경하지 않는다.** (도우미 재설치 유발 금지)
- **신규 `StorageKey`를 추가하지 않는다.** 기존 `@AppStorage` 키를 그대로 사용한다.
- **다국어 키 카탈로그(`Localizable.xcstrings`)의 기존 키를 보존한다.** ("자동 방전", "수동 방전", "덮개를 닫아도 방전 계속" 등 기존 키와 설명 문구 유지)
- 기존의 `@onChange` 핸들러(자동 방전 변경 및 수동 방전 목표치 변경 감지)와 `.task` 생명주기는 뷰 계층 최상단에서 변경 없이 유지된다.

### 공통 명령

빌드:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath .build/DerivedData build
```

테스트:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/BatterySectionPresentationTests
```

전체 테스트:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test
```

---

## File Structure

| 파일 | 책임 | 변경 내용 |
|---|---|---|
| `Wattly/Views/Settings/SettingsBatteryDischargeSection.swift` | 배터리 설정의 방전 제어 카드 뷰 | `dischargeControlCard`(통합) 및 `clamshellDischargeCard`(분리)로 재구성 |
| `WattlyTests/SnapshotGeneratorTests.swift` | 설정 화면 스냅샷 테스트 | 변경된 카드 레이아웃 렌더링 검증 |

---

## Tasks

### Task 1: `SettingsBatteryDischargeSection.swift` 카드 구조 재편

**Files:**
- Modify: `Wattly/Views/Settings/SettingsBatteryDischargeSection.swift`

**Interfaces:**
- Consumes: `autoDischargeEnabled`, `manualDischargeTarget`, `clamshellDischargeEnabled`, `dischargeTarget`, `isDischargeHardwareUsable`, `isManualDischargeActive`, `isClamshellToggleEnabled`
- Produces: `dischargeControlCard: some View`, `clamshellDischargeCard: some View`

- [ ] **Step 1: `SettingsBatteryDischargeSection.swift`의 `body` 및 카드 빌더 수정**

`Wattly/Views/Settings/SettingsBatteryDischargeSection.swift`에서:
1. `body` 내의 카드 호출을 `autoDischargeCard` + `manualDischargeCard`에서 `dischargeControlCard` + `clamshellDischargeCard`로 변경:
   ```swift
   SettingsSection("방전 제어") {
       dischargeControlCard
       clamshellDischargeCard
   }
   ```
2. `dischargeControlCard`를 작성:
   - 하나의 `SettingsCard` 내에 `SettingsToggleRow(isOn: $autoDischargeEnabled, divider: true, ...)`를 상단에 배치.
   - `divider: true`이므로 하단 1px 구분선 자동 삽입.
   - 그 아래 수동 방전 영역(`VStack(alignment: .leading, spacing: 10)`):
     - 제목/설명: `padding(EdgeInsets(top: 12, leading: 14, bottom: 0, trailing: 14))`
     - 슬라이더 및 눈금 라벨: `padding(EdgeInsets(top: 0, leading: 14, bottom: 8, trailing: 14))`
     - 1px 구분선: `Rectangle().fill(t.line).frame(height: 1)`
     - 시작/중지 및 실시간 상태 영역: `padding(EdgeInsets(top: 0, leading: 14, bottom: 14, trailing: 14))` (진행 중일 때는 `bottom: 12`)
     - *(기존 하단에 있던 덮개 방전 토글 및 구분선은 제거)*
3. `clamshellDischargeCard`를 작성:
   - 독립 `SettingsCard`로 분리:
     ```swift
     @ViewBuilder
     private var clamshellDischargeCard: some View {
         SettingsCard {
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
         }
     }
     ```

- [ ] **Step 2: 컴파일 빌드 검증**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath .build/DerivedData build 2>&1 | grep -E 'error:|BUILD' | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: 커밋**

```bash
git add Wattly/Views/Settings/SettingsBatteryDischargeSection.swift
git commit -m "refactor(settings): unify discharge controls and extract clamshell card"
```

---

### Task 2: 회귀 테스트 및 스냅샷/런타임 검증

**Files:**
- Test: `WattlyTests/SnapshotGeneratorTests.swift`
- Test: `WattlyTests/BatterySectionPresentationTests.swift`

- [ ] **Step 1: 프레젠테이션 단위 테스트 실행**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/BatterySectionPresentationTests 2>&1 | grep -E 'Test Suite|passed|failed' | tail -3
```
Expected: All tests pass.

- [ ] **Step 2: 전체 단위 테스트 실행**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test 2>&1 | grep -E 'Test Suite .All tests|passed|failed' | tail -3
```
Expected: All test suites pass.

- [ ] **Step 3: 런타임 실행 검증**

스킬 `wattly-run`의 절차대로 현재 워크트리의 디버그 빌드를 실행하여 설정 창의 "배터리" 탭에서:
1. "방전 제어" 섹션에 [카드 1: 자동+수동 방전 통합 카드]와 [카드 2: 덮개 방전 단독 카드]가 올바른 여백과 구분선으로 렌더링되는지 확인.
2. 자동 방전 토글, 수동 방전 슬라이더 및 시작/중지 버튼, 덮개 방전 토글이 정상 반응하는지 확인.

- [ ] **Step 4: 필요시 스냅샷 갱신 및 최종 커밋**

```bash
git status
# 스냅샷 생성물 등이 업데이트된 경우 커밋
git add -A
git commit -m "test(settings): verify unified discharge card and isolated clamshell card"
```
