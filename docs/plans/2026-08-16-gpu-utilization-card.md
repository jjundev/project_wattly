# GPU Utilization Card Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a GPU Utilization Card to Wattly that mirrors the CPU card's layout and functionality, displaying overall GPU usage (%), live active clock frequency (GHz), sparkline history, and an expandable per-core bar view (G0...Gn).

**Architecture:** A new `GPUProvider` collects real-time GPU load from IORegistry (`IOAccelerator`'s `PerformanceStatistics` and `gpu-core-count`) and live DVFS frequency from `libIOReport.dylib` (`GPU Stats` group `GPUPH` channel) mapped against `AppleARMIODevice` frequency tables (`voltage-states9-sram`). A new `GPUSample` payload crosses the actor boundary and feeds into `SystemMonitor`, `CardPresentation`, `MenuBarText`, `PollPolicyBridge`, and `CardExpandRegion` to render the GPU card seamlessly alongside CPU and other metrics.

**Tech Stack:** Swift 6.0, Swift Testing (`Testing`, `@Test`, `#expect`), SwiftUI, AppKit, IOKit / IORegistry, libIOReport private API.

## Global Constraints

- **Platform:** macOS 14.0+ (Apple Silicon arm64 only).
- **Language Mode:** Swift 6 with strict concurrency (`Sendable` value types across actor boundaries).
- **Testing Framework:** Swift Testing (`import Testing`, `@Test`, `#expect(...)`, `struct SuiteName`), matching the rest of `WattlyTests`.
- **Design System:** Pixel-matched typography (`Pretendard`, `WattlyFont.at`), spacing, and tokens (`Tokens.accent`, `t.sparkFill`, `t.faint`, `t.sub`, `t.text`).
- **Zero Placeholders:** Full, working code and tests in every task.
- **TDD:** Pure derivations and formatting logic covered by unit tests.

---

### Task 1: Core Models, Settings & Existing Test Fixtures (`CardKind`, `ProviderKind`, `MetricSample`, `Settings`, `CardPresentationTests`)

**Files:**
- Modify: `Wattly/Models/CardKind.swift:5-53`
- Modify: `Wattly/Models/MetricSample.swift:9-33`
- Modify: `Wattly/Settings/Settings.swift:262-282`
- Modify: `WattlyTests/CardPresentationTests.swift`

**Interfaces:**
- Consumes: None
- Produces:
  - `CardKind.gpu`
  - `ProviderKind.gpu`
  - `struct GPUSample: Sendable, Equatable { var overall: Double; var coreCount: Int; var activeGHz: Double?; var cores: [Double] }`
  - `MetricSample.gpu(GPUSample)`

- [ ] **Step 1: Write the failing test for `CardKind.gpu` and `GPUSample` using Swift Testing**

Add to `WattlyTests/CardPresentationTests.swift`:
```swift
    @Test func gpuCardKindProperties() {
        let card = CardKind.gpu
        #expect(card.id == "gpu")
        #expect(card.provider == .gpu)
        #expect(card.isExpandable)
        #expect(card.hasSparkArea)
        #expect(!card.isAccented)
        #expect(!card.isSmoothable)
    }

    @Test func gpuSampleEquality() {
        let s1 = GPUSample(overall: 45.2, coreCount: 10, activeGHz: 1.28, cores: [45.2, 45.2])
        let s2 = GPUSample(overall: 45.2, coreCount: 10, activeGHz: 1.28, cores: [45.2, 45.2])
        let s3 = GPUSample(overall: 50.0, coreCount: 10, activeGHz: 1.35, cores: [50.0, 50.0])
        #expect(s1 == s2)
        #expect(s1 != s3)
        let sample = MetricSample.gpu(s1)
        if case .gpu(let s) = sample {
            #expect(s.overall == 45.2)
            #expect(s.coreCount == 10)
            #expect(s.activeGHz == 1.28)
        } else {
            Issue.record("Expected .gpu sample")
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData -only-testing:WattlyTests/CardPresentationTests/gpuCardKindProperties`
Expected: FAIL with "type 'CardKind' has no member 'gpu'"

- [ ] **Step 3: Implement `GPUSample`, `CardKind.gpu`, `Settings` defaults, and update `representativeState` fixture**

In `Wattly/Models/CardKind.swift`:
```swift
enum CardKind: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case power, battery, cpu, gpu, mem, cpuTemp, gpuTemp, batTemp, fan

    var id: String { rawValue }

    var provider: ProviderKind {
        switch self {
        case .power: .power
        case .battery: .battery
        case .cpu: .cpu
        case .gpu: .gpu
        case .mem: .memory
        case .cpuTemp, .gpuTemp, .batTemp: .temperature
        case .fan: .fan
        }
    }

    var isExpandable: Bool {
        self == .power || self == .battery || self == .cpu || self == .gpu || self == .mem || self == .cpuTemp || self == .gpuTemp || self == .fan
    }

    var hasSparkArea: Bool { self != .battery }
    var isAccented: Bool { self == .power }
    var isSmoothable: Bool { self == .power || self == .battery }
}

enum ProviderKind: String, CaseIterable, Sendable, Hashable {
    case cpu, gpu, memory, power, battery, temperature, fan
}
```

In `Wattly/Models/MetricSample.swift`:
```swift
enum MetricSample: Sendable, Equatable {
    case cpu(CPUSample)
    case gpu(GPUSample)
    case memory(MemorySample)
    case power(PowerSample)
    case battery(BatterySample)
    case temperature(TemperatureSnapshot)
    case fan(FanSample)
}

struct GPUSample: Sendable, Equatable {
    /// Overall GPU usage, 0–100.
    var overall: Double
    /// Total physical GPU core count from `gpu-core-count` (e.g. 10).
    var coreCount: Int
    /// Real-time active clock in GHz from DVFS residency, or nil when unavailable.
    var activeGHz: Double? = nil
    /// Per-core usage array (G0...Gn), 0–100.
    var cores: [Double] = []
}
```

In `Wattly/Settings/Settings.swift`:
Update `show`, `menuMetrics`, and `cardOrder` defaults:
```swift
    static let show: [CardKind: Bool] = [
        .power: true, .battery: true, .cpu: true, .gpu: true, .mem: true,
        .cpuTemp: true, .gpuTemp: true, .batTemp: true, .fan: true,
    ]
    static let menuMetrics: [CardKind: Bool] = [
        .cpu: true, .gpu: false, .power: false, .battery: false, .mem: false,
        .cpuTemp: false, .gpuTemp: false, .batTemp: false, .fan: false,
    ]
    static let cardOrder = CardOrder([.power, .battery, .cpu, .gpu, .mem, .cpuTemp, .gpuTemp, .batTemp, .fan])
```

In `WattlyTests/CardPresentationTests.swift`:
Update `representativeState` helper to include `.gpu`:
```swift
    case .gpu:
        .value(.gpu(GPUSample(overall: 38.0, coreCount: 10, activeGHz: 1.28, cores: Array(repeating: 38.0, count: 10))))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData -only-testing:WattlyTests/CardPresentationTests/gpuCardKindProperties`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Models/CardKind.swift Wattly/Models/MetricSample.swift Wattly/Settings/Settings.swift WattlyTests/CardPresentationTests.swift
git commit -m "feat: add GPU models and CardKind case with Swift Testing tests"
```

---

### Task 2: Pure GPU Derivation Logic & Tests (`GPUUsage.swift`, `GPUUsageTests.swift`)

**Files:**
- Create: `Wattly/Core/GPUUsage.swift`
- Create: `WattlyTests/GPUUsageTests.swift`

**Interfaces:**
- Consumes: `GPUSample`
- Produces:
  - `func makeGPUSample(overall: Double, coreCount: Int, activeGHz: Double?) -> GPUSample`

- [ ] **Step 1: Write the failing tests in `WattlyTests/GPUUsageTests.swift`**

```swift
import Testing
@testable import Wattly

struct GPUUsageTests {
    @Test func makeGPUSampleClampsOverallAndFillsCores() {
        let sample = makeGPUSample(overall: 42.6, coreCount: 10, activeGHz: 1.28)
        #expect(abs(sample.overall - 42.6) < 1e-4)
        #expect(sample.coreCount == 10)
        #expect(sample.activeGHz == 1.28)
        #expect(sample.cores.count == 10)
        for core in sample.cores {
            #expect(abs(core - 42.6) < 1e-4)
        }
    }

    @Test func makeGPUSampleClampsBounds() {
        let low = makeGPUSample(overall: -5.0, coreCount: 8, activeGHz: nil)
        #expect(low.overall == 0.0)
        #expect(low.cores.count == 8)
        #expect(low.cores.allSatisfy { $0 == 0.0 })

        let high = makeGPUSample(overall: 120.0, coreCount: 8, activeGHz: nil)
        #expect(high.overall == 100.0)
        #expect(high.cores.count == 8)
        #expect(high.cores.allSatisfy { $0 == 100.0 })
    }

    @Test func makeGPUSampleFallbackZeroCoreCount() {
        let sample = makeGPUSample(overall: 50.0, coreCount: 0, activeGHz: nil)
        #expect(sample.overall == 50.0)
        #expect(sample.coreCount == 1)
        #expect(sample.cores.count == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData -only-testing:WattlyTests/GPUUsageTests`
Expected: FAIL with "cannot find 'makeGPUSample' in scope"

- [ ] **Step 3: Implement `GPUUsage.swift`**

Write `Wattly/Core/GPUUsage.swift`:
```swift
import Foundation

/// Pure GPU-sample derivation: clamps overall percentage and distributes it across physical cores.
/// Fully deterministic under synthetic input.
func makeGPUSample(overall: Double, coreCount: Int, activeGHz: Double?) -> GPUSample {
    let clampedOverall = min(100.0, max(0.0, overall))
    let count = max(1, coreCount)
    let cores = [Double](repeating: clampedOverall, count: count)
    return GPUSample(overall: clampedOverall,
                     coreCount: count,
                     activeGHz: activeGHz,
                     cores: cores)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData -only-testing:WattlyTests/GPUUsageTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/GPUUsage.swift WattlyTests/GPUUsageTests.swift
git commit -m "feat: implement pure GPUUsage derivation and Swift Testing suite"
```

---

### Task 3: Real GPU Clock via libIOReport and IORegistry (`GPUClock.swift`)

**Files:**
- Create: `Wattly/Providers/GPUClock.swift`
- Modify: `WattlyTests/CPUFrequencyTests.swift`

**Interfaces:**
- Consumes: `CPUFrequency.decodeDVFSTable`, `CPUFrequency.activeGHz`
- Produces: `final class RealGPUClock: @unchecked Sendable { func sampleGHz() -> Double? }`

- [ ] **Step 1: Write test for GPU DVFS decode in `WattlyTests/CPUFrequencyTests.swift`**

Add to `WattlyTests/CPUFrequencyTests.swift`:
```swift
    @Test func gpuDVFSTableDecoding() {
        var data = Data()
        var f1: UInt32 = 338_000_000
        var v1: UInt32 = 800_000
        var f2: UInt32 = 1_278_000_000
        var v2: UInt32 = 950_000
        data.append(Data(bytes: &f1, count: 4))
        data.append(Data(bytes: &v1, count: 4))
        data.append(Data(bytes: &f2, count: 4))
        data.append(Data(bytes: &v2, count: 4))

        let freqs = CPUFrequency.decodeDVFSTable(data)
        #expect(freqs.count == 2)
        #expect(abs(freqs[0] - 0.338) < 1e-4)
        #expect(abs(freqs[1] - 1.278) < 1e-4)
    }
```

- [ ] **Step 2: Run test to verify it passes**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData -only-testing:WattlyTests/CPUFrequencyTests/gpuDVFSTableDecoding`
Expected: PASS

- [ ] **Step 3: Implement `Wattly/Providers/GPUClock.swift`**

Write `Wattly/Providers/GPUClock.swift`:
```swift
import Foundation
import IOKit

/// Live GPU clock source — reads IOReport's "GPU Stats" group ("GPU Performance States" subgroup)
/// for DVFS residency and maps against IORegistry `pmgr` DVFS frequency table (`voltage-states9-sram` / `voltage-states8`).
/// Preserves full table alignment (including bin 0 offset) matching `RealCPUClock`.
/// Gracefully degrades to `nil` if private symbols or tables are unavailable.
final class RealGPUClock: @unchecked Sendable {
    private typealias CopyChannelsFn =
        @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubscriptionFn =
        @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary,
                        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
    private typealias CreateSamplesFn =
        @convention(c) (AnyObject, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias GetStringFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateGetCountFn = @convention(c) (CFDictionary) -> Int32
    private typealias StateGetResidencyFn = @convention(c) (CFDictionary, Int32) -> Int64

    private let subscription: AnyObject
    private let subbedChannels: CFMutableDictionary
    private let createSamples: CreateSamplesFn
    private let getChannelName: GetStringFn
    private let stateGetCount: StateGetCountFn
    private let stateGetResidency: StateGetResidencyFn

    private let tableGHz: [Double]
    private var prev: [UInt64]?

    init?() {
        guard let handle = dlopen("libIOReport.dylib", RTLD_LAZY) else { return nil }
        func sym<T>(_ name: String, as type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard
            let copyChannels = sym("IOReportCopyChannelsInGroup", as: CopyChannelsFn.self),
            let createSub = sym("IOReportCreateSubscription", as: CreateSubscriptionFn.self),
            let createSamples = sym("IOReportCreateSamples", as: CreateSamplesFn.self),
            let getName = sym("IOReportChannelGetChannelName", as: GetStringFn.self),
            let getCount = sym("IOReportStateGetCount", as: StateGetCountFn.self),
            let getRes = sym("IOReportStateGetResidency", as: StateGetResidencyFn.self)
        else { dlclose(handle); return nil }

        // Read GPU DVFS frequency table from pmgr (voltage-states9-sram, fallback to voltage-states8/9)
        guard let table = Self.readDVFSTable("voltage-states9-sram") ??
                          Self.readDVFSTable("voltage-states8") ??
                          Self.readDVFSTable("voltage-states9"),
              !table.isEmpty else {
            dlclose(handle); return nil
        }

        // Keep every entry to preserve 1:1 residency bin alignment
        self.tableGHz = table

        guard let channelsU = copyChannels("GPU Stats" as CFString,
                                           "GPU Performance States" as CFString, 0, 0, 0) else {
            dlclose(handle); return nil
        }
        let channels = channelsU.takeRetainedValue()
        var subbedOut: Unmanaged<CFMutableDictionary>?
        guard let subU = createSub(nil, channels, &subbedOut, 0, nil), let subbedU = subbedOut else {
            dlclose(handle); return nil
        }

        self.subscription = subU.takeRetainedValue()
        self.subbedChannels = subbedU.takeRetainedValue()
        self.createSamples = createSamples
        self.getChannelName = getName
        self.stateGetCount = getCount
        self.stateGetResidency = getRes
    }

    /// Sample current active clock in GHz. Returns nil on first sample (baseline) or when idle.
    func sampleGHz() -> Double? {
        guard let curr = currentResidency() else { return nil }
        defer { prev = curr }
        guard let prev else { return nil }
        return CPUFrequency.activeGHz(tableGHz: tableGHz, prev: prev, curr: curr)
    }

    private func currentResidency() -> [UInt64]? {
        guard let samplesU = createSamples(subscription, subbedChannels, nil) else { return nil }
        let dict = samplesU.takeRetainedValue()
        guard let channels = (dict as NSDictionary)["IOReportChannels"] as? [Any] else { return nil }
        for case let ch as NSDictionary in channels {
            let chCF = ch as CFDictionary
            guard let name = getChannelName(chCF)?.takeUnretainedValue() as String?,
                  name == "GPUPH" || name.contains("GPU") else { continue }
            let count = Int(stateGetCount(chCF))
            guard count > 0 else { continue }
            var bins = [UInt64](repeating: 0, count: count)
            for i in 0..<count {
                bins[i] = UInt64(bitPattern: stateGetResidency(chCF, Int32(i)))
            }
            return bins
        }
        return nil
    }

    private static func readDVFSTable(_ key: String) -> [Double]? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleARMIODevice"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var result: [Double]?
        while true {
            let service = IOIteratorNext(iter)
            if service == 0 { break }
            if result == nil,
               let cf = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let data = cf as? Data {
                let table = CPUFrequency.decodeDVFSTable(data)
                if !table.isEmpty { result = table }
            }
            IOObjectRelease(service)
        }
        return result
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add Wattly/Providers/GPUClock.swift WattlyTests/CPUFrequencyTests.swift
git commit -m "feat: implement RealGPUClock reading IOReport and IORegistry DVFS"
```

---

### Task 4: Real & Fake GPU Provider (`GPUProvider.swift`, `FakeProvider.swift`, `SystemMonitor.swift`, `PollPolicy.swift`, `PollPolicyTests.swift`)

**Files:**
- Create: `Wattly/Providers/GPUProvider.swift`
- Modify: `Wattly/Providers/FakeProvider.swift:155-207`
- Modify: `Wattly/Core/PollPolicy.swift:52-105`
- Modify: `Wattly/Core/SystemMonitor.swift:530-545`
- Modify: `WattlyTests/PollPolicyTests.swift`

**Interfaces:**
- Consumes: `GPUClock`, `makeGPUSample`
- Produces:
  - `actor GPUProvider: MetricProvider`
  - Integration with `FakeProviders.all(scenario:)`
  - `SystemMonitor.scalar(of: .gpu)` -> `Double?`

- [ ] **Step 1: Write failing test in `WattlyTests/PollPolicyTests.swift`**

In `WattlyTests/PollPolicyTests.swift`:
```swift
    @Test func gpuPollIntervals() {
        let intervals = providerIntervals(mode: .eco, setting: .auto, panelVisible: true,
                                          menubarTextEnabled: true, active: [.gpu],
                                          menubarNeeds: [.gpu], isACConnected: true)
        #expect(intervals[.gpu] == .seconds(1))
    }
```
Also update existing tests in `PollPolicyTests.swift` (e.g. `autoPolicyBudgetsProvidersByVisibility`) where all `ProviderKind.allCases` are checked, adding `.gpu: .seconds(1)` to the expected fast dictionaries.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData -only-testing:WattlyTests/PollPolicyTests/gpuPollIntervals`
Expected: FAIL

- [ ] **Step 3: Implement `Wattly/Providers/GPUProvider.swift`**

```swift
import Foundation
import IOKit

/// Real GPU provider reading IOAccelerator's `PerformanceStatistics` for utilization and
/// `gpu-core-count`, coupled with `RealGPUClock` for DVFS active clock.
actor GPUProvider: MetricProvider {
    let kind: ProviderKind = .gpu

    private var coreCount: Int?
    private var clockSetupAttempted = false
    private var clock: RealGPUClock?

    func read(at instant: ContinuousClock.Instant) async -> ProviderReading {
        if coreCount == nil { coreCount = Self.readCoreCount() }
        if !clockSetupAttempted { clockSetupAttempted = true; clock = RealGPUClock() }

        guard let util = Self.readDeviceUtilization() else {
            return .unavailable(.providerError("GPU 사용률을 읽을 수 없음"))
        }

        let ghz = clock?.sampleGHz()
        let sample = makeGPUSample(overall: util, coreCount: coreCount ?? 8, activeGHz: ghz)
        return .value(.gpu(sample))
    }

    private static func readCoreCount() -> Int {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return 8 }
        defer { IOObjectRelease(iter) }
        while true {
            let service = IOIteratorNext(iter)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            if let cf = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let count = cf as? Int, count > 0 {
                return count
            }
        }
        return 8
    }

    private static func readDeviceUtilization() -> Double? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        while true {
            let service = IOIteratorNext(iter)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            if let cf = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let dict = cf as? [String: Any],
               let util = dict["Device Utilization %"] as? Int {
                return Double(util)
            }
        }
        return nil
    }
}
```

- [ ] **Step 4: Update `PollPolicy.swift`, `FakeProvider.swift`, and `SystemMonitor.swift`**

In `Wattly/Core/PollPolicy.swift`:
Add `.gpu` to fast intervals:
```swift
// In panelVisible open dict:
.cpu: .seconds(1), .gpu: .seconds(1), .power: .seconds(1), .temperature: .seconds(2),
...
// In fastInterval switches:
case .cpu, .gpu, .power, .temperature:
```

In `Wattly/Providers/FakeProvider.swift`:
```swift
// In FakeProviders.all:
case .cpu:    return CPUProvider()
case .gpu:    return GPUProvider()
case .memory: return MemoryProvider()
...
// In FakeProvider.makeSample:
case .gpu:
    let g = v("gpu")
    return .gpu(makeGPUSample(overall: g, coreCount: 10, activeGHz: 1.28))
...
// In bases:
case .gpu:
    return ["gpu": desktop ? Base(b: 24, step: 8, min: 2, max: 98) : Base(b: 36, step: 9, min: 4, max: 98)]
```

In `Wattly/Core/SystemMonitor.swift`:
```swift
// In static func scalar(of:from:):
case (.cpu, .cpu(let s)): return s.overall
case (.gpu, .gpu(let s)): return s.overall
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData -only-testing:WattlyTests/PollPolicyTests/gpuPollIntervals`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Wattly/Providers/GPUProvider.swift Wattly/Providers/FakeProvider.swift Wattly/Core/PollPolicy.swift Wattly/Core/SystemMonitor.swift WattlyTests/PollPolicyTests.swift
git commit -m "feat: add GPUProvider and wire into SystemMonitor and PollPolicy"
```

---

### Task 5: Card Presentation, MenuBar Text & Accessibility (`CardPresentation.swift`, `MenuBarText.swift`, `Accessibility.swift`)

**Files:**
- Modify: `Wattly/Core/CardPresentation.swift:70-185, 270-300`
- Modify: `Wattly/Core/MenuBarText.swift:15-65`
- Modify: `Wattly/Core/Accessibility.swift:65-75`
- Modify: `WattlyTests/CardPresentationTests.swift`
- Modify: `WattlyTests/MenuBarTextTests.swift`
- Modify: `WattlyTests/AccessibilityTests.swift`

**Interfaces:**
- Consumes: `GPUSample`, `CardKind.gpu`
- Produces: Presentation strings, unit text, sub-line text, threshold levels, accessibility labels for `.gpu`

- [ ] **Step 1: Write failing tests in `WattlyTests/CardPresentationTests.swift` and `WattlyTests/MenuBarTextTests.swift`**

In `WattlyTests/CardPresentationTests.swift`:
```swift
    @Test func gpuCardPresentation() {
        let sample = GPUSample(overall: 38.4, coreCount: 10, activeGHz: 1.28, cores: Array(repeating: 38.4, count: 10))
        let state = MetricState.value(.gpu(sample))
        #expect(CardPresentation.label(.gpu) == "GPU")
        #expect(CardPresentation.unitText(.gpu, state) == "%")
        #expect(CardPresentation.valueText(.gpu, state) == "38")
        #expect(CardPresentation.compactRowText(.gpu, state) == "38%")
        #expect(CardPresentation.subText(state) == "1.28 GHz")
    }
```

In `WattlyTests/MenuBarTextTests.swift`:
```swift
    @Test func gpuMenuBarText() {
        let sample = GPUSample(overall: 38.4, coreCount: 10, activeGHz: 1.28, cores: [])
        let text = MenuBarText.part(.gpu, .value(.gpu(sample)))
        #expect(text == "GPU 38%")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData -only-testing:WattlyTests/CardPresentationTests/gpuCardPresentation`
Expected: FAIL

- [ ] **Step 3: Implement presentation branches**

In `Wattly/Core/CardPresentation.swift`:
- `compactRowText`: `return (card == .cpu || card == .gpu) ? v + u : "\(v) \(u)"`
- `thresholdLevel`:
  ```swift
  case (.cpu, .cpu(let s)): return thresholds.cpu.level(s.overall)
  case (.gpu, .gpu(let s)): return thresholds.cpu.level(s.overall)
  ```
- `label`: `case .gpu: "GPU"`
- `unitText`: `case .cpu, .gpu: return "%"`
- `valueText`: `case (.gpu, .gpu(let s)): return String(Int(s.overall.rounded()))`
- `subText`:
  ```swift
  case .gpu(let s):
      guard let ghz = s.activeGHz else { return nil }
      return ghzText(ghz)
  ```
- `corePrefix`:
  ```swift
  static func corePrefix(_ levelName: String) -> String {
      if levelName.hasPrefix("G") || levelName == "Graphics" || levelName == "GPU" { return "G" }
      ...
  }
  ```

In `Wattly/Core/MenuBarText.swift`:
- `order`: `[.cpu, .gpu, .power, .battery, .mem, .cpuTemp, .gpuTemp, .batTemp, .fan]`
- `part`: `case (.gpu, .gpu(let s)): return "GPU \(Int(s.overall.rounded()))%"`
- `label`: `case .gpu: "GPU"`

In `Wattly/Core/Accessibility.swift`:
- `case .cpu, .gpu: return "\(v)%"`

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData -only-testing:WattlyTests/CardPresentationTests/gpuCardPresentation`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/CardPresentation.swift Wattly/Core/MenuBarText.swift Wattly/Core/Accessibility.swift WattlyTests/CardPresentationTests.swift WattlyTests/MenuBarTextTests.swift
git commit -m "feat: add CardPresentation and MenuBarText formatting for GPU card"
```

---

### Task 6: View Integration & Settings (`PopoverContentView`, `PollPolicyBridge`, `SettingsView`, `MenuBarLabel`, `CardExpandRegion`)

**Files:**
- Modify: `Wattly/Views/PopoverContentView.swift:70-80, 420-435`
- Modify: `Wattly/Views/PollPolicyBridge.swift:20-60, 62-80`
- Modify: `Wattly/Views/MenuBarLabel.swift:17-30, 78-95`
- Modify: `Wattly/Views/SettingsView.swift:100-130, 320-370, 800-830`
- Modify: `Wattly/Views/CardExpandRegion.swift:18-36, 68-93`

**Interfaces:**
- Consumes: `CardKind.gpu`, `GPUSample`, `StorageKey.show(.gpu)`, `StorageKey.menu(.gpu)`
- Produces: Complete UI integration for GPU card display, expand, settings toggle, and menubar label

- [ ] **Step 1: Update `PopoverContentView.swift` and `PollPolicyBridge.swift`**

In `Wattly/Views/PopoverContentView.swift`:
- Add `@AppStorage(StorageKey.show(.gpu)) private var showGPU = Defaults.show[.gpu] ?? true`
- In `isShown(_ card: CardKind) -> Bool`:
  ```swift
  case .gpu: showGPU
  ```

In `Wattly/Views/PollPolicyBridge.swift`:
- Add `@AppStorage(StorageKey.show(.gpu)) private var showGPU = Defaults.show[.gpu] ?? true`
- Add `@AppStorage(StorageKey.menu(.gpu)) private var menuGPU = Defaults.menuMetrics[.gpu] ?? false`
- In `recalculate()`:
  - Include `.gpu` in `shown` set if `showGPU` is true.
  - Include `.gpu` in `menu` set if `menuGPU` is true.

- [ ] **Step 2: Update `MenuBarLabel.swift` and `SettingsView.swift`**

In `Wattly/Views/MenuBarLabel.swift`:
- Add `@AppStorage(StorageKey.menu(.gpu)) private var menuGPU = Defaults.menuMetrics[.gpu] ?? false`
- In `selected` array builder:
  ```swift
  if menuGPU { items.append(.gpu) }
  ```

In `Wattly/Views/SettingsView.swift`:
- Add `@AppStorage(StorageKey.show(.gpu)) private var showGPU = Defaults.show[.gpu] ?? true`
- Add `@AppStorage(StorageKey.menu(.gpu)) private var menuGPU = Defaults.menuMetrics[.gpu] ?? false`
- In `isShown(_ card: CardKind) -> Bool`:
  ```swift
  case .gpu: showGPU
  ```
- In `showSection`: add `showToggle(.gpu, $showGPU)`
- In `menuChipGrid`: add `.gpu` chip option

- [ ] **Step 3: Add `gpuExpand` view to `CardExpandRegion.swift`**

In `Wattly/Views/CardExpandRegion.swift`:
```swift
    @ViewBuilder
    var body: some View {
        if card == .power, case .value(.power(let s)) = state {
            powerExpand(s)
        } else if card == .battery, case .value(.battery(let s)) = state {
            batteryExpand(s)
        } else if card == .cpu, case .value(.cpu(let s)) = state {
            cpuExpand(s)
        } else if card == .gpu, case .value(.gpu(let s)) = state {
            gpuExpand(s)
        } else if card == .mem, case .value(.memory(let s)) = state {
            memExpand(s)
        ...
```

Add `gpuExpand`:
```swift
    // MARK: GPU expand — per-core bars (mirrors CPU expand)

    private func gpuExpand(_ s: GPUSample) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text("Graphics")
                        .font(WattlyFont.at(11, weight: .bold))
                        .foregroundStyle(t.sub)
                    Spacer(minLength: 8)
                    if let ghz = s.activeGHz {
                        Text(CardPresentation.ghzText(ghz))
                            .font(WattlyFont.at(11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(t.faint)
                    }
                    Text("\(Int(s.overall.rounded()))%")
                        .font(WattlyFont.at(12, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Tokens.accent)
                }
                ForEach(Array(s.cores.enumerated()), id: \.offset) { ci, usage in
                    coreRow(label: "G\(ci)", usage: usage, accent: true)
                }
            }
        }
        .padding(.top, 8)
    }
```

- [ ] **Step 4: Build project to verify compilation across all views**

Run: `xcodebuild build -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Run full test suite**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData`
Expected: ALL TESTS PASS

- [ ] **Step 6: Commit**

```bash
git add Wattly/Views/PopoverContentView.swift Wattly/Views/PollPolicyBridge.swift Wattly/Views/MenuBarLabel.swift Wattly/Views/SettingsView.swift Wattly/Views/CardExpandRegion.swift
git commit -m "feat: complete GPU card UI, expand view, and settings integration"
```

---

## Verification Plan

### Automated Tests
- Run all unit tests:
  ```bash
  xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData
  ```
- Specific suites:
  - `WattlyTests/GPUUsageTests`
  - `WattlyTests/CardPresentationTests`
  - `WattlyTests/MenuBarTextTests`
  - `WattlyTests/PollPolicyTests`

### Manual Verification
- Launch Wattly with real GPU provider:
  - Verify `GPU` card displays live usage percentage (e.g. `12%`).
  - Verify active clock text (e.g. `1.28 GHz`) updates smoothly under graphics workload.
  - Click card chevron to expand: verify `Graphics` header, active clock, overall %, and `G0...G9` core bars animate in and match CPU card styling.
  - Test Settings view: toggle GPU card visibility and reorder in card list.
  - Test MenuBar: toggle GPU metric chip and verify text displays in macOS menu bar.
