# Discharge Target Status Text Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update the battery card (standard & hero) sub-text from a generic "수동 방전 진행 중" to a target-aware concise format (`"%lld%%까지 수동 방전 중"` / `"%lld%%까지 자동 방전 중"`), fix target routing for automatic discharge, and harmonize VoiceOver labels and settings banner.

**Architecture:** Extend pure presentation logic in `BatterySectionPresentation.dischargeDescription` to accept and format `target%`, resolve correct targets (`limitPercentage` vs `manualDischargeTarget`) across views, and propagate `dischargeOwner` to `Accessibility.cardLabel` so VoiceOver matches visual output.

**Tech Stack:** Swift, SwiftUI, Apple String Catalogs (`.xcstrings`), Swift Testing (`@Test`, `#expect`), Xcode 16.

**Spec:** [대화 인-챗 설계 / implementation_plan.md](file:///Users/hyunjun_macbook_pro/.gemini/antigravity/brain/b2e71e69-cd25-4735-8d85-7c7150fbb5f3/implementation_plan.md)

## Global Constraints

- **Exact phrasing:**
  - Manual discharge: `"%lld%%까지 수동 방전 중"` (English: `"Manual discharge to %lld%%"`)
  - Auto discharge: `"%lld%%까지 자동 방전 중"` (English: `"Auto discharge to %lld%%"`)
  - Fallback (`target <= 0`): `"수동 방전 진행 중"` / `"자동 방전 진행 중"`
- **Preserve existing localization keys:** Do not delete `"수동 방전 진행 중"` or `"자동 방전 진행 중"` from `Localizable.xcstrings`.
- **Pure logic boundary:** `BatterySectionPresentation` and `CardPresentation` must remain pure functions without SwiftUI or I/O imports.

---

### Task 1: 다국어 키 등록 및 현지화 단위 테스트

**Files:**
- Modify: `Wattly/Resources/Localizable.xcstrings`
- Modify: `WattlyTests/LocalizationTests.swift:510-530`

**Interfaces:**
- Produces:
  - Localized key `"%lld%%까지 수동 방전 중"` (ko: `"%lld%%까지 수동 방전 중"`, en: `"Manual discharge to %lld%%"`)
  - Localized key `"%lld%%까지 자동 방전 중"` (ko: `"%lld%%까지 자동 방전 중"`, en: `"Auto discharge to %lld%%"`)

- [ ] **Step 1: Write failing test in `LocalizationTests.swift`**

In `WattlyTests/LocalizationTests.swift`, add expectations for the new keys inside `dischargeLocalization()`:
```swift
        #expect(String(localized: "%lld%%까지 수동 방전 중", locale: en) == "Manual discharge to %lld%%")
        #expect(String(localized: "%lld%%까지 수동 방전 중", locale: ko) == "%lld%%까지 수동 방전 중")

        #expect(String(localized: "%lld%%까지 자동 방전 중", locale: en) == "Auto discharge to %lld%%")
        #expect(String(localized: "%lld%%까지 자동 방전 중", locale: ko) == "%lld%%까지 자동 방전 중")
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/LocalizationTests 2>&1 | grep -E 'error:|failed|passed' | tail -5
```
Expected: FAIL (keys not yet registered in catalog).

- [ ] **Step 3: Register keys in `Localizable.xcstrings`**

Add `"%lld%%까지 수동 방전 중"` and `"%lld%%까지 자동 방전 중"` entries to `Wattly/Resources/Localizable.xcstrings` with `en` and `ko` translations.

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/LocalizationTests 2>&1 | grep -E 'error:|failed|passed' | tail -5
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Resources/Localizable.xcstrings WattlyTests/LocalizationTests.swift
git commit -m "feat(l10n): add discharge target percentage strings"
```

---

### Task 2: 순수 프레젠테이션 포맷터 구현 및 테스트

**Files:**
- Modify: `Wattly/Core/BatterySectionPresentation.swift:508-519`
- Modify: `WattlyTests/BatterySectionPresentationTests.swift:750-763`

**Interfaces:**
- Consumes:
  - Localized keys `"%lld%%까지 수동 방전 중"`, `"%lld%%까지 자동 방전 중"`
- Produces:
  - `BatterySectionPresentation.dischargeDescription(owner:target:currentSoC:watts:locale:) -> String` returning target percentage string when `target > 0`

- [ ] **Step 1: Write failing tests in `BatterySectionPresentationTests.swift`**

Update `dischargePresentationText()` in `WattlyTests/BatterySectionPresentationTests.swift`:
```swift
    @Test func dischargePresentationText() {
        let textKo = BatterySectionPresentation.dischargeDescription(owner: .manual, target: 70, currentSoC: 85, watts: -18.4, locale: ko)
        #expect(textKo == "70%까지 수동 방전 중")

        let textEn = BatterySectionPresentation.dischargeDescription(owner: .manual, target: 70, currentSoC: 85, watts: -18.4, locale: en)
        #expect(textEn == "Manual discharge to 70%")

        let autoKo = BatterySectionPresentation.dischargeDescription(owner: .automatic, target: 80, currentSoC: 95, watts: -11.1, locale: ko)
        #expect(autoKo == "80%까지 자동 방전 중")

        let autoEn = BatterySectionPresentation.dischargeDescription(owner: .automatic, target: 80, currentSoC: 95, watts: -11.1, locale: en)
        #expect(autoEn == "Auto discharge to 80%")

        // Fallback when target <= 0
        let fallbackKo = BatterySectionPresentation.dischargeDescription(owner: .manual, target: 0, currentSoC: 85, watts: -18.4, locale: ko)
        #expect(fallbackKo == "수동 방전 진행 중")

        let fallbackAutoKo = BatterySectionPresentation.dischargeDescription(owner: .automatic, target: 0, currentSoC: 95, watts: -11.1, locale: ko)
        #expect(fallbackAutoKo == "자동 방전 진행 중")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/BatterySectionPresentationTests 2>&1 | grep -E 'error:|failed|passed' | tail -5
```
Expected: FAIL (returns "수동 방전 진행 중" instead of "70%까지 수동 방전 중").

- [ ] **Step 3: Implement `dischargeDescription` in `BatterySectionPresentation.swift`**

```swift
    /// Format discharge status description (e.g. "70%까지 수동 방전 중", "80%까지 자동 방전 중", fallback "수동 방전 진행 중")
    static func dischargeDescription(
        owner: DischargeOwner = .manual,
        target: Int = 0,
        currentSoC _: Int = 0,
        watts _: Double = 0,
        locale: Locale = Locale(identifier: "ko")
    ) -> String {
        guard target > 0 else {
            return owner == .automatic
                ? String(localized: "자동 방전 진행 중", locale: locale)
                : String(localized: "수동 방전 진행 중", locale: locale)
        }
        if owner == .automatic {
            return String(
                format: String(localized: "%lld%%까지 자동 방전 중", locale: locale),
                locale: locale,
                Int64(target)
            )
        } else {
            return String(
                format: String(localized: "%lld%%까지 수동 방전 중", locale: locale),
                locale: locale,
                Int64(target)
            )
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/BatterySectionPresentationTests 2>&1 | grep -E 'error:|failed|passed' | tail -5
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/BatterySectionPresentation.swift WattlyTests/BatterySectionPresentationTests.swift
git commit -m "feat(battery): format discharge description with target percentage"
```

---

### Task 3: CardPresentation 및 Accessibility 동기화

**Files:**
- Modify: `Wattly/Core/CardPresentation.swift:216-223`
- Modify: `Wattly/Core/Accessibility.swift:17-38`
- Modify: `WattlyTests/CardPresentationTests.swift:764-770`

**Interfaces:**
- Consumes:
  - `BatterySectionPresentation.dischargeDescription`
- Produces:
  - `Accessibility.cardLabel(_:state:dischargeOwner:locale:processorName:)`
  - `CardPresentation.subText` returning target percentage string for battery discharge

- [ ] **Step 1: Write failing tests in `CardPresentationTests.swift`**

Update `WattlyTests/CardPresentationTests.swift:766-768`:
```swift
        #expect(CardPresentation.subText(state) == "70%까지 수동 방전 중")
        #expect(CardPresentation.subText(state, dischargeOwner: .automatic) == "70%까지 자동 방전 중")
        #expect(CardPresentation.display(.battery, state, dischargeOwner: .automatic).subText == "70%까지 자동 방전 중")
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/CardPresentationTests 2>&1 | grep -E 'error:|failed|passed' | tail -5
```
Expected: FAIL (CardPresentationTests still expect previous text or fail on matching).

- [ ] **Step 3: Update `Accessibility.swift` and `CardPresentation.swift`**

In `Wattly/Core/Accessibility.swift`:
Update `cardLabel`:
```swift
    static func cardLabel(
        _ card: CardKind,
        _ state: MetricState,
        dischargeOwner: BatterySectionPresentation.DischargeOwner = .idle,
        locale: Locale = Locale(identifier: "ko"),
        processorName: String = currentProcessorName()
    ) -> String {
        let name = CardPresentation.label(card)
        switch state {
        case .loading:
            return "\(name), \(String(localized: "불러오는 중", locale: locale))"
        case .unavailable(let reason):
            return "\(name), \(String(localized: "사용 불가", locale: locale)), \(reason.message)"
        case .value:
            var label = "\(name), \(headPhrase(card, state, locale: locale))"
            if let sub = CardPresentation.subText(state, dischargeOwner: dischargeOwner, locale: locale, processorName: processorName), !sub.isEmpty {
                label += ", \(sub)"
            }
            return label
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test -only-testing:WattlyTests/CardPresentationTests 2>&1 | grep -E 'error:|failed|passed' | tail -5
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/CardPresentation.swift Wattly/Core/Accessibility.swift WattlyTests/CardPresentationTests.swift
git commit -m "feat(presentation): propagate dischargeOwner and target to CardPresentation and Accessibility"
```

---

### Task 4: 뷰 계층 타깃 분기 및 UI 반영

**Files:**
- Modify: `Wattly/Views/MetricCardView.swift:69, 83-96`
- Modify: `Wattly/Views/PopoverHeroView.swift:230-243`
- Modify: `Wattly/Views/Settings/SettingsBatteryDischargeSection.swift:348`

**Interfaces:**
- Consumes:
  - `dischargeOwner`
  - `desiredConfiguration.limitPercentage` (for auto discharge)
  - `desiredConfiguration.manualDischargeTarget` (for manual discharge)
  - `BatterySectionPresentation.dischargeDescription`

- [ ] **Step 1: Update target calculation in `MetricCardView.swift`**

In `MetricCardView.swift`:
In `subTextView`:
```swift
        if isDischarging, case .value(.battery(let s)) = state {
            let target: Int = {
                if let config = batteryControl?.status.desiredConfiguration {
                    return dischargeOwner == .automatic ? config.limitPercentage : config.manualDischargeTarget
                }
                return s.targetPercentage
            }()
            let currentPct = s.percentage ?? (batteryControl?.status.currentPercentage ?? 0)
            let watts = s.netW > 0 ? -s.netW : s.netW
            let desc = BatterySectionPresentation.dischargeDescription(owner: dischargeOwner, target: target, currentSoC: currentPct, watts: watts, locale: locale)
            HStack(spacing: 5) {
                Circle()
                    .fill(Tokens.statusOrange)
                    .frame(width: 6, height: 6)
                Text(desc)
                    .foregroundStyle(Tokens.statusOrange)
                    .lineLimit(isExpanded ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: isExpanded)
            }
```
And in `summaryGroup`:
Pass `dischargeOwner`:
```swift
        .accessibilityLabel(Accessibility.cardLabel(card, state, dischargeOwner: dischargeOwner, locale: locale))
```

- [ ] **Step 2: Update target calculation in `PopoverHeroView.swift`**

In `PopoverHeroView.swift`:
In `subTextView`:
```swift
        if isDischarging, case .value(.battery(let s)) = state {
            let target: Int = {
                if let config = batteryControl?.status.desiredConfiguration {
                    return dischargeOwner == .automatic ? config.limitPercentage : config.manualDischargeTarget
                }
                return s.targetPercentage
            }()
            let currentPct = s.percentage ?? (batteryControl?.status.currentPercentage ?? 0)
            let watts = s.netW > 0 ? -s.netW : s.netW
            let desc = BatterySectionPresentation.dischargeDescription(owner: dischargeOwner, target: target, currentSoC: currentPct, watts: watts, locale: locale)
            Text(desc)
                .lineLimit(isExpanded ? 2 : 1)
                .fixedSize(horizontal: false, vertical: isExpanded)
```

- [ ] **Step 3: Update manual discharge banner in `SettingsBatteryDischargeSection.swift`**

In `SettingsBatteryDischargeSection.swift` around line 348:
Replace:
```swift
Text(LocalizedStringKey("수동 방전 진행 중"))
```
With:
```swift
Text(BatterySectionPresentation.dischargeDescription(owner: .manual, target: target, locale: locale))
```

- [ ] **Step 4: Run build and all tests**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -derivedDataPath .build/DerivedData build 2>&1 | grep -E 'error:|BUILD' | tail -5
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test 2>&1 | grep -E 'Test Suite .All tests|passed|failed' | tail -3
```
Expected: BUILD SUCCEEDED and all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Views/MetricCardView.swift Wattly/Views/PopoverHeroView.swift Wattly/Views/Settings/SettingsBatteryDischargeSection.swift
git commit -m "feat(views): route discharge targets dynamically and display concise target status"
```
