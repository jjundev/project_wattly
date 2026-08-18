# Fix Software Update Download Progress Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the software update download progress bar in `SettingsView` by replacing the unstable AppKit-backed `ProgressView` with a pure SwiftUI `WattlyProgressBar` component that smoothly and reliably renders download progress from 0% to 100%.

**Architecture:** Implement `WattlyProgressBar` as a pure SwiftUI component in `SettingsComponents.swift` utilizing `Capsule`, `GeometryReader`, `t.segTrack`, and `Tokens.accent`. Replace the AppKit-bridged `ProgressView` in `SettingsView.swift`'s `.downloading(let fraction)` branch to eliminate structural identity destruction and AppKit redraw stalls during rapid `URLSession` progress updates.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing framework (`@Test`, `#expect`), XcodeGen.

---

## Global Constraints

- **Pure SwiftUI rendering:** Do not rely on AppKit `NSProgressIndicator` for dynamic download progress.
- **Design System alignment:** Use `Tokens.accent` for the fill bar and `t.segTrack` for the background track.
- **Swift 6 Strict Concurrency:** All UI components must conform to `@MainActor` and Sendable standards.
- **Test execution command:** `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData`
- **Xcode project sync:** Run `xcodegen generate` after any file creation.

---

### Task 1: Create `WattlyProgressBar` and Integrate into `SettingsView`

**Files:**
- Modify: `Wattly/Views/SettingsComponents.swift`
- Modify: `Wattly/Views/SettingsView.swift`
- Create: `WattlyTests/SettingsProgressBarTests.swift`

**Interfaces:**
- Produces: `struct WattlyProgressBar: View` with `let value: Double` (0.0 ... 1.0)
- Consumes: `autoUpdater.state` in `SettingsView.swift`

- [ ] **Step 1: Write unit tests for progress bar value clamping and calculations**

Create `WattlyTests/SettingsProgressBarTests.swift`:
```swift
import Testing
import Foundation
@testable import Wattly

@Suite struct SettingsProgressBarTests {
    @Test func clampsProgressValueBetweenZeroAndOne() {
        #expect(WattlyProgressBar.clampedFraction(-0.5) == 0.0)
        #expect(WattlyProgressBar.clampedFraction(0.0) == 0.0)
        #expect(WattlyProgressBar.clampedFraction(0.42) == 0.42)
        #expect(WattlyProgressBar.clampedFraction(1.0) == 1.0)
        #expect(WattlyProgressBar.clampedFraction(1.5) == 1.0)
        #expect(WattlyProgressBar.clampedFraction(.nan) == 0.0)
        #expect(WattlyProgressBar.clampedFraction(.infinity) == 1.0)
    }
}
```

- [ ] **Step 2: Implement `WattlyProgressBar` in `SettingsComponents.swift`**

In `Wattly/Views/SettingsComponents.swift`:
```swift
// MARK: - Linear Progress Bar (pure SwiftUI, 80×5, rounded capsule)

struct WattlyProgressBar: View {
    let value: Double
    @Environment(\.tokens) private var t

    public static func clampedFraction(_ v: Double) -> Double {
        guard v.isFinite else { return v.isNaN ? 0.0 : (v > 0 ? 1.0 : 0.0) }
        return max(0.0, min(1.0, v))
    }

    var body: some View {
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let fillWidth = totalWidth * Self.clampedFraction(value)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(t.segTrack)
                Capsule()
                    .fill(Tokens.accent)
                    .frame(width: fillWidth)
            }
            .clipShape(Capsule())
        }
        .frame(width: 80, height: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("다운로드 진행률")
        .accessibilityValue("\(Int(Self.clampedFraction(value) * 100))%")
    }
}
```

- [ ] **Step 3: Update `SettingsView.swift` to use `WattlyProgressBar`**

In `Wattly/Views/SettingsView.swift` (around line 106):
Replace:
```swift
                            case .downloading(let fraction):
                                ProgressView(value: fraction)
                                    .progressViewStyle(.linear)
                                    .frame(width: 80)
                                Text("\(Int(fraction * 100))%")
                                    .font(WattlyFont.at(11, weight: .medium))
                                    .foregroundStyle(t.text)
```
With:
```swift
                            case .downloading(let fraction):
                                WattlyProgressBar(value: fraction)
                                Text("\(Int(fraction * 100))%")
                                    .font(WattlyFont.at(11, weight: .medium))
                                    .foregroundStyle(t.text)
```

- [ ] **Step 4: Regenerate Xcode project and run tests**

Run: `xcodegen generate && xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/SettingsProgressBarTests`
Expected: PASS.

- [ ] **Step 5: Run full test suite to ensure no regressions**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData`
Expected: PASS (all tests pass).

- [ ] **Step 6: Commit**

```bash
git add Wattly/Views/SettingsComponents.swift Wattly/Views/SettingsView.swift WattlyTests/SettingsProgressBarTests.swift
git commit -m "fix(ui): replace ProgressView with pure SwiftUI WattlyProgressBar for smooth update progress"
```

---

## Self-Review

- **Spec Coverage:** Resolves progress bar stall by providing a pure SwiftUI implementation immune to AppKit view recreation.
- **Placeholder Scan:** No TODOs or placeholder steps.
- **Type Consistency:** `WattlyProgressBar.clampedFraction` matches the signature in tests and view body.
