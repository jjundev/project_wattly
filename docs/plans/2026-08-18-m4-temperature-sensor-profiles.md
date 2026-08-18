# Apple M4 계열 온도 센서 프로파일 지원 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** M4 MacBook Air(`Mac16,12`/`Mac16,13`) 및 M4 Pro/Max MacBook Pro(`Mac16,5`~`Mac16,8`) 등 M4 전 라인업 기기에서 CPU 및 GPU 온도가 정상 표기되도록 `TemperatureProfile`을 확장 등록한다.

**Architecture:** 기존 `Temperature.swift`의 `TemperatureProfiles` 구조체에 M4 기본형(`m4Base`) 및 M4 Pro/Max(`m4ProMax`) 프로파일을 추가하고, `TemperatureProfiles.all`에 등록하여 `hw.model` 기반 자동 매칭을 지원한다.

**Tech Stack:** Swift 5.9+, IOKit / AppleSMC (`flt ` IEEE-754 LE Float), Swift Testing (`@Test`)

## Global Constraints

- 무권한(no entitlements) 원칙 및 IOKit 직접 호출은 `SMCTemperatureTransport` 격리 유지
- 검증되지 않은 센서 추측 금지, IEEE-754 `flt ` 타입 센서만 디코드 (`validRange: 0...120`)
- `HardwareModel.swift`의 `hw.model` 문자열과 정확히 일치하도록 등록
- 테스트 코드는 Swift Testing (`import Testing`) 프레임워크 유지

---

### Task 1: M4 계열 `TemperatureProfile` 정의 및 `TemperatureProfiles.all` 등록

**Files:**
- Modify: `Wattly/Core/Temperature.swift:43-71`

**Interfaces:**
- Consumes: `TemperatureProfile`, `TemperatureKeyGroup`, `currentHardwareModel()`
- Produces: `TemperatureProfiles.m4Base`, `TemperatureProfiles.m4ProMax`, `TemperatureProfiles.all`

- [ ] **Step 1: M4 기본형 및 M4 Pro/Max 프로파일 코드 작성**

`Wattly/Core/Temperature.swift`의 `TemperatureProfiles`에 M4 라인업의 `hw.model` 및 센서 키 그룹을 추가합니다.

```swift
enum TemperatureProfiles {
    /// Apple M4 기본형 (MacBook Air 13"/15", MacBook Pro 14", Mac mini, iMac)
    /// hw.model: Mac16,12 (Air 13"), Mac16,13 (Air 15"), Mac16,1 (MBP 14"), Mac16,10 (mini), Mac16,2/Mac16,3 (iMac)
    static let m4Base = TemperatureProfile(
        chipModels: ["Mac16,12", "Mac16,13", "Mac16,1", "Mac16,10", "Mac16,2", "Mac16,3"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어",
                keys: ["Tp00", "Tp04", "Tp0C", "Tp0G", "Tp0O", "Tp0R", "Tp0X", "Tp0a", "Tp0p", "Tp0u", "Tp0y"]),
            TemperatureKeyGroup(name: "E-코어",
                keys: ["Te04", "Te08", "Te0C", "Te0R", "Te09", "Te0H"]),
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

    /// Apple M4 Pro / Max (MacBook Pro 14"/16", Mac mini Pro)
    /// hw.model: Mac16,8 (MBP 14" Pro), Mac16,6 (MBP 14" Max), Mac16,7 (MBP 16" Pro), Mac16,5 (MBP 16" Max), Mac16,11 (mini Pro)
    static let m4ProMax = TemperatureProfile(
        chipModels: ["Mac16,8", "Mac16,6", "Mac16,7", "Mac16,5", "Mac16,11"],
        cpuGroups: [
            TemperatureKeyGroup(name: "P-코어",
                keys: ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X",
                       "Tp0a", "Tp0d", "Tp0h", "Tp0p", "Tp0u", "Tp0y", "Tp12", "Tp16", "Tp1E"]),
            TemperatureKeyGroup(name: "E-코어",
                keys: ["Te04", "Te08", "Te09", "Te0C", "Te0H", "Te0R"]),
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

    /// Apple M5 (`Mac17,2`), verified 2026-06-22 (macOS 26.5.1 / 25F80). CPU = `Tp*`
    /// (P-core) + `Te*` (E-core), GPU = `Tg*`, all `flt `. See `Temperature.swift` header.
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

    static let all = [m4Base, m4ProMax, m5]

    /// The verified profile for a `hw.model`, or nil → `noVerifiedProfile` (terminal).
    static func profile(forModel model: String) -> TemperatureProfile? {
        all.first { $0.chipModels.contains(model) }
    }
}
```

- [ ] **Step 2: Commit changes to Temperature.swift**

```bash
git add Wattly/Core/Temperature.swift
git commit -m "feat: add M4 base and M4 Pro/Max temperature sensor profiles"
```

---

### Task 2: 단위 테스트 확장 (`TemperatureTests.swift`)

**Files:**
- Modify: `WattlyTests/TemperatureTests.swift:11-20`

**Interfaces:**
- Consumes: `TemperatureProfiles.profile(forModel:)`, `TemperatureProfiles.m4Base`, `TemperatureProfiles.m4ProMax`
- Produces: M4 하드웨어 식별자 해석 테스트

- [ ] **Step 1: M4 모델 프로파일 해석 테스트 추가**

`WattlyTests/TemperatureTests.swift`에 다음 테스트들을 추가합니다:

```swift
    @Test func m4BaseProfileResolvesForM4Models() {
        #expect(TemperatureProfiles.profile(forModel: "Mac16,12") == TemperatureProfiles.m4Base) // M4 MacBook Air 13"
        #expect(TemperatureProfiles.profile(forModel: "Mac16,13") == TemperatureProfiles.m4Base) // M4 MacBook Air 15"
        #expect(TemperatureProfiles.profile(forModel: "Mac16,1") == TemperatureProfiles.m4Base)  // M4 MacBook Pro 14"
        #expect(TemperatureProfiles.profile(forModel: "Mac16,10") == TemperatureProfiles.m4Base) // M4 Mac mini
    }

    @Test func m4ProMaxProfileResolvesForM4ProMaxModels() {
        #expect(TemperatureProfiles.profile(forModel: "Mac16,8") == TemperatureProfiles.m4ProMax) // M4 Pro MBP 14"
        #expect(TemperatureProfiles.profile(forModel: "Mac16,6") == TemperatureProfiles.m4ProMax) // M4 Max MBP 14"
        #expect(TemperatureProfiles.profile(forModel: "Mac16,7") == TemperatureProfiles.m4ProMax) // M4 Pro MBP 16"
        #expect(TemperatureProfiles.profile(forModel: "Mac16,5") == TemperatureProfiles.m4ProMax) // M4 Max MBP 16"
        #expect(TemperatureProfiles.profile(forModel: "Mac16,11") == TemperatureProfiles.m4ProMax) // M4 Pro Mac mini
    }
```

- [ ] **Step 2: M4 가짜 전송(Fake Transport) 프로바이더 읽기 테스트 추가**

```swift
    @Test func m4AirReadsCpuAndGpuSuccessfully() async {
        let tx = FakeTempTransport()
        tx.cpuCelsius = 52.0
        tx.gpuCelsius = 48.0
        let p = TemperatureProvider(transport: tx, model: "Mac16,12")
        let snap = await readSnapshot(p, at: base)
        #expect(snap.cpu.celsius == 52.0)
        #expect(snap.gpu.celsius == 48.0)
        #expect(tx.openCalls == 1)
    }

    @Test func m4ProMacBookProReadsCpuAndGpuSuccessfully() async {
        let tx = FakeTempTransport()
        tx.cpuCelsius = 64.0
        tx.gpuCelsius = 58.0
        let p = TemperatureProvider(transport: tx, model: "Mac16,8")
        let snap = await readSnapshot(p, at: base)
        #expect(snap.cpu.celsius == 64.0)
        #expect(snap.gpu.celsius == 58.0)
        #expect(tx.openCalls == 1)
    }
```

- [ ] **Step 3: Commit test updates**

```bash
git add WattlyTests/TemperatureTests.swift
git commit -m "test: add M4 and M4 Pro/Max profile resolution and provider reading tests"
```

---

### Task 3: 전체 테스트 스위트 실행 및 검증

**Files:**
- Test: `WattlyTests`

- [ ] **Step 1: 단위 테스트 실행 및 결과 검증**

Run:
```bash
xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .build/DerivedData
```
Expected: `** TEST SUCCEEDED **` (All tests pass)
