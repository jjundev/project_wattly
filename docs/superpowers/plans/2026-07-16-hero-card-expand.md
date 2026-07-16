# Hero Card Expand Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In "히어로 + 리스트" (hero + list, panel mode C), give the hero card the same tap-to-expand detail reveal mode A's stack-row cards already have — a chevron next to the label, tap anywhere on the card to reveal the card-specific expand rows (CPU per-core bars, memory/power Top-3, battery voltage/current, temperature clusters, fan actual/target), tap again to collapse.

**Architecture:** Mode A's expand mechanism lives in two places: `PopoverContentView` owns the persisted `Set<CardKind>` of which cards are expanded (`@AppStorage(StorageKey.expandedCards)`, a CSV string), and `MetricCardView` renders the chevron + tap gesture + a `expandRegion` `@ViewBuilder` that switches on `card` to one of six private render funcs (`cpuExpand`, `memExpand`, `powerExpand`, `batteryExpand`, `tempExpand`, `fanExpand`). Mode C's hero card (`PopoverHeroView.swift`'s private `HeroCard`) is a completely separate, parallel view with its own hardcoded on-dark color palette (`#171719` background, `rgba(247,247,248,…)` text) — it does not use `MetricCardView` at all and today has no gesture, no chevron, no expand region.

We do three things: (1) extract the six expand-render funcs out of `MetricCardView` into a new shared view, `CardExpandRegion`, parameterized by `@Environment(\.tokens)` so each host supplies its own palette; (2) extract the expand-set CSV parse/toggle logic out of `PopoverContentView` into two pure `CardPresentation` funcs (`expandedCards(from:)` / `togglingExpanded(_:in:)`) so both mode A and mode C can read/write the *same* persisted set without duplicating the codec; (3) wire `HeroCard` to use both — it renders `CardExpandRegion` beneath its sub-line when expanded, with `Tokens.dark` force-injected via `.environment(\.tokens, Tokens.dark)` so the shared rows render correctly on the hero's fixed-dark background regardless of the app's current light/dark theme (`Tokens.dark`'s RGB values already match the hero's own hardcoded palette almost exactly — see `Tokens.swift`).

The expand *set* is shared, not per-mode: a card left expanded in mode A shows expanded if it later becomes the mode-C hero, and vice versa. This is a deliberate choice (one "which cards are expanded" concept, matching how `heroMetric`/`panelMode`/`thresholds` are already each a single cross-mode `@AppStorage` value read independently by whichever view needs them) rather than inventing a second, mode-C-only expanded flag.

One correctness gap this surfaces: mode A's memory/power Top-3 process enumeration is gated to `panelMode == .a && <card> expanded` (`PopoverContentView.memEnumActive`/`powerEnumActive`) — mode C never turns that sweep on today, so a mode-C hero showing the memory or power card would tap-expand into a permanent "측정 중…"/"프로세스를 읽을 수 없음" placeholder. We generalize that gating to also fire when the mode-C hero is the expanded mem/power card.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Swift Testing (`import Testing`, `@Test`, `#expect`), XcodeGen (`project.yml` → `Wattly.xcodeproj`, folder-based sources — new files require `xcodegen generate` + committing the regenerated `.pbxproj`).

## Global Constraints

- Swift 6 language mode; deployment target macOS 14.0; arm64 only. (`project.yml`)
- Korean copy lives in `CardPresentation`/`Accessibility` (localization is a separate concern) — this plan adds no new user-facing strings (it reuses the six existing expand-row layouts verbatim), so nothing new to place there.
- Pure display/formatting/state-codec logic lives in `CardPresentation` (no SwiftUI, no I/O) — views stay thin renderers over it, per the existing `cpuExpand`/`memExpand`/`tempExpand`/`fanExpand`/`batteryExpand` pattern this plan extracts and the `resolveHero`/`compactRowText` pattern it follows for the new CSV codec.
- `Tokens` (`Wattly/DesignSystem/Tokens.swift`) is a plain `Sendable, Equatable` struct injected via `@Environment(\.tokens)`; `Tokens.dark`/`Tokens.light` are the two static values, theme-independent by construction — this plan overrides the environment value for one subtree (the hero's expand region) rather than inventing a new palette type.
- Any file added under `Wattly/` requires `xcodegen generate` (run from the repo root, where `project.yml` lives) before the project builds, and the regenerated `Wattly.xcodeproj/project.pbxproj` must be committed alongside the new file (confirmed by prior commit `c682e6f`, which added `Wattly/Core/FanCurveGeometry.swift` + `WattlyTests/FanCurveGeometryTests.swift` and modified `project.pbxproj` in the same commit).
- Build: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
- Test: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test`
  - Filter one suite: append `-only-testing:WattlyTests/CardPresentationTests`

## File Structure

- **Create** `Wattly/Views/CardExpandRegion.swift` — the six expand-row renderers, moved verbatim out of `MetricCardView.swift`, now a standalone `View` any host can embed.
- **Modify** `Wattly/Core/CardPresentation.swift` — add `expandedCards(from:)` / `togglingExpanded(_:in:)`, the pure CSV codec both `PopoverContentView` and `PopoverHeroView` will call.
- **Modify** `Wattly/Views/MetricCardView.swift` — delete the six extracted funcs + their two row helpers; `expandRegion` becomes a one-line delegation to `CardExpandRegion`; drop the now-unused `import AppKit`.
- **Modify** `Wattly/Views/PopoverContentView.swift` — `expanded`/`toggleExpand` delegate to the new `CardPresentation` codec funcs; add a `hero` computed property and generalize `memEnumActive`/`powerEnumActive` to also cover the mode-C hero.
- **Modify** `Wattly/Views/PopoverHeroView.swift` — `PopoverHeroView` gains its own `@AppStorage(StorageKey.expandedCards)` + `expanded`/`toggleExpand`; `HeroCard` gains `isExpanded`/`onToggleExpand`, a chevron, a tap gesture, and renders `CardExpandRegion` (with `Tokens.dark` injected) when expanded.
- **Modify** `WattlyTests/CardPresentationTests.swift` — new tests for the CSV codec.

---

### Task 1: Pure expand-set CSV codec on `CardPresentation`

**Files:**
- Modify: `Wattly/Core/CardPresentation.swift` (add two new static funcs, placed after `resolveHero`)
- Modify: `Wattly/Views/PopoverContentView.swift:70-72` (`expanded`), `:408-412` (`toggleExpand`)
- Test: `WattlyTests/CardPresentationTests.swift` (new tests, inserted after `ghzTextTwoDecimalsWithUnit`)

**Interfaces:**
- Consumes: `CardKind(rawValue: String) -> CardKind?` (existing, `RawRepresentable` via `String` backing enum).
- Produces: `CardPresentation.expandedCards(from raw: String) -> Set<CardKind>` and `CardPresentation.togglingExpanded(_ card: CardKind, in raw: String) -> String` — consumed by Task 3's `PopoverHeroView` and this task's refactored `PopoverContentView`.

- [ ] **Step 1: Write the failing tests**

In `WattlyTests/CardPresentationTests.swift`, insert this new section after `ghzTextTwoDecimalsWithUnit` (before `// MARK: CardKind structural facts`):

```swift
    // MARK: Expand-set persistence (CSV codec) — shared by mode A's stack rows and mode C's
    // hero card expand (plan: hero card expand)

    @Test func expandedCardsParsesCSV() {
        #expect(CardPresentation.expandedCards(from: "") == [])
        #expect(CardPresentation.expandedCards(from: "cpu") == [.cpu])
        #expect(CardPresentation.expandedCards(from: "battery,cpu,mem") == [.battery, .cpu, .mem])
    }

    @Test func expandedCardsDropsUnknownTokens() {
        // A stale/unknown raw value (e.g. a renamed CardKind case) is dropped, not crashed on.
        #expect(CardPresentation.expandedCards(from: "cpu,notACard,mem") == [.cpu, .mem])
    }

    @Test func togglingExpandedAddsAndRemoves() {
        let added = CardPresentation.togglingExpanded(.cpu, in: "")
        #expect(added == "cpu")
        let addedMore = CardPresentation.togglingExpanded(.battery, in: added)
        #expect(CardPresentation.expandedCards(from: addedMore) == [.battery, .cpu])
        let removed = CardPresentation.togglingExpanded(.cpu, in: addedMore)
        #expect(CardPresentation.expandedCards(from: removed) == [.battery])
    }

    @Test func togglingExpandedSortsDeterministically() {
        // Insertion order (mem then battery) still serializes alphabetically by rawValue.
        let raw = CardPresentation.togglingExpanded(.battery,
                    in: CardPresentation.togglingExpanded(.mem, in: ""))
        #expect(raw == "battery,mem")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/CardPresentationTests`
Expected: FAIL to build — `CardPresentation.expandedCards`/`CardPresentation.togglingExpanded` don't exist yet.

- [ ] **Step 3: Implement the codec**

In `Wattly/Core/CardPresentation.swift`, add these two static funcs directly after `resolveHero(persisted:visible:)`:

```swift
    /// Parse the persisted CSV of expanded card raw values. Mode A's stack rows AND mode C's
    /// hero card share ONE set (plan: hero card expand) — a card expanded in one mode stays
    /// expanded if it's shown in the other. Unknown/stale tokens (e.g. a renamed `CardKind`
    /// case) are silently dropped rather than crashing the parse.
    static func expandedCards(from raw: String) -> Set<CardKind> {
        Set(raw.split(separator: ",").compactMap { CardKind(rawValue: String($0)) })
    }

    /// Toggle one card's membership in the persisted expand set, returning the new CSV to
    /// write back. Sorted so the stored string is deterministic (stable diffs, stable tests).
    static func togglingExpanded(_ card: CardKind, in raw: String) -> String {
        var s = expandedCards(from: raw)
        if s.contains(card) { s.remove(card) } else { s.insert(card) }
        return s.map(\.rawValue).sorted().joined(separator: ",")
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/CardPresentationTests`
Expected: PASS (all `CardPresentationTests` cases, including the four new ones)

- [ ] **Step 5: Refactor `PopoverContentView` to delegate to the codec**

In `Wattly/Views/PopoverContentView.swift`, replace the `expanded` computed property (lines 70-72):

```swift
    private var expanded: Set<CardKind> {
        Set(expandedRaw.split(separator: ",").compactMap { CardKind(rawValue: String($0)) })
    }
```

with:

```swift
    private var expanded: Set<CardKind> { CardPresentation.expandedCards(from: expandedRaw) }
```

And replace `toggleExpand` (lines 408-412):

```swift
    private func toggleExpand(_ card: CardKind) {
        var s = expanded
        if s.contains(card) { s.remove(card) } else { s.insert(card) }
        expandedRaw = s.map(\.rawValue).sorted().joined(separator: ",")
    }
```

with:

```swift
    private func toggleExpand(_ card: CardKind) {
        expandedRaw = CardPresentation.togglingExpanded(card, in: expandedRaw)
    }
```

- [ ] **Step 6: Build and run the full test suite**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test`
Expected: `** TEST SUCCEEDED **` — this is a behavior-preserving refactor, so every existing suite (not just `CardPresentationTests`) should still pass unchanged.

- [ ] **Step 7: Commit**

```bash
git add Wattly/Core/CardPresentation.swift Wattly/Views/PopoverContentView.swift WattlyTests/CardPresentationTests.swift
git commit -m "refactor(popover): extract expand-set CSV codec into CardPresentation"
```

---

### Task 2: Extract `CardExpandRegion`, a shared expand-row view

**Files:**
- Create: `Wattly/Views/CardExpandRegion.swift`
- Modify: `Wattly/Views/MetricCardView.swift:1-2` (drop `import AppKit`), `:108-124` (`expandRegion`), delete `:126-180` (`cpuExpand`/`coreRow`), `:182-205` (`memExpand`), `:207-237` (`powerExpand`), `:239-267` (`batteryExpand`/`batteryDetailRow`), `:269-313` (`processRow`/`appIcon`), `:315-356` (`tempExpand`/`tempGroupRow`), `:358-399` (`fanExpand`/`fanRow`)
- Test: none — pure move, regression-checked by the existing suite (no formatting/state logic changes)

**Interfaces:**
- Consumes: `CardKind`, `MetricState`, `Thresholds`, `Defaults.thresholds` (existing); `CardPresentation.ghzText/corePrefix/gbText/wattText/batteryCurrentText/batteryVoltageText/tempBarFraction/clusterSummary/fanBarFraction/f1/thresholdLevel` (existing, unchanged); global `barFraction(footprint:maxBytes:)` (`Wattly/Core/MemoryUsage.swift:69`) and `wattFraction(watts:maxWatts:)` (`Wattly/Core/ProcessPower.swift:53`) — both already free functions in the module, NOT redefined here.
- Produces: `struct CardExpandRegion: View { let card: CardKind; let state: MetricState; var thresholds: Thresholds = Defaults.thresholds }` — consumed by `MetricCardView.expandRegion` (this task) and Task 3's `HeroCard`.

- [ ] **Step 1: Create the new file with the moved code**

Create `Wattly/Views/CardExpandRegion.swift`:

```swift
import SwiftUI
import AppKit   // NSWorkspace for per-process app icons (issue 05)

/// The "tap to reveal detail" region for `isExpandable` cards (processor-power per-app
/// Top-3, battery voltage/current, CPU per-core, memory Top-3, CPU-temp clusters, fan
/// actual/target) — shared by mode A's stack rows (`MetricCardView`) and mode C's hero
/// card (`PopoverHeroView`, plan: hero card expand). Reads `@Environment(\.tokens)` for
/// its palette so each host supplies its own: mode A lets it track the live app theme,
/// while the hero overrides it to `Tokens.dark` (its background is fixed-dark in both
/// themes, so the live theme tokens would vanish against it — see `PopoverHeroView`).
struct CardExpandRegion: View {
    @Environment(\.tokens) private var t
    let card: CardKind
    let state: MetricState
    var thresholds: Thresholds = Defaults.thresholds

    @ViewBuilder
    var body: some View {
        if card == .power, case .value(.power(let s)) = state {
            powerExpand(s)
        } else if card == .battery, case .value(.battery(let s)) = state {
            batteryExpand(s)
        } else if card == .cpu, case .value(.cpu(let s)) = state {
            cpuExpand(s)
        } else if card == .mem, case .value(.memory(let s)) = state {
            memExpand(s)
        } else if card == .cpuTemp, case .value(.temperature(let s)) = state, case .reading(let r) = s.cpu {
            tempExpand(r.groups)
        } else if card == .fan, case .value(.fan(let s)) = state {
            fanExpand(s)
        }
    }

    // MARK: CPU expand — per-core bars grouped by runtime perf level (prototype lines 355–372)

    private func cpuExpand(_ s: CPUSample) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(s.perfLevels.enumerated()), id: \.offset) { idx, level in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(level.name)
                            .font(WattlyFont.at(11, weight: .bold))
                            .foregroundStyle(t.sub)
                        Spacer(minLength: 8)
                        if let ghz = level.activeGHz {
                            Text(CardPresentation.ghzText(ghz))
                                .font(WattlyFont.at(11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(t.faint)
                        }
                        Text("\(Int(level.usage.rounded()))%")
                            .font(WattlyFont.at(12, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(idx == 0 ? Tokens.accent : t.sub)
                    }
                    ForEach(Array(level.cores.enumerated()), id: \.offset) { ci, usage in
                        coreRow(label: "\(CardPresentation.corePrefix(level.name))\(ci)", usage: usage, accent: idx == 0)
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func coreRow(label: String, usage: Double, accent: Bool) -> some View {
        HStack(spacing: 9) {
            Text(label)
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.faint)
                .frame(width: 22, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(t.sparkFill)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(accent ? Tokens.accent : t.faint)
                        .frame(width: geo.size.width * min(100, max(0, usage)) / 100)
                }
            }
            .frame(height: 6)
            Text("\(Int(usage.rounded()))%")
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.sub)
                .frame(width: 26, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(Int(usage.rounded())) 퍼센트")
    }

    // MARK: Memory expand — top processes (issue 05)

    /// Top memory processes. Bar color tracks the memory sparkline stroke (neutral
    /// at 05; threshold color once issue 10 lands — §M12). Bars are proportional to
    /// the largest process; empty → a faint line (§M16).
    @ViewBuilder
    private func memExpand(_ s: MemorySample) -> some View {
        let maxBytes = s.processes.first?.footprintBytes ?? 0
        VStack(alignment: .leading, spacing: 8) {
            if s.processes.isEmpty {
                Text("프로세스를 읽을 수 없음")
                    .font(WattlyFont.at(10.5, weight: .semibold))
                    .foregroundStyle(t.faint)
            } else {
                ForEach(s.processes) { p in
                    processRow(name: p.name,
                               valueText: CardPresentation.gbText(p.footprintBytes),
                               fraction: barFraction(footprint: p.footprintBytes, maxBytes: maxBytes),
                               iconPath: p.iconPath)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: Power expand — top per-app power (issue 16 follow-up)

    /// Top power-consuming apps, symmetric with the memory Top-3. Three-state on
    /// `s.processes`: nil → "측정 중…" (baselining — the energy counter is cumulative, so the
    /// first sweep after expand has no rate yet); [] → "프로세스를 읽을 수 없음"; rows → Top-3.
    /// Watts cover CPU+GPU compute only and your readable apps, so they don't sum to the
    /// card's Combined headline (label-honest, not a breakdown).
    @ViewBuilder
    private func powerExpand(_ s: PowerSample) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch s.processes {
            case .none:
                Text("측정 중…")
                    .font(WattlyFont.at(10.5, weight: .semibold))
                    .foregroundStyle(t.faint)
            case .some(let procs) where procs.isEmpty:
                Text("프로세스를 읽을 수 없음")
                    .font(WattlyFont.at(10.5, weight: .semibold))
                    .foregroundStyle(t.faint)
            case .some(let procs):
                let maxW = procs.first?.watts ?? 0
                ForEach(procs) { p in
                    processRow(name: p.name,
                               valueText: CardPresentation.wattText(p.watts),
                               fraction: wattFraction(watts: p.watts, maxWatts: maxW),
                               iconPath: p.iconPath)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: Battery expand — voltage/current (plan: battery stack-mode display)

    private func batteryExpand(_ s: BatterySample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            batteryDetailRow(label: "전류", value: CardPresentation.batteryCurrentText(s))
            batteryDetailRow(label: "전압", value: CardPresentation.batteryVoltageText(s))
        }
        .padding(.top, 8)
    }

    private func batteryDetailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(WattlyFont.at(10.5, weight: .semibold))
                .foregroundStyle(t.faint)
            Spacer(minLength: 8)
            Text(value)
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.sub)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
    }

    // Process row, pixel-matched to the prototype (lines 138–141): name 74 ellipsis
    // · bar h6 r3 · value 46 right. Generalized over the value (bytes "GB" / watts "W") and
    // its bar fraction so memory (05) and power (16) share one row. Borrows coreRow's
    // structure, not its sizing (§M13).
    private func processRow(name: String, valueText: String, fraction: Double, iconPath: String?) -> some View {
        HStack(spacing: 9) {
            appIcon(iconPath)
                .frame(width: 15, height: 15)
            Text(name)
                .font(WattlyFont.at(11, weight: .semibold))
                .foregroundStyle(t.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 74, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(t.sparkFill)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(sparkStroke)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 6)
            Text(valueText)
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.sub)
                .frame(width: 46, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(valueText)")
    }

    /// Small app icon from the resolved bundle/executable path (NSWorkspace caches
    /// these). nil path → a faint placeholder so the rows stay aligned.
    @ViewBuilder
    private func appIcon(_ path: String?) -> some View {
        if let path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 3).fill(t.sparkFill)
        }
    }

    // MARK: Temperature expand — per-cluster summary (issue 08 follow-up)

    /// One row per cluster (P-코어 / E-코어 / GPU): a bar on a fixed 0–110 °C scale plus
    /// the cluster average and hottest sensor. The SMC exposes die-region sensors, not
    /// 1:1 cores, so a per-cluster average is the honest unit (not "per core").
    private func tempExpand(_ groups: [TemperatureGroup]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if groups.isEmpty {
                Text("센서를 읽을 수 없음")
                    .font(WattlyFont.at(10.5, weight: .semibold))
                    .foregroundStyle(t.faint)
            } else {
                ForEach(groups, id: \.name) { tempGroupRow($0) }
            }
        }
        .padding(.top, 8)
    }

    private func tempGroupRow(_ g: TemperatureGroup) -> some View {
        HStack(spacing: 9) {
            Text(g.name)
                .font(WattlyFont.at(10.5, weight: .semibold))
                .foregroundStyle(t.faint)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(t.sparkFill)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(t.spark)
                        .frame(width: geo.size.width * CardPresentation.tempBarFraction(g.average))
                }
            }
            .frame(height: 6)
            Text(CardPresentation.clusterSummary(average: g.average, hottest: g.hottest))
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.sub)
                .frame(width: 104, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(g.name), 평균 \(CardPresentation.f1(g.average))도, 최고 \(CardPresentation.f1(g.hottest))도")
    }

    // MARK: Fan expand — per-fan actual/target (Phase A)

    /// One row per physical fan: a bar on the fan's own 0–max scale plus its actual and
    /// target RPM. Single-fan Macs show one row; multi-fan Macs (some MacBook Pros) show one
    /// per fan. Mirrors `tempExpand`'s shape.
    private func fanExpand(_ s: FanSample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if s.fans.isEmpty {
                Text("팬을 읽을 수 없음")
                    .font(WattlyFont.at(10.5, weight: .semibold))
                    .foregroundStyle(t.faint)
            } else {
                ForEach(s.fans) { fanRow($0) }
            }
        }
        .padding(.top, 8)
    }

    private func fanRow(_ f: FanReading) -> some View {
        HStack(spacing: 9) {
            Text("팬 \(f.index + 1)")
                .font(WattlyFont.at(10.5, weight: .semibold))
                .foregroundStyle(t.faint)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(t.sparkFill)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(t.spark)
                        .frame(width: geo.size.width * CardPresentation.fanBarFraction(actual: f.actualRPM, max: f.maxRPM))
                }
            }
            .frame(height: 6)
            Text("\(Int(f.actualRPM.rounded())) RPM · 목표 \(Int(f.targetRPM.rounded()))")
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.sub)
                .frame(width: 128, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("팬 \(f.index + 1), \(Int(f.actualRPM.rounded())) RPM, 목표 \(Int(f.targetRPM.rounded())) RPM")
    }

    // Same rule as MetricCardView's headline sparkline: threshold color when the card has
    // one, else neutral/accent by card family — kept in step so the Top-3 bars in mem/power
    // expand match their card's own sparkline color.
    private var sparkStroke: Color {
        if let level = CardPresentation.thresholdLevel(card, state, thresholds) { return level.stroke }
        return card.isAccented ? Tokens.accent : t.spark
    }
}
```

- [ ] **Step 2: Register the new file with XcodeGen**

Run: `xcodegen generate` (from the repo root, where `project.yml` lives)
Expected: regenerates `Wattly.xcodeproj/project.pbxproj` to include `Wattly/Views/CardExpandRegion.swift`. Confirm with `git status` that `Wattly.xcodeproj/project.pbxproj` shows as modified.

- [ ] **Step 3: Build to verify the new file compiles standalone**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **` — `CardExpandRegion` compiles fine alongside `MetricCardView`'s still-present (not yet deleted) copies; Swift allows same-named private methods on two different types.

- [ ] **Step 4: Delete the moved code from `MetricCardView` and delegate**

In `Wattly/Views/MetricCardView.swift`, remove the `import AppKit` line (line 2 — no longer needed once `appIcon`/`processRow` move out; nothing else in this file uses AppKit):

```swift
import SwiftUI
import AppKit   // NSWorkspace for per-process app icons (issue 05)
```

becomes:

```swift
import SwiftUI
```

Replace the `expandRegion` `@ViewBuilder` (the dispatch switch, originally lines 108-124):

```swift
    // Power per-app Top-3 (16). CPU per-core bars (04). Memory Top-3 (05). CPU-temp clusters (08).
    @ViewBuilder
    private var expandRegion: some View {
        if card == .power, case .value(.power(let s)) = state {
            powerExpand(s)
        } else if card == .battery, case .value(.battery(let s)) = state {
            batteryExpand(s)
        } else if card == .cpu, case .value(.cpu(let s)) = state {
            cpuExpand(s)
        } else if card == .mem, case .value(.memory(let s)) = state {
            memExpand(s)
        } else if card == .cpuTemp, case .value(.temperature(let s)) = state, case .reading(let r) = s.cpu {
            tempExpand(r.groups)
        } else if card == .fan, case .value(.fan(let s)) = state {
            fanExpand(s)
        }
    }
```

with a one-line delegation:

```swift
    // Content lives in the shared `CardExpandRegion` (plan: hero card expand) — mode C's
    // hero card reuses it too, with `Tokens.dark` force-injected instead of the live theme.
    private var expandRegion: some View {
        CardExpandRegion(card: card, state: state, thresholds: thresholds)
    }
```

Then delete every func from `cpuExpand` through `fanRow` — i.e. everything between the old `expandRegion` (just replaced) and the `// MARK: Unavailable cards` comment: `cpuExpand`, `coreRow`, the `// MARK: Memory expand` block (`memExpand`), the `// MARK: Power expand` block (`powerExpand`), the `// MARK: Battery expand` block (`batteryExpand`/`batteryDetailRow`), `processRow`, `appIcon`, the `// MARK: Temperature expand` block (`tempExpand`/`tempGroupRow`), and the `// MARK: Fan expand` block (`fanExpand`/`fanRow`). `MetricCardView.swift` should go directly from the new one-line `expandRegion` to `// MARK: Unavailable cards`.

- [ ] **Step 5: Build again**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Run the full test suite**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test`
Expected: `** TEST SUCCEEDED **` (every suite — this is a pure move, no formatting/state-logic changed)

- [ ] **Step 7: Manual on-device visual regression check**

Run: `open <DerivedData>/Build/Products/Debug/Wattly.app --args -WattlyScenario laptop` (substitute the actual DerivedData path from Step 5's build output)

In mode A ("스택 행", 설정 → 패널 레이아웃), expand each of 프로세서 전력 / 배터리 / CPU / 메모리 / CPU 온도 / 팬 속도 in turn and confirm every row (per-app Top-3, per-core bars, 전류/전압, per-cluster bars, per-fan RPM) renders exactly as before this refactor — colors, spacing, and text unchanged, since `CardExpandRegion` is a verbatim move.

- [ ] **Step 8: Commit**

```bash
git add Wattly.xcodeproj/project.pbxproj Wattly/Views/CardExpandRegion.swift Wattly/Views/MetricCardView.swift
git commit -m "refactor(popover): extract shared CardExpandRegion from MetricCardView"
```

---

### Task 3: Hero card chevron, tap-to-expand, and expand region

**Files:**
- Modify: `Wattly/Views/PopoverHeroView.swift` (whole file — struct doc comment, `PopoverHeroView` gains `expandedRaw`/`expanded`/`toggleExpand`, `HeroCard` gains `isExpanded`/`onToggleExpand`/chevron/tap gesture/expand region)

**Interfaces:**
- Consumes: `CardPresentation.expandedCards(from:)` / `togglingExpanded(_:in:)` (Task 1); `CardExpandRegion` (Task 2); `CardKind.isExpandable` (existing, unchanged); `Tokens.dark` (existing static value).
- Produces: `HeroCard`'s new `isExpanded: Bool = false` / `onToggleExpand: (() -> Void)? = nil` params — private to this file (only `PopoverHeroView.body` constructs `HeroCard`), so no other file's interface changes.

- [ ] **Step 1: Replace `Wattly/Views/PopoverHeroView.swift`**

Replace the entire file contents with:

```swift
import SwiftUI

/// Mode C — the dark hero card + a label↔value list (prototype lines 207–222). One promoted
/// metric is shown large (40px) on a fixed-dark card; every other visible card is a compact row,
/// and tapping a row promotes it to hero. The visible set + order arrive from `PopoverContentView`
/// (`cardOrder ∩ isPresent ∩ isShown`); the hero choice is the shared `@AppStorage(heroMetric)`,
/// so the settings picker and a row tap stay in sync for free.
///
/// The hero card also supports the SAME tap-to-expand as mode A's stack rows (plan: hero card
/// expand) — `isExpandable` cards get a chevron and reveal `CardExpandRegion` beneath the
/// sub-line on tap. The expand SET is the shared `@AppStorage(expandedCards)` mode A already
/// uses (one CSV Set keyed by `CardKind`, not per-mode) — a card left expanded in mode A shows
/// expanded here too if it becomes the hero, and vice versa; this is a deliberate, accepted
/// consequence of reusing "which cards are expanded" as one concept rather than inventing a
/// second mode-C-only flag.
///
/// Because the hero card is dark in BOTH themes, its text and the neutral/accent spark colors are
/// hardcoded light-on-dark — they CANNOT reuse the theme tokens (`t.spark`/`Tokens.accent`) the
/// way modes A/B do, or they'd vanish in light mode. The expand region is the one exception: it
/// reuses `CardExpandRegion` (shared with mode A) but with `Tokens.dark` force-injected via
/// `.environment(\.tokens, ...)`, since `Tokens.dark`'s colors are computed independent of the
/// app's current theme and already match the hero's fixed dark background (see `Tokens.swift`).
/// Threshold-driven cards still reuse the theme-independent status colors. The list below the
/// hero sits on the panel background and uses the theme tokens normally. Power-type cards get
/// the EMA-smoothed series (same toggle as mode A).
struct PopoverHeroView: View {
    let cards: [CardKind]
    let monitor: SystemMonitor
    var thresholds: Thresholds = Defaults.thresholds
    var powerSmoothed: Bool

    @AppStorage(StorageKey.heroMetric) private var heroMetric = Defaults.heroMetric
    // Shared with mode A's `PopoverContentView.expandedRaw` — same key, same CSV Set (see the
    // doc comment above).
    @AppStorage(StorageKey.expandedCards) private var expandedRaw = ""
    @Environment(\.tokens) private var t

    private var hero: CardKind? {
        CardPresentation.resolveHero(persisted: heroMetric, visible: cards)
    }
    private var expanded: Set<CardKind> { CardPresentation.expandedCards(from: expandedRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // hero == nil only when nothing is visible (all cards hidden) → render nothing, no crash.
            if let hero {
                HeroCard(card: hero,
                         state: monitor.cardState(hero, smoothed: powerSmoothed),
                         historyValues: monitor.historyValues(for: hero, smoothed: powerSmoothed),
                         thresholds: thresholds,
                         isExpanded: expanded.contains(hero),
                         onToggleExpand: hero.isExpandable ? { toggleExpand(hero) } : nil)
                list(excluding: hero)
            }
        }
        .padding(.vertical, 1)
    }

    private func toggleExpand(_ card: CardKind) {
        expandedRaw = CardPresentation.togglingExpanded(card, in: expandedRaw)
    }

    // The list = the visible cards minus the hero, in `cardOrder` order (prototype 213–220).
    private func list(excluding hero: CardKind) -> some View {
        let rows = cards.filter { $0 != hero }
        return VStack(spacing: 0) {
            ForEach(rows) { card in
                listRow(card,
                        monitor.cardState(card, smoothed: powerSmoothed),
                        divider: card != rows.last)
            }
        }
    }

    private func listRow(_ card: CardKind, _ state: MetricState, divider: Bool) -> some View {
        let unavailable: Bool = { if case .unavailable = state { return true }; return false }()
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(CardPresentation.label(card))
                    .font(WattlyFont.at(13, weight: .semibold))
                    .foregroundStyle(t.cText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(CardPresentation.compactRowText(card, state))
                    .font(WattlyFont.at(14, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(unavailable ? t.faint : t.cText)
                    .lineLimit(1)
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 6)
            if divider {
                Rectangle().fill(t.line).frame(height: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { heroMetric = card }
        // One VoiceOver element per row: the card summary + a promote action (issue 15 regs reused).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Accessibility.cardLabel(card, state))
        .accessibilityValue(Accessibility.stateWord(card, state, thresholds) ?? "")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("히어로로 강조")
        .accessibilityAction { heroMetric = card }
    }
}

/// The dark hero card (prototype line 208): fixed `#171719` in both themes, radius 14, padding 16.
/// Its text + the neutral/accent spark colors are hardcoded light-on-dark (see `PopoverHeroView`).
/// `isExpandable` cards get the same chevron + tap-to-expand as mode A's stack rows (plan: hero
/// card expand) — the whole card is the tap target, matching `MetricCardView.standardCard`.
private struct HeroCard: View {
    let card: CardKind
    let state: MetricState
    var historyValues: [Double] = []
    var thresholds: Thresholds = Defaults.thresholds
    var isExpanded: Bool = false
    var onToggleExpand: (() -> Void)? = nil

    // Hardcoded light-on-dark surface/text (prototype line 208).
    private static let heroBg = Color(hex: "#171719")
    private static let labelColor = Color.rgba(247, 247, 248, 0.6)
    private static let unitColor = Color.rgba(247, 247, 248, 0.6)
    private static let subColor = Color.rgba(247, 247, 248, 0.55)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary
            if isExpanded, hasChevron {
                CardExpandRegion(card: card, state: state, thresholds: thresholds)
                    .environment(\.tokens, Tokens.dark)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Self.heroBg))
        .contentShape(Rectangle())
        .onTapGesture { onToggleExpand?() }
    }

    /// The hero's spoken summary — its own VoiceOver element, a SIBLING of the expand region
    /// (mirrors `MetricCardView.summaryGroup`/`expandRegion`, issue 15 §2/§6), so the expand
    /// rows stay individually navigable instead of being swallowed into one combined element.
    /// Mouse taps toggle via `HeroCard.body`'s `.onTapGesture`; VoiceOver toggles via the
    /// `.accessibilityAction` here (a gesture VO can't otherwise actuate).
    @ViewBuilder
    private var summary: some View {
        let content = VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Text(CardPresentation.label(card))
                    .font(WattlyFont.at(11.5, weight: .semibold))
                    .foregroundStyle(Self.labelColor)
                    .lineLimit(1)
                if hasChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Self.labelColor)
                }
            }
            switch state {
            case .unavailable(let reason):
                // Hero unavailable (prototype line 211): same dark card + the full reason.
                Text(reason.message)
                    .font(WattlyFont.at(12, weight: .regular))
                    .foregroundStyle(Self.subColor)
                    .fixedSize(horizontal: false, vertical: true)
            case .loading, .value:
                valueBody
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Accessibility.cardLabel(card, state))
        .accessibilityValue(Accessibility.stateWord(card, state, thresholds) ?? "")

        if hasChevron {
            content
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onToggleExpand?() }
        } else {
            content
        }
    }

    // value 40/700 white + unit 16/600 → spark (h32, area+line) → sub 11 (prototype 208).
    @ViewBuilder private var valueBody: some View {
        let d = CardPresentation.display(card, state)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(d.valueText)
                .font(WattlyFont.at(40, weight: .bold)).tracking(-1.2)
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(d.unitText)
                .font(WattlyFont.at(16, weight: .semibold))
                .foregroundStyle(Self.unitColor)
                .lineLimit(1)
        }
        if hasValue {
            // The hero always draws area + line, even for the battery card (which is line-only in
            // mode A) — prototype-faithful (line 208 renders a polygon for every metric).
            SparklineView(values: historyValues, stroke: sparkStroke, fill: sparkFill, height: 32)
                .accessibilityHidden(true)
        }
        if let sub = d.subText {
            Text(sub)
                .font(WattlyFont.at(11, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(Self.subColor)
                .lineLimit(1)
        }
    }

    // Spark colors on the DARK hero card (prototype heroColorMap 705–715): threshold cards use the
    // theme-independent status colors; the accented (power) card uses an on-dark accent (#3385ff,
    // NOT the panel accent #0066ff); everything else (battery / neutral) uses a light-on-dark tone.
    private var sparkStroke: Color {
        if let level = CardPresentation.thresholdLevel(card, state, thresholds) { return level.stroke }
        return card.isAccented ? Color(hex: "#3385ff") : .rgba(247, 247, 248, 0.85)
    }

    private var sparkFill: Color {
        if let level = CardPresentation.thresholdLevel(card, state, thresholds) { return level.fill }
        return card.isAccented ? .rgba(51, 133, 255, 0.18) : .rgba(247, 247, 248, 0.12)
    }

    private var hasValue: Bool { if case .value = state { return true }; return false }

    // No chevron/expand for an unavailable card — mirrors `MetricCardView`, which renders a
    // completely separate `unavailableCard` layout with no header/chevron machinery at all.
    private var isUnavailable: Bool { if case .unavailable = state { return true }; return false }
    private var hasChevron: Bool { card.isExpandable && !isUnavailable }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Run the full test suite**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test`
Expected: `** TEST SUCCEEDED **` (no test targets this file directly — `HeroSelectionTests`/`PanelPresentationTests` cover the pure `resolveHero`/`compactRowText` funcs this view calls, unaffected)

- [ ] **Step 4: Manual on-device check**

Run: `open <DerivedData>/Build/Products/Debug/Wattly.app --args -WattlyScenario laptop` (substitute the actual DerivedData path from Step 2's build output)

In 설정 → 패널 레이아웃, switch to C ("히어로 + 리스트"). For each of the six expandable card kinds (프로세서 전력, 배터리, CPU, 메모리, CPU 온도, 팬 속도), promote it to hero (tap its list row) and verify:
- A small chevron appears next to the hero's label.
- Tapping anywhere on the hero card reveals the expand rows beneath the sub-line (per-core bars for CPU, 전류/전압 for 배터리, per-cluster bars for CPU 온도, per-fan RPM for 팬 속도) — text and bars readable against the dark hero background in BOTH light and dark app theme (toggle 설정 → 테마).
- Tapping again collapses it.
- For 프로세서 전력/메모리 specifically: expanding shows "측정 중…"/"프로세스를 읽을 수 없음" and does NOT populate a Top-3 yet — **this is expected and fixed by Task 4**, not a regression to chase down here.
- Promote GPU 온도 or 배터리 온도 to hero (neither is `isExpandable`) and confirm NO chevron appears and tapping the hero card does nothing (no visual change, no console error).
- Switch back to A ("스택 행") and confirm a card's expand state carried over if it matches what was left expanded in C (e.g. if CPU was expanded as hero, CPU's mode-A card opens already expanded) — this is the intentional shared-state behavior documented in `PopoverHeroView`'s doc comment, not a bug.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Views/PopoverHeroView.swift
git commit -m "feat(popover): hero card expand-to-reveal in hero+list mode"
```

---

### Task 4: Gate memory/power process enumeration to the mode-C hero too

**Files:**
- Modify: `Wattly/Views/PopoverContentView.swift:26-29` (add `heroMetric` AppStorage after `thresholds`), `:74-82` (`memExpanded`/`powerExpanded`/`memEnumActive`/`powerEnumActive`)

**Interfaces:**
- Consumes: `CardPresentation.resolveHero(persisted:visible:)` (existing); `StorageKey.heroMetric`/`Defaults.heroMetric` (existing).
- Produces: no new public interface — `hero`/`memEnumActive`/`powerEnumActive` are private to `PopoverContentView`.

- [ ] **Step 1: Add the `heroMetric` AppStorage read**

In `Wattly/Views/PopoverContentView.swift`, immediately after the existing `thresholds` declaration (originally lines 26-29):

```swift
    /// Warn/crit thresholds (issue 10). Read here (the card composition root) and passed
    /// into each card; an `@AppStorage` change re-renders the cards, so a slider edit recolors
    /// the panel live with no extra observer.
    @AppStorage(StorageKey.thresholds) private var thresholds = Defaults.thresholds
```

add:

```swift
    /// Mode C's hero metric (plan 20). Read independently here — NOT passed down from
    /// `PopoverHeroView` — purely to resolve `hero` below for the process-enumeration gate
    /// (plan: hero card expand). Mirrors how `PopoverHeroView`/`SettingsView` each read this
    /// same key independently.
    @AppStorage(StorageKey.heroMetric) private var heroMetric = Defaults.heroMetric
```

- [ ] **Step 2: Generalize the enumeration gate**

Replace (originally lines 74-82):

```swift
    private var memExpanded: Bool { expanded.contains(.mem) }
    private var powerExpanded: Bool { expanded.contains(.power) }

    // Per-process enumeration is only meaningful in mode A (the only layout with an expand
    // region). Gating on `panelMode == .a` too means switching A→B mid-session — while the
    // mem/power card is expanded — turns the sweep off, instead of leaking it into a layout
    // that never shows the Top-3 (review row 6). Composite so the `.task` re-fires on switch.
    private var memEnumActive: Bool { panelMode == .a && memExpanded }
    private var powerEnumActive: Bool { panelMode == .a && powerExpanded }
```

with:

```swift
    private var memExpanded: Bool { expanded.contains(.mem) }
    private var powerExpanded: Bool { expanded.contains(.power) }

    // Mode C's hero card (plan: hero card expand) reuses the SAME expand mechanism —
    // resolved independently here (not passed down from `PopoverHeroView`) via the same pure
    // `resolveHero`, the same `heroMetric`/`cardOrder` AppStorage, and the same `visibleCards`
    // this view already computes. `nil` outside mode C, so the `hero == <card>` checks below
    // are inherently panelMode-gated without repeating `panelMode == .c` in each one.
    private var hero: CardKind? {
        panelMode == .c ? CardPresentation.resolveHero(persisted: heroMetric, visible: visibleCards) : nil
    }

    // Per-process enumeration is only meaningful in mode A's stack rows OR mode C's hero card
    // (the only two layouts with an expand region — mode B never shows one). Gating on the
    // mode too means switching away mid-session — while the mem/power card is expanded — turns
    // the sweep off, instead of leaking it into a layout that never shows the Top-3 (review row
    // 6). Composite so the `.task` re-fires on switch.
    private var memEnumActive: Bool { memExpanded && (panelMode == .a || hero == .mem) }
    private var powerEnumActive: Bool { powerExpanded && (panelMode == .a || hero == .power) }
```

- [ ] **Step 3: Build and run the full test suite**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 4: Manual on-device check**

Run: `open <DerivedData>/Build/Products/Debug/Wattly.app --args -WattlyScenario laptop` (substitute the actual DerivedData path from Step 3's build output)

In 설정 → 패널 레이아웃, switch to C. Promote 메모리 to hero, tap it to expand: confirm the Top-3 memory processes populate within ~1s (no longer stuck on "프로세스를 읽을 수 없음"). Collapse it, promote 프로세서 전력 to hero, tap it to expand: confirm it shows "측정 중…" briefly then populates a Top-3 (the power counter needs one baseline sweep, same as mode A). Collapse and switch to mode A (스택 행): expand 메모리/프로세서 전력 there too and confirm both still populate normally (no regression to the existing mode-A path). Switch to mode B (그리드): confirm no CPU spike from either sweep (neither mode B nor an unexpanded mode-C hero should trigger enumeration).

- [ ] **Step 5: Commit**

```bash
git add Wattly/Views/PopoverContentView.swift
git commit -m "fix(popover): gate mem/power process enumeration to hero card expand too"
```
