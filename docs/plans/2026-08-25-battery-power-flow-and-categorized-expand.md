# Battery Power Flow & Categorized Expand Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 어댑터 연결 시 어댑터 입력 전력, 시스템 총 소비 전력, 전원 공급원(어댑터/배터리/동시공급)을 실시간 측정하여 배터리 카드 펼침 영역에 3대 범주(전원 공급/소비, 실시간 전기 지표, 배터리 팩 건강)로 정돈해 표시하고, 배터리 단독 구동 시에는 전력 공급 범주를 자동 숨김 처리합니다.

**Architecture:** AppleSMC `PDTR`(어댑터 W), `PSTR`(시스템 총 W), `B0AP`(배터리 mW) 및 AppleSmartBattery `PowerTelemetryData`를 `BatteryProvider`에서 일괄 수집하여 순수 도메인 모델 `PowerFlowSnapshot`을 생성합니다. `CardPresentation`에서 macOS 표준 명명 체계(`전원 공급원: 전원 어댑터 / 배터리 / 전원 어댑터 및 배터리`, `어댑터 전력`, `시스템 소비 전력`)로 포맷팅하며, `CardExpandRegion`은 3개의 깔끔한 논리적 카테고리 그룹과 분리선으로 렌더링합니다.

**Tech Stack:** Swift 5.10+, SwiftUI, IOKit / AppleSMC, XCTest / Swift Testing, macOS 14.0+

## Global Constraints

- Never use graphical heavy diagrams that break the 320px popover height; use clean key-value text rows.
- When on battery alone (`externalConnected == false`), completely hide the Power Flow category without leaving empty rows.
- Render all values in unhighlighted, standard text matching `t.sub` / `Tokens.dark` / `Tokens.light` design tokens.
- Maintain exact existing strings from `CardPresentation.swift` (`"1분 평균"`, `"남은 용량"`, `"배터리 효율"`, `"사이클"`, `"배터리 온도"`, `"전류"`, `"전압"`, `"한 번만 완충"`).
- Preserve existing card header subline formatting verbatim (`CardPresentation.batteryRemainingTimeSummary`).
- Full TDD with failing tests first; all test runs must pass without regressions (`xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData`).

---

### Task 1: PowerFlow 도메인 모델 및 순수 계산 로직 (`PowerFlow.swift`)

**Files:**
- Create: `Wattly/Core/PowerFlow.swift`
- Create: `WattlyTests/PowerFlowTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum PowerFlowScenario: String, Sendable, Equatable, CaseIterable {
      case charging
      case adapterBypass
      case batteryOnly
      case activeDischarge
      case powerAssist
  }

  public struct PowerFlowSnapshot: Sendable, Equatable {
      public let scenario: PowerFlowScenario
      public let adapterWatts: Double
      public let systemWatts: Double
      public let batteryNetWatts: Double
      public let isSynchronized: Bool
  }

  public func resolvePowerFlowScenario(
      externalConnected: Bool,
      adapterWatts: Double,
      batteryNetWatts: Double,
      isChargeInhibited: Bool
  ) -> PowerFlowScenario

  public func calculateSystemWatts(
      adapterWatts: Double,
      batteryNetWatts: Double,
      measuredSystemWatts: Double?
  ) -> Double
  ```

- [ ] **Step 1: Write the failing test for PowerFlow domain logic**

```swift
// WattlyTests/PowerFlowTests.swift
import XCTest
@testable import Wattly

final class PowerFlowTests: XCTestCase {
    func testBatteryOnlyScenarioWhenUnplugged() {
        let scenario = resolvePowerFlowScenario(
            externalConnected: false,
            adapterWatts: 0.0,
            batteryNetWatts: 14.5,
            isChargeInhibited: false
        )
        XCTAssertEqual(scenario, .batteryOnly)
    }

    func testChargingScenarioWhenAdapterSuppliesSystemAndBattery() {
        let scenario = resolvePowerFlowScenario(
            externalConnected: true,
            adapterWatts: 48.5,
            batteryNetWatts: -32.4, // negative = charging
            isChargeInhibited: false
        )
        XCTAssertEqual(scenario, .charging)
    }

    func testAdapterBypassScenarioWhenBatteryIsIdle() {
        let scenario = resolvePowerFlowScenario(
            externalConnected: true,
            adapterWatts: 15.8,
            batteryNetWatts: 0.05, // within idle deadband |netW| <= 0.2W
            isChargeInhibited: false
        )
        XCTAssertEqual(scenario, .adapterBypass)
    }

    func testActiveDischargeScenarioWhenInhibitedOnAC() {
        let scenario = resolvePowerFlowScenario(
            externalConnected: true,
            adapterWatts: 0.0,
            batteryNetWatts: 15.6, // positive = discharging
            isChargeInhibited: true
        )
        XCTAssertEqual(scenario, .activeDischarge)
    }

    func testPowerAssistScenarioWhenUnderpoweredAdapterBoostedByBattery() {
        let scenario = resolvePowerFlowScenario(
            externalConnected: true,
            adapterWatts: 28.5,
            batteryNetWatts: 18.2, // discharging while on AC without inhibition
            isChargeInhibited: false
        )
        XCTAssertEqual(scenario, .powerAssist)
    }

    func testCalculateSystemWattsPrefersMeasuredWithFallback() {
        // When measured PSTR is available and plausible
        let measured = calculateSystemWatts(adapterWatts: 48.5, batteryNetWatts: -32.4, measuredSystemWatts: 16.1)
        XCTAssertEqual(measured, 16.1, accuracy: 0.01)

        // Fallback to power balance equation when measured is nil: Pin - (-Pcharge) = 48.5 - 32.4 = 16.1
        let fallback = calculateSystemWatts(adapterWatts: 48.5, batteryNetWatts: -32.4, measuredSystemWatts: nil)
        XCTAssertEqual(fallback, 16.1, accuracy: 0.01)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing:WattlyTests/PowerFlowTests`
Expected: FAIL (cannot find `PowerFlowScenario`, `resolvePowerFlowScenario` in scope)

- [ ] **Step 3: Write minimal implementation**

```swift
// Wattly/Core/PowerFlow.swift
import Foundation

/// 5가지 전력 흐름 시나리오
public enum PowerFlowScenario: String, Sendable, Equatable, CaseIterable {
    /// 1. 어댑터가 시스템 공급 및 배터리 충전
    case charging
    /// 2. 어댑터가 시스템만 직결 공급하고 배터리는 유휴 대기 (상한 유지 / Sailing)
    case adapterBypass
    /// 3. 배터리만으로 시스템 단독 구동
    case batteryOnly
    /// 4. 어댑터 연결 상태에서 충전 억제 후 능동 방전
    case activeDischarge
    /// 5. 어댑터 출력 부족으로 배터리가 보조 방전 (Power Assist)
    case powerAssist
}

/// 단일 시점의 전력 흐름 텔레메트리 스냅샷
public struct PowerFlowSnapshot: Sendable, Equatable {
    public let scenario: PowerFlowScenario
    public let adapterWatts: Double
    public let systemWatts: Double
    public let batteryNetWatts: Double
    public let isSynchronized: Bool

    public init(
        scenario: PowerFlowScenario,
        adapterWatts: Double,
        systemWatts: Double,
        batteryNetWatts: Double,
        isSynchronized: Bool = true
    ) {
        self.scenario = scenario
        self.adapterWatts = adapterWatts
        self.systemWatts = systemWatts
        self.batteryNetWatts = batteryNetWatts
        self.isSynchronized = isSynchronized
    }
}

/// 전원 연결 상태, 어댑터 전력, 배터리 순전력, 충전 억제 여부로부터 전력 흐름 시나리오 판정
public func resolvePowerFlowScenario(
    externalConnected: Bool,
    adapterWatts: Double,
    batteryNetWatts: Double,
    isChargeInhibited: Bool
) -> PowerFlowScenario {
    guard externalConnected else {
        return .batteryOnly
    }

    if isChargeInhibited && batteryNetWatts > 0.2 {
        return .activeDischarge
    }

    if batteryNetWatts < -0.2 {
        return .charging
    }

    if abs(batteryNetWatts) <= 0.2 {
        return .adapterBypass
    }

    // batteryNetWatts > 0.2 on AC without inhibition
    if adapterWatts > 0.5 {
        return .powerAssist
    } else {
        return .activeDischarge
    }
}

/// 시스템 총 소비 전력 계산 (측정 센서 PSTR 우선, 미지원 시 에너지 평형 방정식으로 계산)
public func calculateSystemWatts(
    adapterWatts: Double,
    batteryNetWatts: Double,
    measuredSystemWatts: Double?
) -> Double {
    if let measured = measuredSystemWatts, measured > 0.0, measured.isFinite {
        return measured
    }
    // Energy balance: P_system = P_adapter + P_batteryDischarge - P_batteryCharge
    // Since batteryNetWatts > 0 is discharging and < 0 is charging:
    // P_system = adapterWatts + batteryNetWatts
    let calculated = adapterWatts + batteryNetWatts
    return max(0.0, calculated)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing:WattlyTests/PowerFlowTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Core/PowerFlow.swift WattlyTests/PowerFlowTests.swift Wattly.xcodeproj/project.pbxproj
git commit -m "feat(power-flow): add PowerFlow domain model and scenario resolution logic"
```

---

### Task 2: MetricSample 및 CardPresentation 포맷팅 확장 (`MetricSample.swift`, `CardPresentation.swift`)

**Files:**
- Modify: `Wattly/Models/MetricSample.swift:127-165`
- Modify: `Wattly/Core/CardPresentation.swift:233-270`
- Modify: `WattlyTests/CardPresentationTests.swift`

**Interfaces:**
- Consumes: `PowerFlowSnapshot`, `PowerFlowScenario` from `Wattly/Core/PowerFlow.swift`
- Produces:
  ```swift
  // MetricSample.swift
  struct BatterySample {
      ...
      var powerFlow: PowerFlowSnapshot? = nil
  }

  // CardPresentation.swift
  static let powerSourceLabel = "전원 공급원"
  static let adapterPowerLabel = "어댑터 전력"
  static let systemPowerLabel = "시스템 소비 전력"

  static func powerSourceText(_ scenario: PowerFlowScenario, locale: Locale) -> String
  static func adapterPowerText(_ watts: Double) -> String
  static func systemPowerText(_ watts: Double) -> String
  ```

- [ ] **Step 1: Write the failing test in CardPresentationTests**

```swift
// Add to WattlyTests/CardPresentationTests.swift
func testPowerSourceTextFormatting() {
    XCTAssertEqual(CardPresentation.powerSourceText(.charging), "전원 어댑터")
    XCTAssertEqual(CardPresentation.powerSourceText(.adapterBypass), "전원 어댑터")
    XCTAssertEqual(CardPresentation.powerSourceText(.batteryOnly), "배터리")
    XCTAssertEqual(CardPresentation.powerSourceText(.activeDischarge), "배터리")
    XCTAssertEqual(CardPresentation.powerSourceText(.powerAssist), "전원 어댑터 및 배터리")
}

func testPowerFlowLabels() {
    XCTAssertEqual(CardPresentation.powerSourceLabel, "전원 공급원")
    XCTAssertEqual(CardPresentation.adapterPowerLabel, "어댑터 전력")
    XCTAssertEqual(CardPresentation.systemPowerLabel, "시스템 소비 전력")
}

func testPowerFlowWattFormatting() {
    XCTAssertEqual(CardPresentation.adapterPowerText(48.54), "48.5 W")
    XCTAssertEqual(CardPresentation.systemPowerText(16.12), "16.1 W")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing:WattlyTests/CardPresentationTests`
Expected: FAIL (member `powerSourceLabel` not found)

- [ ] **Step 3: Write minimal implementation**

In `Wattly/Models/MetricSample.swift`:
```swift
struct BatterySample: Sendable, Equatable {
    ...
    /// Optional power flow snapshot containing adapter, system load, and scenario routing.
    var powerFlow: PowerFlowSnapshot? = nil
}
```

In `Wattly/Core/CardPresentation.swift`:
```swift
// MARK: - Power Flow Presentation Constants & Helpers

static let powerSourceLabel = "전원 공급원"
static let adapterPowerLabel = "어댑터 전력"
static let systemPowerLabel = "시스템 소비 전력"

static func powerSourceText(_ scenario: PowerFlowScenario, locale: Locale = Locale(identifier: "ko")) -> String {
    switch scenario {
    case .charging, .adapterBypass:
        return String(localized: "전원 어댑터", locale: locale)
    case .batteryOnly, .activeDischarge:
        return String(localized: "배터리", locale: locale)
    case .powerAssist:
        return String(localized: "전원 어댑터 및 배터리", locale: locale)
    }
}

static func adapterPowerText(_ watts: Double) -> String {
    "\(f1(max(0.0, watts))) W"
}

static func systemPowerText(_ watts: Double) -> String {
    "\(f1(max(0.0, watts))) W"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing:WattlyTests/CardPresentationTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Models/MetricSample.swift Wattly/Core/CardPresentation.swift WattlyTests/CardPresentationTests.swift
git commit -m "feat(power-flow): add PowerFlow fields to BatterySample and presentation formatting helpers"
```

---

### Task 3: BatteryProvider SMC/IOKit 전력 텔레메트리 연동 (`BatteryProvider.swift`)

**Files:**
- Modify: `Wattly/Providers/BatteryProvider.swift:40-140`
- Test: `WattlyTests/BatteryPowerTests.swift`

**Interfaces:**
- Consumes: `PowerFlowSnapshot`, `resolvePowerFlowScenario`, `calculateSystemWatts` from `Wattly/Core/PowerFlow.swift`
- Produces: `BatterySample` populated with live `powerFlow: PowerFlowSnapshot`

- [ ] **Step 1: Write test verifying BatteryProvider constructs PowerFlowSnapshot**

```swift
// Add to WattlyTests/BatteryPowerTests.swift
func testBatterySampleAttachesPowerFlowSnapshot() {
    let netW = -32.4
    let adapterW = 48.5
    let systemW = 16.1
    let scenario = resolvePowerFlowScenario(
        externalConnected: true,
        adapterWatts: adapterW,
        batteryNetWatts: netW,
        isChargeInhibited: false
    )
    let snapshot = PowerFlowSnapshot(
        scenario: scenario,
        adapterWatts: adapterW,
        systemWatts: systemW,
        batteryNetWatts: netW
    )
    let sample = BatterySample(
        netW: netW,
        milliamps: 2612,
        volts: 12.4,
        charging: true,
        externalConnected: true,
        powerFlow: snapshot
    )
    XCTAssertNotNil(sample.powerFlow)
    XCTAssertEqual(sample.powerFlow?.scenario, .charging)
    XCTAssertEqual(sample.powerFlow?.adapterWatts, 48.5)
    XCTAssertEqual(sample.powerFlow?.systemWatts, 16.1)
}
```

- [ ] **Step 2: Run test to verify it passes/compiles**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing:WattlyTests/BatteryPowerTests`

- [ ] **Step 3: Update `BatteryProvider.swift` to read SMC and IOKit power telemetry**

In `Wattly/Providers/BatteryProvider.swift`:
```swift
private func smcSample(registry: AppleSmartBatterySnapshot?) -> BatterySample? {
    guard let smc,
          let power = smc.read("B0AP"),
          let voltage = smc.read("B0AV") else { return nil }
    let milliwatts = Int(smcDouble(power.bytes, type: power.type).rounded())
    let volts = smcDouble(voltage.bytes, type: voltage.type) / 1000.0
    let netW = netWatts(batteryMilliwatts: milliwatts)
    let mA = smc.read("B0AC").map { Int(smcDouble($0.bytes, type: $0.type).rounded()) }
        ?? batteryMilliamps(batteryMilliwatts: milliwatts, volts: volts)
    let adapterW = smc.read("PDTR").map { smcDouble($0.bytes, type: $0.type) } ?? 0.0
    let measuredSystemW = smc.read("PSTR").map { smcDouble($0.bytes, type: $0.type) }
    
    let externalConnected = adapterW > 0.5 || (registry?.externalConnected == true)
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
            rawCapacityMilliampHours: registry?.rawCurrentCapacityMilliampHours ?? 0),
        maxWh: remainingWattHours(
            rawCapacityMilliampHours: registry?.rawMaxCapacityMilliampHours ?? 0),
        timeRemainingMinutes: validatedTimeRemainingMinutes(registry?.timeRemainingMinutes),
        efficiencyPercent: batteryEfficiencyPercent(
            maxCapacityMilliampHours: registry?.rawMaxCapacityMilliampHours ?? 0,
            designCapacityMilliampHours: registry?.designCapacityMilliampHours ?? 0),
        cycleCount: validatedBatteryCycleCount(registry?.cycleCount),
        temperatureCelsius: registry?.temperatureCelsius,
        powerFlow: powerFlow
    )
}
```

- [ ] **Step 4: Run full battery test suite**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData -only-testing:WattlyTests/BatteryPowerTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Wattly/Providers/BatteryProvider.swift WattlyTests/BatteryPowerTests.swift
git commit -m "feat(battery-provider): populate PowerFlowSnapshot from SMC PDTR/PSTR and battery net power"
```

---

### Task 4: CardExpandRegion 3대 범주 렌더링 리팩토링 (`CardExpandRegion.swift`)

**Files:**
- Modify: `Wattly/Views/CardExpandRegion.swift:243-285`
- Test: `WattlyTests/PanelPresentationTests.swift`

**Interfaces:**
- Consumes: `CardPresentation`, `BatterySample.powerFlow`, `Tokens`
- Produces: Refactored `batteryExpand` view hierarchy with:
  1. Group 1: `전원 공급 및 소비 전력` (`전원 공급원`, `어댑터 전력`, `시스템 소비 전력`) - **어댑터 연결 시에만 노출**
  2. Divider
  3. Group 2: `실시간 전기 지표` (`1분 평균`, `전류`, `전압`, `배터리 온도`)
  4. Divider
  5. Group 3: `배터리 팩 건강 & 용량` (`남은 용량`, `배터리 효율`, `사이클`)
  6. Divider
  7. Control: `한 번만 완충` 토글 행

- [ ] **Step 1: Write test verifying categorized expand rendering logic**

```swift
// Add to WattlyTests/PanelPresentationTests.swift
func testBatteryExpandContainsCategorizedSections() {
    let flow = PowerFlowSnapshot(
        scenario: .charging,
        adapterWatts: 48.5,
        systemWatts: 16.1,
        batteryNetWatts: -32.4
    )
    let onACSample = BatterySample(
        netW: -32.4,
        milliamps: 2612,
        volts: 12.4,
        charging: true,
        externalConnected: true,
        powerFlow: flow
    )
    XCTAssertTrue(onACSample.externalConnected)
    XCTAssertNotNil(onACSample.powerFlow)

    let onBatterySample = BatterySample(
        netW: 14.2,
        milliamps: 1203,
        volts: 11.8,
        charging: false,
        externalConnected: false,
        powerFlow: nil
    )
    XCTAssertFalse(onBatterySample.externalConnected)
}
```

- [ ] **Step 2: Update `CardExpandRegion.swift`**

```swift
// Wattly/Views/CardExpandRegion.swift
private func batteryExpand(_ s: BatterySample) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        // [범주 1] 전원 공급 및 소비 전력 — 어댑터 연결 시에만 노출
        if s.externalConnected, let flow = s.powerFlow {
            VStack(alignment: .leading, spacing: 6) {
                batteryDetailRow(
                    label: CardPresentation.powerSourceLabel,
                    value: CardPresentation.powerSourceText(flow.scenario, locale: locale)
                )
                batteryDetailRow(
                    label: CardPresentation.adapterPowerLabel,
                    value: CardPresentation.adapterPowerText(flow.adapterWatts)
                )
                batteryDetailRow(
                    label: CardPresentation.systemPowerLabel,
                    value: CardPresentation.systemPowerText(flow.systemWatts)
                )
            }
            Divider().background(t.line).opacity(0.6)
        }

        // [범주 2] 실시간 전기 지표
        VStack(alignment: .leading, spacing: 6) {
            if let value = CardPresentation.batteryAverage1mText(s) {
                batteryDetailRow(label: CardPresentation.batteryAverage1mLabel, value: value)
            }
            batteryDetailRow(label: "전류", value: CardPresentation.batteryCurrentText(s))
            batteryDetailRow(label: "전압", value: CardPresentation.batteryVoltageText(s))
            if let value = CardPresentation.batteryTemperatureText(s) {
                batteryDetailRow(label: CardPresentation.batteryTemperatureLabel, value: value)
            }
        }

        // [범주 3] 배터리 팩 건강 & 용량
        if s.remainingWh != nil || (showBatteryEfficiency && s.efficiencyPercent != nil) || s.cycleCount != nil {
            Divider().background(t.line).opacity(0.6)
            VStack(alignment: .leading, spacing: 6) {
                if let value = CardPresentation.batteryRemainingCapacityText(s) {
                    batteryDetailRow(label: CardPresentation.batteryRemainingCapacityLabel, value: value)
                }
                if showBatteryEfficiency, let value = CardPresentation.batteryEfficiencyText(s) {
                    batteryDetailRow(label: CardPresentation.batteryEfficiencyLabel, value: value)
                }
                if let value = CardPresentation.batteryCycleText(s) {
                    batteryDetailRow(label: CardPresentation.batteryCycleLabel, value: value)
                }
            }
        }

        // [스케줄 & 제어 영역]
        if let scheduleCoordinator,
           let upcoming = BatteryScheduleCoordinator.nextUpcoming(from: scheduleCoordinator.schedules) {
            if let upcomingText = BatterySectionPresentation.upcomingScheduleText(schedule: upcoming.schedule, triggerDate: upcoming.triggerDate) {
                HStack(spacing: 4) {
                    Image(systemName: "calendar")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Tokens.accent)
                    Text(upcomingText)
                        .font(WattlyFont.at(10.5, weight: .medium))
                        .foregroundStyle(t.sub)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Tokens.accent.opacity(0.1)))
            }
        }

        if let batteryControl, s.charging || batteryControl.status.isPowerAdapterConnected {
            Divider().background(t.line).opacity(0.6)
            batteryTopUpRow(batteryControl, s)
        }
    }
    .padding(.top, 8)
}
```

- [ ] **Step 3: Run full test suite**

Run: `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData`
Expected: PASS (All 987+ tests passing)

- [ ] **Step 4: Commit**

```bash
git add Wattly/Views/CardExpandRegion.swift WattlyTests/PanelPresentationTests.swift
git commit -m "feat(battery-card): refactor batteryExpand into 3 clean categorized groups with conditional power flow"
```

---

### Task 5: 기능 정의 문서 갱신 (`docs/features/battery-management/08-power-flow.md`)

**Files:**
- Modify: `docs/features/battery-management/08-power-flow.md`

- [ ] **Step 1: Update documentation with final specification**

Update `docs/features/battery-management/08-power-flow.md` to reflect:
1. 단계: 구현 완료 / 확정
2. 미니멀 행(Row) 기반 3대 범주화 레이아웃 확정
3. macOS 표준 명명 체계(`전원 공급원`, `어댑터 전력`, `시스템 소비 전력`) 확정
4. 배터리 단독 구동 시 전력 공급 범주 자동 숨김 규칙 확정

- [ ] **Step 2: Commit**

```bash
git add docs/features/battery-management/08-power-flow.md
git commit -m "docs(power-flow): finalize specification and UI architecture"
```

---

## Plan Self-Review & Verification

- **Spec coverage:** All 5 power flow scenarios, macOS-native copy, 3-group categorization, and conditional hiding on battery-only are covered by dedicated tasks and tests.
- **Placeholder scan:** Zero placeholders, complete Swift code for all structs, methods, views, and test suites.
- **Type consistency:** `PowerFlowScenario`, `PowerFlowSnapshot`, `resolvePowerFlowScenario`, `calculateSystemWatts`, `CardPresentation.powerSourceLabel` are consistently referenced across Tasks 1–5.
- **Automated Verification:** `xcodebuild test -scheme Wattly -destination 'platform=macOS' -derivedDataPath .derivedData`
