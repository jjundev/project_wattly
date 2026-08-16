# Optional GPU Threshold Warning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement an optional status warning threshold for the GPU utilization card (Plan A), disabled by default to prevent false alarms during normal intensive graphics/compute workloads, with a toggleable setting in `SettingsView`.

**Architecture:** Extend `struct Thresholds` in `Settings.swift` with an optional `gpu: ThresholdPair?` (defaulting to `nil` / disabled), maintaining explicit memberwise `Equatable` comparison. Update `CardPresentation.thresholdLevel` for `.gpu` to evaluate against `thresholds.gpu?.level(...)` (returning `nil` when disabled, keeping the card neutral/accent, and `.normal` / `.warn` / `.crit` when enabled). Add a toggleable GPU threshold block in `SettingsView.swift` with explanatory copy, VoiceOver accessibility labels, and dual sliders (주의/위험) that appear when enabled with automatic mutual drag-clamping via `ThresholdPair.setting`.

**Tech Stack:** Swift 6.0, Swift Testing (`Testing`, `@Test`, `#expect`), SwiftUI, AppKit.

## Global Constraints

- **Platform:** macOS 14.0+ (Apple Silicon arm64 only).
- **Language Mode:** Swift 6 with strict concurrency (`Sendable` value types across actor boundaries).
- **Testing Framework:** Swift Testing (`import Testing`, `@Test`, `#expect(...)`, `struct SuiteName`), matching the rest of `WattlyTests`.
- **Design System:** Pixel-matched typography (`Pretendard`, `WattlyFont.at`), spacing, and tokens (`Tokens.accent`, `Tokens.statusOrange`, `Tokens.statusRed`, `t.line`, `t.faint`, `t.sub`, `t.text`).
- **Zero Placeholders:** Full, working code and tests in every task.
- **TDD:** Pure derivations and formatting logic covered by unit tests.

---

### Task 1: Threshold Model, Evaluation & Accessibility Updates (`Settings.swift`, `CardPresentation.swift`, `ThresholdTests.swift`, `CardPresentationTests.swift`, `AccessibilityTests.swift`)

**Files:**
- Modify: `Wattly/Settings/Settings.swift:105-180`
- Modify: `Wattly/Core/CardPresentation.swift:95-110`
- Modify: `WattlyTests/ThresholdTests.swift:1-130`
- Modify: `WattlyTests/CardPresentationTests.swift:90-140`
- Modify: `WattlyTests/AccessibilityTests.swift:105-125`

**Interfaces:**
- Consumes: None
- Produces:
  - `Thresholds.gpu: ThresholdPair?` (persisted via JSON)
  - `CardPresentation.thresholdLevel(.gpu, state, thresholds) -> ThresholdLevel?`

- [ ] **Step 1: Write failing tests in `WattlyTests/ThresholdTests.swift`, `WattlyTests/CardPresentationTests.swift`, and `WattlyTests/AccessibilityTests.swift`**

In `WattlyTests/ThresholdTests.swift`:
```swift
    @Test func gpuThresholdOptionalSerialization() {
        // 1. Without GPU (default)
        let tDefault = Thresholds(
            cpu: ThresholdPair(warn: 70, crit: 90),
            temp: ThresholdPair(warn: 70, crit: 90),
            gpu: nil
        )
        #expect(tDefault.gpu == nil)
        let rawDefault = tDefault.rawValue
        let restoredDefault = Thresholds(rawValue: rawDefault)
        #expect(restoredDefault?.gpu == nil)
        #expect(restoredDefault == tDefault)

        // 2. With GPU enabled
        let tWithGPU = Thresholds(
            cpu: ThresholdPair(warn: 70, crit: 90),
            temp: ThresholdPair(warn: 70, crit: 90),
            gpu: ThresholdPair(warn: 85, crit: 95)
        )
        let rawWithGPU = tWithGPU.rawValue
        let restoredWithGPU = Thresholds(rawValue: rawWithGPU)
        #expect(restoredWithGPU?.gpu == ThresholdPair(warn: 85, crit: 95))
        #expect(restoredWithGPU == tWithGPU)
    }
```

In `WattlyTests/CardPresentationTests.swift`:
```swift
    @Test func gpuThresholdEvaluation() {
        let sampleLow = GPUSample(overall: 50.0, coreCount: 10, activeGHz: 1.28)
        let sampleWarn = GPUSample(overall: 88.0, coreCount: 10, activeGHz: 1.28)
        let sampleCrit = GPUSample(overall: 98.0, coreCount: 10, activeGHz: 1.28)

        // When disabled (default): always returns nil regardless of overall usage
        let thresholdsDisabled = Thresholds(
            cpu: ThresholdPair(warn: 70, crit: 90),
            temp: ThresholdPair(warn: 70, crit: 90),
            gpu: nil
        )
        #expect(CardPresentation.thresholdLevel(.gpu, .value(.gpu(sampleLow)), thresholdsDisabled) == nil)
        #expect(CardPresentation.thresholdLevel(.gpu, .value(.gpu(sampleWarn)), thresholdsDisabled) == nil)
        #expect(CardPresentation.thresholdLevel(.gpu, .value(.gpu(sampleCrit)), thresholdsDisabled) == nil)

        // When enabled: evaluates against gpu threshold pair (.normal, .warn, .crit)
        let thresholdsEnabled = Thresholds(
            cpu: ThresholdPair(warn: 70, crit: 90),
            temp: ThresholdPair(warn: 70, crit: 90),
            gpu: ThresholdPair(warn: 85, crit: 95)
        )
        #expect(CardPresentation.thresholdLevel(.gpu, .value(.gpu(sampleLow)), thresholdsEnabled) == .normal)
        #expect(CardPresentation.thresholdLevel(.gpu, .value(.gpu(sampleWarn)), thresholdsEnabled) == .warn)
        #expect(CardPresentation.thresholdLevel(.gpu, .value(.gpu(sampleCrit)), thresholdsEnabled) == .crit)
    }
```

In `WattlyTests/AccessibilityTests.swift`:
```swift
    @Test func gpuStateWordCritWarnNormal() {
        let sampleCrit = GPUSample(overall: 98.0, coreCount: 10, activeGHz: 1.28)
        let sampleWarn = GPUSample(overall: 88.0, coreCount: 10, activeGHz: 1.28)
        let sampleNormal = GPUSample(overall: 50.0, coreCount: 10, activeGHz: 1.28)

        // Disabled by default -> no warning state word
        let thDefault = Defaults.thresholds
        #expect(Accessibility.stateWord(.gpu, .value(.gpu(sampleCrit)), thDefault) == nil)
        #expect(Accessibility.stateWord(.gpu, .value(.gpu(sampleWarn)), thDefault) == nil)
        #expect(Accessibility.stateWord(.gpu, .value(.gpu(sampleNormal)), thDefault) == nil)

        // Enabled -> returns "위험" / "주의" / nil
        let thEnabled = Thresholds(
            cpu: ThresholdPair(warn: 70, crit: 90),
            temp: ThresholdPair(warn: 70, crit: 90),
            gpu: ThresholdPair(warn: 85, crit: 95)
        )
        #expect(Accessibility.stateWord(.gpu, .value(.gpu(sampleCrit)), thEnabled) == "위험")
        #expect(Accessibility.stateWord(.gpu, .value(.gpu(sampleWarn)), thEnabled) == "주의")
        #expect(Accessibility.stateWord(.gpu, .value(.gpu(sampleNormal)), thEnabled) == nil)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData -only-testing:WattlyTests/ThresholdTests/gpuThresholdOptionalSerialization`
Expected: FAIL (missing `gpu` parameter in `Thresholds`)

- [ ] **Step 3: Update `Settings.swift` and `CardPresentation.swift`**

In `Wattly/Settings/Settings.swift`:
```swift
struct Thresholds: Equatable, Sendable, RawRepresentable {
    var cpu: ThresholdPair
    var temp: ThresholdPair
    var gpu: ThresholdPair?

    init(cpu: ThresholdPair, temp: ThresholdPair, gpu: ThresholdPair? = nil) {
        self.cpu = cpu
        self.temp = temp
        self.gpu = gpu
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cpuObject = object["cpu"] as? [String: Double],
              let tempObject = object["temp"] as? [String: Double],
              let cpuWarn = cpuObject["warn"], let cpuCrit = cpuObject["crit"],
              let tempWarn = tempObject["warn"], let tempCrit = tempObject["crit"]
        else { return nil }

        self.cpu = ThresholdPair(warn: cpuWarn, crit: cpuCrit)
        self.temp = ThresholdPair(warn: tempWarn, crit: tempCrit)

        if let gpuObject = object["gpu"] as? [String: Double],
           let gpuWarn = gpuObject["warn"], let gpuCrit = gpuObject["crit"] {
            self.gpu = ThresholdPair(warn: gpuWarn, crit: gpuCrit)
        } else {
            self.gpu = nil
        }
    }

    var rawValue: String {
        var dict: [String: Any] = [
            "cpu": ["warn": cpu.warn, "crit": cpu.crit],
            "temp": ["warn": temp.warn, "crit": temp.crit]
        ]
        if let g = gpu {
            dict["gpu"] = ["warn": g.warn, "crit": g.crit]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: data, encoding: .utf8)
        else { return "" }
        return string
    }

    /// Memberwise equality — NOT JSON string equality (#L12).
    static func == (lhs: Thresholds, rhs: Thresholds) -> Bool {
        lhs.cpu == rhs.cpu && lhs.temp == rhs.temp && lhs.gpu == rhs.gpu
    }
}
```

In `Defaults` (`Wattly/Settings/Settings.swift`):
```swift
    static let thresholds = Thresholds(
        cpu: ThresholdPair(warn: 70, crit: 90),
        temp: ThresholdPair(warn: 70, crit: 90),
        gpu: nil
    )
```

In `Wattly/Core/CardPresentation.swift`:
```swift
    static func thresholdLevel(_ card: CardKind, _ state: MetricState, _ thresholds: Thresholds) -> ThresholdLevel? {
        guard case .value(let sample) = state else { return nil }
        switch (card, sample) {
        case (.cpu, .cpu(let s)):
            return thresholds.cpu.level(s.overall)
        case (.gpu, .gpu(let s)):
            return thresholds.gpu?.level(s.overall)
        case (.mem, .memory(let sample)):
            return sample.pressure?.thresholdLevel
        case (.cpuTemp, .temperature(let s)): return tempLevel(s.cpu, thresholds.temp)
        case (.gpuTemp, .temperature(let s)): return tempLevel(s.gpu, thresholds.temp)
        case (.batTemp, .temperature(let s)): return tempLevel(s.battery, thresholds.temp)
        default: return nil   // power/battery (fixed) + any state/sample mismatch
        }
    }
```

- [ ] **Step 4: Run tests to verify all suites pass**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData`
Expected: ALL TESTS PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Settings/Settings.swift Wattly/Core/CardPresentation.swift WattlyTests/ThresholdTests.swift WattlyTests/CardPresentationTests.swift WattlyTests/AccessibilityTests.swift
git commit -m "feat: add optional gpu threshold pair to Thresholds model and evaluation"
```

---

### Task 2: Settings UI Integration (`SettingsView.swift`)

**Files:**
- Modify: `Wattly/Views/SettingsView.swift:440-505`

**Interfaces:**
- Consumes: `Thresholds.gpu`, `Tokens`, `WattlyFont`
- Produces: `gpuThresholdBlock` in `SettingsView.thresholdSection`

- [ ] **Step 1: Add `gpuThresholdBlock` in `SettingsView.swift`**

In `Wattly/Views/SettingsView.swift`:
```swift
    // MARK: 상태 경고 기준

    private var thresholdSection: some View {
        SettingsSection(title: "상태 경고 기준") {
            SettingsCard(padding: Tokens.cardPadding) {
                VStack(alignment: .leading, spacing: 16) {
                    thresholdBlock(title: "CPU 사용률 (%)", keyPath: \.cpu,
                                   warnRange: 10...95, critRange: 20...100, suffix: "%")
                    thresholdDivider
                    gpuThresholdBlock
                    thresholdDivider
                    thresholdBlock(title: "온도 · CPU·GPU·배터리 (°C)", keyPath: \.temp,
                                   warnRange: 40...100, critRange: 50...110, suffix: "°")
                }
            }
        }
    }

    private var gpuThresholdBlock: some View {
        let isEnabled = thresholds.gpu != nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GPU 사용률 (%)")
                        .font(WattlyFont.at(12.5, weight: .semibold))
                        .foregroundStyle(t.text)
                    Text("그래픽 렌더링 및 연산 시 사용률이 높아지는 것은 정상 동작입니다. 알림이 필요할 때만 켜세요.")
                        .font(WattlyFont.at(10.5, weight: .regular))
                        .foregroundStyle(t.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(
                    get: { thresholds.gpu != nil },
                    set: { on in
                        if on {
                            thresholds.gpu = ThresholdPair(warn: 85, crit: 95)
                        } else {
                            thresholds.gpu = nil
                        }
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("GPU 사용률 상태 경고")
            }

            if isEnabled {
                VStack(spacing: 8) {
                    thresholdRow(
                        dot: Tokens.statusOrange,
                        label: "주의",
                        binding: Binding(
                            get: { thresholds.gpu?.warn ?? 85 },
                            set: { v in
                                if let pair = thresholds.gpu {
                                    thresholds.gpu = pair.setting(.warn, to: v)
                                }
                            }
                        ),
                        range: 10...95,
                        suffix: "%"
                    )
                    thresholdRow(
                        dot: Tokens.statusRed,
                        label: "위험",
                        binding: Binding(
                            get: { thresholds.gpu?.crit ?? 95 },
                            set: { v in
                                if let pair = thresholds.gpu {
                                    thresholds.gpu = pair.setting(.crit, to: v)
                                }
                            }
                        ),
                        range: 20...100,
                        suffix: "%"
                    )
                }
                .padding(.top, 4)
            }
        }
    }
```

- [ ] **Step 2: Run all unit tests**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData`
Expected: ALL TESTS PASS

- [ ] **Step 3: Commit**

```bash
git add Wattly/Views/SettingsView.swift
git commit -m "feat: add toggleable GPU threshold block in SettingsView"
```

---

## Verification Plan

### Automated Tests
- Run all unit tests:
  ```bash
  xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath ./build/DerivedData
  ```
- Focus suites:
  - `WattlyTests/ThresholdTests`
  - `WattlyTests/CardPresentationTests`
  - `WattlyTests/AccessibilityTests`

### Manual Verification
- Open Settings window -> "상태 경고 기준" 섹션:
  - Verify **GPU 사용률 (%)** row with toggle switch and explanatory description.
  - When toggle is OFF: GPU card remains neutral/accent even under high load.
  - When toggle is ON: sliders for `주의` (85%) and `위험` (95%) appear and adjust smoothly with mutual drag-clamping.
