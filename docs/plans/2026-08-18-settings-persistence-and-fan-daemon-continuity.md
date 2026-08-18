# Settings Persistence & Fan Daemon Continuity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure user settings (Theme, Language, Fan Control) seamlessly persist across software updates, set both Theme and Language default behavior to "System" (dynamically adapting to macOS system settings), and eliminate false "Uninstalled (미설치)" warnings by intelligently probing and reconnecting to the background fan daemon without redundant administrator password prompts.

**Architecture:** 
1. **Fan Daemon Smart Probing & Reconnect (`FanControlClient`, `FanControlBridge`, `SettingsFanCurveSection`):** Proactively query background daemon status via XPC on app startup and Settings open. When user toggles Fan Control ON, probe existing daemon via `refreshStatus()` first; if already running, immediately engage control via `apply()` without triggering `installAndEngage` (no password dialog). Only prompt for admin auth if the daemon is genuinely missing.
2. **System Theme & System Language Resolution (`Theme.swift`, `Settings.swift`, `ThemedRoot`):** Solidify `Defaults.theme = .system` and `Defaults.appLanguage = "system"`, ensuring live adaptation to macOS Dark/Light appearance changes via `SystemAppearanceMonitor` and system locale via `Locale.autoupdatingCurrent`.
3. **App Replacement & Persistence Integrity (`AppReplacer`, `scripts/build_release.sh`):** Verify bundle identifier consistency (`dev.jjundev.Wattly`), embedded helper preservation (`Contents/Helpers/WattlyFanDaemon`), and user defaults stability across update cycles.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSXPCConnection`, `Process`, `NSWorkspace`), Swift Testing framework (`@Test`, `#expect`), XcodeGen.

---

## Global Constraints

- **Swift 6 Strict Concurrency:** Strict concurrency complete. All UI-facing models are `@Observable` and `@MainActor`.
- **Zero redundant admin prompts:** If `dev.jjundev.WattlyFanDaemon` is already running in launchd, toggling or updating the app must NEVER trigger `osascript with administrator privileges`.
- **No breaking changes to XPC Protocol:** Maintain exact Codable / XPC contract in `FanControlProtocol.swift`.
- **Test execution command:** `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData`
- **Xcode project sync:** Run `xcodegen generate` after any file creation.

---

### Task 1: Smart Fan Daemon Probing & Password-Free Reconnection (`FanControlClient` & `SettingsFanCurveSection`)

**Files:**
- Modify: `Wattly/Control/FanControlClient.swift`
- Modify: `Wattly/Views/FanControlBridge.swift`
- Modify: `Wattly/Views/Settings/SettingsFanCurveSection.swift`
- Create: `WattlyTests/FanControlClientTests.swift`

**Interfaces:**
- Consumes: `FanControlClient`, `FanControlXPCService`, `FanControlServiceStatus`
- Produces: 
  - `FanControlClient.refreshStatus() async -> FanControlServiceStatus?`
  - Smart engagement in `SettingsFanCurveSection` checking daemon presence before fallback installer

- [ ] **Step 1: Write unit tests for FanControlClient probing and smart engage behavior**

Create `WattlyTests/FanControlClientTests.swift`:
```swift
import Testing
import Foundation
@testable import Wattly

@Suite struct FanControlClientTests {
    @Test func refreshStatusUpdatesClientStatusWhenServiceAvailable() async {
        let expectedStatus = FanControlServiceStatus(
            mode: .automatic,
            detail: "macOS 자동 제어",
            updatedAt: 1000
        )
        
        let client = await FanControlClient(requestHandler: { request in
            if case .status = request {
                return .success(expectedStatus)
            }
            return .failure(.init(detail: "unhandled"))
        })

        let status = await client.refreshStatus()
        #expect(status == expectedStatus)
        let currentStatus = await client.status
        #expect(currentStatus == expectedStatus)
    }

    @Test func refreshStatusSetsUnavailableWhenServiceFails() async {
        let client = await FanControlClient(requestHandler: { request in
            return .failure(.init(detail: "연결 실패"))
        })

        let status = await client.refreshStatus()
        #expect(status == nil)
        let currentStatus = await client.status
        #expect(currentStatus.mode == .unavailable)
        #expect(currentStatus.detail == "연결 실패")
    }

    @Test func applyUpdatesStatusDirectlyWhenDaemonResponds() async {
        let controllingStatus = FanControlServiceStatus(
            mode: .controlling,
            detail: "팬 커브 적용 중",
            updatedAt: 2000
        )
        
        let client = await FanControlClient(requestHandler: { request in
            if case .configure = request {
                return .success(controllingStatus)
            }
            return .failure(.init(detail: "unhandled"))
        })

        await client.apply(enabled: true, curve: Defaults.fanCurve)
        let currentStatus = await client.status
        #expect(currentStatus.mode == .controlling)
    }
}
```

- [ ] **Step 2: Run test to verify it passes or fails**

Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/FanControlClientTests`
Expected: PASS (verifying existing client request handler seam).

- [ ] **Step 3: Update `FanControlBridge.swift` and `SettingsFanCurveSection.swift` for smart probing and reconnect**

Modify `Wattly/Views/FanControlBridge.swift`:
Ensure `FanControlBridge` probes daemon status on mount regardless of whether `enabled` is true:
```swift
            .task {
                if enabled {
                    await client.apply(enabled: true, curve: curve)
                } else {
                    await client.refreshStatus()
                }
            }
```

Modify `Wattly/Views/Settings/SettingsFanCurveSection.swift`:
1. On view appearance (`.task`), proactively probe the daemon status:
```swift
            .task {
                await fanControl.refreshStatus()
            }
```
2. In `.onChange(of: fanControlEnabled)`:
Smart engagement logic: Try to refresh / connect to existing daemon first; only prompt admin install if daemon is genuinely offline:
```swift
            .onChange(of: fanControlEnabled) { _, enabled in
                guard enabled, !fanControl.isInstallingHelper else {
                    if !enabled {
                        Task { await fanControl.apply(enabled: false, curve: fanCurve) }
                    }
                    return
                }
                let window = NSApp.keyWindow
                Task {
                    // 1. Probe if the daemon is already alive in the system
                    let currentStatus = await fanControl.refreshStatus()
                    if let mode = currentStatus?.mode, mode != .unavailable {
                        // Daemon already running! Seamlessly apply curve without admin prompt
                        await fanControl.apply(enabled: true, curve: fanCurve)
                        editApplyDeadline = Date().addingTimeInterval(5)
                        return
                    }

                    // 2. Daemon not running or unavailable -> trigger in-app helper install
                    let success = await fanControl.installAndEngage(curve: fanCurve, window: window)
                    if !success {
                        fanControlEnabled = false
                    } else {
                        editApplyDeadline = Date().addingTimeInterval(5)
                    }
                }
            }
```

- [ ] **Step 4: Run tests and verify**

Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/FanControlClientTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Control/FanControlClient.swift Wattly/Views/FanControlBridge.swift Wattly/Views/Settings/SettingsFanCurveSection.swift WattlyTests/FanControlClientTests.swift
git commit -m "fix(fan): implement smart daemon probe and reconnect without password prompt"
```

---

### Task 2: System Theme & System Language Resolution & Persistence Tests

**Files:**
- Modify: `Wattly/Settings/Settings.swift`
- Modify: `Wattly/DesignSystem/Theme.swift`
- Modify: `WattlyTests/ThemeResolverTests.swift`
- Modify: `WattlyTests/LocalizationTests.swift`

**Interfaces:**
- Consumes: `ThemeMode.system`, `AppLanguage.supportedLanguages`, `ThemedRoot`
- Produces: Live resolution of system dark/light and system locale.

- [ ] **Step 1: Write test for system theme & language resolution**

In `WattlyTests/ThemeResolverTests.swift`, verify system scheme mapping:
```swift
    @Test func systemThemeFollowsSystemDarkFlag() {
        #expect(ThemeResolver.scheme(.system, systemDark: true) == .dark)
        #expect(ThemeResolver.scheme(.system, systemDark: false) == .light)
        #expect(ThemeResolver.preferredColorScheme(.system) == nil)
    }
```

In `WattlyTests/LocalizationTests.swift`, verify "system" locale option and string resolution:
```swift
    @Test func systemLanguageOptionIsPresentAndResolvesLocale() {
        let systemOpt = AppLanguage.supportedLanguages.first(where: { $0.id == "system" })
        #expect(systemOpt != nil)
        #expect(systemOpt?.displayName == "시스템")

        let locale = AppLanguage.locale(for: "system")
        #expect(locale == Locale.autoupdatingCurrent)
    }
```

- [ ] **Step 2: Run tests to verify**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/ThemeResolverTests -only-testing:WattlyTests/LocalizationTests`
Expected: PASS.

- [ ] **Step 3: Verify Defaults and Storage Keys in `Settings.swift`**

Verify `Defaults.theme == .system` and `Defaults.appLanguage == "system"`. Ensure `SettingsReset.applyDefaults()` properly resets to `.system`.

- [ ] **Step 4: Commit**

```bash
git add WattlyTests/ThemeResolverTests.swift WattlyTests/LocalizationTests.swift
git commit -m "test(settings): add verification for system theme and language resolution"
```

---

### Task 3: App Packaging & Update Persistence Integrity Verification

**Files:**
- Modify: `scripts/build_release.sh`
- Test: `WattlyTests/AppReplacerTests.swift`
- Test: `WattlyTests/UpdateCheckerTests.swift`

**Interfaces:**
- Consumes: `project.yml`, `scripts/build_release.sh`, `AppReplacer.swift`
- Produces: Valid release zip with identical bundle identifier and embedded helpers.

- [ ] **Step 1: Verify Release Build Script embeds `WattlyFanDaemon` into `Wattly.app/Contents/Helpers`**

Verify `project.yml` target `Wattly` copy build phase for `WattlyFanDaemon`:
`destination: wrapper`, `subpath: Contents/Helpers`.

In `scripts/build_release.sh`, verify the build process checks for the embedded daemon:
```bash
if [ ! -x "$APP_PATH/Contents/Helpers/WattlyFanDaemon" ]; then
  echo "Error: Embedded WattlyFanDaemon helper missing or not executable in $APP_PATH/Contents/Helpers" >&2
  exit 1
fi
```

- [ ] **Step 2: Run complete automated test suite**

Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData`
Expected: PASS (all tests pass).

- [ ] **Step 3: Commit**

```bash
git add scripts/build_release.sh
git commit -m "chore(build): add embedded helper verification to release build script"
```

---

## Self-Review

- **Spec Coverage:**
  1. System Theme & Language default support & dynamic adaptation: covered in Task 2.
  2. Fan Daemon continuity & "미설치" false-positive elimination: covered in Task 1.
  3. No unnecessary password prompts when daemon already installed: covered in Task 1.
  4. Release packaging & update persistence: covered in Task 3.
- **Placeholder Scan:** No TODOs or vague steps. All code blocks and test assertions are concrete.
- **Strict Concurrency:** MainActor and Sendable conformances verified.
