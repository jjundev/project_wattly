# Missing i18n Strings Localization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use dispatching-parallel-agents and subagent-driven-development (recommended) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate all hardcoded Korean strings and incomplete translations in Wattly, enabling seamless multilingual support across 30 languages when users switch their language in Settings.

**Architecture:** 
1. Isolate Swift source changes across 3 independent parallel worker agents (Domain 1: Scheduling & Notifications, Domain 2: Settings Guides & MenuBar & Lifecycle & Settings Components, Domain 3: Sensor Metrics & App Intents & Accessibility & Popover/Card VoiceOver Views) so that each agent modifies completely disjoint sets of files with zero file conflicts.
2. In parallel, each worker converts raw strings into `String(localized:)` / `LocalizedStringKey` / injected `Locale`, and exports the extracted Korean catalog keys with their English counterparts into dedicated JSON fragments in `scripts/i18n_additions/`.
3. A centralized Catalog Master task consolidates all new keys plus the 49 existing partially-translated keys, generates 30-language translations, and safely merges them into `Wattly/Resources/Localizable.xcstrings` using `scripts/add_localizations.py`.
4. Run comprehensive automated validation and unit test suites to verify 100% catalog coverage and build integrity.

**Tech Stack:** Swift, SwiftUI, Xcode String Catalogs (`.xcstrings`), AppKit, UserNotifications, App Intents, Python 3.

## Global Constraints

- **Source Language:** Korean (`"ko"`).
- **Target Languages (30):** `ar`, `cs`, `da`, `de`, `el`, `en`, `es`, `fi`, `fr`, `he`, `hi`, `hu`, `id`, `it`, `ja`, `ko`, `nb`, `nl`, `pl`, `pt-BR`, `pt-PT`, `ro`, `ru`, `sv`, `th`, `tr`, `uk`, `vi`, `zh-Hans`, `zh-Hant`.
- **Zero Raw Strings in UI:** All UI-facing strings must use `LocalizedStringKey`, `String(localized:locale:)`, or `String(localized:)`.
- **Locale Propagation:** Notifications and background formatting must read the configured `@AppStorage(StorageKey.appLanguage)` locale via `AppLanguage.locale(for: UserDefaults.standard.string(forKey: StorageKey.appLanguage) ?? Defaults.appLanguage)`, never defaulting solely to `Locale.current`.
- **Safe JSON Merging:** `Wattly/Resources/Localizable.xcstrings` must be formatted identically with `ensure_ascii=False, indent=2` and zero manual schema corruption.

---

## File Structure & Agent Ownership

```
├── Parallel Worker 1: Scheduling & Notification
│   ├── Wattly/Views/Settings/ScheduleEditorSheet.swift
│   ├── Wattly/Views/Settings/SettingsScheduleCard.swift
│   ├── Wattly/Core/BatteryChargingSchedule.swift
│   ├── Wattly/Core/BatteryScheduleLogEntry.swift
│   ├── Wattly/Core/BatteryScheduleCoordinator.swift
│   ├── Wattly/Core/BatteryNotificationManager.swift
│   └── scripts/i18n_additions/schedule_notifications.json
│
├── Parallel Worker 2: Settings Guides, MenuBar, Lifecycle & SettingsComponents
│   ├── Wattly/Views/Settings/SettingsBatterySection.swift
│   ├── Wattly/Views/Settings/SettingsFanCurveSection.swift
│   ├── Wattly/Views/SettingsView.swift
│   ├── Wattly/Views/SettingsComponents.swift
│   ├── Wattly/Core/MenuBarIconStyle.swift
│   ├── Wattly/Core/MenuBarText.swift
│   ├── Wattly/Core/AppUninstaller.swift
│   ├── Wattly/Core/AutoUpdater.swift
│   ├── Wattly/Core/UpdateChecker.swift
│   ├── Wattly/Control/FanControlClient.swift
│   ├── Wattly/Control/FanHelperInstaller.swift
│   └── scripts/i18n_additions/settings_menubar_lifecycle.json
│
├── Parallel Worker 3: Sensor Metrics, App Intents, Accessibility & Popover Views
│   ├── Wattly/Models/MetricState.swift
│   ├── Wattly/Providers/BatteryProvider.swift
│   ├── Wattly/Providers/FanProvider.swift
│   ├── Wattly/Providers/CPUProvider.swift
│   ├── Wattly/Providers/GPUProvider.swift
│   ├── Wattly/Providers/MemoryProvider.swift
│   ├── Wattly/Providers/PowerProvider.swift
│   ├── Wattly/Providers/TemperatureProvider.swift
│   ├── Wattly/Core/Temperature.swift
│   ├── Wattly/Core/Accessibility.swift
│   ├── Wattly/Views/CardExpandRegion.swift
│   ├── Wattly/Views/PopoverContentView.swift
│   ├── Wattly/Views/PopoverHeroView.swift
│   ├── Wattly/Intents/Intents/*.swift
│   ├── Wattly/Intents/Entities/*.swift
│   ├── Wattly/Intents/Errors/BatteryIntentError.swift
│   └── scripts/i18n_additions/metrics_intents_accessibility.json
│
└── Central Catalog Master:
    ├── scripts/i18n_additions/existing_49_gaps.json
    ├── scripts/generate_full_catalog.py
    └── Wattly/Resources/Localizable.xcstrings
```

---

## Tasks

### Task 1 (Parallel Agent 1): Localize Charging Schedule & Notification Systems

**Files:**
- Modify: `Wattly/Views/Settings/ScheduleEditorSheet.swift`
- Modify: `Wattly/Views/Settings/SettingsScheduleCard.swift`
- Modify: `Wattly/Core/BatteryChargingSchedule.swift`
- Modify: `Wattly/Core/BatteryScheduleLogEntry.swift`
- Modify: `Wattly/Core/BatteryScheduleCoordinator.swift`
- Modify: `Wattly/Core/BatteryNotificationManager.swift`
- Create: `scripts/i18n_additions/schedule_notifications.json`

**Interfaces:**
- Consumes: `AppStorage(StorageKey.appLanguage)`, `AppLanguage.locale(for:)`
- Produces: `scripts/i18n_additions/schedule_notifications.json` mapping all schedule/notification Korean keys to English translations.

- [ ] **Step 1: Update `BatteryNotificationManager.swift` to resolve configured app locale**
  Ensure notification triggers (`postTopUpCompleteNotification`, `postDischargeCompleteNotification`, `postScheduleTriggeredNotification`) resolve the user's selected language via `AppLanguage.locale(for: UserDefaults.standard.string(forKey: StorageKey.appLanguage) ?? Defaults.appLanguage)`. Replace interpolation in format strings with positional tokens (`String(format: String(localized: "예약 충전: %@", locale: locale), scheduleName)` and `String(format: String(localized: "설정된 작업이 실행되었습니다: %@", locale: locale), actionSummary)`).

- [ ] **Step 2: Localize `ScheduleEditorSheet.swift` and `SettingsScheduleCard.swift`**
  Wrap all UI strings in `LocalizedStringKey` or `String(localized:)`. Replace time formatting (`"%02d시"`, `"%02d분"`) and repeat options (`"매일"`, `"평일"`, `"주말"`, `"1회만"`) with localized strings.

- [ ] **Step 3: Localize `BatteryChargingSchedule.swift` and `BatteryScheduleLogEntry.swift`**
  Provide localized weekday names and action descriptions using `String(localized:)`.

- [ ] **Step 4: Export key additions to `scripts/i18n_additions/schedule_notifications.json`**
  Save all new keys with their English translation dictionary.

- [ ] **Step 5: Run compiler check on modified files**
  Verify zero syntax errors.

---

### Task 2 (Parallel Agent 2): Localize Settings Guides, MenuBar, Lifecycle & SettingsComponents

**Files:**
- Modify: `Wattly/Views/Settings/SettingsBatterySection.swift`
- Modify: `Wattly/Views/Settings/SettingsFanCurveSection.swift`
- Modify: `Wattly/Views/SettingsView.swift`
- Modify: `Wattly/Views/SettingsComponents.swift`
- Modify: `Wattly/Core/MenuBarIconStyle.swift`
- Modify: `Wattly/Core/MenuBarText.swift`
- Modify: `Wattly/Core/AppUninstaller.swift`
- Modify: `Wattly/Core/AutoUpdater.swift`
- Modify: `Wattly/Core/UpdateChecker.swift`
- Modify: `Wattly/Control/FanControlClient.swift`
- Modify: `Wattly/Control/FanHelperInstaller.swift`
- Create: `scripts/i18n_additions/settings_menubar_lifecycle.json`

**Interfaces:**
- Consumes: SwiftUI `LocalizedStringKey`, `String(localized:)`
- Produces: `scripts/i18n_additions/settings_menubar_lifecycle.json` mapping all guide, menu bar, and lifecycle Korean keys to English translations.

- [ ] **Step 1: Localize Settings guidance popovers, dialogs, and components**
  In `SettingsBatterySection.swift`, `SettingsFanCurveSection.swift`, `SettingsView.swift`, and `SettingsComponents.swift` (line 447 `다운로드 진행률`), replace hardcoded strings with `String(localized:)` / `LocalizedStringKey` (e.g., Optimized Battery Charging guide, 0 RPM fan hold note, full uninstall warning alert).

- [ ] **Step 2: Localize `MenuBarIconStyle.swift` and `MenuBarText.swift`**
  Convert icon style category titles and multi-line descriptions to `String(localized:)`. In `MenuBarText.swift`, support locale injection while keeping default `locale: Locale = Locale(identifier: "ko")` for test suite backward compatibility.

- [ ] **Step 3: Localize Lifecycle & Client Error Strings**
  In `AppUninstaller.swift`, `AutoUpdater.swift`, `UpdateChecker.swift`, `FanControlClient.swift`, and `FanHelperInstaller.swift`, wrap user-facing error reasons with `String(localized:)`.

- [ ] **Step 4: Export key additions to `scripts/i18n_additions/settings_menubar_lifecycle.json`**
  Save all new keys with their English translation dictionary.

- [ ] **Step 5: Run compiler check on modified files**
  Verify zero syntax errors in the modified files.

---

### Task 3 (Parallel Agent 3): Localize Sensor Metrics, App Intents, Accessibility & Popover Views

**Files:**
- Modify: `Wattly/Models/MetricState.swift`
- Modify: `Wattly/Providers/BatteryProvider.swift`
- Modify: `Wattly/Providers/FanProvider.swift`
- Modify: `Wattly/Providers/CPUProvider.swift`
- Modify: `Wattly/Providers/GPUProvider.swift`
- Modify: `Wattly/Providers/MemoryProvider.swift`
- Modify: `Wattly/Providers/PowerProvider.swift`
- Modify: `Wattly/Providers/TemperatureProvider.swift`
- Modify: `Wattly/Core/Temperature.swift`
- Modify: `Wattly/Core/Accessibility.swift`
- Modify: `Wattly/Views/CardExpandRegion.swift`
- Modify: `Wattly/Views/PopoverContentView.swift`
- Modify: `Wattly/Views/PopoverHeroView.swift`
- Modify: `Wattly/Intents/Intents/*.swift`
- Modify: `Wattly/Intents/Entities/*.swift`
- Modify: `Wattly/Intents/Errors/BatteryIntentError.swift`
- Create: `scripts/i18n_additions/metrics_intents_accessibility.json`

**Interfaces:**
- Consumes: `LocalizedStringResource`, `String(localized:)`
- Produces: `scripts/i18n_additions/metrics_intents_accessibility.json`

- [ ] **Step 1: Localize `MetricState.swift` and Provider error messages**
  Update `shortMessage` and `message` to return `String(localized:)`. Localize default messages in `BatteryProvider`, `FanProvider`, `CPUProvider`, `GPUProvider`, `MemoryProvider`, `PowerProvider`, and `Temperature.swift` (Cluster / Die names).

- [ ] **Step 2: Localize `Accessibility.swift` VoiceOver helpers & UI Popover views**
  Ensure all VoiceOver announcements (`accessibilityLabel`, `fanAnchorLabel`, `powerLabel`) use `String(localized:locale:)` with default `locale: Locale = Locale(identifier: "ko")` for test compatibility. In `CardExpandRegion.swift`, `PopoverContentView.swift`, and `PopoverHeroView.swift`, replace all raw VoiceOver strings (`"정상"`, `"주의"`, `"켜짐"`, `"꺼짐"`, `"히어로로 강조"`, `"최고"`, `"목표"`, `"팬"`, `"수동 방전 (%lld%%)"`) with `String(localized:)` / `LocalizedStringKey`.

- [ ] **Step 3: Localize App Intents dialogues, parameters, and entities**
  In `Wattly/Intents`, update dialog outputs (`dialogText`) to use `IntentDialog(LocalizedStringResource)` interpolated string literals (e.g. `IntentDialog("배터리 충전 한도를 \(limit)%로 설정했습니다.")`) instead of dynamically concatenated unlocalized Strings. Localize `BatteryIntentError` messages and `BatteryStateEntity` subtitles.

- [ ] **Step 4: Export key additions to `scripts/i18n_additions/metrics_intents_accessibility.json`**
  Save all new keys with their English translation dictionary.

- [ ] **Step 5: Run compiler check on modified files**
  Verify zero syntax errors in the modified files.

---

### Task 4 (Catalog Master): Translate & Merge All Missing Keys into `Localizable.xcstrings`

**Files:**
- Create: `scripts/i18n_additions/existing_49_gaps.json`
- Create: `scripts/generate_full_catalog.py`
- Modify: `Wattly/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: All JSON files in `scripts/i18n_additions/`
- Produces: Fully populated `Wattly/Resources/Localizable.xcstrings` covering 100% of the 30 languages.

- [ ] **Step 1: Extract the 49 existing incomplete keys**
  Collect the 49 existing partial keys that currently only have `ko` and `en` into `scripts/i18n_additions/existing_49_gaps.json`.

- [ ] **Step 2: Generate 30-language translation dictionary for all additions**
  Implement `scripts/generate_full_catalog.py` with complete high-quality translations across all 30 supported languages (`ar`, `cs`, `da`, `de`, `el`, `en`, `es`, `fi`, `fr`, `he`, `hi`, `hu`, `id`, `it`, `ja`, `ko`, `nb`, `nl`, `pl`, `pt-BR`, `pt-PT`, `ro`, `ru`, `sv`, `th`, `tr`, `uk`, `vi`, `zh-Hans`, `zh-Hant`) for all collected keys.

- [ ] **Step 3: Merge into `Localizable.xcstrings`**
  Merge the translations into `Wattly/Resources/Localizable.xcstrings` ensuring clean JSON formatting (`ensure_ascii=False, indent=2`).

- [ ] **Step 4: Automated 30-Language Verification Gate**
  Run catalog audit script to verify that 100% of keys in `Localizable.xcstrings` have `state == 'translated'` for all 30 languages.

---

### Task 5: Comprehensive Verification & Test Suite Execution

**Files:**
- Test: `WattlyTests/*.swift`

- [ ] **Step 1: Run catalog audit script**
  Verify 0 uncataloged Korean strings in production code and 0 incomplete language keys in the catalog.

- [ ] **Step 2: Run Xcode test suite**
  Run tests to confirm all tests pass.

- [ ] **Step 3: Verification walkthrough**
  Document the resolved keys, files modified, and verification results.
