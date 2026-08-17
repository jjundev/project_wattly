# Pulse Wave Motion & Amplitude Tuning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tune Pulse Wave menubar icon motion dynamics according to user settings (Min RPS: 0.50, Max RPS: 3.50, Linear curve, Target Watts: 25W for base fan models) and implement dynamic wave amplitude tiering so that low wattage (1W) and higher wattages (5W+) are immediately distinguishable by both speed and wave height.

**Architecture:** Update `KineticNotchMotion.swift` for `rpsMax = 3.50`, linear progression (`progress = clampedLoad / 100.0`), and base fan `targetWatts = 25.0`. Enhance `PulseWaveMark` in `Glyphs.swift` and `displayedFrame(style: .pulseWave, ...)` in `KineticNotchMotion.swift` to support 4 amplitude tiers ($s \times 0.16$ to $s \times 0.40$) across 24 frames ($4 \times 6$ subphases), preserving the fixed 24-frame caching architecture in `MenuBarGlyph.template`. Update unit tests in `WattlyTests/`.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Swift Testing (`Testing`), Xcodebuild

## Global Constraints

- Fixed frame count: `MenuBarIconStyle.pulseWave.frameCount` remains 24, divided into 4 tiers $\times$ 6 subphases for seamless caching in `MenuBarGlyph.template`.
- All tests must pass with `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData`.
- Preserve Reduce Motion accessibility support across all modified components.

---

### Task 1: Update Physical RPS, Speed Progression, and Target Watts

**Files:**
- Modify: `Wattly/Core/KineticNotchMotion.swift:57-65, 154-164`
- Modify: `WattlyTests/KineticNotchMotionTests.swift:36, 72-101`

**Interfaces:**
- Consumes: `KineticNotchSource.targetWatts`, `MenuBarIconMotion.revolutionsPerSecond(load:)`
- Produces: Updated physical RPS curve ($0.50 \to 3.50\text{ RPS}$, linear) and target wattage for base fan models ($25.0\text{W}$).

- [ ] **Step 1: Write the failing tests for updated RPS curve and target watts**

Update `WattlyTests/KineticNotchMotionTests.swift`:
```swift
    @Test func targetWatts_hardwareCoolingRules() {
        #expect(KineticNotchSource.targetWatts(gpuCores: 8, fanCount: 0) == 20.0)
        #expect(KineticNotchSource.targetWatts(gpuCores: 10, fanCount: 0) == 20.0)

        // Base fan model: 25.0W
        #expect(KineticNotchSource.targetWatts(gpuCores: 10, fanCount: 1) == 25.0)

        // Pro: 55.0W
        #expect(KineticNotchSource.targetWatts(gpuCores: 14, fanCount: 2) == 55.0)
        #expect(KineticNotchSource.targetWatts(gpuCores: 16, fanCount: 2) == 55.0)

        // Max: 100.0W
        #expect(KineticNotchSource.targetWatts(gpuCores: 24, fanCount: 2) == 100.0)
        #expect(KineticNotchSource.targetWatts(gpuCores: 32, fanCount: 2) == 100.0)

        // Ultra: 200.0W
        #expect(KineticNotchSource.targetWatts(gpuCores: 48, fanCount: 2) == 200.0)
        #expect(KineticNotchSource.targetWatts(gpuCores: 64, fanCount: 2) == 200.0)
    }

    @Test func physicalRevolutionsPerSecondIsStrictlyBoundToLoad() {
        #expect(MenuBarIconMotion.revolutionsPerSecond(load: 0.0) == 0.50)
        #expect(MenuBarIconMotion.revolutionsPerSecond(load: 100.0) == 3.50)
        // 25% load -> linear progression 0.25 -> 0.50 + 3.00 * 0.25 = 1.25
        #expect(abs(MenuBarIconMotion.revolutionsPerSecond(load: 25.0) - 1.25) < 1e-9)
    }

    @Test func smoothedRPS_physicalInertiaSmoothing() {
        #expect(abs(MenuBarIconMotion.smoothedRPS(current: 0.50, target: 3.50, dt: 0.25) - (0.50 + 3.00 * (1.0 - exp(-1.0)))) < 1e-9)
        #expect(MenuBarIconMotion.smoothedRPS(current: 0.50, target: 3.50, dt: 0) == 3.50)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing:WattlyTests/KineticNotchMotionTests`
Expected: FAIL due to previous constants (30.0W target watts, 2.50 max RPS, sqrt curve).

- [ ] **Step 3: Update `KineticNotchMotion.swift`**

In `Wattly/Core/KineticNotchMotion.swift`:
```swift
    static func targetWatts(gpuCores: Int?, fanCount: Int?, model: String? = nil) -> Double {
        if let fanCount, fanCount == 0 { return 20.0 }
        let cores = gpuCores ?? 8
        if cores >= 48 { return 200.0 } // Ultra
        if cores >= 24 { return 100.0 } // Max
        if cores >= 14 { return 55.0 }  // Pro
        // Base Pro / Mac mini (with fans) vs fallback
        return (fanCount ?? 0) > 0 ? 25.0 : 20.0
    }
```

And in `enum MenuBarIconMotion`:
```swift
    static let rpsMin = 0.50 // 1 rev per 2.0s at 0% idle load
    static let rpsMax = 3.50 // 1 rev per 0.29s at 100% full load

    /// Physical rotation speed in revolutions per second (RPS), solely determined by workload.
    static func revolutionsPerSecond(load: Double) -> Double {
        let clampedLoad = min(max(load, 0), 100)
        let progress = clampedLoad / 100.0
        return rpsMin + (rpsMax - rpsMin) * progress
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing:WattlyTests/KineticNotchMotionTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/KineticNotchMotion.swift WattlyTests/KineticNotchMotionTests.swift
git commit -m "perf(motion): tune physical RPS to 0.5-3.5 with linear curve and 25W base target"
```

---

### Task 2: Implement Dynamic Wave Amplitude Tiering for `PulseWaveMark`

**Files:**
- Modify: `Wattly/DesignSystem/Glyphs.swift:106-150`
- Modify: `Wattly/Core/KineticNotchMotion.swift:230-256`
- Modify: `WattlyTests/KineticNotchMotionTests.swift:169-185`
- Modify: `WattlyTests/GlyphsRenderingTests.swift:6-30`

**Interfaces:**
- Consumes: `MenuBarIconMotion.displayedFrame(style: .pulseWave, phase:load:reduceMotion:)`
- Produces: Tiered 24-frame sprite rendering in `PulseWaveMark` where low load ($<25\%$, Tier 0) renders gentle $0.16s$ amplitude wave, ramping up to $0.40s$ amplitude on heavy load ($>75\%$, Tier 3).

- [ ] **Step 1: Write failing tests for Pulse Wave workload tier dispatch and rendering**

In `WattlyTests/KineticNotchMotionTests.swift`:
```swift
    @Test func pulseWaveScalesTierWithLoad() {
        let lowFrame = MenuBarIconMotion.displayedFrame(style: .pulseWave, phase: 0.3, load: 10.0, reduceMotion: false)
        #expect(lowFrame >= 0 && lowFrame <= 5)

        let midLowFrame = MenuBarIconMotion.displayedFrame(style: .pulseWave, phase: 0.3, load: 35.0, reduceMotion: false)
        #expect(midLowFrame >= 6 && midLowFrame <= 11)

        let midHighFrame = MenuBarIconMotion.displayedFrame(style: .pulseWave, phase: 0.3, load: 60.0, reduceMotion: false)
        #expect(midHighFrame >= 12 && midHighFrame <= 17)

        let highFrame = MenuBarIconMotion.displayedFrame(style: .pulseWave, phase: 0.3, load: 95.0, reduceMotion: false)
        #expect(highFrame >= 18 && highFrame <= 23)
    }
```

In `WattlyTests/GlyphsRenderingTests.swift`:
```swift
    @Test @MainActor func pulseWaveMarkRendersAcrossAllTiers() {
        for frame in 0..<24 {
            let mark = PulseWaveMark(frame: frame, markerColor: .black)
            #expect(mark.frame == frame)
        }
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing:WattlyTests/KineticNotchMotionTests`
Expected: FAIL with `pulseWaveScalesTierWithLoad` failing.

- [ ] **Step 3: Implement tiered amplitude in `PulseWaveMark` and `displayedFrame`**

In `Wattly/Core/KineticNotchMotion.swift`:
```swift
        // Flowing Pulse Waveform scales wave amplitude across 4 workload tiers (4 tiers x 6 subphases)
        if style == .pulseWave {
            let clampedLoad = min(max(activeLoad, 0), 100)
            let tier = min(Int(clampedLoad / 25.0), 3) // Tier 0 (low) ~ Tier 3 (max load)
            let subPhase = Int(safePhase * 6.0) % 6
            return tier * 6 + subPhase
        }
```

In `Wattly/DesignSystem/Glyphs.swift`:
```swift
// 2. Flowing Pulse W Waveform Mark
struct PulseWaveMark: View {
    let frame: Int
    var markerColor: Color = Tokens.accent

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            let strokeW = max(1.5, s * 0.08)
            let centerY = s * 0.52

            // 4 Workload Tiers (6 subphases per tier = 24 frames total)
            let safeFrame = min(max(frame, 0), 23)
            let tier = safeFrame / 6
            let subPhase = safeFrame % 6
            let phase = Double(subPhase) / 6.0

            // Amplitude scales from gentle 0.16s (Tier 0: idle/1W) to vigorous 0.40s (Tier 3: 100% load)
            let amp = s * (0.16 + Double(tier) * 0.08)

            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: s * 0.08, y: centerY))
                    p.addLine(to: CGPoint(x: s * 0.92, y: centerY))
                }
                .stroke(style: StrokeStyle(lineWidth: strokeW * 0.5, dash: [2, 2]))
                .opacity(0.25)

                Path { p in
                    let steps = 24
                    for i in 0...steps {
                        let progress = Double(i) / Double(steps)
                        let x = progress * s
                        let envelope = sin(progress * .pi)
                        let wave = sin(progress * .pi * 2.5 - phase * .pi * 2.0)
                        let y = centerY - (wave * envelope * amp)
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round))

                Circle()
                    .fill(markerColor)
                    .frame(width: strokeW * 2.2, height: strokeW * 2.2)
                    .position(
                        x: s * 0.5 + sin(phase * .pi * 2.0) * s * 0.35,
                        y: centerY - cos(phase * .pi * 2.0) * (amp * 0.75)
                    )
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData`
Expected: PASS for all tests across the entire test suite.

- [ ] **Step 5: Commit**

```bash
git add Wattly/DesignSystem/Glyphs.swift Wattly/Core/KineticNotchMotion.swift WattlyTests/KineticNotchMotionTests.swift WattlyTests/GlyphsRenderingTests.swift
git commit -m "feat(pulseWave): add dynamic wave amplitude tiering across power loads"
```
