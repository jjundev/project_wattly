# Fix I18n UI Overflow and Icon Theme Localization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 다국어 모드에서 긴 단어로 인해 발생하는 세그먼트/버튼 텍스트 깨짐 및 오버플로우를 근본적으로 방지하고, 번역이 누락된 7개 메뉴바 아이콘 디자인 테마 라벨을 30개 언어 카탈로그에 추가한다. 설정 창 폭을 480px로 최적화하고 세그먼트 텍스트 반응형 자동 축소 및 라벨 간결화를 적용한다.

**Architecture:**
- **Localizable.xcstrings**: 7개 아이콘 테마 스타일 키(`쿨링 터빈`, `펄스 웨이브`, `VU 파워 미터`, `3D 큐브`, `열 대류 버블`, `디지털 이퀄라이저`, `러너 (경사로 질주)`)를 30개 언어로 추가.
- **Responsive Segments**: `WattlySegment`, `WattlyChip`, `iconStyleButton`에 `.lineLimit(1)` 및 `.minimumScaleFactor(0.7)`을 적용하여 독일어/러시아어/프랑스어 등 긴 단어가 2줄로 겹치거나 잘리지 않도록 폰트 자동 스케일링.
- **Concise Segment Labels**: 세그먼트 버튼 폭을 과도하게 차지하는 `(권장)` 문구를 세그먼트 버튼에서 제거하고(`전력 소비 (권장)` ➔ `전력 소비`, `스마트 (권장)` ➔ `스마트`), 하단 설명 텍스트에 `(권장)` 태그를 명시하여 모든 언어에서 세그먼트 균형 유지.
- **Window Width Optimization**: `SettingsView` 너비를 440px에서 480px로 확장하여 다국어 환경에서 쾌적한 카드 레이아웃과 텍스트 여백 확보.

**Tech Stack:** Swift 6, SwiftUI, Xcode String Catalog (`.xcstrings`), Swift Testing framework.

---

### Task 1: 7개 아이콘 디자인 테마 30개 다국어 번역 추가 및 검증

**Files:**
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Modify: `WattlyTests/LocalizationTests.swift`

- [x] **Step 1: Write test in `LocalizationTests.swift` for icon style translations**

```swift
    @Test func iconDesignThemeTranslations() {
        #expect(String(localized: "쿨링 터빈", locale: Locale(identifier: "en")) == "Cooling Turbine")
        #expect(String(localized: "쿨링 터빈", locale: Locale(identifier: "ja")) == "クーリングタービン")
        #expect(String(localized: "펄스 웨이브", locale: Locale(identifier: "en")) == "Pulse Wave")
        #expect(String(localized: "VU 파워 미터", locale: Locale(identifier: "en")) == "VU Power Meter")
        #expect(String(localized: "3D 큐브", locale: Locale(identifier: "en")) == "3D Cube")
        #expect(String(localized: "열 대류 버블", locale: Locale(identifier: "en")) == "Thermal Bubbles")
        #expect(String(localized: "디지털 이퀄라이저", locale: Locale(identifier: "en")) == "Equalizer")
        #expect(String(localized: "러너 (경사로 질주)", locale: Locale(identifier: "en")) == "Hill Runner")
    }
```

- [x] **Step 2: Add 7 icon styles with 30 languages into `Localizable.xcstrings`**

Add complete 30-locale translations for:
1. `쿨링 터빈` (Cooling Turbine)
2. `펄스 웨이브` (Pulse Wave)
3. `VU 파워 미터` (VU Power Meter)
4. `3D 큐브` (3D Cube)
5. `열 대류 버블` (Thermal Bubbles)
6. `디지털 이퀄라이저` (Digital Equalizer)
7. `러너 (경사로 질주)` (Hill Runner)

- [x] **Step 3: Run test & verify**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData -only-testing:WattlyTests/LocalizationTests`
Commit: `git commit -m "feat(i18n): add 30-language translations for 7 icon design themes"`

---

### Task 2: 세그먼트 라벨 간결화 및 설명 텍스트 권장 표기 일원화

**Files:**
- Modify: `Wattly/Core/KineticNotchMotion.swift`
- Modify: `Wattly/Settings/Settings.swift`
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Modify: `WattlyTests/KineticNotchMotionTests.swift`
- Modify: `WattlyTests/SettingsResetTests.swift`
- Modify: `WattlyTests/LocalizationTests.swift`

- [x] **Step 1: Update `KineticNotchSource` & `KineticNotchSpeed` labels and descriptions**

In `Wattly/Core/KineticNotchMotion.swift`:
- `KineticNotchSource.power.label`: `"전력 소비"` (기존 `"전력 소비 (권장)"`에서 간결화)
- `KineticNotchSource.power.description`: `"(권장) SoC 전체 전력 소비량(W)에 비례하여 움직입니다. 시스템의 실제 작업 부하를 가장 정확하게 반영합니다."`
- `KineticNotchSpeed.smart.label`: `"스마트"` (기존 `"스마트 (권장)"`에서 간결화)
- `KineticNotchSpeed.smart.description`: `"(권장) 메뉴바 상주 시에는 ProMotion 절전을 위해 24 fps로 고정되며, 팝오버를 열거나 설정창을 볼 때는 전원 상태(AC 60 fps / 배터리 24 fps)에 따라 부드럽게 동작합니다."`

In `Wattly/Settings/Settings.swift`:
- `PowerMode.eco.label`: `"스마트"`
- `BackgroundRefreshPreset.eco.label`: `"스마트"`

- [x] **Step 2: Update `Localizable.xcstrings` and unit test assertions**

- Add translation for `"전력 소비"`, `"스마트"`, and updated descriptions.
- Update `KineticNotchMotionTests.swift` and `SettingsResetTests.swift`.

- [x] **Step 3: Run tests & commit**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData`
Commit: `git commit -m "refactor(settings): streamline segment labels and move recommended badge to description"`

---

### Task 3: 세그먼트/칩 반응형 텍스트 스케일링 및 설정 창 폭 480px 최적화

**Files:**
- Modify: `Wattly/Views/SettingsComponents.swift`
- Modify: `Wattly/Views/SettingsView.swift`
- Modify: `Wattly/Views/Settings/SettingsMenuBarSection.swift`

- [x] **Step 1: Add `.lineLimit(1)` and `.minimumScaleFactor(0.7)` to `WattlySegment` and `WattlyChip`**

In `Wattly/Views/SettingsComponents.swift`:
```swift
    private func pill(_ value: T, _ label: String) -> some View {
        let active = selection == value
        return Text(LocalizedStringKey(label))
            .font(WattlyFont.at(fontSize, weight: .semibold))
            .foregroundStyle(active ? t.text : scheme.segInactiveText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .allowsTightening(true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 2)
            .padding(.vertical, pillVPadding)
            ...
    }
```

In `SettingsMenuBarSection.swift` (`iconStyleButton`):
```swift
                Text(LocalizedStringKey(style.label))
                    .font(WattlyFont.at(11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(labelColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .allowsTightening(true)
```

- [x] **Step 2: Update `SettingsView` content width from 440 to 480**

In `Wattly/Views/SettingsView.swift`:
- Change `.frame(width: 440)` to `.frame(width: 480)`.

- [x] **Step 3: Run full tests, build and commit**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData`
Commit: `git commit -m "fix(ui): apply responsive text scaling to segments and expand settings width to 480px"`

---

### Task 4: 최종 E2E 빌드, 다국어 UI 검증 및 앱 재실행

**Files:**
- `walkthrough.md`

- [ ] **Step 1: Run full automated test suite (468+ tests)**
- [ ] **Step 2: Build and run Wattly app**
- [ ] **Step 3: Update Walkthrough documentation**
