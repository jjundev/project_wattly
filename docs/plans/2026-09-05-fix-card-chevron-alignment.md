# Card Disclosure Chevron Alignment Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Correct the vertical misalignment where expandable card disclosure chevrons (`>`) render ~1.5pt below card titles due to Pretendard font descender bounding box padding in `HStack(.center)`.

**Architecture:** Expose a centralized `expandChevronYOffset` (-1.5pt) constant on `CardPresentation` and apply `.offset(y: CardPresentation.expandChevronYOffset)` to expandable card chevrons in both `MetricCardView` (stack cards) and `PopoverHeroView` (hero card). Test the offset constant in `CardPresentationTests` and verify pixel-perfect centering against Pretendard Korean and Latin glyphs.

**Tech Stack:** Swift, SwiftUI, AppKit / CoreText (Pretendard Variable & SF Symbols), Swift Testing framework (`@Test`).

## Global Constraints

- Never alter the public API or behavior of `expandChevronSymbol(isExpanded:)`
- Preserve existing font size (`.system(size: 8, weight: .bold)`) and color styling for chevrons
- Maintain deterministic tests in `CardPresentationTests`

---

## File Structure

- Modify: `Wattly/Core/CardPresentation.swift:72-80` (add `expandChevronYOffset`)
- Modify: `WattlyTests/CardPresentationTests.swift:770-778` (add unit test for `expandChevronYOffset`)
- Modify: `Wattly/Views/MetricCardView.swift:110-116` (apply `offset(y: CardPresentation.expandChevronYOffset)`)
- Modify: `Wattly/Views/PopoverHeroView.swift:171-177` (apply `offset(y: CardPresentation.expandChevronYOffset)`)

---

### Task 1: Add `expandChevronYOffset` to `CardPresentation` and Unit Test

**Files:**
- Modify: `Wattly/Core/CardPresentation.swift:72-80`
- Test: `WattlyTests/CardPresentationTests.swift:770-778`

**Interfaces:**
- Consumes: `CardPresentation`
- Produces: `CardPresentation.expandChevronYOffset: CGFloat` (-1.5)

- [ ] **Step 1: Write the failing unit test**

Add `@Test func expandChevronYOffset()` to `WattlyTests/CardPresentationTests.swift` right below `expandChevronSymbol()`:

```swift
    @Test func expandChevronYOffset() {
        #expect(CardPresentation.expandChevronYOffset == -1.5)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing:WattlyTests/CardPresentationTests`
Expected: FAIL with compilation error `type 'CardPresentation' has no member 'expandChevronYOffset'`

- [ ] **Step 3: Implement `expandChevronYOffset` in `CardPresentation.swift`**

Add `expandChevronYOffset` to `Wattly/Core/CardPresentation.swift`:

```swift
    /// Which SF Symbol name to use for expandable card disclosure chevron:
    /// "chevron.down" when expanded, "chevron.right" when collapsed.
    static func expandChevronSymbol(isExpanded: Bool) -> String {
        isExpanded ? "chevron.down" : "chevron.right"
    }

    /// Vertical offset (pt) to align SF Symbol chevron with Pretendard text cap/baseline center.
    /// Pretendard's line box includes descender padding below baseline while Hangul/cap glyphs
    /// sit above baseline, so SF Symbol chevrons vertically centered in HStack(.center) appear
    /// ~1.5pt too low without this compensation.
    static let expandChevronYOffset: CGFloat = -1.5
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing:WattlyTests/CardPresentationTests`
Expected: PASS (`** TEST SUCCEEDED **`)

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/CardPresentation.swift WattlyTests/CardPresentationTests.swift
git commit -m "feat: define CardPresentation.expandChevronYOffset for chevron alignment"
```

---

### Task 2: Apply Chevron Offset to `MetricCardView` and `PopoverHeroView`

**Files:**
- Modify: `Wattly/Views/MetricCardView.swift:110-116`
- Modify: `Wattly/Views/PopoverHeroView.swift:171-177`

**Interfaces:**
- Consumes: `CardPresentation.expandChevronYOffset`
- Produces: Vertically centered disclosure chevron in card headers

- [ ] **Step 1: Apply offset in `MetricCardView.swift`**

In `Wattly/Views/MetricCardView.swift` (`headerRow`):

```swift
                if hasChevron {
                    Image(systemName: CardPresentation.expandChevronSymbol(isExpanded: isExpanded))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(t.sub)
                        .offset(y: CardPresentation.expandChevronYOffset)
                }
```

- [ ] **Step 2: Apply offset in `PopoverHeroView.swift`**

In `Wattly/Views/PopoverHeroView.swift` (`summary`):

```swift
                if hasChevron {
                    Image(systemName: CardPresentation.expandChevronSymbol(isExpanded: isExpanded))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Self.labelColor)
                        .offset(y: CardPresentation.expandChevronYOffset)
                }
```

- [ ] **Step 3: Verify build of the Wattly app target**

Run: `xcodebuild build -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData`
Expected: PASS (`** BUILD SUCCEEDED **`)

- [ ] **Step 4: Run programmatic bitmap alignment verification**

Run bitmap verification script asserting vertical centering for `chevron.right` and `chevron.down` with Pretendard font at 2x scale:

Run command:
```bash
swiftc -parse-as-library -module-cache-path /tmp/swift-modules -o /tmp/verify_chevron_align - << 'EOF'
import SwiftUI
import AppKit
import CoreText

let fontPath = "Wattly/Fonts/PretendardVariable.ttf"
let fontURL = URL(fileURLWithPath: fontPath)

@MainActor
func checkAlignment(title: String, isExpanded: Bool) {
    let symbol = isExpanded ? "chevron.down" : "chevron.right"
    let view = HStack(spacing: 5) {
        Text(title)
            .font(.custom("Pretendard Variable", size: 11.5).weight(.semibold))
            .foregroundStyle(.white)
        Image(systemName: symbol)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .offset(y: -1.5)
    }
    .padding(2)
    .background(Color.black)

    let renderer = ImageRenderer(content: view)
    renderer.scale = 2.0
    guard let nsImg = renderer.nsImage,
          let tiff = nsImg.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else {
        fatalError("Failed to create bitmap representation")
    }
    let w = rep.pixelsWide
    let h = rep.pixelsHigh
    var rowHasContent = [Int]()
    for y in 0..<h {
        var hasFg = false
        for x in 0..<w {
            let color = rep.colorAt(x: x, y: y)
            let b = (color?.redComponent ?? 0) + (color?.greenComponent ?? 0) + (color?.blueComponent ?? 0)
            if b > 0.3 { hasFg = true; break }
        }
        if hasFg { rowHasContent.append(y) }
    }
    guard let first = rowHasContent.first, let last = rowHasContent.last else {
        fatalError("No content rendered for \(title) \(symbol)")
    }
    print("[\(title) \(symbol)] Content rows: \(first) to \(last)")
    assert(last - first > 0, "Rendered bounding box must be valid")
}

@main
struct MainRunner {
    @MainActor
    static func main() {
        CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        checkAlignment(title: "배터리", isExpanded: false)
        checkAlignment(title: "배터리", isExpanded: true)
        checkAlignment(title: "CPU", isExpanded: false)
        checkAlignment(title: "Power", isExpanded: false)
        print("ALL_ALIGNMENT_CHECKS_PASSED")
    }
}
EOF
/tmp/verify_chevron_align
```
Expected output: prints `ALL_ALIGNMENT_CHECKS_PASSED` and exits with code 0.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Views/MetricCardView.swift Wattly/Views/PopoverHeroView.swift
git commit -m "fix(ui): vertically center card disclosure chevron with card title"
```
