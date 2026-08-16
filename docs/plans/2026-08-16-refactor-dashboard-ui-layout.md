# Refactor Dashboard UI Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor Dashboard UI copy, labels, and sensor mapping for Apple Silicon M5 (S-Core, Cluster labels), simplify the collapsed Fan Speed Card sub-text, and verify default card layout order.

**Architecture:** Update pure presentation rules in `CardPresentation.swift` and verified hardware temperature profiles in `Temperature.swift`, keeping Swift models isolated and fully covered by Swift Testing suites.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing framework, macOS 14+ Target.

## Global Constraints

- Preserve pure/view separation (`CardPresentation` & `Temperature` pure functions tested without SwiftUI).
- All unit tests must pass via `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData`.
- Copy must match Korean UI standards of Wattly.

---

### Task 1: Update M5 Temperature Sensor Cluster Names (S-코어 & 클러스터 N)

**Files:**
- Modify: `Wattly/Core/Temperature.swift:48-63`
- Test: `WattlyTests/TemperatureTests.swift:83-102`

**Interfaces:**
- Consumes: `TemperatureKeyGroup`, `TemperatureProfile`, `TemperatureProfiles.m5`
- Produces: `TemperatureProfiles.m5` with `S-코어` for CPU and `클러스터 1`/`클러스터 2` for GPU groups.

- [ ] **Step 1: Write the failing test**

Modify `WattlyTests/TemperatureTests.swift`:
```swift
    // MARK: Provider: cluster groups carry per-cluster average + hottest

    @Test func buildsClusterGroupsWithAverageAndHottest() async {
        let tx = FakeTempTransport()
        tx.keyValues = ["Tp00": 80, "Tp0X": 90,   // S-코어 → avg 85, hottest 90
                        "Te04": 60, "Te08": 70,   // E-코어 → avg 65, hottest 70
                        "Tg04": 50, "Tg0C": 60,   // 클러스터 1 → avg 55, hottest 60
                        "Tg12": 70, "Tg1s": 80]   // 클러스터 2 → avg 75, hottest 80
        let p = TemperatureProvider(transport: tx, model: "Mac17,2")
        let snap = await readSnapshot(p, at: base)

        guard case .reading(let cpu) = snap.cpu else { Issue.record("cpu should read"); return }
        #expect(cpu.celsius == 75)            // headline = mean of all CPU sensors (80+90+60+70)/4
        #expect(cpu.groups == [TemperatureGroup(name: "S-코어", average: 85, hottest: 90),
                               TemperatureGroup(name: "E-코어", average: 65, hottest: 70)])

        guard case .reading(let gpu) = snap.gpu else { Issue.record("gpu should read"); return }
        #expect(gpu.celsius == 65)            // headline = mean of all GPU sensors (50+60+70+80)/4
        #expect(gpu.groups == [TemperatureGroup(name: "클러스터 1", average: 55, hottest: 60),
                               TemperatureGroup(name: "클러스터 2", average: 75, hottest: 80)])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/TemperatureTests/buildsClusterGroupsWithAverageAndHottest`
Expected: FAIL with expectation mismatch (`"P-코어"` != `"S-코어"`, `"GPU 클러스터 1"` != `"클러스터 1"`).

- [ ] **Step 3: Update `Temperature.swift`**

In `Wattly/Core/Temperature.swift`:
```swift
    static let m5 = TemperatureProfile(
        chipModels: ["Mac17,2"],
        cpuGroups: [
            TemperatureKeyGroup(name: "S-코어",
                keys: ["Tp00", "Tp04", "Tp0C", "Tp0G", "Tp0O", "Tp0R", "Tp0X",
                       "Tp0a", "Tp0p", "Tp0u", "Tp0y", "Tp12", "Tp16", "Tp1E"]),
            TemperatureKeyGroup(name: "E-코어",
                keys: ["Te04", "Te08", "Te0C", "Te0R"]),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1",
                keys: ["Tg04", "Tg0C", "Tg0G", "Tg0K", "Tg0O", "Tg0R", "Tg0U", "Tg0X",
                       "Tg0d", "Tg0g", "Tg0j", "Tg0m", "Tg0p"]),
            TemperatureKeyGroup(name: "클러스터 2",
                keys: ["Tg12", "Tg16", "Tg1A", "Tg1I", "Tg1M", "Tg1Y", "Tg1c",
                       "Tg1g", "Tg1o", "Tg1s"]),
        ],
        validRange: 0...120)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/TemperatureTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/Temperature.swift WattlyTests/TemperatureTests.swift
git commit -m "fix(temp): update M5 cluster labels to S-Core and shorten GPU cluster names"
```

---

### Task 2: Remove Target/Max RPM SubText from Fan Speed Card

**Files:**
- Modify: `Wattly/Core/CardPresentation.swift:203-206`
- Test: `WattlyTests/CardPresentationTests.swift`

**Interfaces:**
- Consumes: `MetricState.value(.fan(FanSample))`
- Produces: `CardPresentation.subText(state) -> String?` (returns `nil` for `.fan`)

- [ ] **Step 1: Write the failing test**

In `WattlyTests/CardPresentationTests.swift`, add:
```swift
    @Test func fanSubTextIsNil() {
        let fans = [
            FanReading(index: 0, actualRPM: 2100, minRPM: 1200, maxRPM: 6000, targetRPM: 2000)
        ]
        let state = MetricState.value(.fan(FanSample(fans: fans, mode: .auto, helperPresent: true)))
        #expect(CardPresentation.subText(state) == nil)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/CardPresentationTests/fanSubTextIsNil`
Expected: FAIL with expectation mismatch (`"목표 2000 RPM · 최대 6000 RPM"` != `nil`).

- [ ] **Step 3: Update `CardPresentation.swift`**

In `Wattly/Core/CardPresentation.swift`:
```swift
        case .fan:
            return nil
        case .temperature:
            return nil
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/CardPresentationTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/CardPresentation.swift WattlyTests/CardPresentationTests.swift
git commit -m "refactor(fan): omit target and max RPM from collapsed card subtext"
```

---

### Task 3: Verify and Test Default Card Order (CPU -> GPU -> Mem)

**Files:**
- Modify: `Wattly/Settings/Settings.swift:290` (verify)
- Test: `WattlyTests/CardPresentationTests.swift` (or dedicated `CardOrderTests`)

**Interfaces:**
- Consumes: `Defaults.cardOrder`, `CardOrder`
- Produces: Verified `Defaults.cardOrder` ordering: `[.power, .battery, .cpu, .gpu, .mem, .cpuTemp, .gpuTemp, .batTemp, .fan]`

- [ ] **Step 1: Write the test for default card order**

In `WattlyTests/CardPresentationTests.swift`, add:
```swift
    @Test func defaultCardOrderPlacesGpuBetweenCpuAndMemory() {
        let order = Defaults.cardOrder.cards
        guard let cpuIdx = order.firstIndex(of: .cpu),
              let gpuIdx = order.firstIndex(of: .gpu),
              let memIdx = order.firstIndex(of: .mem)
        else {
            Issue.record("Missing required cards in Defaults.cardOrder")
            return
        }
        #expect(gpuIdx == cpuIdx + 1)
        #expect(memIdx == gpuIdx + 1)
    }
```

- [ ] **Step 2: Run test to verify it passes**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData -only-testing:WattlyTests/CardPresentationTests/defaultCardOrderPlacesGpuBetweenCpuAndMemory`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add WattlyTests/CardPresentationTests.swift
git commit -m "test(settings): verify GPU is ordered between CPU and memory in default card order"
```
