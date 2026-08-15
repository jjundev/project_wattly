# 설정 화면 레이아웃 디폴트 및 UI 문구 개선 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 설정 화면의 기본 레이아웃을 "히어로 + 리스트"로 변경하고, CPU/GPU 온도 표시 지표 표기를 실제 측정 기준(평균)에 맞게 수정하며, 설정 화면 전반의 설명 문구 및 용어를 일관되고 간결하게 정돈한다.

**Architecture:** 
- `Settings.swift`의 `Defaults.panelMode`를 `.c`로 변경하고, `PanelMode.c.label`의 띄어쓰기를 `"히어로 + 리스트"`로 통일한다.
- `SettingsView.swift`의 표시 지표 토글에서 실제 평균 온도를 나타내는 CPU/GPU 항목의 `suffix: "· 최고값"`을 제거한다.
- `SettingsView.swift`의 일반/레이아웃/메모리·전력 프로세스 제한/메뉴바 섹션의 문구를 서술형 평서문(`~합니다`) 및 간결한 형태로 정돈하고 용어를 "메뉴바"로 통일한다.

**Tech Stack:** Swift, SwiftUI, AppKit, Swift Testing / XCTest

## Global Constraints

- 배터리 효율 보기 설명 문구("배터리 효율 수치가 신경 쓰인다면, 필요할 때만 표시하세요.")는 변경하지 않고 그대로 유지한다.
- 기존 설정 초기화(`SettingsReset`) 및 설정 저장 구조와의 하위 호환성을 유지한다.
- 주석 및 기존 코드 서식을 유지하며 정확한 위치를 수정한다.

---

### Task 1: 기본 레이아웃을 "히어로 + 리스트"로 변경 및 라벨 정돈

**Files:**
- Modify: `Wattly/Settings/Settings.swift:70-72,230-232`
- Test: `WattlyTests/SettingsResetTests.swift:35-50`

**Interfaces:**
- Consumes: `PanelMode`, `Defaults.panelMode`
- Produces: `Defaults.panelMode == .c`, `PanelMode.c.label == "히어로 + 리스트"`

- [ ] **Step 1: Write/Update the test in SettingsResetTests.swift**

```swift
// In WattlyTests/SettingsResetTests.swift
@Test func testApplyDefaultsRestoresPanelModeToHeroAndList() {
    let d = UserDefaults(suiteName: "testApplyDefaultsRestoresPanelModeToHeroAndList")!
    d.set(PanelMode.b.rawValue, forKey: StorageKey.panelMode)
    
    SettingsReset.applyDefaults(into: d)
    
    #expect(d.string(forKey: StorageKey.panelMode) == PanelMode.c.rawValue)
    #expect(Defaults.panelMode == .c)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/SettingsResetTests -quiet`
Expected: FAIL with `Defaults.panelMode == .c` (currently `.a`)

- [ ] **Step 3: Modify Settings.swift to set default to .c and format label**

In `Wattly/Settings/Settings.swift`:
```swift
// Line 70
        case .c: "히어로 + 리스트"
```
```swift
// Line 230
    static let panelMode = PanelMode.c       // ship default: hero + list (mode C)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/SettingsResetTests -quiet`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Settings/Settings.swift WattlyTests/SettingsResetTests.swift
git commit -m "feat(settings): set default panel layout to hero+list and format label"
```

---

### Task 2: CPU 및 GPU 온도 표기 수정 (최고값 접미사 제거)

**Files:**
- Modify: `Wattly/Views/SettingsView.swift:356-357`

**Interfaces:**
- Consumes: `metricToggle` helper in `SettingsView`
- Produces: Clean title strings `"CPU 온도"`, `"GPU 온도"` without misleading `"· 최고값"` suffix

- [ ] **Step 1: Update SettingsView.swift to remove temperature suffix**

In `Wattly/Views/SettingsView.swift`:
```swift
// Replace lines 356-357:
// OLD:
// metricToggle(.cpuTemp, isOn: $showCpuTemp, divider: true, title: "CPU 온도", suffix: "· 최고값")
// metricToggle(.gpuTemp, isOn: $showGpuTemp, divider: true, title: "GPU 온도", suffix: "· 최고값")
// NEW:
metricToggle(.cpuTemp, isOn: $showCpuTemp, divider: true, title: "CPU 온도")
metricToggle(.gpuTemp, isOn: $showGpuTemp, divider: true, title: "GPU 온도")
```

- [ ] **Step 2: Verify build**

Run: `xcodebuild build -scheme Wattly -destination 'platform=macOS' -quiet`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Wattly/Views/SettingsView.swift
git commit -m "fix(settings): remove misleading max value suffix from cpu and gpu temp toggles"
```

---

### Task 3: 설정 화면 설명 문구 및 용어 정돈

**Files:**
- Modify: `Wattly/Views/SettingsView.swift:217,276-285,396-401,421-426,785`

**Interfaces:**
- Consumes: SwiftUI view hierarchy in `SettingsView`
- Produces: Unified tone (`~합니다`), consistent term ("메뉴바"), clean descriptions

- [ ] **Step 1: Update text across SettingsView.swift**

In `Wattly/Views/SettingsView.swift`:

1. **General Section (Line 217)**:
```swift
// OLD: Text("Mac에 로그인하면 Wattly가 메뉴 막대에서 자동으로 시작됩니다.")
// NEW:
Text("Mac에 로그인하면 Wattly가 메뉴바에서 자동으로 시작됩니다.")
```

2. **Layout Descriptions (Lines 276-285)**:
```swift
    private var layoutDescription: String {
        switch panelMode {
        case .a:
            "모든 지표를 카드 형태로 세로 배치합니다. 세부 정보 펼침과 순서 변경을 지원합니다."
        case .b:
            "2열 그리드로 지표를 콤팩트하게 배치하여 한눈에 확인하기 좋습니다."
        case .c:
            "주요 지표 하나를 상단에 강조하고 나머지는 목록으로 표시합니다."
        }
    }
```

3. **Memory & Power Process Limit Sections (Lines 396-401, 421-426)**:
Remove redundant conditional note `if panelMode == .b { ... }` from both sections so the description remains focused on process count limit.

4. **Menubar Section (Line 785)**:
```swift
// OLD: Text("아이콘 옆에 선택한 지표를 함께 표시")
// NEW:
Text("메뉴바 아이콘 옆에 선택한 지표를 함께 표시합니다.")
```

- [ ] **Step 2: Verify build**

Run: `xcodebuild build -scheme Wattly -destination 'platform=macOS' -quiet`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Wattly/Views/SettingsView.swift
git commit -m "style(settings): clean up descriptions, unify tone, and standardize menubar terminology"
```

---

### Task 4: 전체 테스트 및 통합 검증

**Files:**
- Test: All tests across `WattlyTests`

- [ ] **Step 1: Run complete test suite**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -quiet`
Expected: ALL TESTS PASS

- [ ] **Step 2: Commit any final test alignment adjustments if necessary**

```bash
git commit --allow-empty -m "chore: verify full test suite passes after settings refactoring"
```
