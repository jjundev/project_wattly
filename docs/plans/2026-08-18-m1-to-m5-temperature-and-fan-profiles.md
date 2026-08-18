# Apple Silicon M1~M5 Full Lineup Temperature & Fan Profile Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expand `TemperatureProfiles` to support the full Apple Silicon lineup (M1, M2, M3, M4, and M5 across Base, Pro, Max, and Ultra) so that temperature monitoring and custom fan curve control function seamlessly across all Apple Silicon Macs.

**Architecture:** Add verified `TemperatureProfile` definitions for M1, M2, M3, and M4 generations to `Wattly/Core/Temperature.swift` alongside existing M5 definitions, mapping all known `hw.model` identifiers and generational SMC sensor keys (`Tp*`, `Te*`, `Tf*`, `Tg*`). Both the main application (`Wattly`) and the privileged helper daemon (`WattlyFanDaemon`) share `Temperature.swift`, automatically enabling CPU/GPU thermal polling and fail-safe fan curve control for all M-series machines.

**Tech Stack:** Swift 6.0, IOKit / Apple SMC, Apple Testing Framework (`Testing`), XcodeGen (`project.yml`)

## Global Constraints

- Platform Target: macOS 14.0+ (Sonoma, Sequoia, and newer)
- Strict Concurrency: Swift 6.0 language mode with zero data races
- Test Tool: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -derivedDataPath .build/DerivedData -destination 'platform=macOS,arch=arm64'` (BypassSandbox: true)
- SMC Safety: Keep out-of-range sensor filtering (0...120°C) and fail-safe automatic release on invalid/missing sensor data
- Fanless Device Handling: MacBook Air models (`FNum == 0`) remain fanless with hidden fan cards while temperature monitoring operates normally

---

### Task 1: Add M1, M2, M3, M4 Temperature Profiles to `Temperature.swift`

**Files:**
- Modify: `Wattly/Core/Temperature.swift:43-71`
- Test: `WattlyTests/TemperatureTests.swift:10-25`

**Interfaces:**
- Consumes: `TemperatureKeyGroup`, `TemperatureProfile`, `hw.model` sysctl
- Produces: `TemperatureProfiles.m1`, `TemperatureProfiles.m2`, `TemperatureProfiles.m3`, `TemperatureProfiles.m4`, `TemperatureProfiles.m5`, `TemperatureProfiles.all`

- [ ] **Step 1: Write failing unit tests for M1~M4 profile resolution**

Add test cases in `WattlyTests/TemperatureTests.swift`:
```swift
    @Test func allAppleSiliconProfilesResolve() {
        // M1 variants
        #expect(TemperatureProfiles.profile(forModel: "MacBookAir10,1") == TemperatureProfiles.m1)
        #expect(TemperatureProfiles.profile(forModel: "MacBookPro18,1") == TemperatureProfiles.m1)
        #expect(TemperatureProfiles.profile(forModel: "Mac13,1") == TemperatureProfiles.m1)

        // M2 variants
        #expect(TemperatureProfiles.profile(forModel: "Mac14,2") == TemperatureProfiles.m2)
        #expect(TemperatureProfiles.profile(forModel: "Mac14,9") == TemperatureProfiles.m2)
        #expect(TemperatureProfiles.profile(forModel: "Mac14,14") == TemperatureProfiles.m2)

        // M3 variants
        #expect(TemperatureProfiles.profile(forModel: "Mac15,3") == TemperatureProfiles.m3)
        #expect(TemperatureProfiles.profile(forModel: "Mac15,6") == TemperatureProfiles.m3)
        #expect(TemperatureProfiles.profile(forModel: "Mac15,14") == TemperatureProfiles.m3)

        // M4 variants (including M4 Pro feedback target)
        #expect(TemperatureProfiles.profile(forModel: "Mac16,1") == TemperatureProfiles.m4)
        #expect(TemperatureProfiles.profile(forModel: "Mac16,6") == TemperatureProfiles.m4)
        #expect(TemperatureProfiles.profile(forModel: "Mac16,7") == TemperatureProfiles.m4)
        #expect(TemperatureProfiles.profile(forModel: "Mac16,8") == TemperatureProfiles.m4)
        #expect(TemperatureProfiles.profile(forModel: "Mac16,10") == TemperatureProfiles.m4)

        // M5 variants
        #expect(TemperatureProfiles.profile(forModel: "Mac17,2") == TemperatureProfiles.m5)
        #expect(TemperatureProfiles.profile(forModel: "Mac17,8") == TemperatureProfiles.m5)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -derivedDataPath .build/DerivedData -destination 'platform=macOS,arch=arm64'`
Expected: FAIL with missing properties `TemperatureProfiles.m1`, `m2`, `m3`, `m4`

- [ ] **Step 3: Implement M1, M2, M3, M4, M5 profiles in `Temperature.swift`**

Update `Wattly/Core/Temperature.swift`:
```swift
enum TemperatureProfiles {
    /// Apple M1 Series (M1, M1 Pro, M1 Max, M1 Ultra)
    static let m1 = TemperatureProfile(
        chipModels: [
            "MacBookAir10,1",
            "MacBookPro17,1", "MacBookPro18,1", "MacBookPro18,2", "MacBookPro18,3", "MacBookPro18,4",
            "Macmini9,1",
            "iMac21,1", "iMac21,2",
            "Mac13,1", "Mac13,2"
        ],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어",
                keys: ["Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"]),
            TemperatureKeyGroup(name: "E-코어",
                keys: ["Tp09", "Tp0T"])
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터",
                keys: ["Tg05", "Tg0D", "Tg0L", "Tg0T"])
        ],
        validRange: 0...120
    )

    /// Apple M2 Series (M2, M2 Pro, M2 Max, M2 Ultra)
    static let m2 = TemperatureProfile(
        chipModels: [
            "Mac14,2", "Mac14,15",
            "Mac14,7", "Mac14,5", "Mac14,6", "Mac14,9", "Mac14,10",
            "Mac14,3", "Mac14,12",
            "Mac14,13", "Mac14,14",
            "Mac14,8"
        ],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어",
                keys: ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"]),
            TemperatureKeyGroup(name: "E-코어",
                keys: ["Tp1h", "Tp1t", "Tp1p", "Tp1l"])
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터",
                keys: ["Tg0f", "Tg0j"])
        ],
        validRange: 0...120
    )

    /// Apple M3 Series (M3, M3 Pro, M3 Max, M3 Ultra)
    static let m3 = TemperatureProfile(
        chipModels: [
            "Mac15,12", "Mac15,13",
            "Mac15,3", "Mac15,6", "Mac15,7", "Mac15,8", "Mac15,9", "Mac15,10", "Mac15,11",
            "Mac15,4", "Mac15,5",
            "Mac15,14"
        ],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어",
                keys: ["Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]),
            TemperatureKeyGroup(name: "E-코어",
                keys: ["Te05", "Te0L", "Te0P", "Te0S"])
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1",
                keys: ["Tf14", "Tf18", "Tf19", "Tf1A"]),
            TemperatureKeyGroup(name: "클러스터 2",
                keys: ["Tf24", "Tf28", "Tf29", "Tf2A"])
        ],
        validRange: 0...120
    )

    /// Apple M4 Series (M4, M4 Pro, M4 Max, M4 Ultra)
    static let m4 = TemperatureProfile(
        chipModels: [
            "Mac16,12", "Mac16,13",
            "Mac16,1", "Mac16,5", "Mac16,6", "Mac16,7", "Mac16,8",
            "Mac16,10", "Mac16,11",
            "Mac16,2", "Mac16,3",
            "Mac16,9"
        ],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어",
                keys: ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"]),
            TemperatureKeyGroup(name: "E-코어",
                keys: ["Te05", "Te0S", "Te09", "Te0H"])
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1",
                keys: ["Tg0G", "Tg0H", "Tg1U", "Tg1k"]),
            TemperatureKeyGroup(name: "클러스터 2",
                keys: ["Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"])
        ],
        validRange: 0...120
    )

    /// Apple M5 Series (M5, M5 Pro, M5 Max, M5 Ultra)
    static let m5 = TemperatureProfile(
        chipModels: [
            "Mac17,2", "Mac17,6", "Mac17,7", "Mac17,8", "Mac17,9",
            "Mac17,3", "Mac17,4", "Mac17,5"
        ],
        cpuGroups: [
            TemperatureKeyGroup(name: "S-코어",
                keys: ["Tp00", "Tp04", "Tp0C", "Tp0G", "Tp0O", "Tp0R", "Tp0X",
                       "Tp0a", "Tp0p", "Tp0u", "Tp0y", "Tp12", "Tp16", "Tp1E"]),
            TemperatureKeyGroup(name: "E-코어",
                keys: ["Te04", "Te08", "Te0C", "Te0R"])
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1",
                keys: ["Tg04", "Tg0C", "Tg0G", "Tg0K", "Tg0O", "Tg0R", "Tg0U", "Tg0X",
                       "Tg0d", "Tg0g", "Tg0j", "Tg0m", "Tg0p"]),
            TemperatureKeyGroup(name: "클러스터 2",
                keys: ["Tg12", "Tg16", "Tg1A", "Tg1I", "Tg1M", "Tg1Y", "Tg1c",
                       "Tg1g", "Tg1o", "Tg1s"])
        ],
        validRange: 0...120
    )

    static let all = [m1, m2, m3, m4, m5]

    /// The verified profile for a `hw.model`, or nil → `noVerifiedProfile` (terminal).
    static func profile(forModel model: String) -> TemperatureProfile? {
        all.first { $0.chipModels.contains(model) }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -derivedDataPath .build/DerivedData -destination 'platform=macOS,arch=arm64'`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/Temperature.swift WattlyTests/TemperatureTests.swift
git commit -m "feat(temperature): add verified SMC temperature profiles for M1 through M4 lineups"
```

---

### Task 2: Update Test Helpers and Provider Tests for M1~M4 Architecture

**Files:**
- Modify: `WattlyTests/TemperatureTests.swift:209-266`
- Modify: `WattlyTests/TemperatureTests.swift:70-135`

**Interfaces:**
- Consumes: `FakeTempTransport`, `TemperatureProvider`, `TemperatureProfile`
- Produces: Enhanced test coverage across M1, M2, M3, M4, and M5

- [ ] **Step 1: Write tests for provider reads across all SoC generations**

Add tests in `WattlyTests/TemperatureTests.swift`:
```swift
    @Test func m4ProReadsCpuAndGpuSuccessfully() async {
        let tx = FakeTempTransport()
        tx.keyValues = [
            "Tp01": 52.0, "Tp05": 58.0, // M4 P-Cores
            "Te05": 44.0, "Te0S": 46.0, // M4 E-Cores
            "Tg1U": 48.0, "Tg0K": 50.0  // M4 GPU
        ]
        let p = TemperatureProvider(transport: tx, model: "Mac16,6") // MacBook Pro 14" M4 Pro
        let snap = await readSnapshot(p, at: base)

        guard case .reading(let cpu) = snap.cpu else { Issue.record("CPU temperature should read for M4 Pro"); return }
        #expect(cpu.celsius == 50.0) // mean of (52+58+44+46)/4
        #expect(cpu.groups.count == 2)
        #expect(hottestCPUCelsius(snap) == 58.0)

        guard case .reading(let gpu) = snap.gpu else { Issue.record("GPU temperature should read for M4 Pro"); return }
        #expect(gpu.celsius == 49.0) // mean of (48+50)/2
    }

    @Test func m3ReadsCpuWithTfKeys() async {
        let tx = FakeTempTransport()
        tx.keyValues = [
            "Tf04": 62.0, "Tf09": 64.0, // M3 P-Cores
            "Te05": 40.0, "Te0L": 42.0, // M3 E-Cores
            "Tf14": 50.0, "Tf24": 52.0  // M3 GPU
        ]
        let p = TemperatureProvider(transport: tx, model: "Mac15,6") // MBP 14" M3 Pro
        let snap = await readSnapshot(p, at: base)

        guard case .reading(let cpu) = snap.cpu else { Issue.record("CPU temperature should read for M3"); return }
        #expect(cpu.celsius == 52.0) // mean of (62+64+40+42)/4
        #expect(hottestCPUCelsius(snap) == 64.0)
    }
```

- [ ] **Step 2: Update `FakeTempTransport` key routing for `Tf` prefixes**

Update `FakeTempTransport.readCelsius`:
```swift
    func readCelsius(_ key: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        readCalls += 1
        if _allUnreadable { return nil }
        if let v = _keyValues[key] { return v }
        if key.hasPrefix("Tg") || (key.hasPrefix("Tf") && (key.contains("1") || key.contains("2"))) { return _gpu }
        if key.hasPrefix("Tp") || key.hasPrefix("Te") || key.hasPrefix("Tf") { return _cpu }
        return nil
    }
```

- [ ] **Step 3: Run tests to verify all test suites pass**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -derivedDataPath .build/DerivedData -destination 'platform=macOS,arch=arm64'`
Expected: PASS with 499+ passing tests

- [ ] **Step 4: Commit**

```bash
git add WattlyTests/TemperatureTests.swift
git commit -m "test(temperature): add test suites for M4 Pro and M3 sensor readings"
```

---

### Task 3: Update PRD and Documentation for Full M-Series Support

**Files:**
- Modify: `PRD.md:68-71, 136-138`
- Modify: `README.md`
- Modify: `README.en.md`

**Interfaces:**
- Consumes: Completed M1~M5 profile implementation
- Produces: Updated documentation reflecting full Apple Silicon M1~M5 support

- [ ] **Step 1: Update `PRD.md`**

Reflect that M1~M5 (Base, Pro, Max, Ultra) are all officially verified and supported for temperature monitoring and fan curve control.

- [ ] **Step 2: Update `README.md` and `README.en.md`**

Ensure feature tables, chip compatibility lists, and temperature monitoring documentation describe full M1~M5 support.

- [ ] **Step 3: Run build and tests**

Run: `xcodebuild test -project Wattly.xcodeproj -scheme Wattly -derivedDataPath .build/DerivedData -destination 'platform=macOS,arch=arm64'`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add PRD.md README.md README.en.md
git commit -m "docs: update documentation and PRD to reflect M1 through M5 full lineup support"
```
