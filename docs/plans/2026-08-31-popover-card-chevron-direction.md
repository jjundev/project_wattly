# Popover Card Expand/Collapse Chevron Indicator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change the expand/collapse indicator arrow in popover metric cards (Mode A stack & Mode C hero) from a static downward chevron (`chevron.down`) to a dynamic chevron that shows rightward (`chevron.right`, `>`) when collapsed and downward (`chevron.down`, `⌵`) when expanded, with a subtle easeInOut toggle animation.

**Architecture:**
- Add a pure presentation helper `CardPresentation.expandChevronSymbol(isExpanded:) -> String` to centralize SF Symbol selection and ensure 100% unit-testability without SwiftUI view dependencies.
- Update `MetricCardView` (Mode A) and `HeroCard` inside `PopoverHeroView` (Mode C) to display `CardPresentation.expandChevronSymbol(isExpanded: isExpanded)`.
- Wrap expansion state toggles in `PopoverContentView.swift` and `PopoverHeroView.swift` with `withAnimation(.easeInOut(duration: 0.15))` for smooth disclosure transition.

**Tech Stack:** Swift 6.0, SwiftUI, SF Symbols (`chevron.right` / `chevron.down`), Swift Testing (`@Test`, `#expect`), AppKit.

## Global Constraints

- Platform deployment target: macOS 14.0+
- Architecture: Apple Silicon (`arm64`)
- Language: Swift 6.0 with strict concurrency complete
- Zero external package dependencies (Pure SwiftUI / AppKit)
- Visual styling must preserve 8pt bold font and theme-aligned colors (`t.sub` and `Self.labelColor`)
- All test suites must pass via `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData`

---

### Task 1: Pure Presentation Logic & Unit Tests for Chevron Direction (`CardPresentation`)

**Files:**
- Modify: `Wattly/Core/CardPresentation.swift`
- Test: `WattlyTests/CardPresentationTests.swift`

**Interfaces:**
- Consumes: `isExpanded: Bool`
- Produces: `CardPresentation.expandChevronSymbol(isExpanded: Bool) -> String` ("chevron.down" when true, "chevron.right" when false)

- [ ] **Step 1: Write the failing unit tests for `expandChevronSymbol`**

Add `testExpandChevronSymbol` in `WattlyTests/CardPresentationTests.swift`:
```swift
    @Test func expandChevronSymbol() {
        #expect(CardPresentation.expandChevronSymbol(isExpanded: false) == "chevron.right")
        #expect(CardPresentation.expandChevronSymbol(isExpanded: true) == "chevron.down")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData`
Expected: Compilation failure or FAIL with `expandChevronSymbol` not found on `CardPresentation`.

- [ ] **Step 3: Implement minimal code in `CardPresentation.swift`**

Add `expandChevronSymbol` to `enum CardPresentation` in `Wattly/Core/CardPresentation.swift`:
```swift
    /// Which SF Symbol name to use for expandable card disclosure chevron:
    /// "chevron.down" when expanded, "chevron.right" when collapsed.
    static func expandChevronSymbol(isExpanded: Bool) -> String {
        isExpanded ? "chevron.down" : "chevron.right"
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData`
Expected: PASS (All test suites pass)

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/CardPresentation.swift WattlyTests/CardPresentationTests.swift
git commit -m "feat: add CardPresentation.expandChevronSymbol for card disclosure direction"
```

---

### Task 2: Update `MetricCardView` and `PopoverHeroView` with Dynamic Chevron & Toggle Animation

**Files:**
- Modify: `Wattly/Views/MetricCardView.swift:110-115`
- Modify: `Wattly/Views/PopoverHeroView.swift:63-67,168-173`
- Modify: `Wattly/Views/PopoverContentView.swift:436-439`

**Interfaces:**
- Consumes: `CardPresentation.expandChevronSymbol(isExpanded: isExpanded)`
- Produces: Updated SwiftUI card views with dynamic disclosure indicators and animated expansion toggle

- [ ] **Step 1: Update `MetricCardView.swift`**

Modify `headerRow(_ d: CardDisplay)` in `Wattly/Views/MetricCardView.swift`:
```swift
            HStack(spacing: 5) {
                Text(LocalizedStringKey(d.label))
                    .font(WattlyFont.at(11.5, weight: .semibold))
                    .foregroundStyle(t.sub)
                    .fixedSize()
                if hasChevron {
                    Image(systemName: CardPresentation.expandChevronSymbol(isExpanded: isExpanded))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(t.sub)
                }
            }
```

- [ ] **Step 2: Update `PopoverHeroView.swift`**

Modify `HeroCard.summary` and `toggleExpand` in `Wattly/Views/PopoverHeroView.swift`:
```swift
    private func toggleExpand(_ card: CardKind) {
        withAnimation(.easeInOut(duration: 0.15)) {
            expandedRaw = CardPresentation.togglingExpanded(card, in: expandedRaw)
        }
    }
```
And in `HeroCard`:
```swift
            HStack(spacing: 5) {
                Text(LocalizedStringKey(CardPresentation.label(card)))
                    .font(WattlyFont.at(11.5, weight: .semibold))
                    .foregroundStyle(Self.labelColor)
                    .lineLimit(1)
                if hasChevron {
                    Image(systemName: CardPresentation.expandChevronSymbol(isExpanded: isExpanded))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Self.labelColor)
                }
            }
```

- [ ] **Step 3: Update `PopoverContentView.swift`**

Modify `toggleExpand` in `Wattly/Views/PopoverContentView.swift`:
```swift
    private func toggleExpand(_ card: CardKind) {
        withAnimation(.easeInOut(duration: 0.15)) {
            expandedRaw = CardPresentation.togglingExpanded(card, in: expandedRaw)
        }
    }
```

- [ ] **Step 4: Run unit and integration tests to verify everything passes**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS,arch=arm64' -derivedDataPath .derivedData`
Expected: PASS (All test suites pass)

- [ ] **Step 5: Commit**

```bash
git add Wattly/Views/MetricCardView.swift Wattly/Views/PopoverHeroView.swift Wattly/Views/PopoverContentView.swift
git commit -m "feat: render dynamic chevron indicator and animate card toggle in popover"
```
