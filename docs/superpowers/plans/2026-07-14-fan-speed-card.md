# Fan Speed Card (Phase A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only "팬 속도" (fan speed, RPM) card as Wattly's 8th metric card, auto-hidden on fanless Macs (Apple Silicon MacBook Air).

**Architecture:** Reuse the temperature card's seam exactly — a pure core (`Fan.swift`), an actor `FanProvider` behind a `FanTransport` protocol (live impl over the existing read-only `SMCConnection`), and a new `CardKind.fan` / `ProviderKind.fan` / `MetricSample.fan` case threaded through the existing pure presentation/gating machinery. Fanless detection mirrors the desktop-battery `.notPresent` path, which already hides a card generically. No SMC writes, no entitlements, no privileged helper — those belong to the separate Phase B-1 (curve model/preview) and Phase B-2 (daemon + writes) plans.

**Tech Stack:** Swift 6, SwiftUI, `@Observable`, IOKit/`AppleSMC` (read-only), Swift Testing (`import Testing`, `@Test`, `#expect`).

## Global Constraints

- **Swift 6 strict concurrency.** Providers are `Sendable`; the one holding IOKit state is an `actor`; live transports that hold a C handle are `final class … @unchecked Sendable` touched only inside the actor. Only `MetricSample`-bearing values cross the actor boundary.
- **Pure core, tested without hardware.** All arithmetic/aggregation lives in pure free functions (no IOKit) — mirror `Temperature.swift`. The provider's connection/backoff/partial-failure logic is tested by injecting a fake transport.
- **Korean UI copy**, matching existing cards (label "팬 속도", unit "RPM", fanless copy "팬 없음 — 팬리스 Mac" paralleling battery's "배터리 없음 — 데스크톱 Mac").
- **Read-only SMC only** in Phase A. `SMCConnection` exposes only `cmdRead`/`cmdKeyInfo`; do not add a write path in this plan.
- **Test framework is Swift Testing** (`import Testing`), not XCTest. New test files live in `WattlyTests/`.
- **Follow the established seam pattern.** `TemperatureProvider` + `SMCTemperatureTransport` + `Temperature.swift` + `FakeTempTransport` are the templates; keep names and structure parallel.
- **Frequent commits.** One commit per task step group as shown.

---

## File Structure

**New files:**
- `Wattly/Core/Fan.swift` — pure fan helpers (`averageRPM`) + the `FanReading` / `FanSample` value types. No IOKit.
- `Wattly/Providers/FanProvider.swift` — `actor FanProvider`, the `FanTransport` protocol + `RawFan`, the live `SMCFanTransport`, and the DEBUG `FanProbe`.
- `WattlyTests/FanTests.swift` — pure-helper tests.
- `WattlyTests/FanProviderTests.swift` — provider tests via a `FakeFanTransport`.

**Modified files (each a single, compiler-forced or wiring edit):**
- `Wattly/Models/MetricSample.swift` — add `case fan(FanSample)`.
- `Wattly/Models/CardKind.swift` — add `CardKind.fan` (+ `provider`, `isExpandable`) and `ProviderKind.fan`.
- `Wattly/Core/CardPresentation.swift` — `label`/`unitText`/`valueText`/`subText` fan cases + `fanBarFraction`.
- `Wattly/Core/SystemMonitor.swift` — `scalar(of:from:)` fan case.
- `Wattly/Core/MenuBarText.swift` — `order` + `longLabel` + `part` fan cases.
- `Wattly/Core/Accessibility.swift` — `headPhrase` fan case.
- `Wattly/Core/PollPolicy.swift` — add `.fan` to the panel-open interval dict.
- `Wattly/Providers/FakeProvider.swift` — `makeSample`/`bases` fan cases + wire real `FanProvider` into `FakeProviders.all`.
- `Wattly/Settings/Settings.swift` — `Defaults.show`/`menuMetrics`/`cardOrder` fan entries + `CardOrder` migration to append newly-added cards.
- `Wattly/Views/PollPolicyBridge.swift` — `show`/`menu` `@AppStorage` + set-insert branches for fan.
- `Wattly/Views/PopoverContentView.swift` — `show.fan` `@AppStorage` + `isShown` fan case.
- `Wattly/Views/SettingsView.swift` — `show.fan`/`menu.fan` `@AppStorage` + a toggle row + a menubar chip + `isShown` fan case.
- `Wattly/Views/MenuBarLabel.swift` — `menu.fan` `@AppStorage` + `selected` insert branch.
- `Wattly/Views/MetricCardView.swift` — `expandRegion` fan branch + `fanExpand`/`fanRow`.
- `WattlyTests/CardPresentationTests.swift` — update the structural-flags assertions + add coverage tests.
- `WattlyTests/PollPolicyTests.swift` — add a "panel-open schedules every provider" coverage test AND update `autoPolicyBudgetsProvidersByVisibility`'s panel-open expectation to include `.fan`.
- `WattlyTests/CardReorderTests.swift` — add a `CardOrder` migration test AND fix the exact-literal assertions the 8-card default + migration change (the six drag tests append `.fan`; `rawValueRoundTrips` round-trips a full permutation).

**Build/verify commands** (used throughout):
- Build + test: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | xcbeautify` (or without `| xcbeautify` if unavailable).
- Single test (Swift Testing): filter with `-only-testing:WattlyTests/<TypeName>`.

> **Note on ordering:** `.fan` is appended LAST in both `CardKind` and `ProviderKind`, so `CardKind.allCases`-ordered filters put fan at the end (this is what the updated structural-flags assertions expect).

---

### Task 1: Pure fan core + sample type

Adds the value types and pure helpers. Adding `MetricSample.fan` forces the one exhaustive-over-`MetricSample` switch (`CardPresentation.subText`) to gain a fan case — folded in here so the project compiles.

**Files:**
- Create: `Wattly/Core/Fan.swift`
- Create: `WattlyTests/FanTests.swift`
- Modify: `Wattly/Models/MetricSample.swift` (add enum case)
- Modify: `Wattly/Core/CardPresentation.swift` (subText fan case + `fanBarFraction`)

**Interfaces:**
- Produces:
  - `struct FanReading: Sendable, Equatable, Identifiable { var index: Int; var actualRPM: Double; var minRPM: Double; var maxRPM: Double; var targetRPM: Double; var id: Int { index } }`
  - `struct FanSample: Sendable, Equatable { var fans: [FanReading] }`
  - `MetricSample.fan(FanSample)`
  - `func averageRPM(_ fans: [FanReading]) -> Double?`
  - `CardPresentation.fanBarFraction(actual: Double, max: Double) -> Double`

- [ ] **Step 1: Write the failing pure-helper test**

Create `WattlyTests/FanTests.swift`:

```swift
import Testing
import Foundation
@testable import Wattly

/// Phase A — fan speed. Pure helpers tested directly (no hardware); the provider's
/// connection / fanless / backoff machine is tested with a fake transport in
/// `FanProviderTests`.
struct FanTests {

    @Test func averageRPMEmptyIsNil() {
        #expect(averageRPM([]) == nil)
    }

    @Test func averageRPMMeanAcrossFans() {
        let fans = [
            FanReading(index: 0, actualRPM: 3000, minRPM: 1200, maxRPM: 6000, targetRPM: 3200),
            FanReading(index: 1, actualRPM: 5000, minRPM: 1200, maxRPM: 6000, targetRPM: 5200),
        ]
        #expect(averageRPM(fans) == 4000)   // (3000 + 5000) / 2
    }

    @Test func fanBarFractionScalesAndClamps() {
        #expect(CardPresentation.fanBarFraction(actual: 2000, max: 4000) == 0.5)
        #expect(CardPresentation.fanBarFraction(actual: 9000, max: 4000) == 1.0)   // clamp high
        #expect(CardPresentation.fanBarFraction(actual: -100, max: 4000) == 0.0)   // clamp low
        #expect(CardPresentation.fanBarFraction(actual: 2000, max: 0) == 0.0)      // no max → 0
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/FanTests test 2>&1 | xcbeautify`
Expected: FAIL to compile — `FanReading`, `FanSample`, `averageRPM`, `CardPresentation.fanBarFraction` do not exist.

- [ ] **Step 3: Add the pure core file**

Create `Wattly/Core/Fan.swift`:

```swift
import Foundation

/// Pure fan helpers (Phase A — fan speed). `FanProvider` does the SMC I/O and hands these
/// decoded numbers; no IOKit here, so the aggregation is tested in one place (mirrors
/// `Temperature.swift` / `PowerEnergy`). Fan RPM keys (`FNum`, `F{n}Ac/Mn/Mx/Tg`) are
/// standard SMC keys, so — unlike temperature's die sensors — there is no per-chip verified
/// profile: the provider probes `FNum` at runtime and reads whatever fans exist.

/// One physical fan's live reading (RPM). `index` is the SMC fan index (0-based); the card
/// labels it "팬 \(index + 1)". Identifiable by index for stable SwiftUI diffing.
struct FanReading: Sendable, Equatable, Identifiable {
    var index: Int
    var actualRPM: Double
    var minRPM: Double
    var maxRPM: Double
    var targetRPM: Double
    var id: Int { index }
}

/// One snapshot carries every fan's reading. Empty only transiently — the provider returns
/// `.notPresent` (fanless) or `.channelUnreadable` (stale) rather than an empty sample.
struct FanSample: Sendable, Equatable {
    var fans: [FanReading]
}

/// The card headline — the mean actual RPM across all fans (per-fan detail lives in the
/// expand). `nil` for an empty list, so callers show "—". Mirrors temperature's
/// average-across-sensors headline.
func averageRPM(_ fans: [FanReading]) -> Double? {
    guard !fans.isEmpty else { return nil }
    return fans.map(\.actualRPM).reduce(0, +) / Double(fans.count)
}
```

- [ ] **Step 4: Add the `MetricSample` case**

In `Wattly/Models/MetricSample.swift`, add the case to the enum (after `.temperature`):

```swift
enum MetricSample: Sendable, Equatable {
    case cpu(CPUSample)
    case memory(MemorySample)
    case power(PowerSample)
    case battery(BatterySample)
    case temperature(TemperatureSnapshot)
    case fan(FanSample)
}
```

- [ ] **Step 5: Add the `subText` fan case + `fanBarFraction`**

In `Wattly/Core/CardPresentation.swift`, add a `.fan` case to the `subText(_:)` switch (which is exhaustive over `MetricSample`), just before `case .temperature:`:

```swift
        case .fan(let s):
            guard let avgTarget = averageRPM(s.fans.map { FanReading(index: $0.index, actualRPM: $0.targetRPM, minRPM: 0, maxRPM: 0, targetRPM: 0) }),
                  let maxMax = s.fans.map(\.maxRPM).max() else { return nil }
            return "목표 \(Int(avgTarget.rounded())) RPM · 최대 \(Int(maxMax.rounded())) RPM"
        case .temperature:
            return nil
```

Then add the bar-fraction helper next to `tempBarFraction` in the same file:

```swift
    /// Fan bar fill fraction = actual / max, clamped to 0…1 (the fan expand's per-fan bar).
    /// `0` when `max` is non-positive (unreadable), so the row still renders a flat track.
    static func fanBarFraction(actual: Double, max: Double) -> Double {
        guard max > 0 else { return 0 }
        return min(1, Swift.max(0, actual / max))
    }
```

- [ ] **Step 6: Run the pure tests to verify they pass**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/FanTests test 2>&1 | xcbeautify`
Expected: PASS (3 tests).

- [ ] **Step 7: Commit**

```bash
git add Wattly/Core/Fan.swift Wattly/Models/MetricSample.swift Wattly/Core/CardPresentation.swift WattlyTests/FanTests.swift
git commit -m "feat(fan): add pure fan core + FanSample metric case"
```

---

### Task 2: Wire `CardKind.fan` / `ProviderKind.fan` through presentation

Adding the two enum cases forces every exhaustive switch over `CardKind` (`label`, `unitText`, `CardKind.provider`, `MenuBarText.longLabel`, `Accessibility.headPhrase`, `PopoverContentView.isShown`, `SettingsView.isShown`) and over `ProviderKind` (`FakeProvider.makeSample`, `FakeProvider.bases`) to gain a fan case, or the project won't compile. This task lands every presentation-layer edit + its tests. (The two view `isShown` switches are edited in Task 4 alongside their `@AppStorage` properties; here we take the pure/model switches. **Because `isShown` won't compile until Task 4, keep Task 2 and Task 4 in one working session — or temporarily add `case .fan: false` to both `isShown` switches now and replace it in Task 4.** The steps below add the temporary lines so Task 2 compiles standalone.)

**Files:**
- Modify: `Wattly/Models/CardKind.swift` (CardKind.fan + provider + isExpandable; ProviderKind.fan)
- Modify: `Wattly/Core/CardPresentation.swift` (label/unitText/valueText)
- Modify: `Wattly/Core/SystemMonitor.swift` (scalar)
- Modify: `Wattly/Core/MenuBarText.swift` (order/longLabel/part)
- Modify: `Wattly/Core/Accessibility.swift` (headPhrase)
- Modify: `Wattly/Providers/FakeProvider.swift` (makeSample/bases)
- Modify: `Wattly/Views/PopoverContentView.swift` (isShown temp line)
- Modify: `Wattly/Views/SettingsView.swift` (isShown temp line)
- Modify: `WattlyTests/CardPresentationTests.swift` (structural flags + coverage)

**Interfaces:**
- Consumes: `FanReading`, `FanSample`, `MetricSample.fan`, `averageRPM` (Task 1).
- Produces:
  - `CardKind.fan` with `provider == .fan`, `isExpandable == true`, `hasSparkArea == true`, `isAccented == false`, `isSmoothable == false`.
  - `ProviderKind.fan`.
  - `CardPresentation.label(.fan) == "팬 속도"`, `unitText(.fan, _) == "RPM"`, `valueText(.fan, .value(.fan(s)))` = rounded `averageRPM` string.
  - `SystemMonitor.scalar(of: .fan, from: .fan(s))` = `averageRPM(s.fans)`.
  - `MenuBarText.part(.fan, …)` = `"팬 <rpm> RPM"`; `.fan` in `MenuBarText.order`.

- [ ] **Step 1: Write the failing presentation + coverage tests**

In `WattlyTests/CardPresentationTests.swift`, replace the `cardKindStructuralFlags()` body assertions to include fan and add new tests. First update the existing test:

```swift
    @Test func cardKindStructuralFlags() {
        #expect(CardKind.allCases.filter(\.isExpandable) == [.power, .cpu, .mem, .cpuTemp, .fan])
        #expect(CardKind.allCases.filter(\.hasSparkArea) == [.power, .cpu, .mem, .cpuTemp, .gpuTemp, .batTemp, .fan])
        #expect(CardKind.allCases.filter(\.isAccented) == [.power])
    }
```

Then add, inside the same `struct` (after `cardKindStructuralFlags`):

```swift
    // MARK: Fan presentation

    @Test func fanLabelUnitAndValue() {
        let state = MetricState.value(.fan(FanSample(fans: [
            FanReading(index: 0, actualRPM: 2000, minRPM: 0, maxRPM: 4000, targetRPM: 2200),
            FanReading(index: 1, actualRPM: 4000, minRPM: 0, maxRPM: 4000, targetRPM: 4200),
        ])))
        #expect(CardPresentation.label(.fan) == "팬 속도")
        #expect(CardPresentation.unitText(.fan, state) == "RPM")
        #expect(CardPresentation.valueText(.fan, state) == "3000")   // (2000 + 4000) / 2, integer
    }

    @Test func fanValueTextNoReadingIsDash() {
        #expect(CardPresentation.valueText(.fan, .value(.fan(FanSample(fans: [])))) == "—")
        #expect(CardPresentation.valueText(.fan, .loading) == "—")
    }

    @Test func fanHasNoThresholdColor() {
        let state = MetricState.value(.fan(FanSample(fans: [
            FanReading(index: 0, actualRPM: 9000, minRPM: 0, maxRPM: 9000, targetRPM: 9000)])))
        #expect(CardPresentation.thresholdLevel(.fan, state, Defaults.thresholds) == nil)
    }

    // MARK: Coverage — every CardKind must format a value, plot a scalar, and (if menubar-
    // eligible) format a menubar part. Guards the default-guarded tuple switches that would
    // otherwise silently show "—" for a forgotten new card.

    private func representativeState(_ card: CardKind) -> MetricState {
        switch card {
        case .power:   return .value(.power(PowerSample(totalW: 8, cpuW: 3, gpuW: 2, npuW: 0.1)))
        case .battery: return .value(.battery(BatterySample(netW: 5, milliamps: 400, volts: 12,
                                                            charging: false, externalConnected: false)))
        case .cpu:     return .value(.cpu(CPUSample(overall: 42, perfLevels: [])))
        case .mem:     return .value(.memory(MemorySample(usedGB: 8, totalGB: 16, wiredGB: 2, compressedGB: 1)))
        case .cpuTemp, .gpuTemp, .batTemp:
            return .value(.temperature(TemperatureSnapshot(
                cpu: .reading(TemperatureReading(celsius: 50)),
                gpu: .reading(TemperatureReading(celsius: 45)),
                battery: .reading(TemperatureReading(celsius: 30)))))
        case .fan:     return .value(.fan(FanSample(fans: [
                            FanReading(index: 0, actualRPM: 2000, minRPM: 0, maxRPM: 4000, targetRPM: 2200)])))
        }
    }

    @Test func everyCardFormatsAValue() {
        for card in CardKind.allCases {
            #expect(CardPresentation.valueText(card, representativeState(card)) != "—",
                    "\(card) valueText fell through to —")
        }
    }

    @Test func everyCardHasASparklineScalar() {
        for card in CardKind.allCases {
            guard case .value(let s) = representativeState(card) else { continue }
            #expect(SystemMonitor.scalar(of: card, from: s) != nil, "\(card) has no scalar")
        }
    }

    @Test func everyMenubarMetricFormatsValue() {
        for card in MenuBarText.order {
            let part = MenuBarText.part(card, representativeState(card))
            #expect(!part.hasSuffix("—"), "\(card) menubar part fell through to placeholder")
        }
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/CardPresentationTests test 2>&1 | xcbeautify`
Expected: FAIL to compile — `CardKind.fan` / `ProviderKind.fan` don't exist and switches are non-exhaustive.

- [ ] **Step 3: Add the enum cases in `CardKind.swift`**

In `Wattly/Models/CardKind.swift`:

Change the case list (add `fan`):
```swift
    case power, battery, cpu, mem, cpuTemp, gpuTemp, batTemp, fan
```

Add the provider mapping (in the `provider` switch, after `.cpuTemp, .gpuTemp, .batTemp`):
```swift
        case .fan: .fan
```

Extend `isExpandable`:
```swift
    var isExpandable: Bool { self == .power || self == .cpu || self == .mem || self == .cpuTemp || self == .fan }
```

Add the provider case (add `fan` to `ProviderKind`):
```swift
enum ProviderKind: String, CaseIterable, Sendable, Hashable {
    case cpu, memory, power, battery, temperature, fan
}
```

(`hasSparkArea` = `self != .battery` and `isSmoothable` = power/battery already give fan the right values — no edit.)

- [ ] **Step 4: Add `label` / `unitText` / `valueText` fan cases in `CardPresentation.swift`**

`label(_:)` — add before the closing brace of the switch:
```swift
        case .fan: "팬 속도"
```

`unitText(_:_:)` — add a fan case (fan shares the static-unit shape):
```swift
        case .fan: return "RPM"
```
Place it by changing the temperature arm to:
```swift
        case .cpuTemp, .gpuTemp, .batTemp: return "°C"
        case .fan: return "RPM"
```

`valueText(_:_:)` — add a fan case to the `(card, sample)` switch, before `default:`:
```swift
        case (.fan, .fan(let s)):
            return averageRPM(s.fans).map { String(Int($0.rounded())) } ?? "—"
```

- [ ] **Step 5: Add `scalar` fan case in `SystemMonitor.swift`**

In `static func scalar(of:from:)`, add before `default: return nil`:
```swift
        case (.fan, .fan(let s)): return averageRPM(s.fans)
```

- [ ] **Step 6: Add `MenuBarText` fan cases**

In `Wattly/Core/MenuBarText.swift`:

`order` — append `.fan`:
```swift
    static let order: [CardKind] = [.cpu, .power, .mem, .cpuTemp, .gpuTemp, .batTemp, .fan]
```

`part(_:_:)` — add to the `(card, sample)` switch before `default:`:
```swift
        case (.fan, .fan(let s)):
            return averageRPM(s.fans).map { "팬 \(Int($0.rounded())) RPM" } ?? "\(longLabel(card)) —"
```

`longLabel(_:)` — add a fan case (this switch is exhaustive over `CardKind`):
```swift
        case .fan: "팬"
```

- [ ] **Step 7: Add `Accessibility.headPhrase` fan case**

In `Wattly/Core/Accessibility.swift`, `headPhrase(_:_:)` switch (exhaustive over `CardKind`), change the temperature arm block to add fan:
```swift
        case .cpuTemp, .gpuTemp, .batTemp: return "\(v)°C"
        case .fan: return "\(v) RPM"
```

- [ ] **Step 8: Add `FakeProvider` fan cases (compiler-forced by `ProviderKind.fan`)**

In `Wattly/Providers/FakeProvider.swift`:

`makeSample()` switch — add a `.fan` case (synthetic, used only if the real `FanProvider` isn't wired for a scenario; harmless demo data):
```swift
        case .fan:
            let base = 2200.0
            return .fan(FanSample(fans: [
                FanReading(index: 0, actualRPM: v("fan"), minRPM: 1200, maxRPM: 6000, targetRPM: base),
            ]))
```

`bases(kind:scenario:)` switch — add a `.fan` case:
```swift
        case .fan:
            return ["fan": Base(b: 2400, step: 180, min: 1200, max: 6000)]
```

- [ ] **Step 9: Add temporary `isShown` fan cases in the two view switches (replaced in Task 4)**

In `Wattly/Views/PopoverContentView.swift`, `isShown(_:)` — add:
```swift
        case .fan: false   // TEMP: replaced by `showFan` in Task 4
```

In `Wattly/Views/SettingsView.swift`, `isShown(_:)` — add the same:
```swift
        case .fan: false   // TEMP: replaced by `showFan` in Task 4
```

- [ ] **Step 10: Run the presentation + coverage tests to verify they pass**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/CardPresentationTests test 2>&1 | xcbeautify`
Expected: PASS (existing tests + `fanLabelUnitAndValue`, `fanValueTextNoReadingIsDash`, `fanHasNoThresholdColor`, `everyCardFormatsAValue`, `everyCardHasASparklineScalar`, `everyMenubarMetricFormatsValue`).

- [ ] **Step 11: Commit**

```bash
git add Wattly/Models/CardKind.swift Wattly/Core/CardPresentation.swift Wattly/Core/SystemMonitor.swift Wattly/Core/MenuBarText.swift Wattly/Core/Accessibility.swift Wattly/Providers/FakeProvider.swift Wattly/Views/PopoverContentView.swift Wattly/Views/SettingsView.swift WattlyTests/CardPresentationTests.swift
git commit -m "feat(fan): thread CardKind.fan/ProviderKind.fan through presentation"
```

---

### Task 3: Real `FanProvider` + transport + probe

The actor that reads fans off the SMC, with fanless detection and the same connection/backoff lifecycle as `TemperatureProvider`. Tested with a `FakeFanTransport` (no hardware). Then swap the real provider into the app's provider list.

**Files:**
- Create: `Wattly/Providers/FanProvider.swift`
- Create: `WattlyTests/FanProviderTests.swift`
- Modify: `Wattly/Providers/FakeProvider.swift` (`FakeProviders.all` — wire real `FanProvider`)

**Interfaces:**
- Consumes: `FanReading`, `FanSample`, `MetricSample.fan`, `ProviderKind.fan`, `reconnectBackoffSeconds` (existing, in `Temperature.swift`), `SMCConnection`, `smcDouble`.
- Produces:
  - `protocol FanTransport: Sendable { func open() -> Bool; func fanCount() -> Int?; func readFan(_ index: Int) -> RawFan?; func close() }`
  - `struct RawFan: Sendable, Equatable { var actual: Double; var min: Double; var max: Double; var target: Double }`
  - `actor FanProvider: MetricProvider` (`kind == .fan`), `init(transport: any FanTransport = SMCFanTransport())`.
  - `final class SMCFanTransport: FanTransport, @unchecked Sendable`.
  - Fanless → `.unavailable(.notPresent("팬 없음 — 팬리스 Mac"))`; stale/failed → `.unavailable(.channelUnreadable("팬 센서에 연결할 수 없음 — 재시도 중"))`.

- [ ] **Step 1: Write the failing provider tests**

Create `WattlyTests/FanProviderTests.swift`:

```swift
import Testing
import Foundation
@testable import Wattly

/// Phase A — fan provider. The connection / fanless / backoff / partial-failure machine
/// is tested by injecting a fake transport with hand-advanced instants (no hardware). The
/// fake counts I/O so we can assert a fanless/terminal state does ZERO further SMC I/O.
struct FanProviderTests {

    private let base = ContinuousClock().now

    private func readReading(_ p: FanProvider, at instant: ContinuousClock.Instant) async -> ProviderReading {
        await p.read(at: instant)
    }

    @Test func readsTwoFansAndAverages() async {
        let tx = FakeFanTransport()
        tx.count = 2
        tx.fans = [0: RawFan(actual: 2000, min: 1200, max: 6000, target: 2200),
                   1: RawFan(actual: 4000, min: 1200, max: 6000, target: 4200)]
        let p = FanProvider(transport: tx)
        guard case .value(.fan(let s)) = await readReading(p, at: base) else {
            Issue.record("expected a fan sample"); return
        }
        #expect(s.fans.count == 2)
        #expect(averageRPM(s.fans) == 3000)
        #expect(tx.openCalls == 1)
    }

    @Test func fanlessIsNotPresentAndDoesNoFurtherIO() async {
        let tx = FakeFanTransport()
        tx.count = 0   // FNum == 0 → fanless (MacBook Air)
        let p = FanProvider(transport: tx)
        for i in 0..<3 {
            let r = await readReading(p, at: base.advanced(by: .seconds(Double(i * 2))))
            guard case .unavailable(.notPresent(let msg)) = r else {
                Issue.record("expected notPresent, got \(r)"); return
            }
            #expect(msg == "팬 없음 — 팬리스 Mac")
        }
        // Terminal after the first detection: FNum read once, individual fans never read.
        #expect(tx.readFanCalls == 0)
        #expect(tx.fanCountCalls == 1)
    }

    @Test func openFailureIsRetryableChannelUnreadable() async {
        let tx = FakeFanTransport(); tx.openDefault = false
        let p = FanProvider(transport: tx)
        let r = await readReading(p, at: base)
        guard case .unavailable(.channelUnreadable) = r else {
            Issue.record("expected channelUnreadable, got \(r)"); return
        }
    }

    @Test func allFansUnreadableClosesAndBacksOff() async {
        let tx = FakeFanTransport(); tx.count = 2; tx.fans = [:]   // count OK, every fan read nil
        let p = FanProvider(transport: tx)
        let r = await readReading(p, at: base)
        guard case .unavailable(.channelUnreadable) = r else {
            Issue.record("expected channelUnreadable, got \(r)"); return
        }
        #expect(tx.closeCalls == 1)   // stale connection dropped
    }

    @Test func connectionOpensOnceAcrossPolls() async {
        let tx = FakeFanTransport(); tx.count = 1
        tx.fans = [0: RawFan(actual: 2400, min: 1200, max: 6000, target: 2500)]
        let p = FanProvider(transport: tx)
        _ = await readReading(p, at: base)
        _ = await readReading(p, at: base.advanced(by: .seconds(5)))
        _ = await readReading(p, at: base.advanced(by: .seconds(10)))
        #expect(tx.openCalls == 1)
    }

    @Test func wakeResetsConnection() async {
        let tx = FakeFanTransport(); tx.count = 1
        tx.fans = [0: RawFan(actual: 2400, min: 1200, max: 6000, target: 2500)]
        let p = FanProvider(transport: tx)
        _ = await readReading(p, at: base)
        #expect(tx.openCalls == 1)
        _ = await readReading(p, at: base.advanced(by: .seconds(40)))   // dt > 30 → wake reset → reopen
        #expect(tx.openCalls == 2)
    }
}

/// In-memory `FanTransport` for tests. Lock-guarded so the test isolation and the provider
/// actor can both touch it; counts I/O so "zero further I/O" claims are assertable.
final class FakeFanTransport: FanTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _openDefault = true
    private var _count: Int? = 1
    private var _fans: [Int: RawFan] = [:]
    private(set) var openCalls = 0
    private(set) var fanCountCalls = 0
    private(set) var readFanCalls = 0
    private(set) var closeCalls = 0

    var openDefault: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _openDefault }
        set { lock.lock(); _openDefault = newValue; lock.unlock() }
    }
    var count: Int? {
        get { lock.lock(); defer { lock.unlock() }; return _count }
        set { lock.lock(); _count = newValue; lock.unlock() }
    }
    var fans: [Int: RawFan] {
        get { lock.lock(); defer { lock.unlock() }; return _fans }
        set { lock.lock(); _fans = newValue; lock.unlock() }
    }

    func open() -> Bool { lock.lock(); defer { lock.unlock() }; openCalls += 1; return _openDefault }
    func fanCount() -> Int? { lock.lock(); defer { lock.unlock() }; fanCountCalls += 1; return _count }
    func readFan(_ index: Int) -> RawFan? {
        lock.lock(); defer { lock.unlock() }; readFanCalls += 1; return _fans[index]
    }
    func close() { lock.lock(); defer { lock.unlock() }; closeCalls += 1 }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/FanProviderTests test 2>&1 | xcbeautify`
Expected: FAIL to compile — `FanProvider`, `FanTransport`, `RawFan`, `SMCFanTransport` don't exist.

- [ ] **Step 3: Add the provider file**

Create `Wattly/Providers/FanProvider.swift`:

```swift
import Foundation
import IOKit

/// What the fan provider reads through — the single read-only seam under which the real
/// SMC I/O lives (mirrors `TemperatureTransport`). The provider knows only this protocol,
/// so the connection / fanless / backoff machine is tested with a fake transport (no
/// hardware) and the `io_connect_t` never leaves the live implementation.
protocol FanTransport: Sendable {
    /// Open the SMC connection. `false` ⇒ retryable failure (→ backoff).
    func open() -> Bool
    /// `FNum` (fan count). `0` ⇒ fanless (MacBook Air). `nil` ⇒ unreadable (stale/failed).
    func fanCount() -> Int?
    /// One fan's RPM fields, or `nil` if its actual-RPM key is unreadable.
    func readFan(_ index: Int) -> RawFan?
    /// Release the SMC connection (terminal / stale-after-wake).
    func close()
}

/// One fan's raw decoded RPM fields (actual/min/max/target). `min`/`max`/`target` default
/// to 0 in the live transport when their key is absent — only `actual` gates readability.
struct RawFan: Sendable, Equatable {
    var actual: Double
    var min: Double
    var max: Double
    var target: Double
}

/// Real fan provider (Phase A) — no entitlements, read-only SMC. Fans come from the standard
/// `FNum` / `F{n}Ac|Mn|Mx|Tg` keys; unlike temperature there is no per-chip verified profile
/// (these keys are universal), so the provider probes `FNum` at runtime. `FNum == 0` is the
/// fanless (MacBook Air) path → `.notPresent`, which hides the card exactly like the desktop
/// battery. All arithmetic is in pure `Fan`; this actor only orchestrates I/O and lifecycle.
///
/// `actor` is required: `read` is awaited from the `@MainActor` `SystemMonitor`, so the
/// synchronous IOKit calls run off the main thread (like `TemperatureProvider`).
actor FanProvider: MetricProvider {
    let kind: ProviderKind = .fan

    static let fanlessMessage = "팬 없음 — 팬리스 Mac"
    static let unreadableMessage = "팬 센서에 연결할 수 없음 — 재시도 중"
    /// Plausibility band (RPM). A finite reading outside this is rejected as bogus.
    private static let rpmRange = 0.0...12000.0
    /// Elapsed beyond this ⇒ a gap (missed poll / sleep-wake) → reset backoff + reconnect
    /// (mirrors `TemperatureProvider.maxPlausibleDt`).
    private static let maxPlausibleDt = 30.0

    private let transport: any FanTransport

    private var smcOpen = false
    /// Terminal once `FNum` reads 0 — a fanless Mac never grows a fan, so we short-circuit
    /// with zero further I/O (mirrors temperature's `noVerifiedProfile` terminal).
    private var fanless = false
    private var consecutiveFailures = 0
    private var retryAt: ContinuousClock.Instant?
    private var lastInstant: ContinuousClock.Instant?

    init(transport: any FanTransport = SMCFanTransport()) {
        self.transport = transport
    }

    func read(at instant: ContinuousClock.Instant) async -> ProviderReading {
        // Sleep/wake or a long gap → the io_connect_t may be stale: reset and reconnect.
        if let last = lastInstant, Self.seconds(from: last, to: instant) > Self.maxPlausibleDt {
            resetConnection()
        }
        defer { lastInstant = instant }

        if fanless { return .unavailable(.notPresent(Self.fanlessMessage)) }   // terminal, zero I/O

        if !smcOpen {
            if let retryAt, instant < retryAt {
                return .unavailable(.channelUnreadable(Self.unreadableMessage))  // in backoff window
            }
            if transport.open() {
                smcOpen = true
                consecutiveFailures = 0
                retryAt = nil
            } else {
                registerFailure(at: instant)
                return .unavailable(.channelUnreadable(Self.unreadableMessage))
            }
        }

        guard let count = transport.fanCount() else {
            transport.close(); smcOpen = false
            registerFailure(at: instant)
            return .unavailable(.channelUnreadable(Self.unreadableMessage))
        }

        if count == 0 {
            fanless = true
            transport.close(); smcOpen = false
            return .unavailable(.notPresent(Self.fanlessMessage))
        }

        var fans: [FanReading] = []
        for i in 0..<count {
            guard let raw = transport.readFan(i),
                  raw.actual.isFinite, Self.rpmRange.contains(raw.actual) else { continue }
            fans.append(FanReading(index: i, actualRPM: raw.actual,
                                   minRPM: raw.min, maxRPM: raw.max, targetRPM: raw.target))
        }

        if fans.isEmpty {
            // Count > 0 but not one fan readable ⇒ connection went stale → invalidate + back off.
            transport.close(); smcOpen = false
            registerFailure(at: instant)
            return .unavailable(.channelUnreadable(Self.unreadableMessage))
        }

        return .value(.fan(FanSample(fans: fans)))
    }

    private func registerFailure(at instant: ContinuousClock.Instant) {
        consecutiveFailures += 1
        let wait = reconnectBackoffSeconds(consecutiveFailures: consecutiveFailures)
        retryAt = instant.advanced(by: .seconds(wait))
    }

    private func resetConnection() {
        consecutiveFailures = 0
        retryAt = nil
        if smcOpen { transport.close(); smcOpen = false }
    }

    private static func seconds(from a: ContinuousClock.Instant, to b: ContinuousClock.Instant) -> Double {
        let d = a.duration(to: b)
        return Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
    }
}

// MARK: - Live transport

/// Live `FanTransport`: SMC (`SMCConnection`) for the `FNum` / `F{n}Ac|Mn|Mx|Tg` keys. Only
/// ever touched inside `FanProvider`'s actor isolation, so `@unchecked Sendable` (same basis
/// as `SMCTemperatureTransport`). Fan RPM keys are `flt ` on Apple silicon; `smcDouble`
/// decodes both `flt ` and the integer `FNum`.
final class SMCFanTransport: FanTransport, @unchecked Sendable {
    private var smc: SMCConnection?

    func open() -> Bool {
        if smc != nil { return true }
        smc = SMCConnection()
        return smc != nil
    }

    func fanCount() -> Int? {
        guard let smc, let r = smc.read("FNum") else { return nil }
        let v = smcDouble(r.bytes, type: r.type)
        return v.isFinite ? Int(v) : nil
    }

    func readFan(_ index: Int) -> RawFan? {
        guard let smc else { return nil }
        func rpm(_ suffix: String) -> Double? {
            guard let r = smc.read("F\(index)\(suffix)") else { return nil }
            let v = smcDouble(r.bytes, type: r.type)
            return v.isFinite ? v : nil
        }
        guard let actual = rpm("Ac") else { return nil }
        return RawFan(actual: actual, min: rpm("Mn") ?? 0, max: rpm("Mx") ?? 0, target: rpm("Tg") ?? 0)
    }

    func close() { smc = nil }   // SMCConnection.deinit closes the io_connect_t
}

#if DEBUG
/// DEBUG on-device verification probe (Phase A Phase-0). Run headless to dump live fan
/// readings from the REAL provider + live transport, then exit — for confirming the `FNum` /
/// `F0Ac` keys read plausible RPM on this Mac before trusting the card:
///   `Wattly.app/Contents/MacOS/Wattly -WattlyFanProbe`
/// Excluded from Release. Detached so it runs off the (blocked) main thread.
enum FanProbe {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("-WattlyFanProbe") else { return }
        let provider = FanProvider()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let clock = ContinuousClock()
            for i in 0..<3 {
                let reading = await provider.read(at: clock.now)
                print("[fan-probe] sample \(i): \(describe(reading))")
                try? await Task.sleep(for: .seconds(1))
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }

    private static func describe(_ r: ProviderReading) -> String {
        switch r {
        case .value(.fan(let s)):
            let fans = s.fans.map { "팬\($0.index) \(Int($0.actualRPM))rpm(목표 \(Int($0.targetRPM)), \(Int($0.minRPM))–\(Int($0.maxRPM)))" }
                .joined(separator: ", ")
            return "avg \(averageRPM(s.fans).map { Int($0) } ?? 0) rpm [\(fans)]"
        case .unavailable(let reason): return "unavailable(\(reason.message))"
        default: return "\(r)"
        }
    }
}
#endif
```

- [ ] **Step 4: Run the provider tests to verify they pass**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/FanProviderTests test 2>&1 | xcbeautify`
Expected: PASS (6 tests).

- [ ] **Step 5: Wire the real provider into the app**

In `Wattly/Providers/FakeProvider.swift`, `FakeProviders.all(scenario:)` — add an explicit `.fan` arm before `default:` so the app uses the real provider (not the synthetic fake):

```swift
            case .temperature where scenario != .desktop: return TemperatureProvider()
            case .fan:    return FanProvider()
            default:      return FakeProvider(kind: kind, scenario: scenario)
```

- [ ] **Step 6: Register the DEBUG probe (mirror ThermalProbe)**

In `Wattly/App/WattlyApp.swift`, inside the `#if DEBUG` block in `init()`, add after `ThermalProbe.runIfRequested()`:

```swift
        ThermalProbe.runIfRequested()  // -WattlyThermalProbe: dump live temps and exit (plan 08 Phase 0)
        FanProbe.runIfRequested()      // -WattlyFanProbe: dump live fan RPM and exit (Phase A Phase 0)
```

- [ ] **Step 7: Build to confirm the app compiles with the real provider wired**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' build 2>&1 | xcbeautify`
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add Wattly/Providers/FanProvider.swift Wattly/Providers/FakeProvider.swift Wattly/App/WattlyApp.swift WattlyTests/FanProviderTests.swift
git commit -m "feat(fan): add FanProvider + SMC transport + wire into app"
```

---

### Task 4: Persistence, view wiring, poll cadence, expand region, order migration

Makes the fan card actually appear, toggle, schedule, and expand. Replaces the temporary `isShown` lines from Task 2 with real `@AppStorage`-backed flags, adds the settings toggle + menubar chip, slots the fan provider into the panel-open cadence, renders the per-fan expand, and migrates existing persisted card orders so upgraders see the new card.

**Files:**
- Modify: `Wattly/Settings/Settings.swift` (Defaults + `CardOrder` migration)
- Modify: `Wattly/Views/PollPolicyBridge.swift`
- Modify: `Wattly/Views/PopoverContentView.swift`
- Modify: `Wattly/Views/SettingsView.swift`
- Modify: `Wattly/Views/MenuBarLabel.swift`
- Modify: `Wattly/Core/PollPolicy.swift`
- Modify: `Wattly/Views/MetricCardView.swift`
- Modify: `WattlyTests/CardReorderTests.swift`
- Modify: `WattlyTests/PollPolicyTests.swift`

**Interfaces:**
- Consumes: `CardKind.fan`, `ProviderKind.fan`, `FanSample`, `CardPresentation.fanBarFraction`, `averageRPM`.
- Produces:
  - `Defaults.show[.fan] == true`, `Defaults.menuMetrics[.fan] == false`, `.fan` last in `Defaults.cardOrder`.
  - `CardOrder(rawValue:)` appends any `CardKind.allCases` missing from the persisted CSV.
  - `providerIntervals(…, panelVisible: true, …)[.fan] != nil`.

- [ ] **Step 1: Write the failing `CardOrder` migration + poll-coverage tests**

In `WattlyTests/CardReorderTests.swift`, add (inside the existing test `struct`):

```swift
    @Test func cardOrderAppendsNewlyAddedCards() {
        // A persisted order from before the fan card shipped (7 cards, no ".fan").
        let legacy = "power,battery,cpu,mem,cpuTemp,gpuTemp,batTemp"
        let order = CardOrder(rawValue: legacy)
        #expect(order != nil)
        #expect(order?.cards.contains(.fan) == true)               // migrated in
        #expect(Set(order?.cards ?? []) == Set(CardKind.allCases))  // every card present
        #expect(order?.cards.prefix(7).map(\.rawValue) == legacy.split(separator: ",").map(String.init))  // user order preserved, new card appended
    }

```

(Do NOT add a garbage-rejection test — the existing `emptyStringIsRejected` and `unknownTokenIsRejected` in this file already cover it, and the migration line runs only after their `guard`, so they still pass.)

In `WattlyTests/PollPolicyTests.swift`, add:

```swift
    @Test func panelOpenSchedulesEveryProvider() {
        let ivals = providerIntervals(mode: .eco, setting: .auto, panelVisible: true,
                                      menubarTextEnabled: true,
                                      active: Set(ProviderKind.allCases), menubarNeeds: [])
        for kind in ProviderKind.allCases {
            #expect(ivals[kind] != nil, "\(kind) missing from the panel-open schedule")
        }
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/CardReorderTests -only-testing:WattlyTests/PollPolicyTests test 2>&1 | xcbeautify`
Expected: FAIL — `cardOrderAppendsNewlyAddedCards` fails (`.fan` not appended) and `panelOpenSchedulesEveryProvider` fails (`.fan` absent from the `open` dict).

- [ ] **Step 3: Add the `CardOrder` migration + Defaults**

In `Wattly/Settings/Settings.swift`:

`CardOrder.init?(rawValue:)` — append missing cards:
```swift
    init?(rawValue: String) {
        let parts = rawValue.split(separator: ",").map(String.init)
        let parsed = parts.compactMap { CardKind(rawValue: $0) }
        guard parsed.count == parts.count, !parsed.isEmpty else { return nil }
        // Migration: append any card kinds added after this order was persisted (e.g. the fan
        // card), so upgraders see new cards at the end instead of never (visibility is still
        // governed by the per-card show flags). Preserves the user's existing relative order.
        let missing = CardKind.allCases.filter { !parsed.contains($0) }
        self.init(parsed + missing)
    }
```

`Defaults.show` — add `.fan: true`:
```swift
    static let show: [CardKind: Bool] = [
        .power: true, .battery: true, .cpu: true, .mem: true,
        .cpuTemp: true, .gpuTemp: true, .batTemp: true, .fan: true,
    ]
```

`Defaults.menuMetrics` — add `.fan: false`:
```swift
    static let menuMetrics: [CardKind: Bool] = [
        .cpu: true, .power: false, .mem: false,
        .cpuTemp: false, .gpuTemp: false, .batTemp: false, .fan: false,
    ]
```

`Defaults.cardOrder` — append `.fan`:
```swift
    static let cardOrder = CardOrder([.power, .battery, .cpu, .mem, .cpuTemp, .gpuTemp, .batTemp, .fan])
```

**Then fix the pre-existing `CardReorderTests` that this change breaks.** Six drag tests use `private let order = Defaults.cardOrder` (now 8 cards) and assert exact 7-element arrays; `.fan` is appended last and is never the drag source/target, so it carries through as a trailing element — append `.fan` to each expectation. In `WattlyTests/CardReorderTests.swift`:

```swift
    @Test func dragDownLandsAfterTarget() {
        let r = order.reordering(.power, onto: .cpu)
        #expect(r.cards == [.battery, .cpu, .power, .mem, .cpuTemp, .gpuTemp, .batTemp, .fan])
    }

    @Test func dragDownAdjacentSwaps() {
        let r = order.reordering(.power, onto: .battery)
        #expect(r.cards == [.battery, .power, .cpu, .mem, .cpuTemp, .gpuTemp, .batTemp, .fan])
    }

    @Test func dragFirstToLast() {
        let r = order.reordering(.power, onto: .batTemp)
        #expect(r.cards == [.battery, .cpu, .mem, .cpuTemp, .gpuTemp, .batTemp, .power, .fan])
    }

    @Test func dragUpLandsBeforeTarget() {
        let r = order.reordering(.batTemp, onto: .cpu)
        #expect(r.cards == [.power, .battery, .batTemp, .cpu, .mem, .cpuTemp, .gpuTemp, .fan])
    }

    @Test func dragUpAdjacentSwaps() {
        let r = order.reordering(.mem, onto: .cpu)
        #expect(r.cards == [.power, .battery, .mem, .cpu, .cpuTemp, .gpuTemp, .batTemp, .fan])
    }

    @Test func dragLastToFirst() {
        let r = order.reordering(.batTemp, onto: .power)
        #expect(r.cards == [.batTemp, .power, .battery, .cpu, .mem, .cpuTemp, .gpuTemp, .fan])
    }
```

Also fix `rawValueRoundTrips`: it round-trips a PARTIAL 3-card order, which the migration now expands to a full 8-card order (so the old exact equality no longer holds). Round-trip a FULL permutation instead — that has no missing cards to append, so it genuinely round-trips:

```swift
    @Test func rawValueRoundTrips() {
        let o = CardOrder(CardKind.allCases.reversed())   // a full permutation — nothing to migrate
        #expect(CardOrder(rawValue: o.rawValue)?.cards == o.cards)
    }
```

(`defaultsRoundTrip`, `sameCardIsNoOp`, `reorderIsAPermutation`, `reorderKeepsOtherCardsRelativeOrder`, `emptyStringIsRejected`, `unknownTokenIsRejected` all still hold as written: the first four compare against `order.cards`/`custom` which are already the migrated/array-built values, and the array `init(_:)` does NOT migrate — only `init?(rawValue:)` does.)

- [ ] **Step 4: Add `.fan` to the panel-open poll cadence**

In `Wattly/Core/PollPolicy.swift`, the `open` dict inside `providerIntervals` — add `.fan` (fan changes slowly, so 5 s like memory/battery):
```swift
        let open: [ProviderKind: Duration] = [
            .cpu: .seconds(1), .power: .seconds(1), .temperature: .seconds(2),
            .memory: .seconds(5), .battery: .seconds(5), .fan: .seconds(5),
        ]
```

**Then fix the pre-existing `autoPolicyBudgetsProvidersByVisibility` test this change breaks.** Its first assertion (`panelVisible: true`, `active: Set(ProviderKind.allCases)`) now includes `.fan` in the result. In `WattlyTests/PollPolicyTests.swift`, update that first expected literal (leave the two `panelVisible: false` assertions unchanged — their `menubarNeeds: [.cpu]` doesn't include fan):

```swift
        #expect(providerIntervals(mode: .eco, setting: .auto, panelVisible: true,
                                  menubarTextEnabled: true, active: all,
                                  menubarNeeds: [.cpu]) == [
            .cpu: .seconds(1), .power: .seconds(1), .temperature: .seconds(2),
            .memory: .seconds(5), .battery: .seconds(5), .fan: .seconds(5),
        ])
```

- [ ] **Step 5: Run the affected test files to verify they pass**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -only-testing:WattlyTests/CardReorderTests -only-testing:WattlyTests/PollPolicyTests test 2>&1 | xcbeautify`
Expected: PASS — both the new tests (`cardOrderAppendsNewlyAddedCards`, `panelOpenSchedulesEveryProvider`) AND the fixed pre-existing tests (the six drag tests, `rawValueRoundTrips`, `autoPolicyBudgetsProvidersByVisibility`).

- [ ] **Step 6: Replace the temporary `isShown` lines + add `show.fan` (PopoverContentView)**

In `Wattly/Views/PopoverContentView.swift`:

Add the `@AppStorage` property after `showBatTemp`:
```swift
    @AppStorage(StorageKey.show(.fan))     private var showFan     = Defaults.show[.fan]     ?? true
```

Replace the temporary `isShown` fan line with the real one:
```swift
        case .fan: showFan
```

- [ ] **Step 7: Wire `show.fan` + `menu.fan` into `PollPolicyBridge`**

In `Wattly/Views/PollPolicyBridge.swift`:

Add after `showBatTemp`:
```swift
    @AppStorage(StorageKey.show(.fan))     private var showFan     = Defaults.show[.fan]     ?? true
```
Add after `menuBatTemp`:
```swift
    @AppStorage(StorageKey.menu(.fan))     private var menuFan     = Defaults.menuMetrics[.fan]     ?? false
```
In `shownCards`, add before `return s`:
```swift
        if showFan     { s.insert(.fan) }
```
In `menubarMetrics`, add before `return s`:
```swift
        if menuFan     { s.insert(.fan) }
```

- [ ] **Step 8: Wire `menu.fan` into `MenuBarLabel`**

In `Wattly/Views/MenuBarLabel.swift`:

Add after `menuBatTemp`:
```swift
    @AppStorage(StorageKey.menu(.fan))     private var menuFan     = Defaults.menuMetrics[.fan]     ?? false
```
In `selected`, add before `return s`:
```swift
        if menuFan     { s.insert(.fan) }
```

- [ ] **Step 9: Add the settings toggle + menubar chip + `show.fan`/`menu.fan` (SettingsView)**

In `Wattly/Views/SettingsView.swift`:

Add after `showBatTemp`:
```swift
    @AppStorage(StorageKey.show(.fan))     private var showFan     = Defaults.show[.fan]     ?? true
```
Add after `menuBatTemp`:
```swift
    @AppStorage(StorageKey.menu(.fan))     private var menuFan     = Defaults.menuMetrics[.fan]     ?? false
```
Replace the temporary `isShown` fan line with:
```swift
        case .fan: showFan
```
In `showSection`, change the last row's `divider` to `true` and add the fan row after `showBatTemp`:
```swift
                SettingsToggleRow(isOn: $showBatTemp, divider: true) { rowTitle("배터리 온도") }
                SettingsToggleRow(isOn: $showFan, divider: false) { rowTitle("팬 속도") }
```
In `menuChipGrid`, add a chip after the batTemp chip:
```swift
            WattlyChip(label: "배터리 온도 (°C)", isOn: menuBatTemp) { menuBatTemp.toggle() }
            WattlyChip(label: "팬 (RPM)", isOn: menuFan) { menuFan.toggle() }
```

- [ ] **Step 10: Add the fan expand region (MetricCardView)**

In `Wattly/Views/MetricCardView.swift`:

Extend `expandRegion` — add a fan branch after the `cpuTemp` branch:
```swift
        } else if card == .cpuTemp, case .value(.temperature(let s)) = state, case .reading(let r) = s.cpu {
            tempExpand(r.groups)
        } else if card == .fan, case .value(.fan(let s)) = state {
            fanExpand(s)
        }
```

Add the two rendering functions (place them after `tempGroupRow`):
```swift
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
```

- [ ] **Step 11: Run the full test suite**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | xcbeautify`
Expected: BUILD SUCCEEDED, all tests PASS (no regressions in the existing ~193 tests + the new fan tests).

- [ ] **Step 12: Commit**

```bash
git add Wattly/Settings/Settings.swift Wattly/Core/PollPolicy.swift Wattly/Views/PollPolicyBridge.swift Wattly/Views/PopoverContentView.swift Wattly/Views/SettingsView.swift Wattly/Views/MenuBarLabel.swift Wattly/Views/MetricCardView.swift WattlyTests/CardReorderTests.swift WattlyTests/PollPolicyTests.swift
git commit -m "feat(fan): wire fan card visibility, cadence, expand, and order migration"
```

---

### Task 5: On-device Phase-0 verification

The fan SMC keys are asserted from well-known conventions but were not verifiable from the repo. This task confirms them on the real (fan-equipped) dev Mac before the card is trusted. It is a verification gate, not a code change — but it is the point of the read-only `FanProbe`.

**Files:** none (runtime verification; a code change only if the probe reveals a key/type mismatch).

- [ ] **Step 1: Build the app for running**

Run: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -configuration Debug build 2>&1 | xcbeautify`
Expected: BUILD SUCCEEDED. Note the built `.app` path from the build output (under `DerivedData/.../Build/Products/Debug/Wattly.app`).

- [ ] **Step 2: Run the fan probe headless on the real Mac**

Run: `"<path-to>/Wattly.app/Contents/MacOS/Wattly" -WattlyFanProbe`
Expected: three `[fan-probe] sample N:` lines. On a fan-equipped Mac each should read `avg <NNNN> rpm [팬0 <NNNN>rpm(목표 …, …–…)]` with plausible values (idle roughly 0–2500 RPM; the range max typically a few thousand). On a fanless Mac it prints `unavailable(팬 없음 — 팬리스 Mac)`.

- [ ] **Step 3: Sanity-check against a known tool (optional but recommended)**

Compare the probe's RPM against `sudo powermetrics --samplers smc -i1 -n1 | grep -i fan` (or a fan utility already installed). Confirm the numbers are in the same ballpark.
Expected: probe RPM ≈ reference RPM. If they diverge wildly or the probe reports `unavailable` on a Mac that has fans, the `FNum`/`F0Ac` key names or SMC type decoding need revisiting in `SMCFanTransport` before shipping — record findings and open a follow-up.

- [ ] **Step 4: Launch the app and eyeball the card**

Run the built app normally (double-click or `open "<path-to>/Wattly.app"`). Open the popover; confirm the "팬 속도" card shows a live RPM headline, its sparkline moves over successive polls, and tapping it expands to the per-fan row(s). Open Settings → 표시 지표 and toggle "팬 속도" off/on to confirm the card hides/shows.
Expected: card behaves like the other metric cards; on a fanless Mac it is absent entirely (and its settings toggle, though present, has no visible effect — matching the battery card on a desktop).

- [ ] **Step 5: Record the verification outcome**

Note the observed idle/loaded RPM and that the keys verified, in the PR description or a short comment. No commit unless Step 3 forced a `SMCFanTransport` fix (in which case: `git commit -m "fix(fan): correct SMC fan key/type after on-device probe"`).

---

## Self-Review

**1. Spec coverage** (grilled v4 design → tasks):
- Fan card as 8th metric, temperature-seam reuse → Tasks 1–3. ✔
- Fanless auto-hide via `.notPresent` → Task 3 (`fanless`), verified Task 5. ✔
- `.fan` statically expandable + per-fan expand rows (v3 blocker fix) → Task 2 (`isExpandable`) + Task 4 (`expandRegion`/`fanExpand`). ✔
- Per-card poll wiring is NOT automatic — all four hand-assembly sites edited (v2 blocker fix): `PollPolicyBridge`, `PopoverContentView.isShown`, `MenuBarLabel.selected`, `SettingsView` → Task 4. ✔
- Default-guarded switches covered by tests (v2/v3 advisory) → Task 2 coverage tests + Task 4 poll-coverage test. ✔
- Compiler-enforced switch inventory (`label`/`unitText`/`longLabel`/`headPhrase`/`isShown` + `makeSample`/`bases`) → Task 2. ✔
- No threshold color for fan → Task 2 (`fanHasNoThresholdColor`, relies on existing `default: nil`). ✔
- Menubar exposure (order + longLabel + part + `selected` + chip) → Tasks 2 & 4. ✔
- `CardOrder` migration so upgraders see the new card → Task 4 (identified during file read; not in the grilled design but required for the card to appear for existing installs). ✔
- On-device Phase-0 key verification via `FanProbe` → Task 3 (probe) + Task 5 (run it). ✔
- Phase B-1 (curve model/preview) and Phase B-2 (daemon + writes) are explicitly OUT of scope — separate plans. ✔

**2. Placeholder scan:** No "TBD"/"add error handling"/"similar to Task N" — every code step shows complete code. ✔

**3. Type consistency:** `FanReading(index:actualRPM:minRPM:maxRPM:targetRPM:)`, `FanSample(fans:)`, `RawFan(actual:min:max:target:)`, `averageRPM(_:)`, `CardPresentation.fanBarFraction(actual:max:)`, `FanProvider(transport:)`, `FanTransport.{open,fanCount,readFan,close}` — used identically across Tasks 1–4 and both test files. `.notPresent`/`.channelUnreadable` are existing `MetricUnavailableReason` cases (confirmed in `MetricState.swift`). ✔

---

## Notes for the executor

- Tasks 2 and 4 are coupled by the two `isShown` switches (Task 2 adds a temporary `case .fan: false`; Task 4 replaces it with `showFan`). Run them in the same session; the intermediate state after Task 2 compiles and passes tests, but the fan card is intentionally hidden until Task 4.
- If `xcbeautify` isn't installed, drop the `| xcbeautify` suffix from every command.
- The existing test count (~193) is approximate; the pass criterion is "no regressions + the new fan tests green", not an exact number.
