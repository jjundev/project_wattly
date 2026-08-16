# GPU Engine & VRAM View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor the GPU card's expand region from duplicate G0...Gn core bars into distinct, real-time GPU engine & memory pipeline bars (**Renderer**, **Tiler**, and **VRAM**), leveraging the distinct hardware statistics already exposed by macOS `IOAccelerator`.

**Architecture:** Update `GPUSample` to carry real-time `rendererUsage`, `tilerUsage`, `inUseMemoryBytes`, and `allocMemoryBytes`. Update `GPUProvider` to parse these fields from `IOAccelerator`'s `PerformanceStatistics`. Update `CardExpandRegion`'s `gpuExpand` to render the headline GPU cluster summary followed by three dedicated metric rows: Renderer (3D shading/pixel load), Tiler (geometry/rasterizing load), and VRAM (in-use vs allocated memory bar), matching Wattly's design tokens and Pretendard typography while preserving `coreRow` for the CPU card.

**Tech Stack:** Swift 6.0, Swift Testing (`Testing`, `@Test`, `#expect`), SwiftUI, AppKit, IOKit / IORegistry.

## Global Constraints

- **Platform:** macOS 14.0+ (Apple Silicon arm64 only).
- **Language Mode:** Swift 6 with strict concurrency (`Sendable` value types across actor boundaries).
- **Testing Framework:** Swift Testing (`import Testing`, `@Test`, `#expect(...)`, `struct SuiteName`), matching the rest of `WattlyTests`.
- **Design System:** Pixel-matched typography (`Pretendard`, `WattlyFont.at`), spacing (`10` / `9`), and tokens (`Tokens.accent`, `t.sparkFill`, `t.faint`, `t.sub`, `t.text`).
- **Zero Placeholders:** Full, working code and tests in every task.
- **TDD:** Pure derivations and formatting logic covered by unit tests.

---

### Task 1: Model, Pure Derivation & Call-site Updates (`MetricSample.swift`, `GPUUsage.swift`, `GPUUsageTests.swift`, `CardPresentationTests.swift`, `AccessibilityTests.swift`, `MenuBarTextTests.swift`, `GPUProviderTests.swift`)

**Files:**
- Modify: `Wattly/Models/MetricSample.swift:25-36`
- Modify: `Wattly/Core/GPUUsage.swift:1-20`
- Modify: `WattlyTests/GPUUsageTests.swift`
- Modify: `WattlyTests/CardPresentationTests.swift:26-55, 440-460`
- Modify: `WattlyTests/AccessibilityTests.swift:56-65, 110-120`
- Modify: `WattlyTests/MenuBarTextTests.swift:25-35, 150-165`
- Modify: `WattlyTests/GPUProviderTests.swift:15-30`

**Interfaces:**
- Consumes: None
- Produces:
  - Updated `struct GPUSample`:
    ```swift
    struct GPUSample: Sendable, Equatable {
        var overall: Double
        var coreCount: Int
        var activeGHz: Double?
        var rendererUsage: Double
        var tilerUsage: Double
        var inUseMemoryBytes: UInt64
        var allocMemoryBytes: UInt64
    }
    ```
  - Updated `makeGPUSample`:
    ```swift
    func makeGPUSample(overall: Double,
                       rendererUsage: Double = 0,
                       tilerUsage: Double = 0,
                       inUseMemoryBytes: UInt64 = 0,
                       allocMemoryBytes: UInt64 = 0,
                       coreCount: Int,
                       activeGHz: Double?) -> GPUSample
    ```

- [ ] **Step 1: Write the failing tests in `WattlyTests/GPUUsageTests.swift`**

Update `WattlyTests/GPUUsageTests.swift`:
```swift
import Testing
@testable import Wattly

struct GPUUsageTests {
    @Test func makeGPUSampleClampsAndPreservesEngineMetrics() {
        let sample = makeGPUSample(overall: 42.6,
                                   rendererUsage: 45.0,
                                   tilerUsage: 20.0,
                                   inUseMemoryBytes: 858 * 1024 * 1024,
                                   allocMemoryBytes: 2048 * 1024 * 1024,
                                   coreCount: 10,
                                   activeGHz: 1.28)
        #expect(abs(sample.overall - 42.6) < 1e-4)
        #expect(abs(sample.rendererUsage - 45.0) < 1e-4)
        #expect(abs(sample.tilerUsage - 20.0) < 1e-4)
        #expect(sample.inUseMemoryBytes == 858 * 1024 * 1024)
        #expect(sample.allocMemoryBytes == 2048 * 1024 * 1024)
        #expect(sample.coreCount == 10)
        #expect(sample.activeGHz == 1.28)
    }

    @Test func makeGPUSampleClampsBounds() {
        let low = makeGPUSample(overall: -5.0,
                                rendererUsage: -10.0,
                                tilerUsage: -2.0,
                                inUseMemoryBytes: 0,
                                allocMemoryBytes: 0,
                                coreCount: 8,
                                activeGHz: nil)
        #expect(low.overall == 0.0)
        #expect(low.rendererUsage == 0.0)
        #expect(low.tilerUsage == 0.0)

        let high = makeGPUSample(overall: 120.0,
                                 rendererUsage: 110.0,
                                 tilerUsage: 105.0,
                                 inUseMemoryBytes: 100,
                                 allocMemoryBytes: 100,
                                 coreCount: 8,
                                 activeGHz: nil)
        #expect(high.overall == 100.0)
        #expect(high.rendererUsage == 100.0)
        #expect(high.tilerUsage == 100.0)
    }

    @Test func makeGPUSampleFallbackZeroCoreCount() {
        let sample = makeGPUSample(overall: 50.0,
                                   rendererUsage: 50.0,
                                   tilerUsage: 25.0,
                                   inUseMemoryBytes: 0,
                                   allocMemoryBytes: 0,
                                   coreCount: 0,
                                   activeGHz: nil)
        #expect(sample.coreCount == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData -only-testing:WattlyTests/GPUUsageTests`
Expected: FAIL (extra arguments in `makeGPUSample` call)

- [ ] **Step 3: Update `MetricSample.swift`, `GPUUsage.swift`, and all test/view call-sites**

In `Wattly/Models/MetricSample.swift`:
```swift
struct GPUSample: Sendable, Equatable {
    /// Overall GPU usage, 0–100.
    var overall: Double
    /// Total physical GPU core count from `gpu-core-count` (e.g. 10).
    var coreCount: Int
    /// Real-time active clock in GHz from DVFS residency, or nil when unavailable.
    var activeGHz: Double? = nil
    /// Renderer engine utilization (3D shading, pixel pipeline), 0–100.
    var rendererUsage: Double = 0
    /// Tiler engine utilization (geometry, scene splitting, rasterizing), 0–100.
    var tilerUsage: Double = 0
    /// In-use GPU video memory in bytes (`In use system memory`).
    var inUseMemoryBytes: UInt64 = 0
    /// Total allocated GPU video memory in bytes (`Alloc system memory`).
    var allocMemoryBytes: UInt64 = 0
}
```

In `Wattly/Core/GPUUsage.swift`:
```swift
import Foundation

/// Pure GPU-sample derivation: clamps percentages and binds engine metrics into a Sendable GPUSample.
/// Fully deterministic under synthetic input.
func makeGPUSample(overall: Double,
                   rendererUsage: Double = 0,
                   tilerUsage: Double = 0,
                   inUseMemoryBytes: UInt64 = 0,
                   allocMemoryBytes: UInt64 = 0,
                   coreCount: Int,
                   activeGHz: Double?) -> GPUSample {
    let clampedOverall = min(100.0, max(0.0, overall))
    let clampedRenderer = min(100.0, max(0.0, rendererUsage))
    let clampedTiler = min(100.0, max(0.0, tilerUsage))
    return GPUSample(
        overall: clampedOverall,
        coreCount: max(1, coreCount),
        activeGHz: activeGHz,
        rendererUsage: clampedRenderer,
        tilerUsage: clampedTiler,
        inUseMemoryBytes: inUseMemoryBytes,
        allocMemoryBytes: allocMemoryBytes
    )
}
```

In `WattlyTests/CardPresentationTests.swift`, `WattlyTests/AccessibilityTests.swift`, `WattlyTests/MenuBarTextTests.swift`, `WattlyTests/GPUProviderTests.swift`, and `Wattly/Views/CardExpandRegion.swift`:
Update `GPUSample` initialization call sites (removing obsolete `cores:` argument).

- [ ] **Step 4: Run tests to verify all suites pass**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData`
Expected: ALL TESTS PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Models/MetricSample.swift Wattly/Core/GPUUsage.swift Wattly/Views/CardExpandRegion.swift WattlyTests/
git commit -m "feat: expand GPUSample with renderer, tiler, and VRAM memory fields"
```

---

### Task 2: Hardware & Fake Provider Updates (`GPUProvider.swift`, `FakeProvider.swift`, `GPUProviderTests.swift`)

**Files:**
- Modify: `Wattly/Providers/GPUProvider.swift:15-80`
- Modify: `Wattly/Providers/FakeProvider.swift:145-160`
- Modify: `WattlyTests/GPUProviderTests.swift:15-40`

**Interfaces:**
- Consumes: `makeGPUSample`, `IOAccelerator` `PerformanceStatistics`
- Produces: `struct GPUStatsSnapshot: Sendable` parsing from IORegistry and populating full `GPUSample`

- [ ] **Step 1: Write failing test in `WattlyTests/GPUProviderTests.swift`**

Update `WattlyTests/GPUProviderTests.swift`:
```swift
    @Test func gpuProviderPopulatesEngineAndMemoryMetrics() async {
        let fake = FakeProvider(kind: .gpu, scenario: .laptop)
        let reading = await fake.read(at: .now)
        if case .value(.gpu(let sample)) = reading {
            #expect(sample.overall >= 0)
            #expect(sample.rendererUsage >= 0)
            #expect(sample.tilerUsage >= 0)
            #expect(sample.inUseMemoryBytes > 0)
            #expect(sample.allocMemoryBytes >= sample.inUseMemoryBytes)
            #expect(sample.coreCount > 0)
        } else {
            Issue.record("Expected .value(.gpu) from FakeProvider")
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData -only-testing:WattlyTests/GPUProviderTests/gpuProviderPopulatesEngineAndMemoryMetrics`
Expected: FAIL (in-use memory bytes not yet populated)

- [ ] **Step 3: Update `GPUProvider.swift` and `FakeProvider.swift`**

In `Wattly/Providers/GPUProvider.swift`:
```swift
struct GPUStatsSnapshot: Sendable {
    var deviceUtilization: Double
    var rendererUtilization: Double
    var tilerUtilization: Double
    var inUseMemoryBytes: UInt64
    var allocMemoryBytes: UInt64
}

actor GPUProvider: MetricProvider {
    let kind: ProviderKind = .gpu

    private var coreCount: Int?
    private var clockSetupAttempted = false
    private var clock: RealGPUClock?

    func read(at instant: ContinuousClock.Instant) async -> ProviderReading {
        if coreCount == nil { coreCount = Self.readCoreCount() }
        if !clockSetupAttempted { clockSetupAttempted = true; clock = RealGPUClock() }

        guard let stats = Self.readPerformanceStatistics() else {
            return .unavailable(.providerError("GPU 사용률을 읽을 수 없음"))
        }

        let ghz = clock?.sampleGHz()
        let sample = makeGPUSample(
            overall: stats.deviceUtilization,
            rendererUsage: stats.rendererUtilization,
            tilerUsage: stats.tilerUtilization,
            inUseMemoryBytes: stats.inUseMemoryBytes,
            allocMemoryBytes: stats.allocMemoryBytes,
            coreCount: coreCount ?? 8,
            activeGHz: ghz
        )
        return .value(.gpu(sample))
    }

    private static func readPerformanceStatistics() -> GPUStatsSnapshot? {
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
               let devUtil = dict["Device Utilization %"] as? Int {
                let rendUtil = dict["Renderer Utilization %"] as? Int ?? devUtil
                let tileUtil = dict["Tiler Utilization %"] as? Int ?? 0
                let inUseMem = (dict["In use system memory"] as? NSNumber)?.uint64Value ?? 0
                let allocMem = (dict["Alloc system memory"] as? NSNumber)?.uint64Value ?? inUseMem
                return GPUStatsSnapshot(
                    deviceUtilization: Double(devUtil),
                    rendererUtilization: Double(rendUtil),
                    tilerUtilization: Double(tileUtil),
                    inUseMemoryBytes: inUseMem,
                    allocMemoryBytes: allocMem
                )
            }
        }
        return nil
    }
...
```

In `Wattly/Providers/FakeProvider.swift`:
```swift
        case .gpu:
            let g = v("gpu")
            return .gpu(makeGPUSample(
                overall: g,
                rendererUsage: g * 0.9,
                tilerUsage: g * 0.35,
                inUseMemoryBytes: 858 * 1024 * 1024,
                allocMemoryBytes: 2048 * 1024 * 1024,
                coreCount: 10,
                activeGHz: 1.28
            ))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData -only-testing:WattlyTests/GPUProviderTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Providers/GPUProvider.swift Wattly/Providers/FakeProvider.swift WattlyTests/GPUProviderTests.swift
git commit -m "feat: read renderer, tiler, and VRAM stats from IOAccelerator PerformanceStatistics"
```

---

### Task 3: Presentation Helpers & Card Expand Region UI (`CardPresentation.swift`, `CardExpandRegion.swift`, `CardPresentationTests.swift`)

**Files:**
- Modify: `Wattly/Core/CardPresentation.swift:280-330`
- Modify: `Wattly/Views/CardExpandRegion.swift:52-110`
- Modify: `WattlyTests/CardPresentationTests.swift:150-180`

**Interfaces:**
- Consumes: `GPUSample`, `Tokens`, `WattlyFont`
- Produces:
  - `CardPresentation.mbText(_ bytes: UInt64) -> String`
  - `CardPresentation.gpuMemoryFraction(inUse: UInt64, alloc: UInt64) -> Double`
  - `gpuExpand(_ s: GPUSample) -> some View` in `CardExpandRegion` (with `coreRow` preserved for CPU card)

- [ ] **Step 1: Write failing test in `WattlyTests/CardPresentationTests.swift`**

Add to `WattlyTests/CardPresentationTests.swift`:
```swift
    @Test func gpuMemoryFormatting() {
        #expect(CardPresentation.mbText(0) == "0 MB")
        #expect(CardPresentation.mbText(858 * 1024 * 1024) == "858 MB")
        #expect(CardPresentation.mbText(2048 * 1024 * 1024) == "2.0 GB")
        
        let inUse: UInt64 = 858 * 1024 * 1024
        let alloc: UInt64 = 2048 * 1024 * 1024
        let frac = CardPresentation.gpuMemoryFraction(inUse: inUse, alloc: alloc)
        #expect(abs(frac - (858.0 / 2048.0)) < 1e-4)
        #expect(CardPresentation.gpuMemoryFraction(inUse: 100, alloc: 0) == 0.0)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData -only-testing:WattlyTests/CardPresentationTests/gpuMemoryFormatting`
Expected: FAIL (missing `mbText` or `gpuMemoryFraction`)

- [ ] **Step 3: Implement helpers in `CardPresentation.swift`**

In `Wattly/Core/CardPresentation.swift`:
```swift
    /// Format bytes to "X MB" (or "X.X GB" if >= 1 GB).
    static func mbText(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576.0
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024.0)
        }
        return "\(Int(mb.rounded())) MB"
    }

    /// Calculate fraction of in-use memory against allocated memory, clamped 0...1.
    static func gpuMemoryFraction(inUse: UInt64, alloc: UInt64) -> Double {
        guard alloc > 0 else { return 0 }
        return min(1.0, max(0.0, Double(inUse) / Double(alloc)))
    }
```

- [ ] **Step 4: Update `CardExpandRegion.swift` (`gpuExpand`)**

In `Wattly/Views/CardExpandRegion.swift`:
*(Note: Retain `coreRow` method intact as it is required by `cpuExpand`)*
```swift
    // MARK: GPU expand — Renderer, Tiler, and VRAM pipeline bars

    private func gpuExpand(_ s: GPUSample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(s.coreCount)-Core GPU")
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
            
            gpuEngineRow(label: "렌더러", usage: s.rendererUsage, accent: true)
            gpuEngineRow(label: "타일러", usage: s.tilerUsage, accent: false)
            gpuMemoryRow(label: "VRAM", inUse: s.inUseMemoryBytes, alloc: s.allocMemoryBytes)
        }
        .padding(.top, 8)
    }

    private func gpuEngineRow(label: String, usage: Double, accent: Bool) -> some View {
        HStack(spacing: 9) {
            Text(label)
                .font(WattlyFont.at(10.5, weight: .semibold))
                .foregroundStyle(t.faint)
                .frame(width: 44, alignment: .leading)
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
                .frame(width: 32, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(Int(usage.rounded())) 퍼센트")
    }

    private func gpuMemoryRow(label: String, inUse: UInt64, alloc: UInt64) -> some View {
        let frac = CardPresentation.gpuMemoryFraction(inUse: inUse, alloc: alloc)
        let text = CardPresentation.mbText(inUse)
        return HStack(spacing: 9) {
            Text(label)
                .font(WattlyFont.at(10.5, weight: .semibold))
                .foregroundStyle(t.faint)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(t.sparkFill)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(t.spark)
                        .frame(width: geo.size.width * frac)
                }
            }
            .frame(height: 6)
            Text(text)
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.sub)
                .frame(width: 58, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(text)")
    }
```

- [ ] **Step 5: Run all unit tests**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData`
Expected: ALL TESTS PASS

- [ ] **Step 6: Commit**

```bash
git add Wattly/Core/CardPresentation.swift Wattly/Views/CardExpandRegion.swift WattlyTests/CardPresentationTests.swift
git commit -m "feat: render distinct Renderer, Tiler, and VRAM bars in GPU expand view"
```

---

## Verification Plan

### Automated Tests
- Run all unit tests:
  ```bash
  xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData
  ```
- Focus suites:
  - `WattlyTests/GPUUsageTests`
  - `WattlyTests/GPUProviderTests`
  - `WattlyTests/CardPresentationTests`

### Manual Verification
- Launch Wattly and click GPU card chevron:
  - Verify **10-Core GPU** (or hardware core count) and live **1.28 GHz** display in header.
  - Verify **렌더러 (Renderer)** and **타일러 (Tiler)** bars show independent, dynamic usage percentages.
  - Verify **VRAM** row shows active memory usage (e.g. `858 MB` or `1.2 GB`) with proportional gauge bar.
