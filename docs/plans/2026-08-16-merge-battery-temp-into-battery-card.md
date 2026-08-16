# Merge Battery Temperature into Battery Card Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the standalone "Battery Temperature" (`.batTemp`) card, integrate battery temperature telemetry directly into `BatterySample` and `BatteryProvider`, display battery temperature in the expanded "Battery" card list, and preserve menubar custom battery temperature display.

**Architecture:**
1. `CardKind.batTemp` is removed, reducing the popover card list from 9 to 8 cards (`.power, .battery, .cpu, .gpu, .mem, .cpuTemp, .gpuTemp, .fan`).
2. `BatterySample` receives `temperatureCelsius: Double? = nil`, populated directly by `BatteryProvider` via `AppleSmartBattery`'s `"Temperature"` property (centi-°C decoded via `batteryCelsius`).
3. `TemperatureSnapshot` is simplified to 2 categories (`cpu: CategoryReading` and `gpu: CategoryReading`), removing redundant battery temperature I/O from `TemperatureProvider`.
4. `CardExpandRegion` displays the "배터리 온도" row in the expanded battery card, positioned right after cycle count and before current/voltage.
5. Menubar customization continues to support displaying battery temperature (`배터리 31°C`) via `Defaults.menuBatteryTempEnabled` and `MenuBarText.batteryTempPart`.
6. Settings view removes the standalone `.batTemp` toggle and updates the status threshold caption to "온도 · CPU·GPU (°C)".

**Tech Stack:** Swift 6.0, Swift Testing (`Testing`, `@Test`, `#expect`), SwiftUI, AppKit, IOKit / AppleSmartBattery.

## Global Constraints

- **Platform:** macOS 14.0+ (Apple Silicon arm64 only).
- **Language Mode:** Swift 6 with strict concurrency (`Sendable` value types across actor boundaries).
- **Testing Framework:** Swift Testing (`import Testing`, `@Test`, `#expect(...)`, `struct SuiteName`), matching the rest of `WattlyTests`.
- **Design System:** Pixel-matched typography (`Pretendard`, `WattlyFont.at`), spacing, and tokens (`Tokens.accent`, `t.sparkFill`, `t.faint`, `t.sub`, `t.text`).
- **Zero Placeholders:** Full, working code and tests in every task.
- **TDD:** Pure derivations and formatting logic covered by unit tests.

---

### Task 1: Core Models, Settings & Card Order (`CardKind`, `MetricSample`, `Settings`, `SettingsReset`)

**Files:**
- Modify: `Wattly/Models/CardKind.swift`
- Modify: `Wattly/Models/MetricSample.swift`
- Modify: `Wattly/Settings/Settings.swift`
- Modify: `Wattly/Core/SettingsReset.swift`
- Modify: `WattlyTests/CardPresentationTests.swift`
- Modify: `WattlyTests/SettingsResetTests.swift`

**Interfaces:**
- Consumes: None
- Produces:
  - `CardKind`: 8 cases (`power, battery, cpu, gpu, mem, cpuTemp, gpuTemp, fan`)
  - `BatterySample.temperatureCelsius: Double?`
  - `TemperatureSnapshot`: 2 fields (`cpu: CategoryReading`, `gpu: CategoryReading`)
  - `Defaults.cardOrder`: 8 cards
  - `Defaults.show`: 8 cards
  - `Defaults.menuMetrics`: 8 cards
  - `Defaults.menuBatteryTempEnabled: Bool` (false)
  - `StorageKey.menuBatteryTemp = "menu.batteryTemp"`
  - `CardOrder.init?(rawValue:)` tolerant to legacy/unknown tokens

- [ ] **Step 1: Write tests in `WattlyTests/CardPresentationTests.swift` and `WattlyTests/SettingsResetTests.swift`**

Add to `WattlyTests/CardPresentationTests.swift`:
```swift
    @Test func cardKindExcludesBatTemp() {
        let allCards = CardKind.allCases
        #expect(allCards == [.power, .battery, .cpu, .gpu, .mem, .cpuTemp, .gpuTemp, .fan])
        #expect(allCards.count == 8)
        #expect(allCards.allSatisfy(\.isExpandable))
    }

    @Test func batterySampleIncludesTemperature() {
        let sample = BatterySample(
            netW: -12.5,
            milliamps: 1100,
            volts: 11.4,
            charging: false,
            externalConnected: false,
            temperatureCelsius: 32.4
        )
        #expect(sample.temperatureCelsius == 32.4)
    }

    @Test func temperatureSnapshotHasTwoCategories() {
        let snap = TemperatureSnapshot(
            cpu: .reading(TemperatureReading(celsius: 45.0)),
            gpu: .reading(TemperatureReading(celsius: 42.0))
        )
        #expect(snap.cpu.celsius == 45.0)
        #expect(snap.gpu.celsius == 42.0)
    }
```

In `WattlyTests/SettingsResetTests.swift`:
```swift
    @Test func applyDefaultsResetsMenuBatteryTemp() {
        let defaults = UserDefaults(suiteName: "test.reset.batteryTemp")!
        defaults.set(true, forKey: StorageKey.menuBatteryTemp)
        SettingsReset.applyDefaults(into: defaults, login: FakeLoginItem())
        #expect(defaults.bool(forKey: StorageKey.menuBatteryTemp) == false)
    }
```

- [ ] **Step 2: Implement `CardKind.swift`, `MetricSample.swift`, `Settings.swift`, and `SettingsReset.swift`**

In `Wattly/Models/CardKind.swift`:
```swift
import Foundation

/// The eight cards the popover can show, in the default order.
enum CardKind: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case power, battery, cpu, gpu, mem, cpuTemp, gpuTemp, fan

    var id: String { rawValue }

    /// Which provider feeds this card.
    var provider: ProviderKind {
        switch self {
        case .power: .power
        case .battery: .battery
        case .cpu: .cpu
        case .gpu: .gpu
        case .mem: .memory
        case .cpuTemp, .gpuTemp: .temperature
        case .fan: .fan
        }
    }

    // MARK: Structural facts (state-independent) — the card's layout shape.

    /// All 8 cards have an expand region + chevron.
    var isExpandable: Bool { true }

    /// The battery card draws a polyline only; every other card fills the sparkline
    /// area beneath the line.
    var hasSparkArea: Bool { self != .battery }

    /// The processor-power card is the single accented (brand-blue) card.
    var isAccented: Bool { self == .power }

    /// The processor-power and battery cards apply display smoothing.
    var isSmoothable: Bool { self == .power || self == .battery }
}

/// The seven providers that cross the actor boundary.
enum ProviderKind: String, CaseIterable, Sendable, Hashable {
    case cpu, gpu, memory, power, battery, temperature, fan
}
```

In `Wattly/Models/MetricSample.swift`:
```swift
struct BatterySample: Sendable, Equatable {
    var netW: Double
    var milliamps: Int
    var volts: Double
    var charging: Bool
    var externalConnected: Bool
    var remainingWh: Double? = nil
    var maxWh: Double? = nil
    var timeRemainingMinutes: Int? = nil
    var projectedTimeRemainingMinutes: Int? = nil
    var efficiencyPercent: Double? = nil
    var cycleCount: Int? = nil
    var average1mW: Double? = nil
    /// Battery pack temperature, °C (from AppleSmartBattery centi-°C). nil on desktop or unreadable.
    var temperatureCelsius: Double? = nil
}

struct TemperatureSnapshot: Sendable, Equatable {
    var cpu: CategoryReading
    var gpu: CategoryReading
}
```

In `Wattly/Settings/Settings.swift`:
```swift
// In StorageKey:
    static let menuBatteryTemp = "menu.batteryTemp"

// In Defaults:
    static let menuBatteryTempEnabled = false

    static let show: [CardKind: Bool] = [
        .power: true, .battery: true, .cpu: true, .gpu: true, .mem: true,
        .cpuTemp: true, .gpuTemp: true, .fan: true,
    ]

    static let menuMetrics: [CardKind: Bool] = [
        .cpu: true, .gpu: false, .power: false, .battery: false, .mem: false,
        .cpuTemp: false, .gpuTemp: false, .fan: false,
    ]

    static let cardOrder = CardOrder([.power, .battery, .cpu, .gpu, .mem, .cpuTemp, .gpuTemp, .fan])
```

Update `CardOrder.init?(rawValue:)`:
```swift
    init?(rawValue: String) {
        let tokens = rawValue.split(separator: ",").map(String.init)
        guard !tokens.isEmpty else { return nil }
        let known = tokens.compactMap { CardKind(rawValue: $0) }
        guard !known.isEmpty else { return nil }
        var result: [CardKind] = []
        var seen = Set<CardKind>()
        for card in known where seen.insert(card).inserted {
            result.append(card)
        }
        for card in CardKind.allCases where !seen.contains(card) {
            result.append(card)
        }
        self.init(result)
    }
```

In `Wattly/Core/SettingsReset.swift`:
```swift
        defaults.set(Defaults.menuBatteryTempEnabled, forKey: StorageKey.menuBatteryTemp)
```

- [ ] **Step 3: Commit**

```bash
git add Wattly/Models/CardKind.swift Wattly/Models/MetricSample.swift Wattly/Settings/Settings.swift Wattly/Core/SettingsReset.swift WattlyTests/CardPresentationTests.swift WattlyTests/SettingsResetTests.swift
git commit -m "refactor: update CardKind, MetricSample, and Settings for 8-card architecture"
```

---

### Task 2: Battery & Temperature Providers (`BatteryProvider`, `TemperatureProvider`, `FakeProvider`)

**Files:**
- Modify: `Wattly/Providers/BatteryProvider.swift`
- Modify: `Wattly/Providers/TemperatureProvider.swift`
- Modify: `Wattly/Providers/FakeProvider.swift`
- Modify: `WattlyTests/TemperatureTests.swift`

**Interfaces:**
- Consumes: `BatterySample`, `TemperatureSnapshot`
- Produces:
  - `BatteryProvider` reads `"Temperature"` from `AppleSmartBattery` and sets `temperatureCelsius`
  - `TemperatureProvider` produces 2-category snapshot (`cpu` and `gpu`), drops `BatterySource` and `batteryTemperature()`
  - `FakeProvider` populates `temperatureCelsius` in `.battery` and returns 2-category `TemperatureSnapshot`

- [ ] **Step 1: Write tests in `WattlyTests/TemperatureTests.swift`**

Update `FakeTempTransport` in `WattlyTests/TemperatureTests.swift` by removing `batteryTemperature()` and testing 2-category reading:
```swift
    @Test func verifiedChipReadsCpuAndGpu() async {
        let fake = FakeTransport(
            celsius: ["Tp00": 42.0, "Tp04": 44.0, "Te04": 38.0, "Tg04": 50.0],
            openResult: true
        )
        let p = TemperatureProvider(transport: fake, model: "Mac17,2")
        let snap = await readSnapshot(p, at: .now)
        #expect(snap.cpu.celsius != nil)
        #expect(snap.gpu.celsius != nil)
    }
```

- [ ] **Step 2: Update `BatteryProvider.swift`**

In `Wattly/Providers/BatteryProvider.swift`:
```swift
    private struct AppleSmartBatterySnapshot {
        var volts: Double?
        var externalConnected: Bool
        var batteryMilliwatts: Int?
        var rawCurrentCapacityMilliampHours: Int?
        var timeRemainingMinutes: Int?
        var rawMaxCapacityMilliampHours: Int?
        var designCapacityMilliampHours: Int?
        var cycleCount: Int?
        var temperatureCelsius: Double?
    }

    private func smcSample(registry: AppleSmartBatterySnapshot?) -> BatterySample? {
        guard let smc,
              let power = smc.read("B0AP"),
              let voltage = smc.read("B0AV") else { return nil }
        let milliwatts = Int(smcDouble(power.bytes, type: power.type).rounded())
        let volts = smcDouble(voltage.bytes, type: voltage.type) / 1000.0
        let netW = netWatts(batteryMilliwatts: milliwatts)
        let mA = smc.read("B0AC").map { Int(smcDouble($0.bytes, type: $0.type).rounded()) }
            ?? batteryMilliamps(batteryMilliwatts: milliwatts, volts: volts)
        let adapterW = smc.read("PDTR").map { smcDouble($0.bytes, type: $0.type) } ?? 0
        return BatterySample(
            netW: netW,
            milliamps: abs(mA),
            volts: volts,
            charging: isCharging(netW: netW),
            externalConnected: adapterW > 0.5,
            remainingWh: remainingWattHours(
                rawCapacityMilliampHours: registry?.rawCurrentCapacityMilliampHours ?? 0),
            maxWh: remainingWattHours(
                rawCapacityMilliampHours: registry?.rawMaxCapacityMilliampHours ?? 0),
            timeRemainingMinutes: validatedTimeRemainingMinutes(registry?.timeRemainingMinutes),
            efficiencyPercent: batteryEfficiencyPercent(
                maxCapacityMilliampHours: registry?.rawMaxCapacityMilliampHours ?? 0,
                designCapacityMilliampHours: registry?.designCapacityMilliampHours ?? 0),
            cycleCount: validatedBatteryCycleCount(registry?.cycleCount),
            temperatureCelsius: registry?.temperatureCelsius)
    }

    private func appleSmartBatterySnapshot() -> AppleSmartBatterySnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        let volts = number(service, "Voltage").map { Double($0.int64Value) / 1000.0 }
        let externalConnected = bool(service, "ExternalConnected") ?? false
        let batteryMilliwatts: Int?
        if let telemetry = dict(service, "PowerTelemetryData"),
           let raw = (telemetry["BatteryPower"] as? NSNumber)?.uint64Value {
            batteryMilliwatts = twosComplement(raw)
        } else if let rawAmp = number(service, "InstantAmperage")?.uint64Value, let volts {
            batteryMilliwatts = Int((Double(twosComplement(rawAmp)) * volts).rounded())
        } else {
            batteryMilliwatts = nil
        }

        let tempCenti = number(service, "Temperature")?.intValue
        let tempC = tempCenti.flatMap { batteryCelsius(rawCentiCelsius: $0, in: 0.0...80.0) }

        return AppleSmartBatterySnapshot(
            volts: volts,
            externalConnected: externalConnected,
            batteryMilliwatts: batteryMilliwatts,
            rawCurrentCapacityMilliampHours: number(service, "AppleRawCurrentCapacity")?.intValue,
            timeRemainingMinutes: number(service, "TimeRemaining")?.intValue ?? number(service, "AvgTimeToFull")?.intValue ?? number(service, "TimeToFull")?.intValue,
            rawMaxCapacityMilliampHours: number(service, "AppleRawMaxCapacity")?.intValue,
            designCapacityMilliampHours: number(service, "DesignCapacity")?.intValue,
            cycleCount: number(service, "CycleCount")?.intValue,
            temperatureCelsius: tempC)
    }

    private func appleSmartBatteryReading(registry: AppleSmartBatterySnapshot?) -> ProviderReading {
        guard let registry else { return .unavailable(.notPresent(Self.notPresentMessage)) }
        guard let volts = registry.volts, let milliwatts = registry.batteryMilliwatts else { return .pending }
        let netW = fallbackNetWatts(
            batteryMilliwatts: milliwatts,
            externalConnected: registry.externalConnected)
        return .value(.battery(BatterySample(
            netW: netW, milliamps: abs(batteryMilliamps(batteryMilliwatts: milliwatts, volts: volts)),
            volts: volts, charging: isCharging(netW: netW), externalConnected: registry.externalConnected,
            remainingWh: remainingWattHours(
                rawCapacityMilliampHours: registry.rawCurrentCapacityMilliampHours ?? 0),
            maxWh: remainingWattHours(
                rawCapacityMilliampHours: registry.rawMaxCapacityMilliampHours ?? 0),
            timeRemainingMinutes: validatedTimeRemainingMinutes(registry.timeRemainingMinutes),
            efficiencyPercent: batteryEfficiencyPercent(
                maxCapacityMilliampHours: registry.rawMaxCapacityMilliampHours ?? 0,
                designCapacityMilliampHours: registry.designCapacityMilliampHours ?? 0),
            cycleCount: validatedBatteryCycleCount(registry.cycleCount),
            temperatureCelsius: registry.temperatureCelsius)))
    }
```

- [ ] **Step 3: Update `TemperatureProvider.swift`**

Remove `BatterySource`, `batteryTemperature()`, `batteryNotPresentMessage`, and `batteryReading()` from `Wattly/Providers/TemperatureProvider.swift`:

```swift
protocol TemperatureTransport: Sendable {
    func open() -> Bool
    func readCelsius(_ key: String) -> Double?
    func close()
}

final class SMCTemperatureTransport: TemperatureTransport, @unchecked Sendable {
    private var smc: SMCConnection?

    func open() -> Bool {
        if smc != nil { return true }
        smc = SMCConnection()
        return smc != nil
    }

    func readCelsius(_ key: String) -> Double? {
        guard let smc, let r = smc.read(key), r.type.hasPrefix("flt") else { return nil }
        let c = smcDouble(r.bytes, type: r.type)
        return c.isFinite ? c : nil
    }

    func close() { smc = nil }
}
```

In `TemperatureProvider`:
```swift
    func read(at instant: ContinuousClock.Instant) async -> ProviderReading {
        if let last = lastInstant, Self.seconds(from: last, to: instant) > Self.maxPlausibleDt {
            resetConnection()
        }
        defer { lastInstant = instant }

        if !profileResolved {
            profile = TemperatureProfiles.profile(forModel: model)
            profileResolved = true
        }

        let (cpu, gpu) = cpuGpuReadings(at: instant)
        return .value(.temperature(TemperatureSnapshot(cpu: cpu, gpu: gpu)))
    }
```

In `#if DEBUG` `ThermalProbe`:
```swift
    private static func describe(_ r: ProviderReading) -> String {
        guard case .value(.temperature(let s)) = r else { return "non-temperature: \(r)" }
        func d(_ c: CategoryReading) -> String {
            switch c {
            case .reading(let x):
                let groups = x.groups
                    .map { "\($0.name) \(String(format: "%.1f", $0.average))°(최고 \(String(format: "%.1f", $0.hottest))°)" }
                    .joined(separator: ", ")
                return String(format: "평균 %.2f°C", x.celsius) + (groups.isEmpty ? "" : " [\(groups)]")
            case .unavailable(let e): return "unavailable(\(e))"
            case .notPresent(let m): return "notPresent(\(m))"
            }
        }
        return "CPU \(d(s.cpu)) · GPU \(d(s.gpu))"
    }
```

- [ ] **Step 4: Update `FakeProvider.swift`**

In `Wattly/Providers/FakeProvider.swift`:
```swift
    case .battery:
        var b: [String: Base] = desktop ? [:] : ["batteryW": Base(b: 6, step: 1.2, min: -10, max: 20)]
        if !desktop { b["batTemp"] = Base(b: 31, step: 0.7, min: 22, max: 46) }
        return b
    case .temperature:
        return [
            "cpuTemp": desktop ? Base(b: 51, step: 2.4, min: 40, max: 92) : Base(b: 54.3, step: 2.5, min: 42, max: 94),
            "gpuTemp": desktop ? Base(b: 57, step: 2.2, min: 40, max: 88) : Base(b: 48.1, step: 2, min: 38, max: 86),
        ]
```
And in `makeSample()`:
```swift
    case .battery:
        let net = desktop ? 0.0 : v("batteryW")
        let charging = net < -0.2
        return .battery(BatterySample(
            netW: net,
            milliamps: desktop ? 0 : Int(abs(net) * 1000 / 11.4),
            volts: 11.4,
            charging: charging,
            externalConnected: desktop || charging,
            remainingWh: desktop ? nil : 48.2,
            maxWh: desktop ? nil : 52.0,
            timeRemainingMinutes: desktop ? nil : 210,
            efficiencyPercent: desktop ? nil : 94.5,
            cycleCount: desktop ? nil : 142,
            temperatureCelsius: desktop ? nil : v("batTemp")))
    case .temperature:
        let cpu: CategoryReading = .reading(TemperatureReading(celsius: v("cpuTemp"), groups: [
            TemperatureGroup(name: "S-코어", average: v("cpuTemp"), hottest: v("cpuTemp") + 3.0),
            TemperatureGroup(name: "E-코어", average: v("cpuTemp") - 4.0, hottest: v("cpuTemp") - 2.0)
        ]))
        let gpu: CategoryReading = .reading(TemperatureReading(celsius: v("gpuTemp"), groups: [
            TemperatureGroup(name: "클러스터 1", average: v("gpuTemp"), hottest: v("gpuTemp") + 2.0)
        ]))
        return .temperature(TemperatureSnapshot(cpu: cpu, gpu: gpu))
```

- [ ] **Step 5: Commit**

```bash
git add Wattly/Providers/BatteryProvider.swift Wattly/Providers/TemperatureProvider.swift Wattly/Providers/FakeProvider.swift WattlyTests/TemperatureTests.swift
git commit -m "feat: stream battery temperature through BatteryProvider and streamline TemperatureProvider"
```

---

### Task 3: Presentation, Formatting & SystemMonitor (`CardPresentation`, `MenuBarText`, `Accessibility`, `SystemMonitor`, `PollPolicy`)

**Files:**
- Modify: `Wattly/Core/CardPresentation.swift`
- Modify: `Wattly/Core/MenuBarText.swift`
- Modify: `Wattly/Core/Accessibility.swift`
- Modify: `Wattly/Core/SystemMonitor.swift`
- Modify: `Wattly/Core/PollPolicy.swift`
- Modify: `WattlyTests/CardPresentationTests.swift`
- Modify: `WattlyTests/MenuBarTextTests.swift`
- Modify: `WattlyTests/AccessibilityTests.swift`
- Modify: `WattlyTests/SystemMonitorTests.swift`
- Modify: `WattlyTests/ThresholdTests.swift`
- Modify: `WattlyTests/PollPolicyTests.swift`

**Interfaces:**
- Consumes: `CardKind`, `BatterySample`, `TemperatureSnapshot`
- Produces:
  - `CardPresentation.batteryTemperatureLabel = "배터리 온도"`
  - `CardPresentation.batteryTemperatureText(_ s: BatterySample) -> String?`
  - `MenuBarText.order = [.cpu, .gpu, .power, .battery, .mem, .cpuTemp, .gpuTemp, .fan]`
  - `MenuBarText.batteryTempPart(_ state: MetricState) -> String`
  - `SystemMonitor`: manages 8 cards, passes through `temperatureCelsius` in `batterySmoothed`

- [ ] **Step 1: Write tests for Presentation, MenuBarText, and PollPolicy**

In `WattlyTests/CardPresentationTests.swift`:
```swift
    @Test func batteryTemperaturePresentation() {
        let sample = BatterySample(netW: -5.0, milliamps: 450, volts: 11.2, charging: false, externalConnected: false, temperatureCelsius: 32.6)
        #expect(CardPresentation.batteryTemperatureText(sample) == "32.6°C")

        let noTemp = BatterySample(netW: -5.0, milliamps: 450, volts: 11.2, charging: false, externalConnected: false, temperatureCelsius: nil)
        #expect(CardPresentation.batteryTemperatureText(noTemp) == nil)
    }
```

In `WattlyTests/MenuBarTextTests.swift`:
```swift
    @Test func batteryTempMenuBarText() {
        let sample = BatterySample(netW: -5.0, milliamps: 450, volts: 11.2, charging: false, externalConnected: false, temperatureCelsius: 31.4)
        let part = MenuBarText.batteryTempPart(.value(.battery(sample)))
        #expect(part == "배터리 31°C")

        let cold = MenuBarText.batteryTempPart(.loading)
        #expect(cold == "배터리 온도 —")
    }
```

- [ ] **Step 2: Update `CardPresentation.swift`**

In `Wattly/Core/CardPresentation.swift`:
- Remove `.batTemp` cases in `thresholdLevel`, `label`, `unitText`, `valueText`.
- In `thresholdLevel`:
  ```swift
  case (.cpuTemp, .temperature(let s)): return tempLevel(s.cpu, thresholds.temp)
  case (.gpuTemp, .temperature(let s)): return tempLevel(s.gpu, thresholds.temp)
  ```
- In `label`:
  ```swift
  case .cpuTemp: "CPU 온도"
  case .gpuTemp: "GPU 온도"
  case .fan: "팬 속도"
  ```
- In `unitText`:
  ```swift
  case .cpuTemp, .gpuTemp: return "°C"
  ```
- In `valueText`:
  ```swift
  case (.cpuTemp, .temperature(let s)): return tempText(s.cpu)
  case (.gpuTemp, .temperature(let s)): return tempText(s.gpu)
  ```
- Add helper:
  ```swift
  static let batteryTemperatureLabel = "배터리 온도"

  static func batteryTemperatureText(_ s: BatterySample) -> String? {
      guard let c = s.temperatureCelsius, c.isFinite else { return nil }
      return "\(f1(c))°C"
  }
  ```

- [ ] **Step 3: Update `MenuBarText.swift` and `Accessibility.swift`**

In `Wattly/Core/MenuBarText.swift`:
```swift
    static let order: [CardKind] = [.cpu, .gpu, .power, .battery, .mem, .cpuTemp, .gpuTemp, .fan]

    // In part:
    case (.cpuTemp, .temperature(let s)): return tempPart("CPU", longLabel(card), s.cpu)
    case (.gpuTemp, .temperature(let s)): return tempPart("GPU", longLabel(card), s.gpu)
    case (.fan, .fan(let s)):
        return averageRPM(s.fans).map { "팬 \(Int($0.rounded())) RPM" } ?? "\(longLabel(card)) —"

    // In longLabel:
    case .cpu: "CPU"
    case .gpu: "GPU"
    case .power: "전력"
    case .mem: "메모리"
    case .cpuTemp: "CPU 온도"
    case .gpuTemp: "GPU 온도"
    case .fan: "팬"
    case .battery: "배터리"

    // Battery temperature chip formatter:
    static func batteryTempPart(_ state: MetricState) -> String {
        guard case .value(.battery(let s)) = state, let c = s.temperatureCelsius else { return "배터리 온도 —" }
        return "배터리 \(Int(c.rounded()))°C"
    }
```

In `Wattly/Core/Accessibility.swift`:
```swift
    case .cpuTemp, .gpuTemp: return "\(v)°C"
```

- [ ] **Step 4: Update `SystemMonitor.swift` and `PollPolicy.swift`**

In `Wattly/Core/SystemMonitor.swift`:
- In `cardState`:
  ```swift
  case .cpuTemp, .gpuTemp:
      return temperatureCardState(card, from: providerState)
  ```
- In `batterySmoothed`:
  Pass through `temperatureCelsius: raw.temperatureCelsius`.
- In `temperatureCardState`:
  ```swift
  let category: CategoryReading = (card == .cpuTemp) ? snap.cpu : snap.gpu
  ```
- In `scalar(of:from:)`:
  ```swift
  case (.cpuTemp, .temperature(let s)): return s.cpu.celsius
  case (.gpuTemp, .temperature(let s)): return s.gpu.celsius
  ```
- In `isPresent`:
  Battery `.notPresent` continues to hide `.battery`.

In `Wattly/Core/PollPolicy.swift`:
- `want = neededCards.contains(.cpuTemp) || neededCards.contains(.gpuTemp)`

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/CardPresentation.swift Wattly/Core/MenuBarText.swift Wattly/Core/Accessibility.swift Wattly/Core/SystemMonitor.swift Wattly/Core/PollPolicy.swift WattlyTests/CardPresentationTests.swift WattlyTests/MenuBarTextTests.swift WattlyTests/AccessibilityTests.swift WattlyTests/SystemMonitorTests.swift WattlyTests/ThresholdTests.swift WattlyTests/PollPolicyTests.swift
git commit -m "feat: update CardPresentation, MenuBarText, and SystemMonitor for 8-card architecture"
```

---

### Task 4: UI Views Integration (`CardExpandRegion`, `PopoverContentView`, `SettingsView`, `MenuBarLabel`, `PollPolicyBridge`)

**Files:**
- Modify: `Wattly/Views/CardExpandRegion.swift`
- Modify: `Wattly/Views/PopoverContentView.swift`
- Modify: `Wattly/Views/SettingsView.swift`
- Modify: `Wattly/Views/MenuBarLabel.swift`
- Modify: `Wattly/Views/PollPolicyBridge.swift`

**Interfaces:**
- Consumes: `CardKind`, `CardPresentation.batteryTemperatureText`, `Defaults.menuBatteryTempEnabled`, `StorageKey.menuBatteryTemp`
- Produces:
  - Expanded battery card shows battery temperature row
  - Popover cards stack renders 8 cards
  - Settings view displays 8 card toggles + "배터리 온도" menubar chip
  - Menubar label renders battery temperature if selected

- [ ] **Step 1: Update `CardExpandRegion.swift`**

In `Wattly/Views/CardExpandRegion.swift`:
Update `batteryExpand(_ s: BatterySample) -> some View`:
```swift
    private func batteryExpand(_ s: BatterySample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let value = CardPresentation.batteryAverage1mText(s) {
                batteryDetailRow(label: CardPresentation.batteryAverage1mLabel, value: value)
            }
            if let value = CardPresentation.batteryRemainingCapacityText(s) {
                batteryDetailRow(label: CardPresentation.batteryRemainingCapacityLabel, value: value)
            }
            if showBatteryEfficiency, let value = CardPresentation.batteryEfficiencyText(s) {
                batteryDetailRow(label: CardPresentation.batteryEfficiencyLabel, value: value)
            }
            if let value = CardPresentation.batteryCycleText(s) {
                batteryDetailRow(label: CardPresentation.batteryCycleLabel, value: value)
            }
            if let value = CardPresentation.batteryTemperatureText(s) {
                batteryDetailRow(label: CardPresentation.batteryTemperatureLabel, value: value)
            }
            batteryDetailRow(label: "전류", value: CardPresentation.batteryCurrentText(s))
            batteryDetailRow(label: "전압", value: CardPresentation.batteryVoltageText(s))
        }
        .padding(.top, 8)
    }
```

- [ ] **Step 2: Update `PopoverContentView.swift`**

In `Wattly/Views/PopoverContentView.swift`:
- Remove `@AppStorage(StorageKey.show(.batTemp)) private var showBatTemp`.
- In `isShown`: remove `case .batTemp: showBatTemp`.

- [ ] **Step 3: Update `SettingsView.swift`**

In `Wattly/Views/SettingsView.swift`:
- Remove `@AppStorage(StorageKey.show(.batTemp)) private var showBatTemp`.
- Remove `@AppStorage(StorageKey.menu(.batTemp)) private var menuBatTemp`.
- Add `@AppStorage(StorageKey.menuBatteryTemp) private var menuBatteryTemp = Defaults.menuBatteryTempEnabled`.
- In `hasActiveAdvancedMetrics`:
  `menuSClock || menuPClock || menuEClock || menuMemPressure || menuBatteryTemp`
- In `showSection`: remove `metricToggle(.batTemp...)`.
- In `thresholdSection`: update title to `"온도 · CPU·GPU (°C)"`.
- In `menuChipGrid` advanced section:
  ```swift
  GridRow {
      menuMetricChip(.mem, label: "메모리 압력 (%)", isOn: menuMemPressure) { menuMemPressure.toggle() }
      WattlyChip(
          label: "배터리 온도 (°C)",
          isOn: menuBatteryTemp,
          isEnabled: menubarText && monitor.isPresent(.battery),
          disabledReason: !menubarText
              ? "텍스트 표시를 켜면 선택한 지표가 아이콘 옆에 표시됩니다."
              : (!monitor.isPresent(.battery) ? "이 Mac에서는 사용할 수 없습니다" : nil),
          action: { menuBatteryTemp.toggle() }
      )
  }
  ```

- [ ] **Step 4: Update `MenuBarLabel.swift` and `PollPolicyBridge.swift`**

In `Wattly/Views/MenuBarLabel.swift`:
- Replace `@AppStorage(StorageKey.menu(.batTemp)) private var menuBatTemp` with:
  `@AppStorage(StorageKey.menuBatteryTemp) private var menuBatteryTemp = Defaults.menuBatteryTempEnabled`
- In `body` string assembly:
  ```swift
  if menuBatteryTemp {
      extras.append(MenuBarText.batteryTempPart(monitor.cardState(.battery, smoothed: powerSmoothed)))
  }
  ```

In `Wattly/Views/PollPolicyBridge.swift`:
- Remove `showBatTemp` and `menuBatTemp`.
- Add `@AppStorage(StorageKey.menuBatteryTemp) private var menuBatteryTemp = Defaults.menuBatteryTempEnabled`.
- In `recalculate`:
  - If `menuBatteryTemp`, include `.battery` in `menu` set.

- [ ] **Step 5: Commit**

```bash
git add Wattly/Views/CardExpandRegion.swift Wattly/Views/PopoverContentView.swift Wattly/Views/SettingsView.swift Wattly/Views/MenuBarLabel.swift Wattly/Views/PollPolicyBridge.swift
git commit -m "feat: integrate battery temperature in CardExpandRegion and SettingsView"
```

---

### Task 5: Comprehensive Test Suite Updates & Final Verification (`WattlyTests/*`)

**Files:**
- Modify: `WattlyTests/CardPresentationTests.swift`
- Modify: `WattlyTests/CardReorderTests.swift`
- Modify: `WattlyTests/MenuBarTextTests.swift`
- Modify: `WattlyTests/AccessibilityTests.swift`
- Modify: `WattlyTests/SystemMonitorTests.swift`
- Modify: `WattlyTests/ThresholdTests.swift`
- Modify: `WattlyTests/PollPolicyTests.swift`
- Modify: `WattlyTests/TemperatureTests.swift`
- Modify: `WattlyTests/PanelPresentationTests.swift`
- Modify: `WattlyTests/FanTests.swift`
- Modify: `WattlyTests/SettingsResetTests.swift`

**Interfaces:**
- Consumes: All updated components
- Produces: 100% passing test suite across all 33+ test suites

- [ ] **Step 1: Update test files with 8-card order, 2-category snapshot, and updated fixtures**

In `WattlyTests/CardReorderTests.swift`:
- Update default 8-card order: `[.power, .battery, .cpu, .gpu, .mem, .cpuTemp, .gpuTemp, .fan]`.
- Update all reorder index tests (0 to 7).
- Update legacy CSV migration tests: legacy strings `"power,battery,cpu,mem,cpuTemp,gpuTemp,batTemp"` and `"power,battery,cpu,mem,cpuTemp,gpuTemp,batTemp,fan,gpu"` migrate to the new 8-card order `[.power, .battery, .cpu, .gpu, .mem, .cpuTemp, .gpuTemp, .fan]`.

In `WattlyTests/PanelPresentationTests.swift`, `WattlyTests/AccessibilityTests.swift`, `WattlyTests/FanTests.swift`, `WattlyTests/ThresholdTests.swift`:
- Update all `TemperatureSnapshot` initializations to 2 arguments (`cpu:`, `gpu:`).
- Remove `.batTemp` assertions in `PanelPresentationTests` and `ThresholdTests`.

In `WattlyTests/PollPolicyTests.swift`:
- Update fast interval assertions without `.batTemp`.

In `WattlyTests/SystemMonitorTests.swift`:
- Update `hiddenTemperatureCardsDoNoCPUGPUSensorIO` and snapshot usages.

- [ ] **Step 2: Run full test suite**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData`
Expected: **TEST SUCCEEDED** (All tests pass)

- [ ] **Step 3: Commit**

```bash
git add WattlyTests/
git commit -m "test: update all unit test suites for 8-card architecture and 2-category TemperatureSnapshot"
```

---

## Verification Plan

### Automated Tests
- Run full suite:
  ```bash
  xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData
  ```
- Verify specific suites:
  - `WattlyTests/CardPresentationTests`
  - `WattlyTests/CardReorderTests`
  - `WattlyTests/MenuBarTextTests`
  - `WattlyTests/TemperatureTests`
  - `WattlyTests/SystemMonitorTests`
  - `WattlyTests/ThresholdTests`
  - `WattlyTests/PollPolicyTests`

### Manual Verification
1. Launch Wattly on a MacBook.
2. Open popover: Verify there are 8 cards in Mode A and no standalone "배터리 온도" card.
3. Click on the "배터리" card to expand: Verify "배터리 온도" appears with live value (e.g. `31.2°C`) right below 사이클 and above 전류/전압.
4. Open Settings -> 표시 지표: Verify 8 card toggles without "배터리 온도".
5. Open Settings -> 메뉴바 -> 세부 지표: Toggle "배터리 온도 (°C)" on and verify the menubar displays `배터리 XX°C`.
6. Switch to Mode B (Grid) and Mode C (Hero): Verify battery card and temperatures function correctly.
