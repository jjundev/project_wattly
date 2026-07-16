# Settings Window Theme Toggle Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the bug where changing the theme (라이트/다크/시스템) in the Settings window does not visually apply to the open Settings window itself until it is closed and reopened.

**Architecture:** SwiftUI's `.preferredColorScheme(_:)` (applied by `ThemedRoot` in `Wattly/App/WattlyApp.swift`) only sets the color-scheme *trait* SwiftUI content renders with. It does not re-resolve an already-visible `NSWindow`'s own AppKit-drawn chrome (the native titlebar) when the theme changes live — that chrome is only synced to the new value the next time the window is created, which is exactly why close/reopen "fixes" it. The fix adds a small `NSViewRepresentable` that reads the resolved `NSAppearance` for the current theme and reactively assigns it to the Settings window's `.appearance` property every time the theme changes, while the window is open. A new pure function (`ThemeResolver.nsAppearance`) supplies that mapping and is unit-tested; the window-assignment glue itself is AppKit-only and is verified on-device, matching this codebase's existing convention for live-appearance behavior (`WattlyTests/ThemeResolverTests.swift:6` — "live OS-appearance switching is verified on-device").

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSAppearance`, `NSViewRepresentable`), swift-testing (`@Test`/`#expect`).

## Global Constraints

- Swift 6 strict concurrency mode; deployment target 14.0.
- No new files — both changes land in existing files (`Wattly/DesignSystem/Theme.swift`, `Wattly/Views/SettingsView.swift`, `WattlyTests/ThemeResolverTests.swift`), so no `xcodegen generate` re-run is needed.
- Build: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
- Test: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test`
- Do not touch the `MenuBarExtra` popover's window/appearance handling — plan 11 (`plan/11-theme-light-dark-system.md`) explicitly and deliberately leaves that alone because the popover paints its own background from `t.panelBg`/tokens, so it's visually correct regardless of the window's real `NSAppearance`. This fix is scoped to the Settings window only.
- Follow existing code style: doc comments only where the WHY is non-obvious (this repo's comments explain hidden constraints, not what the code does).

---

## File Structure

- **Modify `Wattly/DesignSystem/Theme.swift`** — add `import AppKit` and a new pure static function `ThemeResolver.nsAppearance(_ mode: ThemeMode) -> NSAppearance?`, mirroring the existing `preferredColorScheme(_:)` function's shape (`light`→`.aqua`, `dark`→`.darkAqua`, `system`→`nil`).
- **Modify `WattlyTests/ThemeResolverTests.swift`** — add a unit test asserting the mapping above.
- **Modify `Wattly/Views/SettingsView.swift`** — add a private `WindowAppearanceSync: NSViewRepresentable` that assigns `NSAppearance?` to its hosting window, and wire it into `SettingsView.body` via `.background(WindowAppearanceSync(appearance: ThemeResolver.nsAppearance(theme)))` so every theme change re-applies it to the live Settings window.

---

### Task 1: `ThemeResolver.nsAppearance` pure mapping + unit test

**Files:**
- Modify: `Wattly/DesignSystem/Theme.swift`
- Test: `WattlyTests/ThemeResolverTests.swift`

**Interfaces:**
- Consumes: `ThemeMode` (`Wattly/DesignSystem/Theme.swift:6-18`, cases `.light`/`.dark`/`.system`), which already exists.
- Produces: `ThemeResolver.nsAppearance(_ mode: ThemeMode) -> NSAppearance?` — Task 2 calls this directly from `SettingsView`.

- [ ] **Step 1: Write the failing test**

Open `WattlyTests/ThemeResolverTests.swift` and add a new test after `systemFollowsTheEnvironmentScheme()` (before the struct's closing `}`):

```swift
    // MARK: nsAppearance — the concrete AppKit appearance a hosting NSWindow should adopt

    @Test func modesMapToTheirNativeAppearance() {
        #expect(ThemeResolver.nsAppearance(.light)?.name == .aqua)
        #expect(ThemeResolver.nsAppearance(.dark)?.name == .darkAqua)
        #expect(ThemeResolver.nsAppearance(.system) == nil)
    }
```

The full file should now read:

```swift
import Testing
import SwiftUI
@testable import Wattly

/// Issue 11 — pure theme resolution: the forced `ColorScheme` and the token set, the only
/// theming logic worth unit-testing (live OS-appearance switching is verified on-device).
struct ThemeResolverTests {

    // MARK: preferredColorScheme — light/dark force, system follows the OS (nil)

    @Test func forcedModesForceTheScheme() {
        #expect(ThemeResolver.preferredColorScheme(.light) == .light)
        #expect(ThemeResolver.preferredColorScheme(.dark) == .dark)
        #expect(ThemeResolver.preferredColorScheme(.system) == nil)
    }

    // MARK: tokens — 3 modes × 2 resolved schemes

    @Test func lightAndDarkIgnoreTheEnvironmentScheme() {
        // Forced modes pin the token set regardless of what the OS resolved to.
        for scheme in [ColorScheme.light, .dark] {
            #expect(ThemeResolver.tokens(.light, environment: scheme) == .light)
            #expect(ThemeResolver.tokens(.dark, environment: scheme) == .dark)
        }
    }

    @Test func systemFollowsTheEnvironmentScheme() {
        // `.system` is the only mode that reads the resolved scheme.
        #expect(ThemeResolver.tokens(.system, environment: .light) == .light)
        #expect(ThemeResolver.tokens(.system, environment: .dark) == .dark)
    }

    // MARK: nsAppearance — the concrete AppKit appearance a hosting NSWindow should adopt

    @Test func modesMapToTheirNativeAppearance() {
        #expect(ThemeResolver.nsAppearance(.light)?.name == .aqua)
        #expect(ThemeResolver.nsAppearance(.dark)?.name == .darkAqua)
        #expect(ThemeResolver.nsAppearance(.system) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/ThemeResolverTests/modesMapToTheirNativeAppearance`
Expected: FAIL — build error, `ThemeResolver` has no member `nsAppearance`.

- [ ] **Step 3: Implement the minimal code to make the test pass**

Open `Wattly/DesignSystem/Theme.swift`. Add `import AppKit` under the existing `import SwiftUI` on line 1:

```swift
import SwiftUI
import AppKit
```

Then add the new function inside `enum ThemeResolver` (`Theme.swift:20-39`), directly after `tokens(_:environment:)`:

```swift
    /// The concrete `NSAppearance` a hosting `NSWindow` should adopt for this mode. `nil` =
    /// follow the system, same convention as `preferredColorScheme`. SwiftUI's
    /// `.preferredColorScheme` only sets a window's appearance at window-creation time — it does
    /// not re-apply on a live theme change — so callers that need the window itself to update
    /// while already open (the Settings window) must assign this value reactively themselves.
    static func nsAppearance(_ mode: ThemeMode) -> NSAppearance? {
        switch mode {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }
```

The full `ThemeResolver` enum should now read:

```swift
enum ThemeResolver {
    /// Forced scheme for `.preferredColorScheme`. `nil` = follow the system.
    static func preferredColorScheme(_ mode: ThemeMode) -> ColorScheme? {
        switch mode {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }

    /// Tokens to inject, given the mode and the *resolved* environment scheme.
    static func tokens(_ mode: ThemeMode, environment scheme: ColorScheme) -> Tokens {
        let dark = switch mode {
            case .light: false
            case .dark: true
            case .system: scheme == .dark
        }
        return dark ? .dark : .light
    }

    /// The concrete `NSAppearance` a hosting `NSWindow` should adopt for this mode. `nil` =
    /// follow the system, same convention as `preferredColorScheme`. SwiftUI's
    /// `.preferredColorScheme` only sets a window's appearance at window-creation time — it does
    /// not re-apply on a live theme change — so callers that need the window itself to update
    /// while already open (the Settings window) must assign this value reactively themselves.
    static func nsAppearance(_ mode: ThemeMode) -> NSAppearance? {
        switch mode {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/ThemeResolverTests/modesMapToTheirNativeAppearance`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/DesignSystem/Theme.swift WattlyTests/ThemeResolverTests.swift
git commit -m "feat(theme): add ThemeResolver.nsAppearance mapping"
```

---

### Task 2: Reactively sync the Settings window's `NSAppearance` to the theme

**Files:**
- Modify: `Wattly/Views/SettingsView.swift`

**Interfaces:**
- Consumes: `ThemeResolver.nsAppearance(_ mode: ThemeMode) -> NSAppearance?` (Task 1). `SettingsView` already declares `@AppStorage(StorageKey.theme) private var theme = Defaults.theme` at `SettingsView.swift:27`.
- Produces: nothing consumed by later tasks — this is the terminal fix.

- [ ] **Step 1: Add the `WindowAppearanceSync` NSViewRepresentable**

Open `Wattly/Views/SettingsView.swift`. `import AppKit` is already present at line 2. Add the following private struct directly above `struct SettingsView: View {` (currently line 11):

```swift
/// Reactively syncs the Settings window's own `NSAppearance` to the theme setting.
/// `.preferredColorScheme` (applied by `ThemedRoot`, `Theme.swift:56`) only sets the color-scheme
/// trait SwiftUI content renders with — it does NOT re-resolve an already-visible `NSWindow`'s
/// AppKit-drawn chrome (the native titlebar) after the theme changes; that chrome only picks up
/// the new value the next time the window is created. That gap is exactly why toggling the theme
/// previously required closing and reopening Settings. Assigning `.appearance` on the hosting
/// window directly, on every reactive update, fixes it. Deliberately scoped to the Settings
/// window only — the `MenuBarExtra` popover paints its own background from tokens (plan 11), so
/// it doesn't need this and is left untouched.
private struct WindowAppearanceSync: NSViewRepresentable {
    let appearance: NSAppearance?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // `view.window` is nil until the view is inserted into the hierarchy; defer one tick.
        DispatchQueue.main.async { view.window?.appearance = appearance }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.appearance = appearance
    }
}

```

- [ ] **Step 2: Wire it into `SettingsView.body`**

In the same file, find `SettingsView.body` (`SettingsView.swift:73-96`):

```swift
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                generalSection
                themeSection
                layoutSection
                showSection
                smoothingSection
                thresholdSection
                if monitor.isPresent(.fan) { fanCurveSection }
                menubarSection
                powerModeSection
                pollSection
                resetButton
                footer
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 440, height: 560)
        .background(t.settingsBg)
        // Reconcile the display mirror with the real registration on open (F1).
        .task { loginMirror = loginItem.isEnabled }
    }
```

Add one more `.background(...)` modifier so the appearance re-applies every time `theme` changes and `body` re-evaluates:

```swift
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                generalSection
                themeSection
                layoutSection
                showSection
                smoothingSection
                thresholdSection
                if monitor.isPresent(.fan) { fanCurveSection }
                menubarSection
                powerModeSection
                pollSection
                resetButton
                footer
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 440, height: 560)
        .background(t.settingsBg)
        .background(WindowAppearanceSync(appearance: ThemeResolver.nsAppearance(theme)))
        // Reconcile the display mirror with the real registration on open (F1).
        .task { loginMirror = loginItem.isEnabled }
    }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Run the full test suite (regression check)**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test`
Expected: all tests pass, including the new `modesMapToTheirNativeAppearance` test from Task 1.

- [ ] **Step 5: Manual on-device verification**

This step exists because window-appearance behavior is AppKit runtime state, not something the pure-function unit tests can observe — the same convention this codebase already uses for theme (`WattlyTests/ThemeResolverTests.swift:6`).

1. Run: `open <DerivedData>/Build/Products/Debug/Wattly.app` (or launch from Xcode).
2. Open the menubar icon → Settings.
3. In the 테마 section, tap 라이트. Confirm the Settings window's native titlebar and all content switch to light **immediately**, without closing the window.
4. Tap 다크. Confirm it switches back to dark immediately.
5. Tap 시스템 설정, then toggle the OS appearance in System Settings → Appearance while the Wattly Settings window stays open. Confirm it follows the OS live.
6. Close and reopen Settings once more; confirm the theme is still correctly applied (no regression on the previously-working close/reopen path).

- [ ] **Step 6: Commit**

```bash
git add Wattly/Views/SettingsView.swift
git commit -m "fix(settings): apply theme change to the settings window immediately"
```
