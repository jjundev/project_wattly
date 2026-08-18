# Apple Silicon 전 세대(M1~M5) 온도 센서 프로파일 전면 지원 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** M1, M2, M3, M4, M5 전 라인업(Base, Pro, Max, Ultra 총 30+개 모델)에 대한 온도 센서 프로파일을 `TemperatureProfiles`에 등록하여 모든 Apple Silicon Mac에서 CPU/GPU 온도가 정상 표시되도록 한다.

**Architecture:** `Temperature.swift`에 세대별/라인업별(`m1Base`, `m1ProMax`, `m1Ultra`, `m2Base`, `m2ProMax`, `m2Ultra`, `m3Base`, `m3ProMax`, `m4Base`, `m4ProMax`, `m5Base`, `m5ProMax`) 프로파일을 구조화하여 정의하고 `TemperatureProfiles.all`에 포함시킨다.

**Tech Stack:** Swift 5.9+, IOKit / AppleSMC (`flt ` IEEE-754 LE Float), Swift Testing (`@Test`)

## Global Constraints

- 무권한(no entitlements) 원칙 및 IOKit 호출 격리 유지 (`SMCTemperatureTransport`)
- `flt ` (IEEE-754 LE 32-bit Float, 4바이트, 0...120°C) 센서만 디코드
- `hw.model` 매핑 누락 없이 M1부터 M5까지 전 라인업 완벽 포함
- 단위 테스트(`WattlyTests/TemperatureTests.swift`)에 각 세대별 대표 모델 해석 테스트 추가

---

### Task 1: M1 ~ M5 전 라인업 `TemperatureProfile` 정의 및 `TemperatureProfiles.all` 등록

**Files:**
- Modify: `Wattly/Core/Temperature.swift:43-120`

**Interfaces:**
- Consumes: `TemperatureProfile`, `TemperatureKeyGroup`, `currentHardwareModel()`
- Produces: `TemperatureProfiles.m1Base`, `m1ProMax`, `m1Ultra`, `m2Base`, `m2ProMax`, `m2Ultra`, `m3Base`, `m3ProMax`, `m4Base`, `m4ProMax`, `m5Base`, `m5ProMax`, `all`

- [ ] **Step 1: `Wattly/Core/Temperature.swift`에 전 세대 프로파일 추가**

```swift
enum TemperatureProfiles {
    // MARK: - Common Key Groups

    private static let baseCpuKeys = [
        "Tp00", "Tp04", "Tp0C", "Tp0G", "Tp0O", "Tp0R", "Tp0X", "Tp0a", "Tp0p", "Tp0u", "Tp0y"
    ]
    private static let proMaxCpuKeys = [
        "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X",
        "Tp0a", "Tp0d", "Tp0h", "Tp0p", "Tp0u", "Tp0y", "Tp12", "Tp16", "Tp1E"
    ]
    private static let ultraCpuKeys = proMaxCpuKeys + [
        "Tp20", "Tp24", "Tp28", "Tp2C", "Tp2G", "Tp2K", "Tp2O", "Tp2R", "Tp2U", "Tp2X",
        "Tp2a", "Tp2d", "Tp2h", "Tp2p", "Tp2u", "Tp2y", "Tp32", "Tp36", "Tp3E"
    ]

    private static let commonECoreKeys = ["Te04", "Te08", "Te09", "Te0C", "Te0H", "Te0R", "Te0S"]
    private static let ultraECoreKeys = commonECoreKeys + ["Te24", "Te28", "Te29", "Te2C", "Te2H", "Te2R", "Te2S"]

    private static let gpuCluster1Keys = [
        "Tg04", "Tg0C", "Tg0G", "Tg0K", "Tg0O", "Tg0R", "Tg0U", "Tg0X",
        "Tg0d", "Tg0g", "Tg0j", "Tg0m", "Tg0p"
    ]
    private static let gpuCluster2Keys = [
        "Tg12", "Tg16", "Tg1A", "Tg1I", "Tg1M", "Tg1Y", "Tg1c",
        "Tg1g", "Tg1o", "Tg1s"
    ]
    private static let ultraGpuClusterKeys = [
        "Tg24", "Tg2C", "Tg2G", "Tg2K", "Tg2O", "Tg2R", "Tg2U", "Tg2X",
        "Tg32", "Tg36", "Tg3A", "Tg3I", "Tg3M", "Tg3Y"
    ]

    // MARK: - M1 Series

    /// Apple M1 (MacBook Air, MacBook Pro 13", Mac mini, iMac 24")
    static let m1Base = TemperatureProfile(
        chipModels: ["MacBookAir10,1", "MacBookPro17,1", "Macmini9,1", "iMac21,1", "iMac21,2"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어", keys: baseCpuKeys),
            TemperatureKeyGroup(name: "E-코어", keys: commonECoreKeys),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1", keys: gpuCluster1Keys),
            TemperatureKeyGroup(name: "클러스터 2", keys: gpuCluster2Keys),
        ],
        validRange: 0...120)

    /// Apple M1 Pro / Max (MacBook Pro 14"/16", Mac Studio)
    static let m1ProMax = TemperatureProfile(
        chipModels: ["MacBookPro18,3", "MacBookPro18,1", "MacBookPro18,4", "MacBookPro18,2", "Mac13,1"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어", keys: proMaxCpuKeys),
            TemperatureKeyGroup(name: "E-코어", keys: commonECoreKeys),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1", keys: gpuCluster1Keys),
            TemperatureKeyGroup(name: "클러스터 2", keys: gpuCluster2Keys),
        ],
        validRange: 0...120)

    /// Apple M1 Ultra (Mac Studio)
    static let m1Ultra = TemperatureProfile(
        chipModels: ["Mac13,2"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어", keys: ultraCpuKeys),
            TemperatureKeyGroup(name: "E-코어", keys: ultraECoreKeys),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "다이 1", keys: gpuCluster1Keys + gpuCluster2Keys),
            TemperatureKeyGroup(name: "다이 2", keys: ultraGpuClusterKeys),
        ],
        validRange: 0...120)

    // MARK: - M2 Series

    /// Apple M2 (MacBook Air 13"/15", MacBook Pro 13", Mac mini)
    static let m2Base = TemperatureProfile(
        chipModels: ["Mac14,2", "Mac14,15", "Mac14,7", "Mac14,3"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어", keys: baseCpuKeys),
            TemperatureKeyGroup(name: "E-코어", keys: commonECoreKeys),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1", keys: gpuCluster1Keys),
            TemperatureKeyGroup(name: "클러스터 2", keys: gpuCluster2Keys),
        ],
        validRange: 0...120)

    /// Apple M2 Pro / Max (MacBook Pro 14"/16", Mac mini, Mac Studio)
    static let m2ProMax = TemperatureProfile(
        chipModels: ["Mac14,9", "Mac14,10", "Mac14,12", "Mac14,5", "Mac14,6", "Mac14,13"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어", keys: proMaxCpuKeys),
            TemperatureKeyGroup(name: "E-코어", keys: commonECoreKeys),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1", keys: gpuCluster1Keys),
            TemperatureKeyGroup(name: "클러스터 2", keys: gpuCluster2Keys),
        ],
        validRange: 0...120)

    /// Apple M2 Ultra (Mac Studio, Mac Pro)
    static let m2Ultra = TemperatureProfile(
        chipModels: ["Mac14,14", "Mac14,8"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어", keys: ultraCpuKeys),
            TemperatureKeyGroup(name: "E-코어", keys: ultraECoreKeys),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "다이 1", keys: gpuCluster1Keys + gpuCluster2Keys),
            TemperatureKeyGroup(name: "다이 2", keys: ultraGpuClusterKeys),
        ],
        validRange: 0...120)

    // MARK: - M3 Series

    /// Apple M3 (MacBook Pro 14", MacBook Air 13"/15", iMac 24")
    static let m3Base = TemperatureProfile(
        chipModels: ["Mac15,3", "Mac15,12", "Mac15,13", "Mac15,4", "Mac15,5"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어", keys: baseCpuKeys),
            TemperatureKeyGroup(name: "E-코어", keys: commonECoreKeys),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1", keys: gpuCluster1Keys),
            TemperatureKeyGroup(name: "클러스터 2", keys: gpuCluster2Keys),
        ],
        validRange: 0...120)

    /// Apple M3 Pro / Max (MacBook Pro 14"/16", Mac mini / Mac Studio)
    static let m3ProMax = TemperatureProfile(
        chipModels: ["Mac15,6", "Mac15,7", "Mac15,8", "Mac15,9", "Mac15,10", "Mac15,11"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어", keys: proMaxCpuKeys),
            TemperatureKeyGroup(name: "E-코어", keys: commonECoreKeys),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1", keys: gpuCluster1Keys),
            TemperatureKeyGroup(name: "클러스터 2", keys: gpuCluster2Keys),
        ],
        validRange: 0...120)

    // MARK: - M4 Series

    /// Apple M4 (MacBook Air 13"/15", MacBook Pro 14", Mac mini, iMac 24")
    static let m4Base = TemperatureProfile(
        chipModels: ["Mac16,12", "Mac16,13", "Mac16,1", "Mac16,10", "Mac16,2", "Mac16,3"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어", keys: baseCpuKeys),
            TemperatureKeyGroup(name: "E-코어", keys: commonECoreKeys),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1", keys: gpuCluster1Keys),
            TemperatureKeyGroup(name: "클러스터 2", keys: gpuCluster2Keys),
        ],
        validRange: 0...120)

    /// Apple M4 Pro / Max (MacBook Pro 14"/16", Mac mini Pro)
    static let m4ProMax = TemperatureProfile(
        chipModels: ["Mac16,8", "Mac16,6", "Mac16,7", "Mac16,5", "Mac16,11"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어", keys: proMaxCpuKeys),
            TemperatureKeyGroup(name: "E-코어", keys: commonECoreKeys),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1", keys: gpuCluster1Keys),
            TemperatureKeyGroup(name: "클러스터 2", keys: gpuCluster2Keys),
        ],
        validRange: 0...120)

    // MARK: - M5 Series

    /// Apple M5 (`Mac17,2`), verified 2026-06-22 (macOS 26.5.1 / 25F80)
    static let m5Base = TemperatureProfile(
        chipModels: ["Mac17,2"],
        cpuGroups: [
            TemperatureKeyGroup(name: "S-코어", keys: baseCpuKeys + ["Tp12", "Tp16", "Tp1E"]),
            TemperatureKeyGroup(name: "E-코어", keys: ["Te04", "Te08", "Te0C", "Te0R"]),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1", keys: gpuCluster1Keys),
            TemperatureKeyGroup(name: "클러스터 2", keys: gpuCluster2Keys),
        ],
        validRange: 0...120)

    /// Apple M5 Pro / Max (MacBook Pro 14"/16")
    static let m5ProMax = TemperatureProfile(
        chipModels: ["Mac17,9", "Mac17,8", "Mac17,7", "Mac17,6"],
        cpuGroups: [
            TemperatureKeyGroup(name: "S-코어", keys: proMaxCpuKeys),
            TemperatureKeyGroup(name: "E-코어", keys: commonECoreKeys),
        ],
        gpuGroups: [
            TemperatureKeyGroup(name: "클러스터 1", keys: gpuCluster1Keys),
            TemperatureKeyGroup(name: "클러스터 2", keys: gpuCluster2Keys),
        ],
        validRange: 0...120)

    static let all: [TemperatureProfile] = [
        m1Base, m1ProMax, m1Ultra,
        m2Base, m2ProMax, m2Ultra,
        m3Base, m3ProMax,
        m4Base, m4ProMax,
        m5Base, m5ProMax
    ]

    /// The verified profile for a `hw.model`, or nil → `noVerifiedProfile` (terminal).
    static func profile(forModel model: String) -> TemperatureProfile? {
        all.first { $0.chipModels.contains(model) }
    }
}
```

- [ ] **Step 2: Commit changes**
```bash
git add Wattly/Core/Temperature.swift
git commit -m "feat: add complete M1-M5 Apple Silicon temperature sensor profiles"
```

---

### Task 2: 전 세대 모델 식별자 해석 및 센서 읽기 단위 테스트 확장

**Files:**
- Modify: `WattlyTests/TemperatureTests.swift`

- [ ] **Step 1: `WattlyTests/TemperatureTests.swift`에 세대별 테스트 추가**

```swift
    // MARK: Pure: profile selection for M1~M5 generations

    @Test func m1ProfilesResolve() {
        #expect(TemperatureProfiles.profile(forModel: "MacBookAir10,1") == TemperatureProfiles.m1Base)
        #expect(TemperatureProfiles.profile(forModel: "MacBookPro18,1") == TemperatureProfiles.m1ProMax)
        #expect(TemperatureProfiles.profile(forModel: "Mac13,2") == TemperatureProfiles.m1Ultra)
    }

    @Test func m2ProfilesResolve() {
        #expect(TemperatureProfiles.profile(forModel: "Mac14,2") == TemperatureProfiles.m2Base)
        #expect(TemperatureProfiles.profile(forModel: "Mac14,9") == TemperatureProfiles.m2ProMax)
        #expect(TemperatureProfiles.profile(forModel: "Mac14,14") == TemperatureProfiles.m2Ultra)
    }

    @Test func m3ProfilesResolve() {
        #expect(TemperatureProfiles.profile(forModel: "Mac15,3") == TemperatureProfiles.m3Base)
        #expect(TemperatureProfiles.profile(forModel: "Mac15,8") == TemperatureProfiles.m3ProMax)
    }

    @Test func m4ProfilesResolve() {
        #expect(TemperatureProfiles.profile(forModel: "Mac16,12") == TemperatureProfiles.m4Base)
        #expect(TemperatureProfiles.profile(forModel: "Mac16,8") == TemperatureProfiles.m4ProMax)
    }

    @Test func m5ProfilesResolve() {
        #expect(TemperatureProfiles.profile(forModel: "Mac17,2") == TemperatureProfiles.m5Base)
        #expect(TemperatureProfiles.profile(forModel: "Mac17,9") == TemperatureProfiles.m5ProMax)
    }

    @Test func m1AirReadsCpuAndGpuSuccessfully() async {
        let tx = FakeTempTransport(); tx.cpuCelsius = 45.0; tx.gpuCelsius = 42.0
        let p = TemperatureProvider(transport: tx, model: "MacBookAir10,1")
        let snap = await readSnapshot(p, at: base)
        #expect(snap.cpu.celsius == 45.0)
        #expect(snap.gpu.celsius == 42.0)
    }

    @Test func m2UltraReadsCpuAndGpuSuccessfully() async {
        let tx = FakeTempTransport(); tx.cpuCelsius = 55.0; tx.gpuCelsius = 50.0
        let p = TemperatureProvider(transport: tx, model: "Mac14,14")
        let snap = await readSnapshot(p, at: base)
        #expect(snap.cpu.celsius == 55.0)
        #expect(snap.gpu.celsius == 50.0)
    }
```

- [ ] **Step 2: Commit test changes**
```bash
git add WattlyTests/TemperatureTests.swift
git commit -m "test: add M1-M5 generation profile resolution and provider reading tests"
```

---

### Task 3: 전체 테스트 스위트 빌드 및 회귀 검증

- [ ] **Step 1: `xcodebuild test` 실행 및 전체 통과 검증**
Run:
```bash
xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData
```
Expected: `** TEST SUCCEEDED **`
