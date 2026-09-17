# macOS 27 배터리 사실 이관(레지스트리 → SMC 폴백) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS 27에서 사라진 `AppleSmartBattery` 최상위 키(용량 mAh·온도·충전 전류) 때문에 비어 버린 배터리 효율·Wh·온도·열 보호·캘리브레이션 정체 판정을 SMC 키 폴백으로 복구한다.

**Architecture:** 디코딩과 우선순위(레지스트리 → SMC 폴백)는 새 순수 파일 `BatteryFacts.swift` 한 곳에 두고, IOKit/SMC I/O는 세 소비처(`BatteryProvider`, `AppleSmartBatteryReader`, `FanControlDaemon`)가 각자 한다. `BatterySample`·XPC·UI 계약은 손대지 않아 소비처는 자동으로 복구된다. 순수 함수는 Swift Testing으로, I/O 배선은 DEBUG 프로브로 실기 검증한다.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI 메뉴바 앱 + 루트 LaunchDaemon, IOKit(`IORegistryEntryCreateCFProperty`, `AppleSMC` user client via 기존 `SMCConnection`), XcodeGen(`project.yml`이 `Wattly.xcodeproj`의 원본), Swift Testing(`@Test`/`#expect`).

**Spec:** `docs/superpowers/specs/2026-09-17-macos-27-battery-facts-migration.md`

## Global Constraints

- 우선순위는 **레지스트리 → SMC 폴백**. 세 소비처 모두 동일(스펙 §3-2).
- 최대 용량은 **Nominal**: 레지스트리 `AppleRawMaxCapacity` → `BatteryData.NominalChargeCapacity` → SMC `B0NC`. Full-charge(`B0FC`)는 쓰지 않는다(스펙 §3-1).
- SMC 키: `B0RM`(잔량 mAh, ui16) · `B0NC`(ui16) · `B0DC`(ui16) · `B0CT`(ui16) · `B0AT`(centi-°C, ui16) · `B0AC`(mA, si16, +충전/−방전).
- 범위 가드는 기존 함수 재사용: `batteryCelsius(rawCentiCelsius:in: 0...80)`(`Wattly/Core/Temperature.swift`), `smcInt(_:type:)`(`Wattly/Core/BatteryPower.swift`), `validatedBatteryCycleCount`, `batteryEfficiencyPercent`, `remainingWattHours`.
- mAh는 `> 0`일 때만 유효. 온도는 0…80 °C 밖이면 nil.
- `BatterySample`(`Wattly/Models/MetricSample.swift`), XPC 페이로드, UI 문자열은 변경 금지.
- 새 파일은 반드시 `project.yml`에 반영하고 `xcodegen generate`로 `Wattly.xcodeproj`를 재생성한다(pbxproj 직접 편집 금지). `Wattly/Core/BatteryFacts.swift`는 **Wattly와 WattlyFanDaemon 두 타깃**에 들어간다.
- Swift 6 strict concurrency: 새 타입은 `Sendable`, 클로저 파라미터는 필요 시 `@Sendable`.
- 커밋 메시지는 Conventional Commits(`feat(battery): …`, `test(battery): …`) + 마지막 줄 `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- 테스트 실행 후 `git status`에 `docs/assets/**/*.png`가 수정된 것으로 뜨면(스크린샷 생성 테스트의 부산물) **커밋하지 말고** `git checkout -- docs/assets`로 되돌린다.
- 전체 테스트 명령: `xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | grep -E "Executed|error:|failed|\*\* TEST"` → 마지막 줄 `** TEST SUCCEEDED **`.
- 단일 스위트 실행: 위 명령에 `-only-testing:WattlyTests/<스위트 struct 이름>` 추가.

---

## 파일 구조

| 파일 | 역할 | 작업 |
|---|---|---|
| `Wattly/Core/BatteryFacts.swift` (신규) | `BatteryFacts` 값 타입 + `BatteryFactsSource.fromSMC/fromRegistry/merged` 순수 디코더·병합 | Task 1 |
| `WattlyTests/BatteryFactsTests.swift` (신규) | 위 순수 함수 테스트 | Task 1 |
| `project.yml` | 데몬 타깃 sources에 `Wattly/Core/BatteryFacts.swift` 추가 → `xcodegen generate` | Task 1 |
| `Wattly/Providers/BatteryProvider.swift` | 스냅샷의 5개 필드를 `facts: BatteryFacts`로 교체, SMC 폴백 병합, DEBUG `BatteryProbe` | Task 2 |
| `Wattly/App/WattlyApp.swift:17` | `BatteryProbe.runIfRequested()` 훅 | Task 2 |
| `Wattly/Models/MetricSample.swift:153-162` | 문서 주석만 갱신(효율·온도 출처) | Task 2 |
| `Wattly/Core/AppleSmartBatteryReader.swift` | 용량·사이클 SMC 폴백, `chargingCurrent(registry:smcBatteryCurrent:)` 순수 헬퍼 | Task 3 |
| `WattlyTests/AppleSmartBatteryReaderTests.swift` | 헬퍼 테스트 추가 | Task 3 |
| `Wattly/Core/BatteryCalibration.swift:141-146` | `chargeStallMilliamps` 주석 갱신 | Task 3 |
| `WattlyFanDaemon/FanControlDaemon.swift` | 온도 폴백 클로저 주입 | Task 4 |
| `WattlyFanDaemon/main.swift` | 클로저 배선(`smc` 캡처) | Task 4 |

---

### Task 1: 순수 `BatteryFacts` 디코더·병합 + 두 타깃 등록

**Files:**
- Create: `Wattly/Core/BatteryFacts.swift`
- Create: `WattlyTests/BatteryFactsTests.swift`
- Modify: `project.yml:74-79` (WattlyFanDaemon sources)

**Interfaces:**
- Consumes: `smcInt(_ bytes: [UInt8], type: String) -> Int?` (`Wattly/Core/BatteryPower.swift`), `batteryCelsius(rawCentiCelsius: Int, in: ClosedRange<Double>) -> Double?` (`Wattly/Core/Temperature.swift`). 둘 다 이미 앱·데몬 두 타깃에 컴파일된다.
- Produces (Task 2·3·4가 그대로 쓴다):
  ```swift
  struct BatteryFacts: Equatable, Sendable {
      var remainingMilliampHours: Int? = nil
      var maxMilliampHours: Int? = nil        // Nominal
      var designMilliampHours: Int? = nil
      var cycleCount: Int? = nil
      var temperatureCelsius: Double? = nil
      var currentMilliamps: Int? = nil        // +충전 / −방전
  }
  enum BatteryFactsSource {
      static let temperatureRange: ClosedRange<Double>
      static func fromSMC(read: (String) -> (type: String, bytes: [UInt8])?) -> BatteryFacts
      static func fromRegistry(topLevel: [String: Int], batteryData: [String: Any]?) -> BatteryFacts
      static func merged(primary: BatteryFacts, fallback: BatteryFacts) -> BatteryFacts
  }
  ```

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/BatteryFactsTests.swift`:

```swift
import Testing
@testable import Wattly

/// macOS 27에서 AppleSmartBattery 최상위 키가 사라진 뒤의 배터리 사실 디코딩·우선순위.
/// 바이트 벡터는 2026-09-17 Mac17,2 / macOS 27.0 실측값이다.
struct BatteryFactsTests {

    // MARK: fromSMC — B0RM/B0NC/B0DC/B0CT/B0AT/B0AC (전부 리틀엔디안)

    private static let liveSMC: [String: (type: String, bytes: [UInt8])] = [
        "B0RM": ("ui16", [0xb8, 0x10]),   // 4280 mAh
        "B0NC": ("ui16", [0x6f, 0x18]),   // 6255 mAh
        "B0DC": ("ui16", [0x69, 0x18]),   // 6249 mAh
        "B0CT": ("ui16", [0x89, 0x00]),   // 137 cycles
        "B0AT": ("ui16", [0xfb, 0x0b]),   // 3067 centi-°C
        "B0AC": ("si16", [0x29, 0x10]),   // +4137 mA (charging)
    ]

    @Test func smcDecodesEveryLiveKey() {
        let facts = BatteryFactsSource.fromSMC { Self.liveSMC[$0] }
        #expect(facts.remainingMilliampHours == 4280)
        #expect(facts.maxMilliampHours == 6255)
        #expect(facts.designMilliampHours == 6249)
        #expect(facts.cycleCount == 137)
        #expect(facts.temperatureCelsius == 30.67)
        #expect(facts.currentMilliamps == 4137)
    }

    @Test func smcNegativeCurrentIsSignExtended() {
        let facts = BatteryFactsSource.fromSMC { key in
            key == "B0AC" ? ("si16", [0x12, 0xf8]) : nil     // −2030 mA (discharging)
        }
        #expect(facts.currentMilliamps == -2030)
    }

    @Test func smcMissingKeysStayNil() {
        let facts = BatteryFactsSource.fromSMC { _ in nil }
        #expect(facts == BatteryFacts())
    }

    @Test func smcRejectsZeroCapacityAndOutOfRangeTemperature() {
        let facts = BatteryFactsSource.fromSMC { key in
            switch key {
            case "B0NC": return ("ui16", [0x00, 0x00])   // 0 mAh → 무효
            case "B0AT": return ("ui16", [0x28, 0x23])   // 9000 centi-°C = 90 °C → 범위 밖
            default: return nil
            }
        }
        #expect(facts.maxMilliampHours == nil)
        #expect(facts.temperatureCelsius == nil)
    }

    // MARK: fromRegistry — 레거시 최상위 키 우선, BatteryData 서브딕셔너리 폴백

    @Test func registryLegacyTopLevelKeysWinOverBatteryData() {
        let facts = BatteryFactsSource.fromRegistry(
            topLevel: ["AppleRawCurrentCapacity": 6175, "AppleRawMaxCapacity": 6238,
                       "DesignCapacity": 6249, "CycleCount": 112, "Temperature": 3072],
            batteryData: ["RemainingCapacity": 1, "NominalChargeCapacity": 2, "DesignCapacity": 3])
        #expect(facts.remainingMilliampHours == 6175)
        #expect(facts.maxMilliampHours == 6238)
        #expect(facts.designMilliampHours == 6249)
        #expect(facts.cycleCount == 112)
        #expect(facts.temperatureCelsius == 30.72)
        #expect(facts.currentMilliamps == nil)   // 레지스트리는 전류를 주지 않는다
    }

    @Test func registryFallsBackToBatteryDataOnMacOS27() {
        // macOS 27 실측: 최상위에는 CycleCount만 남고 mAh는 BatteryData로 옮겨갔다.
        let facts = BatteryFactsSource.fromRegistry(
            topLevel: ["CycleCount": 137],
            batteryData: ["RemainingCapacity": 4280, "NominalChargeCapacity": 6255,
                          "FullChargeCapacity": 6103, "DesignCapacity": 6249])
        #expect(facts.remainingMilliampHours == 4280)
        #expect(facts.maxMilliampHours == 6255)      // Nominal, FullChargeCapacity가 아니다
        #expect(facts.designMilliampHours == 6249)
        #expect(facts.cycleCount == 137)
        #expect(facts.temperatureCelsius == nil)
    }

    @Test func registryRejectsNonPositiveAndOutOfRange() {
        let facts = BatteryFactsSource.fromRegistry(
            topLevel: ["AppleRawMaxCapacity": 0, "Temperature": -100],
            batteryData: ["DesignCapacity": -5])
        #expect(facts == BatteryFacts())
    }

    // MARK: merged — 필드별 primary ?? fallback

    @Test func mergedFillsOnlyTheHolesFromFallback() {
        var primary = BatteryFacts()
        primary.cycleCount = 112
        primary.temperatureCelsius = 30.72
        var fallback = BatteryFacts()
        fallback.remainingMilliampHours = 4280
        fallback.maxMilliampHours = 6255
        fallback.cycleCount = 137            // primary가 있으니 무시
        fallback.temperatureCelsius = 30.67  // primary가 있으니 무시
        fallback.currentMilliamps = 4137

        let merged = BatteryFactsSource.merged(primary: primary, fallback: fallback)
        #expect(merged.remainingMilliampHours == 4280)
        #expect(merged.maxMilliampHours == 6255)
        #expect(merged.designMilliampHours == nil)
        #expect(merged.cycleCount == 112)
        #expect(merged.temperatureCelsius == 30.72)
        #expect(merged.currentMilliamps == 4137)
    }
}
```

- [ ] **Step 2: 파일 생성 + 타깃 등록 + 테스트가 실패하는지 확인**

`Wattly/Core/BatteryFacts.swift`를 빈 내용이 아니라 아래 스텁으로 만든다(컴파일은 되지만 전부 nil을 돌려줘 테스트가 실패하게):

```swift
import Foundation

struct BatteryFacts: Equatable, Sendable {
    var remainingMilliampHours: Int? = nil
    var maxMilliampHours: Int? = nil
    var designMilliampHours: Int? = nil
    var cycleCount: Int? = nil
    var temperatureCelsius: Double? = nil
    var currentMilliamps: Int? = nil
}

enum BatteryFactsSource {
    static let temperatureRange: ClosedRange<Double> = 0...80
    static func fromSMC(read: (String) -> (type: String, bytes: [UInt8])?) -> BatteryFacts { BatteryFacts() }
    static func fromRegistry(topLevel: [String: Int], batteryData: [String: Any]?) -> BatteryFacts { BatteryFacts() }
    static func merged(primary: BatteryFacts, fallback: BatteryFacts) -> BatteryFacts { primary }
}
```

`project.yml`의 WattlyFanDaemon sources(74–79행)에 한 줄 추가:

```yaml
    sources:
      - path: WattlyFanDaemon
      - path: FanControlShared
      - path: Wattly/Core/SMC.swift
      - path: Wattly/Core/BatteryPower.swift
      - path: Wattly/Core/BatteryFacts.swift
      - path: Wattly/Core/Temperature.swift
```

Run:
```bash
xcodegen generate
```
Expected: `⚙️  Generating project...` … `✅  Created project at .../Wattly.xcodeproj`

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/BatteryFactsTests 2>&1 | grep -E "Test .* (passed|failed)|error:|\*\* TEST"
```
Expected: 스텁이 빈 사실을 돌려주므로 `smcMissingKeysStayNil`·`registryRejectsNonPositiveAndOutOfRange` 2개만 passed, 나머지 6개 `failed`, 마지막 줄 `** TEST FAILED **`.

- [ ] **Step 3: 최소 구현**

`Wattly/Core/BatteryFacts.swift` 전체를 다음으로 교체:

```swift
import Foundation

/// 용량(mAh)·사이클·온도·실전류를 **출처와 무관하게** 한 형태로 모은 배터리 사실.
///
/// macOS 27(펌웨어 20457, 2026-09-17 Mac17,2 실측)부터 `AppleSmartBattery` 최상위 키
/// `AppleRawMaxCapacity`/`AppleRawCurrentCapacity`/`DesignCapacity`/`Temperature`/
/// `ChargingCurrent`가 사라졌다. mAh는 `BatteryData` 서브딕셔너리로 옮겨갔고, 같은 값이
/// SMC `B0RM`/`B0NC`/`B0DC`/`B0CT`/`B0AT`/`B0AC`로도 읽힌다. 디코딩과 우선순위 결정은
/// 여기 한 곳에만 있고(`BatteryPower`/`Temperature`와 같은 패턴), IOKit·SMC I/O는
/// `BatteryProvider`·`AppleSmartBatteryReader`·`FanControlDaemon`이 각자 한다.
struct BatteryFacts: Equatable, Sendable {
    var remainingMilliampHours: Int? = nil
    /// Nominal 충전 용량. Full-charge(`B0FC`)가 아니다 — 옛 `AppleRawMaxCapacity`의
    /// 관측 범위와 Apple 자체 "최대 용량 %"가 둘 다 Nominal 쪽이다(스펙 §3-1).
    var maxMilliampHours: Int? = nil
    var designMilliampHours: Int? = nil
    var cycleCount: Int? = nil
    var temperatureCelsius: Double? = nil
    /// 배터리 실전류 mA. 양수 = 충전, 음수 = 방전. 레지스트리는 주지 않고 SMC만 준다.
    var currentMilliamps: Int? = nil
}

enum BatteryFactsSource {
    /// 배터리 팩 온도의 그럴듯한 범위(°C). `BatteryProvider`가 예전부터 쓰던 값.
    static let temperatureRange: ClosedRange<Double> = 0...80

    /// SMC 읽기 클로저 → 사실. 없는 키·디코드 실패·0 이하 mAh·범위 밖 온도는 nil.
    /// 실측 타입: `B0RM`/`B0NC`/`B0DC`/`B0CT`/`B0AT` = ui16, `B0AC` = si16 (전부 LE).
    static func fromSMC(read: (String) -> (type: String, bytes: [UInt8])?) -> BatteryFacts {
        func int(_ key: String) -> Int? {
            guard let raw = read(key) else { return nil }
            return smcInt(raw.bytes, type: raw.type)
        }
        var facts = BatteryFacts()
        facts.remainingMilliampHours = positive(int("B0RM"))
        facts.maxMilliampHours = positive(int("B0NC"))
        facts.designMilliampHours = positive(int("B0DC"))
        facts.cycleCount = int("B0CT")
        facts.temperatureCelsius = int("B0AT").flatMap { batteryCelsius(rawCentiCelsius: $0, in: temperatureRange) }
        facts.currentMilliamps = int("B0AC")
        return facts
    }

    /// 레지스트리 → 사실. `topLevel`은 macOS 26 이하의 최상위 키, `batteryData`는 macOS 27의
    /// `BatteryData` 서브딕셔너리. 최상위 키가 있으면 그것이 이긴다(26 이하에서 오늘과
    /// 바이트 단위로 같은 값을 유지하기 위해서).
    static func fromRegistry(topLevel: [String: Int], batteryData: [String: Any]?) -> BatteryFacts {
        func sub(_ key: String) -> Int? { (batteryData?[key] as? NSNumber)?.intValue }
        var facts = BatteryFacts()
        facts.remainingMilliampHours = positive(topLevel["AppleRawCurrentCapacity"] ?? sub("RemainingCapacity"))
        facts.maxMilliampHours = positive(topLevel["AppleRawMaxCapacity"] ?? sub("NominalChargeCapacity"))
        facts.designMilliampHours = positive(topLevel["DesignCapacity"] ?? sub("DesignCapacity"))
        facts.cycleCount = topLevel["CycleCount"]
        facts.temperatureCelsius = topLevel["Temperature"].flatMap { batteryCelsius(rawCentiCelsius: $0, in: temperatureRange) }
        return facts
    }

    /// 필드별 `primary ?? fallback`. 호출자가 우선순위를 정한다(스펙: 레지스트리 → SMC).
    static func merged(primary: BatteryFacts, fallback: BatteryFacts) -> BatteryFacts {
        BatteryFacts(
            remainingMilliampHours: primary.remainingMilliampHours ?? fallback.remainingMilliampHours,
            maxMilliampHours: primary.maxMilliampHours ?? fallback.maxMilliampHours,
            designMilliampHours: primary.designMilliampHours ?? fallback.designMilliampHours,
            cycleCount: primary.cycleCount ?? fallback.cycleCount,
            temperatureCelsius: primary.temperatureCelsius ?? fallback.temperatureCelsius,
            currentMilliamps: primary.currentMilliamps ?? fallback.currentMilliamps)
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/BatteryFactsTests 2>&1 | grep -E "Test .* (passed|failed)|error:|\*\* TEST"
```
Expected: 8개 전부 `passed`, `** TEST SUCCEEDED **`.

데몬 타깃에도 컴파일되는지:
```bash
xcodebuild -project Wattly.xcodeproj -target WattlyFanDaemon -configuration Debug build 2>&1 | grep -E "error:|\*\* BUILD"
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: 커밋**

```bash
git checkout -- docs/assets 2>/dev/null; git add Wattly/Core/BatteryFacts.swift WattlyTests/BatteryFactsTests.swift project.yml Wattly.xcodeproj/project.pbxproj
git commit -m "feat(battery): add BatteryFacts decoder with registry→SMC fallback for macOS 27

AppleSmartBattery lost AppleRawMaxCapacity/AppleRawCurrentCapacity/
DesignCapacity/Temperature/ChargingCurrent at the top level on macOS 27
(firmware 20457). Pure decoder reads the BatteryData sub-dict and the SMC
keys B0RM/B0NC/B0DC/B0CT/B0AT/B0AC; consumers wire it in follow-up commits.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: `BatteryProvider` 배선 + DEBUG 배터리 프로브

**Files:**
- Modify: `Wattly/Providers/BatteryProvider.swift` (스냅샷 구조체 `:29-40`, `smcSample` `:51-100`, `appleSmartBatterySnapshot` `:102-148`, `appleSmartBatteryReading` `:152-194`, 파일 끝에 `BatteryProbe`)
- Modify: `Wattly/App/WattlyApp.swift:17` (훅 한 줄)
- Modify: `Wattly/Models/MetricSample.swift:153-162` (주석)

**Interfaces:**
- Consumes: Task 1의 `BatteryFacts`, `BatteryFactsSource.fromSMC(read:)`, `fromRegistry(topLevel:batteryData:)`, `merged(primary:fallback:)`; 기존 `SMCConnection.read(_:) -> (type: String, bytes: [UInt8])?`.
- Produces: `BatterySample` 필드 의미 불변(`remainingWh`, `maxWh`, `efficiencyPercent`, `cycleCount`, `temperatureCelsius`). 실기 검증용 `Wattly -WattlyBatteryProbe` 플래그.

이 태스크는 IOKit 배선이라 단위 테스트 대신 **DEBUG 프로브로 실기 검증**한다(기존 `ThermalProbe`/`FanProbe`와 같은 관례, `TemperatureProvider.swift:191-230`).

- [ ] **Step 1: 스냅샷 구조체를 `facts` 하나로 바꾼다**

`Wattly/Providers/BatteryProvider.swift:29-40`의 `AppleSmartBatterySnapshot`을 다음으로 교체:

```swift
    private struct AppleSmartBatterySnapshot {
        var volts: Double?
        var externalConnected: Bool
        var batteryMilliwatts: Int?
        var timeRemainingMinutes: Int?
        /// 레지스트리에서 읽은 용량·사이클·온도(macOS 26 이하 최상위 키 → 27의 `BatteryData`).
        /// SMC 폴백과의 병합은 `smcSample`이 한다.
        var facts: BatteryFacts
        var systemPowerInWatts: Double? = nil
        var systemLoadWatts: Double? = nil
    }
```

- [ ] **Step 2: `smcSample`에서 SMC 사실을 폴백으로 병합**

`smcSample(registry:)` 안에서 `return BatterySample(` 직전에 한 줄 추가하고, `BatterySample` 생성부의 5개 인자를 `facts`로 바꾼다. `:51-100`을 다음으로 교체:

```swift
    private func smcSample(registry: AppleSmartBatterySnapshot?) -> BatterySample? {
        guard let smc,
              let power = smc.read("B0AP"),
              let voltage = smc.read("B0AV"),
              let milliwatts = smcInt(power.bytes, type: power.type) else { return nil }
        let volts = smcDouble(voltage.bytes, type: voltage.type) / 1000.0
        let netW = netWatts(batteryMilliwatts: milliwatts)
        let mA = smc.read("B0AC").flatMap { smcInt($0.bytes, type: $0.type) }
            ?? batteryMilliamps(batteryMilliwatts: milliwatts, volts: volts)
        let adapterW = smc.read("PDTR").map { smcDouble($0.bytes, type: $0.type) } ?? registry?.systemPowerInWatts ?? 0.0
        let measuredSystemW = smc.read("PSTR").map { smcDouble($0.bytes, type: $0.type) } ?? registry?.systemLoadWatts
        let externalConnected = adapterW > 0.5 || (registry?.externalConnected == true)
        // 레지스트리가 이기고 SMC가 빈칸을 채운다 — macOS 26 이하는 오늘과 같은 값, 27은
        // 사라진 최상위 키를 B0RM/B0NC/B0DC/B0CT/B0AT가 메운다(스펙 §3-2).
        let facts = BatteryFactsSource.merged(
            primary: registry?.facts ?? BatteryFacts(),
            fallback: BatteryFactsSource.fromSMC(read: smc.read))

        let systemWatts = calculateSystemWatts(
            adapterWatts: adapterW,
            batteryNetWatts: netW,
            measuredSystemWatts: measuredSystemW
        )
        let scenario = resolvePowerFlowScenario(
            externalConnected: externalConnected,
            adapterWatts: adapterW,
            batteryNetWatts: netW,
            isChargeInhibited: false
        )
        let powerFlow = PowerFlowSnapshot(
            scenario: scenario,
            adapterWatts: adapterW,
            systemWatts: systemWatts,
            batteryNetWatts: netW
        )

        return BatterySample(
            netW: netW,
            milliamps: abs(mA),
            volts: volts,
            charging: isCharging(netW: netW),
            externalConnected: externalConnected,
            remainingWh: remainingWattHours(
                rawCapacityMilliampHours: facts.remainingMilliampHours ?? 0),
            maxWh: remainingWattHours(
                rawCapacityMilliampHours: facts.maxMilliampHours ?? 0),
            timeRemainingMinutes: validatedTimeRemainingMinutes(registry?.timeRemainingMinutes),
            efficiencyPercent: batteryEfficiencyPercent(
                maxCapacityMilliampHours: facts.maxMilliampHours ?? 0,
                designCapacityMilliampHours: facts.designMilliampHours ?? 0),
            cycleCount: validatedBatteryCycleCount(facts.cycleCount),
            temperatureCelsius: facts.temperatureCelsius,
            powerFlow: powerFlow)
    }
```

- [ ] **Step 3: 레지스트리 스냅샷이 `BatteryFactsSource.fromRegistry`를 쓰게 한다**

`appleSmartBatterySnapshot()` `:102-148`을 다음으로 교체(온도 계산 블록과 5개 필드가 `facts` 한 줄로 바뀐다):

```swift
    private func appleSmartBatterySnapshot() -> AppleSmartBatterySnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        let volts = number(service, "Voltage").map { Double($0.int64Value) / 1000.0 }
        let rawExternalConnected = bool(service, "ExternalConnected") ?? false
        let adapterWatts = (dict(service, "AdapterDetails")?["Watts"] as? NSNumber)?.intValue ?? 0
        let externalConnected = rawExternalConnected || adapterWatts > 0
        let batteryMilliwatts: Int?
        if let telemetry = dict(service, "PowerTelemetryData"),
           let raw = (telemetry["BatteryPower"] as? NSNumber)?.uint64Value {
            batteryMilliwatts = twosComplement(raw)
        } else if let rawAmp = number(service, "InstantAmperage")?.uint64Value, let volts {
            batteryMilliwatts = Int((Double(twosComplement(rawAmp)) * volts).rounded())
        } else {
            batteryMilliwatts = nil
        }

        // macOS 26 이하 최상위 키(있는 것만 담는다) + macOS 27 `BatteryData` 서브딕셔너리.
        var topLevel: [String: Int] = [:]
        for key in ["AppleRawCurrentCapacity", "AppleRawMaxCapacity", "DesignCapacity", "CycleCount", "Temperature"] {
            if let value = number(service, key)?.intValue { topLevel[key] = value }
        }
        let facts = BatteryFactsSource.fromRegistry(topLevel: topLevel, batteryData: dict(service, "BatteryData"))

        var systemPowerInW: Double? = nil
        var systemLoadW: Double? = nil
        if let telemetry = dict(service, "PowerTelemetryData") {
            if let pin = (telemetry["SystemPowerIn"] as? NSNumber)?.doubleValue {
                systemPowerInW = pin / 1000.0
            }
            if let load = (telemetry["SystemLoad"] as? NSNumber)?.doubleValue {
                systemLoadW = load / 1000.0
            }
        }

        return AppleSmartBatterySnapshot(
            volts: volts,
            externalConnected: externalConnected,
            batteryMilliwatts: batteryMilliwatts,
            timeRemainingMinutes: number(service, "TimeRemaining")?.intValue ?? number(service, "AvgTimeToFull")?.intValue ?? number(service, "TimeToFull")?.intValue,
            facts: facts,
            systemPowerInWatts: systemPowerInW,
            systemLoadWatts: systemLoadW)
    }
```

- [ ] **Step 4: AppleSmartBattery 폴백 경로도 `facts`를 쓴다**

`appleSmartBatteryReading(registry:)` `:152-194`의 `BatterySample(` 생성부에서 5개 인자를 바꾼다(그 위의 netW/powerFlow 계산은 그대로):

```swift
        return .value(.battery(BatterySample(
            netW: netW, milliamps: abs(batteryMilliamps(batteryMilliwatts: milliwatts, volts: volts)),
            volts: volts, charging: isCharging(netW: netW), externalConnected: registry.externalConnected,
            remainingWh: remainingWattHours(
                rawCapacityMilliampHours: registry.facts.remainingMilliampHours ?? 0),
            maxWh: remainingWattHours(
                rawCapacityMilliampHours: registry.facts.maxMilliampHours ?? 0),
            timeRemainingMinutes: validatedTimeRemainingMinutes(registry.timeRemainingMinutes),
            efficiencyPercent: batteryEfficiencyPercent(
                maxCapacityMilliampHours: registry.facts.maxMilliampHours ?? 0,
                designCapacityMilliampHours: registry.facts.designMilliampHours ?? 0),
            cycleCount: validatedBatteryCycleCount(registry.facts.cycleCount),
            temperatureCelsius: registry.facts.temperatureCelsius,
            powerFlow: powerFlow)))
```

- [ ] **Step 5: 빌드로 컴파일 오류 잡기**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -configuration Debug build 2>&1 | grep -E "error:|\*\* BUILD"
```
Expected: `** BUILD SUCCEEDED **`. `rawCurrentCapacityMilliampHours` 등 옛 필드를 참조하는 곳이 남아 있으면 여기서 잡힌다 — 전부 `facts.*`로 바꾼다.

- [ ] **Step 6: DEBUG `BatteryProbe` 추가 + 앱 훅**

`Wattly/Providers/BatteryProvider.swift` 파일 끝에 추가:

```swift
#if DEBUG
/// DEBUG 실기 프로브. 실제 `BatteryProvider`(SMC 우선 + 레지스트리)로 3회 읽어 출력하고 종료한다.
/// OS 업데이트 뒤 배터리 사실(효율·Wh·온도·사이클)이 살아 있는지 GUI 없이 확인하는 용도:
///   `Wattly.app/Contents/MacOS/Wattly -WattlyBatteryProbe`
/// Release에서는 제외. 막힌 메인 스레드 밖에서 돌도록 detached.
enum BatteryProbe {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("-WattlyBatteryProbe") else { return }
        let provider = BatteryProvider()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let clock = ContinuousClock()
            for i in 0..<3 {
                let reading = await provider.read(at: clock.now)
                print("[battery-probe] sample \(i): \(describe(reading))")
                try? await Task.sleep(for: .seconds(1))
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }

    private static func describe(_ r: ProviderReading) -> String {
        guard case .value(.battery(let s)) = r else { return "non-battery: \(r)" }
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "nil" }
        return "net \(f(s.netW)) W · \(s.milliamps) mA · \(f(s.volts)) V · charging=\(s.charging) ext=\(s.externalConnected)"
            + " · remaining \(f(s.remainingWh)) Wh / max \(f(s.maxWh)) Wh · pct \(s.percentage.map(String.init) ?? "nil")"
            + " · efficiency \(f(s.efficiencyPercent)) % · cycles \(s.cycleCount.map(String.init) ?? "nil")"
            + " · temp \(f(s.temperatureCelsius)) °C · timeRemaining \(s.timeRemainingMinutes.map(String.init) ?? "nil") min"
    }
}
#endif
```

`Wattly/App/WattlyApp.swift:17`(`FanProbe.runIfRequested()` 줄) 바로 아래에 추가:

```swift
        BatteryProbe.runIfRequested()  // -WattlyBatteryProbe: dump live battery facts and exit (macOS 27 migration)
```

- [ ] **Step 7: `MetricSample.swift` 주석 갱신**

`Wattly/Models/MetricSample.swift:153-154`의

```swift
    /// Health/efficiency: AppleRawMaxCapacity ÷ DesignCapacity × 100. nil when the
    /// registry capacity pair is absent or invalid.
```
를
```swift
    /// Health/efficiency: Nominal max capacity ÷ DesignCapacity × 100 (`BatteryFacts`:
    /// registry `AppleRawMaxCapacity` → `BatteryData.NominalChargeCapacity` → SMC `B0NC`).
    /// nil when no source yields a valid capacity pair.
```
로, `:162`의
```swift
    /// Battery pack temperature, °C (from AppleSmartBattery centi-°C). nil on desktop or unreadable.
```
를
```swift
    /// Battery pack temperature, °C (registry `Temperature` centi-°C, or SMC `B0AT` on macOS 27+). nil on desktop or unreadable.
```
로 바꾼다.

- [ ] **Step 8: 실기 프로브로 검증(macOS 27)**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -configuration Debug build 2>&1 | grep -E "error:|\*\* BUILD" && APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*Debug/Wattly.app/Contents/MacOS/Wattly" | head -1) && "$APP" -WattlyBatteryProbe 2>&1 | grep -a battery-probe
```
Expected(값은 다르되 형태는 이렇게, **nil이 하나도 없어야 한다**):
```
[battery-probe] sample 0: net -39.19 W · 3265 mA · 12.00 V · charging=true ext=true · remaining 49.43 Wh / max 72.25 Wh · pct 68 · efficiency 100.10 % · cycles 137 · temp 30.67 °C · timeRemaining 104 min
```
`remaining`/`max`/`efficiency`/`temp`/`cycles` 중 하나라도 `nil`이면 Step 2·3의 병합이 잘못된 것이다(SMC 키 이름 오타 우선 의심).

- [ ] **Step 9: 전체 테스트 + 커밋**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | grep -E "Executed|error:|failed|\*\* TEST"
```
Expected: 마지막 줄 `** TEST SUCCEEDED **`.

```bash
git checkout -- docs/assets 2>/dev/null; git add Wattly/Providers/BatteryProvider.swift Wattly/App/WattlyApp.swift Wattly/Models/MetricSample.swift
git commit -m "feat(battery): restore capacity/efficiency/temperature on macOS 27 via SMC fallback

BatteryProvider now merges BatteryFacts (registry first, SMC B0RM/B0NC/
B0DC/B0CT/B0AT fallback) so the battery card's Wh, efficiency, cycle and
temperature rows return on macOS 27. Adds -WattlyBatteryProbe (DEBUG) for
headless on-device checks.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: 캘리브레이션 리더(`AppleSmartBatteryReader`) 폴백 + 정체 전류 헬퍼

**Files:**
- Modify: `Wattly/Core/AppleSmartBatteryReader.swift:39-44` (헬퍼 추가), `:56-78` (`read()`)
- Modify: `WattlyTests/AppleSmartBatteryReaderTests.swift` (테스트 추가)
- Modify: `Wattly/Core/BatteryCalibration.swift:141-146` (주석)

**Interfaces:**
- Consumes: Task 1의 `BatteryFactsSource.fromSMC/fromRegistry/merged`.
- Produces: `CalibrationBatteryReading` 필드·`init` 시그니처 불변(`BatteryCalibrationCoordinatorTests`가 positional로 만든다). 새 순수 헬퍼:
  ```swift
  extension CalibrationBatteryReading {
      static func chargingCurrent(registry: Int?, smcBatteryCurrent: Int?) -> Int?
  }
  ```

- [ ] **Step 1: 실패하는 테스트 작성**

`WattlyTests/AppleSmartBatteryReaderTests.swift`의 `chargeStallUsesTheMeasuredCurrentThreshold` 테스트 바로 아래에 추가:

```swift
    @Test func chargingCurrentPrefersRegistryThenClampsSMCCurrent() {
        // macOS 26 이하: 레지스트리 `ChargingCurrent`(설정 전류)가 그대로 이긴다.
        #expect(CalibrationBatteryReading.chargingCurrent(registry: 100, smcBatteryCurrent: 3265) == 100)
        // macOS 27: 레지스트리가 없으면 SMC `B0AC` 실전류. 충전 중 양수는 그대로.
        #expect(CalibrationBatteryReading.chargingCurrent(registry: nil, smcBatteryCurrent: 3265) == 3265)
        // 방전 중(음수)은 "충전 전류 0" — 게이트가 열렸는데 안 들어오면 정체로 보여야 한다.
        #expect(CalibrationBatteryReading.chargingCurrent(registry: nil, smcBatteryCurrent: -2030) == 0)
        // 둘 다 없으면 nil — 판독 실패를 정체로 단정하지 않는다(isChargeStalled == false).
        #expect(CalibrationBatteryReading.chargingCurrent(registry: nil, smcBatteryCurrent: nil) == nil)
    }
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/AppleSmartBatteryReaderTests 2>&1 | grep -E "error:|Test .* (passed|failed)|\*\* TEST"
```
Expected: 컴파일 오류 `type 'CalibrationBatteryReading' has no member 'chargingCurrent'` → `** TEST FAILED **`.

- [ ] **Step 3: 헬퍼 + `read()` 구현**

`Wattly/Core/AppleSmartBatteryReader.swift`의 `isChargeStalled` 계산 프로퍼티(`:41-44`) 바로 아래, 구조체 닫는 `}` 안에 추가:

```swift
    /// 정체 판정에 쓸 충전 전류. 레지스트리 `ChargingCurrent`(macOS 26 이하, 충전기에 *설정된*
    /// 전류 — 최적화된 배터리 충전이 막으면 100 mA)가 있으면 그대로, 없으면(macOS 27) SMC
    /// `B0AC` 실전류를 쓴다. 실전류는 방전이면 음수라 0으로 접는다 — 게이트를 열었는데 전류가
    /// 안 들어오는 상황이 정확히 "정체"다.
    static func chargingCurrent(registry: Int?, smcBatteryCurrent: Int?) -> Int? {
        if let registry { return registry }
        return smcBatteryCurrent.map { max(0, $0) }
    }
```

`read()` `:56-78`을 다음으로 교체:

```swift
    func read() -> CalibrationBatteryReading {
        var reading = CalibrationBatteryReading()

        if !smcAttempted { smcAttempted = true; smc = SMCConnection() }
        let smcFacts = smc.map { BatteryFactsSource.fromSMC(read: $0.read) } ?? BatteryFacts()

        var registryFacts = BatteryFacts()
        var registryChargingCurrent: Int?
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            reading.isCharging = bool(service, "IsCharging")
            reading.adapterWatts = (dict(service, "AdapterDetails")?["Watts"] as? NSNumber)?.intValue
            registryChargingCurrent = number(service, "ChargingCurrent")?.intValue
            var topLevel: [String: Int] = [:]
            for key in ["AppleRawMaxCapacity", "DesignCapacity", "CycleCount"] {
                if let value = number(service, key)?.intValue { topLevel[key] = value }
            }
            registryFacts = BatteryFactsSource.fromRegistry(topLevel: topLevel, batteryData: dict(service, "BatteryData"))
        }

        // 레지스트리 → SMC 폴백 — `BatteryProvider`와 같은 우선순위라 앱 카드와 캘리브레이션
        // 리포트가 같은 mAh를 말한다(스펙 §3-2).
        let facts = BatteryFactsSource.merged(primary: registryFacts, fallback: smcFacts)
        reading.chargingCurrentMilliamps = CalibrationBatteryReading.chargingCurrent(
            registry: registryChargingCurrent, smcBatteryCurrent: smcFacts.currentMilliamps)
        reading.maxCapacityMilliampHours = facts.maxMilliampHours
        reading.designCapacityMilliampHours = facts.designMilliampHours
        reading.cycleCount = facts.cycleCount

        if let smc, let power = smc.read("B0AP"),
           let milliwatts = smcInt(power.bytes, type: power.type) {
            reading.netWatts = netWatts(batteryMilliwatts: milliwatts)
        }
        return reading
    }
```

- [ ] **Step 4: 테스트 통과 확인**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/AppleSmartBatteryReaderTests 2>&1 | grep -E "error:|Test .* (passed|failed)|\*\* TEST"
```
Expected: 4개 전부 `passed`(기존 3 + 신규 1), `** TEST SUCCEEDED **`. `liveReadEitherAnswersOrDegradesToNils`는 실기에서 `maxCapacityMilliampHours > 0`을 실제로 검사하게 된다.

- [ ] **Step 5: `chargeStallMilliamps` 주석 갱신**

`Wattly/Core/BatteryCalibration.swift:142-145`의

```swift
    /// 충전 정체 판정: 어댑터가 붙고 게이트도 열렸는데 충전 전류가 이 값 아래로 이만큼
    /// 지속되면 외부 요인이 막고 있는 것이다. 실기에서 "최적화된 배터리 충전"이 켜져 있을 때
    /// `ChargingCurrent`가 100 mA에 머물렀다.
```
를
```swift
    /// 충전 정체 판정: 어댑터가 붙고 게이트도 열렸는데 충전 전류가 이 값 아래로 이만큼
    /// 지속되면 외부 요인이 막고 있는 것이다. 실기에서 "최적화된 배터리 충전"이 켜져 있을 때
    /// `ChargingCurrent`가 100 mA에 머물렀다. macOS 27부터 그 키가 없어 SMC `B0AC` 실전류를
    /// 쓴다(`CalibrationBatteryReading.chargingCurrent`) — 실전류도 같은 상황에서 0에 붙는다.
```
로 바꾼다.

- [ ] **Step 6: 관련 스위트 + 커밋**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test -only-testing:WattlyTests/AppleSmartBatteryReaderTests -only-testing:WattlyTests/BatteryCalibrationCoordinatorTests -only-testing:WattlyTests/BatteryCalibrationTests 2>&1 | grep -E "error:|failed|\*\* TEST"
```
Expected: `** TEST SUCCEEDED **`, `failed` 없음.

```bash
git checkout -- docs/assets 2>/dev/null; git add Wattly/Core/AppleSmartBatteryReader.swift WattlyTests/AppleSmartBatteryReaderTests.swift Wattly/Core/BatteryCalibration.swift
git commit -m "feat(battery): calibration reader falls back to SMC facts and B0AC on macOS 27

ChargingCurrent/AppleRawMaxCapacity/DesignCapacity vanished from the
registry on macOS 27; the calibration reader now merges BatteryFacts and
derives the stall current from the SMC battery current (clamped at 0).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: 데몬 열 보호 온도 폴백(SMC `B0AT`)

**Files:**
- Modify: `WattlyFanDaemon/FanControlDaemon.swift:8-49` (프로퍼티·init, init은 `:35-47`), `:193-209` (온도 읽기)
- Modify: `WattlyFanDaemon/main.swift:59-63` (배선)

**Interfaces:**
- Consumes: Task 1의 `BatteryFactsSource.fromSMC(read:)`(데몬 타깃에 이미 컴파일됨), `main.swift`의 기존 `smc: SMCControlConnection`.
- Produces: `FanControlDaemon.init(allowedUID:hardware:batteryCoordinator:batteryTemperatureFallback:)` — 마지막 인자는 `@escaping @Sendable () -> Double?`, 기본값 `{ nil }`.

데몬 타깃에는 테스트 호스트가 없다(`BatteryControlKeys` 주석 참고). 그래서 로직은 Task 1의 순수 함수에 두고 여기서는 **한 줄 폴백**만 배선한다. 검증은 데몬 빌드 + 앱의 설정 > 배터리 열 보호 상태 문구로 한다.

- [ ] **Step 1: 클로저 주입**

`WattlyFanDaemon/FanControlDaemon.swift:10`(`private let batteryCoordinator: BatteryControlCoordinator`) 아래에 프로퍼티 추가:

```swift
    /// 레지스트리 `Temperature`가 없을 때(macOS 27+) 쓰는 배터리 온도. `main.swift`가 SMC
    /// `B0AT`를 읽는 클로저를 넣는다. 데몬 `queue` 위에서만 호출된다 — SMC 연결도 그 큐에서만 쓴다.
    private let batteryTemperatureFallback: @Sendable () -> Double?
```

`init` `:35-47`을 다음으로 교체:

```swift
    init(
        allowedUID: uid_t,
        hardware: any FanControlHardware,
        batteryCoordinator: BatteryControlCoordinator,
        batteryTemperatureFallback: @escaping @Sendable () -> Double? = { nil }
    ) {
        self.allowedUID = allowedUID
        self.engine = FanControlEngine(hardware: hardware)
        self.batteryCoordinator = batteryCoordinator
        self.batteryTemperatureFallback = batteryTemperatureFallback
        self.batteryControlService = BatteryDaemonControlService(
            coordinator: batteryCoordinator)
        self.listener = NSXPCListener(machServiceName: FanControlXPC.machService)
        super.init()
    }
```

- [ ] **Step 2: 온도 읽기에 폴백 적용**

`readBatteryTelemetryFromRegistry()` 안 `:200-206`

```swift
        var tempC: Double? = nil
        if let rawNumber = IORegistryEntryCreateCFProperty(service, "Temperature" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
            let centiCelsius = rawNumber.intValue
            if (0...8000).contains(centiCelsius) {
                tempC = Double(centiCelsius) / 100.0
            }
        }
```
바로 아래에 추가:

```swift
        // macOS 27부터 `Temperature` 키가 없다 — 없으면 SMC `B0AT`(같은 centi-°C 단위)로 채운다.
        // 이게 없으면 열 보호가 영원히 `batterySensorUnreadable`이다.
        if tempC == nil { tempC = batteryTemperatureFallback() }
```

- [ ] **Step 3: `main.swift` 배선**

`WattlyFanDaemon/main.swift:59-63`

```swift
let daemon = FanControlDaemon(
    allowedUID: uid_t(uid),
    hardware: hardware,
    batteryCoordinator: batteryCoordinator
)
```
를
```swift
let daemon = FanControlDaemon(
    allowedUID: uid_t(uid),
    hardware: hardware,
    batteryCoordinator: batteryCoordinator,
    // 레지스트리 `Temperature`가 사라진 macOS 27용 폴백. `smc`는 데몬 큐에서만 쓰인다.
    batteryTemperatureFallback: { BatteryFactsSource.fromSMC(read: smc.read).temperatureCelsius }
)
```
로 바꾼다.

- [ ] **Step 4: 데몬·앱 빌드 + 전체 테스트**

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' -configuration Debug build 2>&1 | grep -E "error:|warning: .*Sendable|\*\* BUILD"
```
Expected: `** BUILD SUCCEEDED **`, Sendable 경고 없음. (`smc`는 `SMCConnection: @unchecked Sendable`이라 `@Sendable` 클로저 캡처가 허용된다. 경고가 나면 `let smcForTemperature = smc` 대신 클로저 안에서 `smc.read`를 직접 참조하는지 확인.)

Run:
```bash
xcodebuild -project Wattly.xcodeproj -scheme Wattly -destination 'platform=macOS' test 2>&1 | grep -E "Executed|error:|failed|\*\* TEST"
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: 커밋**

```bash
git checkout -- docs/assets 2>/dev/null; git add WattlyFanDaemon/FanControlDaemon.swift WattlyFanDaemon/main.swift
git commit -m "feat(daemon): fall back to SMC B0AT for battery temperature on macOS 27

The registry Temperature key is gone on macOS 27, which left heat
protection permanently at batterySensorUnreadable. The daemon now takes
an injected fallback that reads B0AT through its existing SMC connection.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: 실기 종합 검증 + 남은 미확정 기록

**Files:**
- Modify: `docs/superpowers/specs/2026-09-17-macos-27-battery-facts-migration.md` (§5 아래에 실기 결과 한 단락)

**Interfaces:** 없음(검증·기록만).

- [ ] **Step 1: 앱 프로브·팝오버 확인**

Run:
```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -path "*Debug/Wattly.app/Contents/MacOS/Wattly" | head -1) && "$APP" -WattlyBatteryProbe 2>&1 | grep -a battery-probe
```
Expected: 세 샘플 모두 `remaining`/`max`/`efficiency`/`cycles`/`temp`에 `nil` 없음.

앱을 실행해(`open "$(dirname "$(dirname "$(dirname "$APP")")")"`) 메뉴바 팝오버의 배터리 카드를 펼친다. Expected: [범주 2]에 배터리 온도 행, [범주 3]에 잔여 용량 Wh · 효율 % · 사이클 행이 보인다(효율 행은 설정 > 배터리에서 "효율 표시"가 켜져 있을 때). 확인 뒤 앱 종료.

- [ ] **Step 2: 데몬 열 보호 문구 확인 (설치된 도우미 교체는 사용자 결정)**

이 머신에는 `/Library/PrivilegedHelperTools/dev.jjundev.WattlyFanDaemon`이 **이미 설치되어 실행 중**이다(2026-09-09 빌드). 새 데몬은 앱의 설정 > 배터리 > 도우미 행에서 "재설치"를 눌러야 교체되며 관리자 암호가 필요하다. 이 단계는 **사용자에게 재설치를 요청**하고, 재설치 후 열 보호 상태가 `batterySensorUnreadable`("배터리 센서를 읽을 수 없음")이 아닌지만 확인한다. 사용자가 부재면 이 단계를 건너뛰고 Step 3에 "미검증"으로 적는다.

- [ ] **Step 3: 미확정 항목을 스펙에 기록**

스펙 파일 끝에 다음 단락을 추가(값은 실제 관측값으로 채운다):

```markdown
## 6. 실기 결과 (2026-09-17, macOS 27.0)

- `-WattlyBatteryProbe`: remaining/max/efficiency/cycles/temp 전부 non-nil. (관측값 한 줄 붙여넣기)
- 팝오버 배터리 카드: 온도·잔여 용량·효율·사이클 행 복구 확인.
- 데몬 열 보호: (재설치 후 확인 / 미검증 중 하나)
- 미확정: `AppleRawMaxCapacity`가 Nominal이었는지 FCC였는지. 100% 충전 시 `B0RM`이 `B0NC`(6255)·`B0FC`(6103) 중 어느 쪽에 붙는지 확인하면 결정된다 — FCC 쪽이면 `BatteryFactsSource`의 `B0NC`/`NominalChargeCapacity` 두 곳을 `B0FC`/`FullChargeCapacity`로 바꾸고 `BatteryFactsTests`의 기대값을 갱신한다.
```

- [ ] **Step 4: 커밋**

```bash
git checkout -- docs/assets 2>/dev/null; git add docs/superpowers/specs/2026-09-17-macos-27-battery-facts-migration.md docs/superpowers/plans/2026-09-17-macos-27-battery-facts-migration.md
git commit -m "docs(battery): record macOS 27 battery-facts migration spec, plan and on-device results

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review

- **스펙 커버리지**: §1의 다섯 키 → 용량 3종·온도(Task 1 디코더 + Task 2 앱 + Task 4 데몬), `ChargingCurrent`(Task 3). §3-1 Nominal(Task 1 `B0NC`/`NominalChargeCapacity` + 테스트 `registryFallsBackToBatteryDataOnMacOS27`). §3-2 우선순위(Task 2·3 `merged(primary: registry, fallback: smc)`, Task 4는 `Temperature ?? B0AT`). §3-4 정체 전류(Task 3). §3-5 가드 재사용(Task 1). §3-6 계약 불변(Task 2·3 시그니처 유지). §5 검증(Task 1 테스트, Task 2 Step 8, Task 5).
- **플레이스홀더**: 없음. 모든 코드 스텝에 실제 코드.
- **타입 일관성**: `BatteryFacts` 필드명 6개(`remainingMilliampHours`/`maxMilliampHours`/`designMilliampHours`/`cycleCount`/`temperatureCelsius`/`currentMilliamps`)와 `BatteryFactsSource.fromSMC(read:)`/`fromRegistry(topLevel:batteryData:)`/`merged(primary:fallback:)` 시그니처가 Task 1~4에서 동일. `SMCConnection.read`는 `(String) -> (type: String, bytes: [UInt8])?`로 `fromSMC(read:)`에 메서드 참조로 그대로 들어간다. `CalibrationBatteryReading.chargingCurrent(registry:smcBatteryCurrent:)`는 Task 3 테스트·구현·호출이 동일. `FanControlDaemon.init`의 새 인자명 `batteryTemperatureFallback`은 Task 4 Step 1·3에서 동일.
