# 메뉴바 동적 아이콘 부하 원본(Load Sources) 및 연속 모션 모델 구현 계획서

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 메뉴바 동적 아이콘의 애니메이션 부하 원본을 "전력 소비(기본값)", "CPU 클럭", "CPU+GPU 종합 부하" 3종으로 전면 개편하고, 맥북에어/프로 쿨링 폼팩터별 지속 TDP 반영 및 0W부터 연속 동작하는 모션 모델을 구현합니다.

**Architecture:** 순수 연산 로직(`KineticNotchMotion.swift`의 `KineticNotchSource` 및 `MenuBarIconMotion`)에서 하드웨어 폼팩터별 정규화($W_{\text{target}}$)와 연속 전달 함수를 처리하며, `MenuBarLabel`과 `SettingsMenuBarSection`이 `SystemMonitor`의 live card state(`power`, `cpu.activeGHz`, `cpu/gpu overall`)를 안전하게 추출하여 바인딩합니다.

**Tech Stack:** Swift 6 (Strict Concurrency), SwiftUI, Swift Testing (`Testing`), AppKit

## Global Constraints
- Swift 6 strict concurrency 준수 (`Sendable`, 액터 격리 보장).
- 하드웨어 I/O 없이 순수 함수(`KineticNotchSource`, `MenuBarIconMotion`)는 100% 독립 단위 테스트 가능해야 함.
- 0% 부하(Idle) 상태에서도 애니메이션이 멈추지 않고 최저 FPS(6~12 fps)로 우아하게 지속 회전.
- 기존 설정과의 호환성 및 기본값은 `KineticNotchSource.power` (전력 소비).

---

### Task 1: `KineticNotchSource` 3종 소스 개편 및 `MenuBarIconMotion` 연속 프레임레이트 모델 (Core)

**Files:**
- Modify: `Wattly/Core/KineticNotchMotion.swift`
- Test: `WattlyTests/KineticNotchMotionTests.swift`

**Interfaces:**
- Produces:
  - `enum KineticNotchSource: String, CaseIterable, Identifiable, Sendable` (`case power, cpuClock, compute`)
  - `KineticNotchSource.targetWatts(gpuCores: Int?, fanCount: Int?, model: String?) -> Double`
  - `KineticNotchSource.normalizePower(watts: Double, targetWatts: Double) -> Double`
  - `KineticNotchSource.normalizeCPUClock(activeGHz: Double, baseGHz: Double, maxGHz: Double) -> Double`
  - `KineticNotchSource.normalizeCompute(cpu: Double?, gpu: Double?) -> Double?`
  - `KineticNotchSource.load(power: Double?, cpuClockGHz: Double?, cpu: Double?, gpu: Double?, gpuCores: Int?, fanCount: Int?) -> Double?`
  - `MenuBarIconMotion.frameRate(load: Double, speed: KineticNotchSpeed) -> Double` (항상 0W/0%에서도 minimumFrameRate 반환)

- [ ] **Step 1: Write the failing tests in `KineticNotchMotionTests.swift`**

```swift
import Testing
@testable import Wattly

struct KineticNotchMotionTests {
    @Test func sourceRequirementsAndLabels() {
        #expect(KineticNotchSource.power.requiredCards == [.power])
        #expect(KineticNotchSource.cpuClock.requiredCards == [.cpu])
        #expect(KineticNotchSource.compute.requiredCards == [.cpu, .gpu])

        #expect(KineticNotchSource.power.label == "전력 소비")
        #expect(KineticNotchSource.cpuClock.label == "CPU 클럭")
        #expect(KineticNotchSource.compute.label == "CPU + GPU")
    }

    @Test func targetWattsByFormFactor() {
        // MacBook Air (fanCount == 0) -> 20W
        #expect(KineticNotchSource.targetWatts(gpuCores: 8, fanCount: 0) == 20.0)
        #expect(KineticNotchSource.targetWatts(gpuCores: 10, fanCount: 0) == 20.0)

        // Base MacBook Pro / Mac mini (fanCount >= 1, gpuCores <= 10) -> 30W
        #expect(KineticNotchSource.targetWatts(gpuCores: 10, fanCount: 1) == 30.0)

        // Pro chip (gpuCores 14~20) -> 55W
        #expect(KineticNotchSource.targetWatts(gpuCores: 16, fanCount: 2) == 55.0)

        // Max chip (gpuCores 24~40) -> 100W
        #expect(KineticNotchSource.targetWatts(gpuCores: 32, fanCount: 2) == 100.0)

        // Ultra chip (gpuCores >= 48) -> 200W
        #expect(KineticNotchSource.targetWatts(gpuCores: 64, fanCount: 2) == 200.0)
    }

    @Test func powerLoadNormalization() {
        let airTarget = 20.0
        #expect(KineticNotchSource.power.load(power: 0.0, gpuCores: 8, fanCount: 0) == 0.0)
        #expect(KineticNotchSource.power.load(power: 10.0, gpuCores: 8, fanCount: 0) == 50.0)
        #expect(KineticNotchSource.power.load(power: 20.0, gpuCores: 8, fanCount: 0) == 100.0)
        #expect(KineticNotchSource.power.load(power: 35.0, gpuCores: 8, fanCount: 0) == 100.0) // clamped
        #expect(KineticNotchSource.power.load(power: .nan, gpuCores: 8, fanCount: 0) == nil)
    }

    @Test func cpuClockLoadNormalization() {
        #expect(KineticNotchSource.cpuClock.load(cpuClockGHz: 0.8) == 0.0)
        #expect(KineticNotchSource.cpuClock.load(cpuClockGHz: 2.4) == 50.0)
        #expect(KineticNotchSource.cpuClock.load(cpuClockGHz: 4.0) == 100.0)
        #expect(KineticNotchSource.cpuClock.load(cpuClockGHz: 4.5) == 100.0) // clamped
        #expect(KineticNotchSource.cpuClock.load(cpuClockGHz: .nan) == nil)
    }

    @Test func computeLoadNormalization() {
        #expect(KineticNotchSource.compute.load(cpu: 20, gpu: 80) == 50.0)
        #expect(KineticNotchSource.compute.load(cpu: 0, gpu: 0) == 0.0)
        #expect(KineticNotchSource.compute.load(cpu: 100, gpu: 100) == 100.0)
        #expect(KineticNotchSource.compute.load(cpu: 40, gpu: nil) == nil)
    }

    @Test func continuousFrameRateWithoutHardThreshold() {
        // At 0% load, returns exactly minimumFrameRate (continuous alive motion)
        #expect(MenuBarIconMotion.frameRate(load: 0, speed: .eco) == 6.0)
        #expect(MenuBarIconMotion.frameRate(load: 0, speed: .standard) == 8.0)
        #expect(MenuBarIconMotion.frameRate(load: 0, speed: .responsive) == 12.0)

        // At 100% load, returns maximumFrameRate
        #expect(MenuBarIconMotion.frameRate(load: 100, speed: .eco) == 36.0)
        #expect(MenuBarIconMotion.frameRate(load: 100, speed: .standard) == 48.0)
        #expect(MenuBarIconMotion.frameRate(load: 100, speed: .responsive) == 60.0)

        // At 25% load, square root interpolation gives 50% of the speed range
        #expect(abs(MenuBarIconMotion.frameRate(load: 25, speed: .eco) - 21.0) < 1e-9)
        #expect(abs(MenuBarIconMotion.frameRate(load: 25, speed: .standard) - 28.0) < 1e-9)
        #expect(abs(MenuBarIconMotion.frameRate(load: 25, speed: .responsive) - 36.0) < 1e-9)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter KineticNotchMotionTests`
Expected: FAIL due to missing enum cases and signature changes.

- [ ] **Step 3: Implement `KineticNotchMotion.swift`**

Update `KineticNotchSource` and `MenuBarIconMotion.frameRate(load:speed:)` in `Wattly/Core/KineticNotchMotion.swift`:

```swift
import Foundation

enum KineticNotchSource: String, CaseIterable, Identifiable, Sendable {
    case power
    case cpuClock
    case compute

    var id: String { rawValue }

    var label: String {
        switch self {
        case .power: "전력 소비"
        case .cpuClock: "CPU 클럭"
        case .compute: "CPU + GPU"
        }
    }

    var requiredCards: Set<CardKind> {
        switch self {
        case .power: [.power]
        case .cpuClock: [.cpu]
        case .compute: [.cpu, .gpu]
        }
    }

    static func targetWatts(gpuCores: Int?, fanCount: Int?, model: String? = nil) -> Double {
        if let fanCount, fanCount == 0 { return 20.0 }
        let cores = gpuCores ?? 8
        if cores >= 48 { return 200.0 }
        if cores >= 24 { return 100.0 }
        if cores >= 14 { return 55.0 }
        return (fanCount ?? 0) > 0 ? 30.0 : 20.0
    }

    static func normalizePower(watts: Double, targetWatts: Double) -> Double {
        guard watts.isFinite else { return 0 }
        return min(max(watts / targetWatts * 100.0, 0), 100.0)
    }

    static func normalizeCPUClock(activeGHz: Double, baseGHz: Double = 0.8, maxGHz: Double = 4.0) -> Double {
        guard activeGHz.isFinite else { return 0 }
        guard maxGHz > baseGHz else { return 0 }
        return min(max((activeGHz - baseGHz) / (maxGHz - baseGHz) * 100.0, 0), 100.0)
    }

    static func normalizeCompute(cpu: Double?, gpu: Double?) -> Double? {
        func valid(_ value: Double?) -> Double? {
            guard let value, value.isFinite else { return nil }
            return min(max(value, 0), 100)
        }
        guard let c = valid(cpu), let g = valid(gpu) else { return nil }
        return (c + g) / 2.0
    }

    func load(power: Double? = nil,
              cpuClockGHz: Double? = nil,
              cpu: Double? = nil,
              gpu: Double? = nil,
              gpuCores: Int? = nil,
              fanCount: Int? = nil) -> Double? {
        switch self {
        case .power:
            guard let power, power.isFinite else { return nil }
            let target = Self.targetWatts(gpuCores: gpuCores, fanCount: fanCount)
            return Self.normalizePower(watts: power, targetWatts: target)
        case .cpuClock:
            guard let cpuClockGHz, cpuClockGHz.isFinite else { return nil }
            return Self.normalizeCPUClock(activeGHz: cpuClockGHz)
        case .compute:
            return Self.normalizeCompute(cpu: cpu, gpu: gpu)
        }
    }
}

enum KineticNotchSpeed: String, CaseIterable, Identifiable, Sendable {
    case eco, standard, responsive
    var id: String { rawValue }
    var label: String {
        switch self { case .eco: "절전"; case .standard: "표준"; case .responsive: "민감" }
    }
    var minimumFrameRate: Double {
        switch self { case .eco: 6.0; case .standard: 8.0; case .responsive: 12.0 }
    }
    var maximumFrameRate: Double {
        switch self { case .eco: 36.0; case .standard: 48.0; case .responsive: 60.0 }
    }
    var description: String {
        switch self {
        case .eco: "낮은 전력으로 부하에 따라 6~36 fps로 부드럽게 움직입니다."
        case .standard: "균형 잡힌 반응으로 부하에 따라 8~48 fps로 매끄럽게 움직입니다."
        case .responsive: "부하 변화에 민감하게 12~60 fps의 고주사율로 움직입니다."
        }
    }
}

enum MenuBarIconMotion {
    static func displayedFrame(style: MenuBarIconStyle, phase: Int, load: Double? = nil, reduceMotion: Bool) -> Int {
        guard !reduceMotion else { return style.staticFrame }
        let count = style.frameCount

        if style == .vuMeter, let load {
            let clampedLoad = min(max(load, 0), 100)
            let baseIndex = (clampedLoad / 100.0) * Double(count - 1)
            let jitter = sin(Double(phase) * 0.8) * (0.5 + (clampedLoad / 100.0) * 1.5)
            let target = Int(round(baseIndex + jitter))
            return min(max(target, 0), count - 1)
        }

        if style == .equalizer, let load {
            let clampedLoad = min(max(load, 0), 100)
            let tier = min(Int(clampedLoad / 25.0), 3)
            let subPhase = ((phase % 6) + 6) % 6
            return tier * 6 + subPhase
        }

        return ((phase % count) + count) % count
    }

    static func displayedFrame(style: MenuBarIconStyle, phase: Int, reduceMotion: Bool) -> Int {
        displayedFrame(style: style, phase: phase, load: nil, reduceMotion: reduceMotion)
    }

    static func phaseDelayMultiplier(style: MenuBarIconStyle, phase: Int) -> Double {
        switch style {
        case .equalizer:
            return 1.8
        default:
            return 1.0
        }
    }

    static func frameDelay(style: MenuBarIconStyle, phase: Int, frameRate: Double) -> TimeInterval {
        (1.0 / frameRate) * phaseDelayMultiplier(style: style, phase: phase)
    }

    static func frameRate(load: Double, speed: KineticNotchSpeed) -> Double {
        let clampedLoad = min(max(load, 0), 100)
        let progress = sqrt(clampedLoad / 100.0)
        return speed.minimumFrameRate + (speed.maximumFrameRate - speed.minimumFrameRate) * progress
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter KineticNotchMotionTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/KineticNotchMotion.swift WattlyTests/KineticNotchMotionTests.swift
git commit -m "feat(menubar): redesign KineticNotchSource and continuous motion transfer function"
```

---

### Task 2: `Settings` 기본값 및 설정 리셋 갱신

**Files:**
- Modify: `Wattly/Settings/Settings.swift:292`
- Modify: `Wattly/Core/SettingsReset.swift:23`
- Modify: `WattlyTests/SettingsResetTests.swift`

- [ ] **Step 1: Write failing test in `SettingsResetTests.swift`**

Verify `Defaults.kineticNotchSource == .power` and that reset restores `.power`.

```swift
@Test func resetRestoresKineticNotchDefaults() {
    let d = UserDefaults(suiteName: #function)!
    d.set(KineticNotchSource.compute.rawValue, forKey: StorageKey.kineticNotchSource)
    SettingsReset.resetAll(defaults: d)
    #expect(d.string(forKey: StorageKey.kineticNotchSource) == KineticNotchSource.power.rawValue)
}
```

- [ ] **Step 2: Run test to verify failure**

Run: `swift test --filter SettingsResetTests`
Expected: FAIL

- [ ] **Step 3: Update `Settings.swift` & `SettingsReset.swift`**

In `Wattly/Settings/Settings.swift`:
```swift
static let kineticNotchSource = KineticNotchSource.power
```

- [ ] **Step 4: Run test to verify pass**

Run: `swift test --filter SettingsResetTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Settings/Settings.swift Wattly/Core/SettingsReset.swift WattlyTests/SettingsResetTests.swift
git commit -m "feat(settings): set default kinetic notch source to power"
```

---

### Task 3: `MenuBarLabel` 및 `SettingsMenuBarSection` UI 뷰 연동

**Files:**
- Modify: `Wattly/Views/MenuBarLabel.swift`
- Modify: `Wattly/Views/Settings/SettingsMenuBarSection.swift`
- Modify: `Wattly/Views/PollPolicyBridge.swift`

- [ ] **Step 1: Extract telemetry values in `MenuBarLabel.swift`**

```swift
    private var kineticNotchLoad: Double? {
        let power: Double?
        if case .value(.power(let sample)) = monitor.cardState(.power) {
            power = sample.totalW
        } else {
            power = nil
        }

        let cpuClockGHz: Double?
        let cpu: Double?
        if case .value(.cpu(let sample)) = monitor.cardState(.cpu) {
            cpu = sample.overall
            cpuClockGHz = sample.perfLevels.compactMap(\.activeGHz).first
        } else {
            cpu = nil
            cpuClockGHz = nil
        }

        let gpu: Double?
        let gpuCores: Int?
        if case .value(.gpu(let sample)) = monitor.cardState(.gpu) {
            gpu = sample.overall
            gpuCores = sample.coreCount
        } else {
            gpu = nil
            gpuCores = nil
        }

        let fanCount: Int?
        if case .value(.fan(let sample)) = monitor.cardState(.fan) {
            fanCount = sample.fans.count
        } else {
            fanCount = nil
        }

        return kineticNotchSource.load(
            power: power,
            cpuClockGHz: cpuClockGHz,
            cpu: cpu,
            gpu: gpu,
            gpuCores: gpuCores,
            fanCount: fanCount
        )
    }

    private var dynamicIconFrameRate: Double? {
        guard kineticNotchMotionEnabled, !reduceMotion, let kineticNotchLoad else { return nil }
        return MenuBarIconMotion.frameRate(load: kineticNotchLoad, speed: kineticNotchSpeed)
    }
```

- [ ] **Step 2: Update preview calculation in `SettingsMenuBarSection.swift`**

Mirror the exact metric extraction in `SettingsMenuBarSection.previewLoad`, and update `WattlySegment` options to `KineticNotchSource.allCases.map { ($0, $0.label) }`.

- [ ] **Step 3: Verify build and test suite**

Run: `swift test`
Expected: All tests PASS.

- [ ] **Step 4: Commit**

```bash
git add Wattly/Views/MenuBarLabel.swift Wattly/Views/Settings/SettingsMenuBarSection.swift Wattly/Views/PollPolicyBridge.swift
git commit -m "feat(views): wire new load sources into menubar icon and settings preview"
```

---

## Verification Plan

### Automated Tests
- `swift test --filter KineticNotchMotionTests`
- `swift test --filter SettingsResetTests`
- `swift test` (전체 테스트 스위트 회귀 검증)

### Manual Verification
1. 설정창 열기 $\rightarrow$ 메뉴바 아이콘 섹션 진입.
2. 부하 원본 세그먼트에서 [전력 소비], [CPU 클럭], [CPU + GPU] 선택 전환 테스트.
3. 유휴 상태(Idle)에서도 아이콘이 멈추지 않고 6~8 fps로 은은하게 회전하는지 확인.
4. 부하 발생(예: 컴파일 또는 동영상 재생) 시 전력/클럭 상승에 따라 아이콘이 부드럽게 가속하는지 확인.
