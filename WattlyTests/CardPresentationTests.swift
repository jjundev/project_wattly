import Testing
import Foundation
@testable import Wattly

/// Characterization tests for the pure card-presentation seam (issue: deepen the
/// shallow `MetricCardView`). These pin the *current* rendered strings/units/sign
/// rules so the extraction from the view is provably behavior-preserving — they
/// cross the `CardPresentation` interface directly, with no SwiftUI.
struct CardPresentationTests {

    // The displayed minus is U+2212 (MINUS SIGN), not an ASCII hyphen.
    private let minus = "\u{2212}"

    // MARK: Battery sign rule (#17) — one home, shared by value + sub-line

    @Test func gpuCardKindProperties() {
        let card = CardKind.gpu
        #expect(card.id == "gpu")
        #expect(card.provider == .gpu)
        #expect(card.isExpandable)
        #expect(card.hasSparkArea)
        #expect(!card.isAccented)
        #expect(!card.isSmoothable)
    }

    @Test func gpuSampleEquality() {
        let s1 = GPUSample(overall: 45.2, coreCount: 10, activeGHz: 1.28, rendererUsage: 45.0, tilerUsage: 20.0, inUseMemoryBytes: 100, allocMemoryBytes: 200)
        let s2 = GPUSample(overall: 45.2, coreCount: 10, activeGHz: 1.28, rendererUsage: 45.0, tilerUsage: 20.0, inUseMemoryBytes: 100, allocMemoryBytes: 200)
        let s3 = GPUSample(overall: 50.0, coreCount: 10, activeGHz: 1.35, rendererUsage: 50.0, tilerUsage: 25.0, inUseMemoryBytes: 100, allocMemoryBytes: 200)
        #expect(s1 == s2)
        #expect(s1 != s3)
        let sample = MetricSample.gpu(s1)
        if case .gpu(let s) = sample {
            #expect(s.overall == 45.2)
            #expect(s.coreCount == 10)
            #expect(s.activeGHz == 1.28)
            #expect(s.rendererUsage == 45.0)
            #expect(s.tilerUsage == 20.0)
            #expect(s.inUseMemoryBytes == 100)
            #expect(s.allocMemoryBytes == 200)
        } else {
            Issue.record("Expected .gpu sample")
        }
    }

    @Test func gpuCardPresentation() {
        let sample = GPUSample(overall: 38.4, coreCount: 10, activeGHz: 1.28)
        let state = MetricState.value(.gpu(sample))
        #expect(CardPresentation.label(.gpu) == "GPU")
        #expect(CardPresentation.unitText(.gpu, state) == "%")
        #expect(CardPresentation.valueText(.gpu, state) == "38")
        #expect(CardPresentation.compactRowText(.gpu, state) == "38%")
        #expect(CardPresentation.subText(state) == "1.28 GHz")
    }

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

    @Test func batterySignDropsAtZeroMagnitude() {
        #expect(CardPresentation.batterySign(netW: 12.0, charging: false) == minus)   // discharging
        #expect(CardPresentation.batterySign(netW: -30.0, charging: true) == "+")     // charging
        #expect(CardPresentation.batterySign(netW: 0.0, charging: false) == "")       // exact zero → no sign
        #expect(CardPresentation.batterySign(netW: 0.03, charging: false) == "")      // |x| < 0.05 → no sign
        #expect(CardPresentation.batterySign(netW: 0.05, charging: false) == minus)   // boundary: not < 0.05 → sign
    }

    @Test func batteryValueAndCollapsedSummary() {
        let discharging = MetricState.value(.battery(BatterySample(
            netW: 12.0,
            milliamps: 944,
            volts: 12.7,
            charging: false,
            externalConnected: false,
            timeRemainingMinutes: 210,
            projectedTimeRemainingMinutes: 210,
            average1mW: 10.4)))
        #expect(CardPresentation.valueText(.battery, discharging) == "\(minus)12.0")
        #expect(CardPresentation.subText(discharging) == "약 3시간 30분 남음")

        let timeOnly = MetricState.value(.battery(BatterySample(
            netW: 12.0,
            milliamps: 944,
            volts: 12.7,
            charging: false,
            externalConnected: false,
            timeRemainingMinutes: 1,
            projectedTimeRemainingMinutes: 1)))
        #expect(CardPresentation.subText(timeOnly) == "약 1분 남음")

        let averageOnly = MetricState.value(.battery(BatterySample(
            netW: -5.0,
            milliamps: 400,
            volts: 12.7,
            charging: true,
            externalConnected: true,
            average1mW: -3.0)))
        #expect(CardPresentation.subText(averageOnly) == nil)

        let noDetail = MetricState.value(.battery(BatterySample(
            netW: 0.0,
            milliamps: 0,
            volts: 12.7,
            charging: false,
            externalConnected: true)))
        #expect(CardPresentation.subText(noDetail) == nil)
    }

    @Test func batteryAverageAndRemainingTimeVisibilityRules() {
        let discharging = BatterySample(
            netW: 12.0,
            milliamps: 944,
            volts: 12.7,
            charging: false,
            externalConnected: false,
            timeRemainingMinutes: 210,
            projectedTimeRemainingMinutes: 210,
            average1mW: 10.4)
        #expect(CardPresentation.batteryAverage1mLabel == "1분 평균")
        #expect(CardPresentation.batteryAverage1mText(discharging) == "\(minus)10.4 W")
        #expect(CardPresentation.batteryRemainingTimeSummary(discharging) == "약 3시간 30분 남음")

        let rawOnly = BatterySample(
            netW: 20.0,
            milliamps: 1_575,
            volts: 12.7,
            charging: false,
            externalConnected: false,
            remainingWh: 49.5,
            timeRemainingMinutes: 149)
        #expect(CardPresentation.batteryRemainingTimeSummary(rawOnly) == nil)

        let charging = BatterySample(
            netW: -5.0,
            milliamps: 400,
            volts: 12.7,
            charging: true,
            externalConnected: true,
            projectedTimeRemainingMinutes: 210,
            average1mW: -3.0)
        #expect(CardPresentation.batteryAverage1mText(charging) == "+3.0 W")
        #expect(CardPresentation.batteryRemainingTimeSummary(charging) == "완충까지 약 3시간 30분 남음")
    }

    @Test func batteryChargingDisplayRules() {
        let charging = BatterySample(
            netW: -20.0,
            milliamps: 1500,
            volts: 12.5,
            charging: true,
            externalConnected: true,
            remainingWh: 30.0,
            maxWh: 60.0,
            projectedTimeRemainingMinutes: 90
        )
        let state = MetricState.value(.battery(charging))
        // Collapsed subText shows preview when charging
        #expect(CardPresentation.subText(state) == "완충까지 약 1시간 30분 남음")
        // Label and text for expanded view
        #expect(CardPresentation.batteryTimeToFullLabel == "완충까지 남은 시간")
        #expect(CardPresentation.batteryTimeToFullText(charging) == "약 1시간 30분 남음")
    }

    @Test func formatDurationOmitsZeroHours() {
        #expect(CardPresentation.formatDuration(minutes: 10) == "10분")
        #expect(CardPresentation.formatDuration(minutes: 60) == "1시간")
        #expect(CardPresentation.formatDuration(minutes: 90) == "1시간 30분")
    }

    @Test func batteryCurrentAndVoltageTextForExpand() {
        let discharging = BatterySample(netW: 12.0, milliamps: 944, volts: 12.7,
                                         charging: false, externalConnected: false)
        #expect(CardPresentation.batteryCurrentText(discharging) == "\(minus)944 mA")
        #expect(CardPresentation.batteryVoltageText(discharging) == "12.7 V")

        let charging = BatterySample(netW: -30.0, milliamps: 2362, volts: 12.7,
                                      charging: true, externalConnected: true)
        #expect(CardPresentation.batteryCurrentText(charging) == "+2362 mA")
        #expect(CardPresentation.batteryVoltageText(charging) == "12.7 V")

        let zero = BatterySample(netW: 0.0, milliamps: 0, volts: 12.7,
                                  charging: false, externalConnected: true)
        #expect(CardPresentation.batteryCurrentText(zero) == "0 mA")
    }

    @Test func batteryRemainingCapacityEfficiencyAndCycleTextForExpand() {
        let populated = BatterySample(
            netW: 12.0,
            milliamps: 944,
            volts: 12.7,
            charging: false,
            externalConnected: false,
            remainingWh: 49.457568,
            timeRemainingMinutes: 210,
            projectedTimeRemainingMinutes: 210,
            efficiencyPercent: 99.56793086893903,
            cycleCount: 77)
        #expect(CardPresentation.batteryRemainingCapacityLabel == "남은 용량")
        #expect(CardPresentation.batteryEfficiencyLabel == "배터리 효율")
        #expect(CardPresentation.batteryCycleLabel == "사이클")
        #expect(CardPresentation.batteryRemainingCapacityText(populated) == "49.5 Wh")
        #expect(CardPresentation.batteryEfficiencyText(populated) == "99.6%")
        #expect(CardPresentation.batteryCycleText(populated) == "77")
        #expect(CardPresentation.batteryRemainingTimeSummary(populated) == "약 3시간 30분 남음")

        let unavailable = BatterySample(
            netW: -10.0,
            milliamps: 800,
            volts: 12.0,
            charging: true,
            externalConnected: true)
        #expect(CardPresentation.batteryEfficiencyText(unavailable) == nil)
        #expect(CardPresentation.batteryCycleText(unavailable) == nil)

        let invalid = BatterySample(
            netW: 12.0,
            milliamps: 800,
            volts: 12.0,
            charging: false,
            externalConnected: false,
            timeRemainingMinutes: 1_441,
            efficiencyPercent: 201,
            cycleCount: 10_001)
        #expect(CardPresentation.batteryRemainingTimeSummary(invalid) == nil)
        #expect(CardPresentation.batteryEfficiencyText(invalid) == nil)
        #expect(CardPresentation.batteryCycleText(invalid) == nil)
    }

    // MARK: CPU

    @Test func cpuValueRoundsAndSub() {
        let twoLevels = MetricState.value(.cpu(CPUSample(overall: 42.4, perfLevels: [
            PerfLevelUsage(name: "Performance", usage: 80.4),
            PerfLevelUsage(name: "Efficiency", usage: 12.6),
        ])))
        #expect(CardPresentation.valueText(.cpu, twoLevels) == "42")           // 42.4 → 42
        #expect(CardPresentation.unitText(.cpu, twoLevels) == "%")
        #expect(CardPresentation.subText(twoLevels) == "P 80% · E 13%")        // order-based prefixes

        let up = MetricState.value(.cpu(CPUSample(overall: 42.6, perfLevels: [])))
        #expect(CardPresentation.valueText(.cpu, up) == "43")                  // 42.6 → 43

        let single = MetricState.value(.cpu(CPUSample(overall: 50, perfLevels: [
            PerfLevelUsage(name: "Super", usage: 50.0)])))
        #expect(CardPresentation.subText(single) == "S 50%")                   // <2 levels → single

        let none = MetricState.value(.cpu(CPUSample(overall: 50, perfLevels: [])))
        #expect(CardPresentation.subText(none) == nil)                         // no levels → nil
    }

    // Clock visible in the collapsed sub-line too (plan 21 follow-up — not just the expand
    // region), so GHz is readable before the card is tapped open.
    @Test func cpuSubTextIncludesClockWhenAvailable() {
        let twoLevels = MetricState.value(.cpu(CPUSample(overall: 42.4, perfLevels: [
            PerfLevelUsage(name: "Performance", usage: 80.4, activeGHz: 3.204),
            PerfLevelUsage(name: "Efficiency", usage: 12.6, activeGHz: 1.104),
        ])))
        #expect(CardPresentation.subText(twoLevels) == "P 3.20 GHz 80% · E 1.10 GHz 13%")

        let single = MetricState.value(.cpu(CPUSample(overall: 50, perfLevels: [
            PerfLevelUsage(name: "Super", usage: 50.0, activeGHz: 2.5)])))
        #expect(CardPresentation.subText(single) == "S 2.50 GHz 50%")

        // Baseline poll: clock not yet available on one cluster → that cluster's token has no
        // GHz clause while the other (already baselined) keeps its clock — no crash, no stale 0.
        let mixed = MetricState.value(.cpu(CPUSample(overall: 42.4, perfLevels: [
            PerfLevelUsage(name: "Performance", usage: 80.4, activeGHz: nil),
            PerfLevelUsage(name: "Efficiency", usage: 12.6, activeGHz: 1.104),
        ])))
        #expect(CardPresentation.subText(mixed) == "P 80% · E 1.10 GHz 13%")
    }

    // MARK: Memory — the one state-dependent unit ("/ N GB")

    @Test func memoryValueUnitSub() {
        let st = MetricState.value(.memory(MemorySample(
            usedGB: 8.37, totalGB: 16, wiredGB: 3.21, compressedGB: 1.05)))
        #expect(CardPresentation.valueText(.mem, st) == "8.4")
        #expect(CardPresentation.unitText(.mem, st) == "/ 16 GB")             // reads total off state
        #expect(CardPresentation.subText(st) == "고정 3.2 GB · 압축 1.1 GB · 스왑 0.0 GB")
        #expect(CardPresentation.unitText(.mem, .loading) == "GB")           // no value → bare unit
    }

    @Test func memorySubShowsSwapSize() {
        // The swap segment reflects swapUsedGB and uses the same one-decimal GB format.
        let st = MetricState.value(.memory(MemorySample(
            usedGB: 12.0, totalGB: 16, wiredGB: 3.21, compressedGB: 1.05, swapUsedGB: 5.0)))
        #expect(CardPresentation.subText(st) == "고정 3.2 GB · 압축 1.1 GB · 스왑 5.0 GB")
    }

    @Test func memorySubShowsPressurePercent() {
        // When the syscall supplied a pressure %, it leads the sub-line as its own segment.
        let st = MetricState.value(.memory(MemorySample(
            usedGB: 8.37, totalGB: 16, wiredGB: 3.21, compressedGB: 1.05,
            swapUsedGB: 0.0, pressurePercent: 46)))
        #expect(CardPresentation.subText(st) == "압력 46% · 고정 3.2 GB · 압축 1.1 GB · 스왑 0.0 GB")
    }

    @Test func memorySubOmitsPressureWhenUnavailable() {
        // No pressure % (syscall failed / not set) → the sub-line is exactly as before.
        let st = MetricState.value(.memory(MemorySample(
            usedGB: 8.37, totalGB: 16, wiredGB: 3.21, compressedGB: 1.05)))
        #expect(CardPresentation.subText(st) == "고정 3.2 GB · 압축 1.1 GB · 스왑 0.0 GB")
    }

    // MARK: Power — the only accented card

    @Test func powerValueSubAndTint() {
        let st = MetricState.value(.power(PowerSample(totalW: 12.34, cpuW: 5.62, gpuW: 2.10, npuW: 0.30)))
        #expect(CardPresentation.valueText(.power, st) == "12.3")
        #expect(CardPresentation.subText(st) == "CPU 5.6 W · GPU 2.1 W · NPU 0.3 W")
        #expect(CardPresentation.display(.power, st).tint == .accent)
        #expect(CardPresentation.display(.cpu, .loading).tint == .neutral)
    }

    // MARK: Temperature fan-out — value per category, defensive "—"

    @Test func temperatureValuePerCategory() {
        let snap = TemperatureSnapshot(
            cpu: .reading(TemperatureReading(celsius: 58.7)),
            gpu: .reading(TemperatureReading(celsius: 44.2)),
            battery: .reading(TemperatureReading(celsius: 31.0)))
        let st = MetricState.value(.temperature(snap))
        #expect(CardPresentation.valueText(.cpuTemp, st) == "58.7")
        #expect(CardPresentation.valueText(.gpuTemp, st) == "44.2")
        #expect(CardPresentation.valueText(.batTemp, st) == "31.0")
        #expect(CardPresentation.unitText(.cpuTemp, st) == "°C")
        #expect(CardPresentation.subText(st) == nil)

        let degraded = MetricState.value(.temperature(TemperatureSnapshot(
            cpu: .unavailable(.noVerifiedProfile),
            gpu: .reading(TemperatureReading(celsius: 44.2)),
            battery: .notPresent("x"))))
        #expect(CardPresentation.valueText(.cpuTemp, degraded) == "—")        // defends a non-reading category
    }

    // MARK: display() is total over MetricState (so MenuBarLabel etc. are safe)

    @Test func totalOverLoadingAndUnavailable() {
        let loading = CardPresentation.display(.cpu, .loading)
        #expect(loading.valueText == "—")
        #expect(loading.unitText == "%")
        #expect(loading.subText == nil)
        #expect(loading.label == "CPU")

        let unavailable = CardPresentation.display(.power, .unavailable(.channelUnreadable("x")))
        #expect(unavailable.valueText == "—")
        #expect(unavailable.label == "프로세서 전력")
        #expect(unavailable.tint == .accent)
    }

    // MARK: Labels (shared with the in-view unavailable cards)

    @Test func labels() {
        #expect(CardPresentation.label(.power) == "프로세서 전력")
        #expect(CardPresentation.label(.battery) == "배터리")
        #expect(CardPresentation.label(.cpu) == "CPU")
        #expect(CardPresentation.label(.mem) == "메모리")
        #expect(CardPresentation.label(.cpuTemp) == "CPU 온도")
        #expect(CardPresentation.label(.gpuTemp) == "GPU 온도")
        #expect(CardPresentation.label(.batTemp) == "배터리 온도")
    }

    // MARK: Relocated pure helpers (expand regions)

    @Test func formatHelpers() {
        #expect(CardPresentation.f1(2.5) == "2.5")
        #expect(CardPresentation.f1(0.0) == "0.0")
        #expect(CardPresentation.corePrefix("Performance") == "P")
        #expect(CardPresentation.corePrefix("efficiency") == "E")
        #expect(CardPresentation.corePrefix("") == "C")
        #expect(CardPresentation.gbText(1_610_612_736) == "1.5 GB")   // 1.5 GiB
        #expect(CardPresentation.gbText(1_073_741_824) == "1.0 GB")   // 1.0 GiB
        #expect(CardPresentation.tempBarFraction(55.0) == 0.5)        // 55/110
        #expect(CardPresentation.tempBarFraction(220.0) == 1.0)       // clamped high
        #expect(CardPresentation.tempBarFraction(-5.0) == 0.0)        // clamped low
        #expect(CardPresentation.clusterSummary(average: 55.0, hottest: 60.0) == "55.0° · 최고 60.0°")
    }

    @Test func ghzTextTwoDecimalsWithUnit() {
        #expect(CardPresentation.ghzText(3.456) == "3.46 GHz")
        #expect(CardPresentation.ghzText(1.2) == "1.20 GHz")
    }

    // MARK: Expand-set persistence (CSV codec) — shared by mode A's stack rows and mode C's
    // hero card expand (plan: hero card expand)

    @Test func expandedCardsParsesCSV() {
        #expect(CardPresentation.expandedCards(from: "") == [])
        #expect(CardPresentation.expandedCards(from: "cpu") == [.cpu])
        #expect(CardPresentation.expandedCards(from: "battery,cpu,mem") == [.battery, .cpu, .mem])
    }

    @Test func expandedCardsDropsUnknownTokens() {
        // A stale/unknown raw value (e.g. a renamed CardKind case) is dropped, not crashed on.
        #expect(CardPresentation.expandedCards(from: "cpu,notACard,mem") == [.cpu, .mem])
    }

    @Test func togglingExpandedAddsAndRemoves() {
        let added = CardPresentation.togglingExpanded(.cpu, in: "")
        #expect(added == "cpu")
        let addedMore = CardPresentation.togglingExpanded(.battery, in: added)
        #expect(CardPresentation.expandedCards(from: addedMore) == [.battery, .cpu])
        let removed = CardPresentation.togglingExpanded(.cpu, in: addedMore)
        #expect(CardPresentation.expandedCards(from: removed) == [.battery])
    }

    @Test func togglingExpandedSortsDeterministically() {
        // Insertion order (mem then battery) still serializes alphabetically by rawValue.
        let raw = CardPresentation.togglingExpanded(.battery,
                    in: CardPresentation.togglingExpanded(.mem, in: ""))
        #expect(raw == "battery,mem")
    }

    // MARK: CardKind structural facts (D) — single home for the card-family flags

    @Test func cardKindStructuralFlags() {
        #expect(CardKind.allCases.filter(\.isExpandable) == [.power, .battery, .cpu, .gpu, .mem, .cpuTemp, .gpuTemp, .fan])
        #expect(CardKind.allCases.filter(\.hasSparkArea) == [.power, .cpu, .gpu, .mem, .cpuTemp, .gpuTemp, .batTemp, .fan])
        #expect(CardKind.allCases.filter(\.isAccented) == [.power])
    }

    // MARK: Fan presentation

    @Test func fanLabelUnitAndValue() {
        let state = MetricState.value(.fan(FanSample(fans: [
            FanReading(index: 0, actualRPM: 2000, minRPM: 0, maxRPM: 4000, targetRPM: 2200),
            FanReading(index: 1, actualRPM: 4000, minRPM: 0, maxRPM: 4000, targetRPM: 4200),
        ])))
        #expect(CardPresentation.label(.fan) == "팬 속도")
        #expect(CardPresentation.unitText(.fan, state) == "RPM")
        #expect(CardPresentation.valueText(.fan, state) == "3000")   // (2000 + 4000) / 2, integer
    }

    @Test func fanValueTextNoReadingIsDash() {
        #expect(CardPresentation.valueText(.fan, .value(.fan(FanSample(fans: [])))) == "—")
        #expect(CardPresentation.valueText(.fan, .loading) == "—")
    }

    @Test func fanHasNoThresholdColor() {
        let state = MetricState.value(.fan(FanSample(fans: [
            FanReading(index: 0, actualRPM: 9000, minRPM: 0, maxRPM: 9000, targetRPM: 9000)])))
        #expect(CardPresentation.thresholdLevel(.fan, state, Defaults.thresholds) == nil)
    }

    // MARK: Coverage — every CardKind must format a value, plot a scalar, and (if menubar-
    // eligible) format a menubar part. Guards the default-guarded tuple switches that would
    // otherwise silently show "—" for a forgotten new card.

    private func representativeState(_ card: CardKind) -> MetricState {
        switch card {
        case .power:   return .value(.power(PowerSample(totalW: 8, cpuW: 3, gpuW: 2, npuW: 0.1)))
        case .battery: return .value(.battery(BatterySample(netW: 5, milliamps: 400, volts: 12,
                                                            charging: false, externalConnected: false)))
        case .cpu:     return .value(.cpu(CPUSample(overall: 42, perfLevels: [])))
        case .gpu:
            return .value(.gpu(GPUSample(overall: 38.0, coreCount: 10, activeGHz: 1.28)))
        case .mem:     return .value(.memory(MemorySample(usedGB: 8, totalGB: 16, wiredGB: 2, compressedGB: 1)))
        case .cpuTemp, .gpuTemp, .batTemp:
            return .value(.temperature(TemperatureSnapshot(
                cpu: .reading(TemperatureReading(celsius: 50)),
                gpu: .reading(TemperatureReading(celsius: 45)),
                battery: .reading(TemperatureReading(celsius: 30)))))
        case .fan:     return .value(.fan(FanSample(fans: [
                            FanReading(index: 0, actualRPM: 2000, minRPM: 0, maxRPM: 4000, targetRPM: 2200)])))
        }
    }

    @Test func everyCardFormatsAValue() {
        for card in CardKind.allCases {
            #expect(CardPresentation.valueText(card, representativeState(card)) != "—",
                    "\(card) valueText fell through to —")
        }
    }

    @MainActor
    @Test func everyCardHasASparklineScalar() {
        for card in CardKind.allCases {
            guard case .value(let s) = representativeState(card) else { continue }
            #expect(SystemMonitor.scalar(of: card, from: s) != nil, "\(card) has no scalar")
        }
    }

    @Test func everyMenubarMetricFormatsValue() {
        for card in MenuBarText.order {
            let part = MenuBarText.part(card, representativeState(card))
            #expect(!part.hasSuffix("—"), "\(card) menubar part fell through to placeholder")
        }
    }
}
