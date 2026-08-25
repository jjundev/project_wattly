# Expandable Multiline Card Subtext Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expand metric card subtexts (such as memory breakdown) to 2 lines when a card is expanded (`isExpanded == true`), while keeping them strictly 1 line (`.lineLimit(1)` with `.minimumScaleFactor(0.9)`) when collapsed (`isExpanded == false`) to preserve grid alignment.

**Architecture:** Update `MetricCardView` and `PopoverHeroView` (`HeroCard`) to dynamically scale subtext in collapsed mode and allow 2-line expansion when expanded.

**Tech Stack:** Swift, SwiftUI, Xcode Test.

## Global Constraints
- Collapsed state MUST remain 1 line (`.lineLimit(1)`) to preserve grid balance across all metric cards.
- Expanded state MUST allow up to 2 lines (`.lineLimit(2)`) with `.fixedSize(horizontal: false, vertical: true)` so foreign language subtexts are not truncated.
- Accessible announcements via `Accessibility.swift` must remain completely intact.
- All 1,043 existing tests must continue to pass.

---

### Task 1: Update Subtext Views in MetricCardView & PopoverHeroView

**Files:**
- Modify: `Wattly/Views/MetricCardView.swift:60-98`
- Modify: `Wattly/Views/PopoverHeroView.swift:215-230`

**Interfaces:**
- Consumes: `isExpanded: Bool`, `d.subText: String?`
- Produces: Dynamic lineLimit and minimumScaleFactor on `subTextView`

- [ ] **Step 1: Update `MetricCardView.swift`**

```swift
    @ViewBuilder
    private func subTextView(_ fallbackSubText: String?) -> some View {
        if isDischarging, case .value(.battery(let s)) = state {
            let target = batteryControl?.status.desiredConfiguration?.manualDischargeTarget ?? s.targetPercentage
            let currentPct = s.percentage ?? (batteryControl?.status.currentPercentage ?? 0)
            let watts = s.netW > 0 ? -s.netW : s.netW
            let desc = BatterySectionPresentation.dischargeDescription(target: target, currentSoC: currentPct, watts: watts, locale: locale)
            HStack(spacing: 5) {
                Circle()
                    .fill(Tokens.statusOrange)
                    .frame(width: 6, height: 6)
                Text(desc)
                    .foregroundStyle(Tokens.statusOrange)
                    .lineLimit(isExpanded ? 2 : 1)
                    .minimumScaleFactor(0.9)
                    .fixedSize(horizontal: false, vertical: isExpanded)
            }
        } else if let sub = fallbackSubText, !sub.isEmpty {
            Text(sub)
                .lineLimit(isExpanded ? 2 : 1)
                .minimumScaleFactor(0.9)
                .fixedSize(horizontal: false, vertical: isExpanded)
        }
    }
```

- [ ] **Step 2: Update `PopoverHeroView.swift`**

```swift
    @ViewBuilder
    private func subTextView(_ fallbackSubText: String?) -> some View {
        if let sub = fallbackSubText, !sub.isEmpty {
            Text(sub)
                .lineLimit(isExpanded ? 2 : 1)
                .minimumScaleFactor(0.9)
                .fixedSize(horizontal: false, vertical: isExpanded)
        }
    }
```

- [ ] **Step 3: Run compiler build and full unit test suite**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath /tmp/WattlyDerivedData`
Expected: `** TEST SUCCEEDED **` (1043 tests passing)

---
