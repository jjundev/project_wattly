# Fix Menu Metric Selection Ghosting (Focus Ring Lingering) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve the lingering blue focus ring artifact on `WattlyChip`, `WattlySegment`, and `WattlyToggle` when interacted with via mouse clicks, while preserving full keyboard accessibility (Tab navigation & Space/Return activation).

**Architecture:** Update `WattlyChip`, `WattlySegment`, and `WattlyToggle` in `SettingsComponents.swift` so mouse tap gestures clear `@FocusState` immediately upon actuation. Keep keyboard focus navigation and `wattlyFocusRing` rendering intact for keyboard-driven navigation (Space, Return, Tab).

**Tech Stack:** Swift 5.9+, SwiftUI, macOS AppKit, XCTest

## Global Constraints

- macOS 14+ deployment target.
- Full Keyboard Access / Accessibility (VoiceOver) support must be preserved as defined in `plan/15-accessibility.md`.
- No visual regression on normal selection states (active chip white background + active shadow).
- All 411+ existing tests in `WattlyTests` must pass.

---

### Task 1: Prevent Mouse Click Focus Ring Lingering in Settings Custom Controls

**Files:**
- Modify: `Wattly/Views/SettingsComponents.swift:51-174`

**Interfaces:**
- Consumes: `@FocusState`, `wattlyFocusRing`, `Tokens.accent`
- Produces: `WattlyChip`, `WattlySegment`, `WattlyToggle` with cleaned-up mouse focus behavior

- [ ] **Step 1: Inspect current focus handling in `SettingsComponents.swift`**

Verify `WattlyChip`, `WattlySegment`, and `WattlyToggle` `.onTapGesture` and `@FocusState` definitions in `Wattly/Views/SettingsComponents.swift`.

- [ ] **Step 2: Update `WattlyChip` to clear focus on mouse tap**

In `Wattly/Views/SettingsComponents.swift`, update `WattlyChip.onTapGesture` so that clicking with mouse/pointer executes the action and resets `focused = false`:

```swift
            .contentShape(Rectangle())
            .onTapGesture {
                guard isEnabled else { return }
                action()
                focused = false
            }
            .focusable(isEnabled)
            .focused($focused)
            .onKeyPress(.space) { guard isEnabled else { return .ignored }; action(); return .handled }
            .onKeyPress(.return) { guard isEnabled else { return .ignored }; action(); return .handled }
```

- [ ] **Step 3: Update `WattlySegment` and `WattlyToggle` to clear focus on mouse tap**

In `WattlySegment`, update `onTapGesture`:
```swift
            .contentShape(Rectangle())
            .onTapGesture {
                selection = value
                focusedValue = nil
            }
            .focusable()
            .focused($focusedValue, equals: value)
```

In `WattlyToggle`, update `onTapGesture`:
```swift
        .contentShape(Rectangle())
        .onTapGesture {
            guard isEnabled else { return }
            toggle()
            focused = false
        }
        .focusable(isEnabled)
        .focused($focused)
```

- [ ] **Step 4: Build project and verify compilation**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Run all unit tests to ensure no regressions**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData test`
Expected: `** TEST SUCCEEDED **` (411 tests passed)

- [ ] **Step 6: Commit changes**

```bash
git add Wattly/Views/SettingsComponents.swift
git commit -m "fix(settings): dismiss focus ring on mouse tap for custom controls"
```
