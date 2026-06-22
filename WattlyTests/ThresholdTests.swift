import Testing
import Foundation
@testable import Wattly

/// Pure-seam tests for threshold color coding (issue 10): the inclusive warn/crit
/// classification, the card→value routing (mem uses %, temps share one pair, power/battery
/// are threshold-free), and the slider clamp. No SwiftUI — these cross `ThresholdPair` /
/// `CardPresentation.thresholdLevel` directly. (`pickColor`·임곗값 클램프, plan 18 §3.)
struct ThresholdTests {

    // MARK: ThresholdPair.level — inclusive boundaries (prototype `pickColor`)

    @Test func levelBoundariesAreInclusive() {
        let p = ThresholdPair(warn: 70, crit: 90)
        #expect(p.level(0) == .normal)
        #expect(p.level(69.9) == .normal)
        #expect(p.level(70) == .warn)      // inclusive at warn
        #expect(p.level(89.9) == .warn)
        #expect(p.level(90) == .crit)      // inclusive at crit
        #expect(p.level(100) == .crit)
    }

    // MARK: card → value routing

    @Test func cpuComparesOverall() {
        let th = Defaults.thresholds       // cpu 70/90
        #expect(CardPresentation.thresholdLevel(.cpu, cpu(50), th) == .normal)
        #expect(CardPresentation.thresholdLevel(.cpu, cpu(75), th) == .warn)
        #expect(CardPresentation.thresholdLevel(.cpu, cpu(95), th) == .crit)
    }

    @Test func memoryComparesPercentNotGB() {
        let th = Defaults.thresholds       // mem 70/85
        #expect(CardPresentation.thresholdLevel(.mem, mem(used: 8,  total: 16), th) == .normal) // 50%
        #expect(CardPresentation.thresholdLevel(.mem, mem(used: 12, total: 16), th) == .warn)   // 75%
        #expect(CardPresentation.thresholdLevel(.mem, mem(used: 14, total: 16), th) == .crit)   // 87.5%
    }

    @Test func memoryZeroTotalIsNormalNotNil() {
        // A value with totalGB=0 is still a value → 0%, not nil (nil is reserved for no-value).
        #expect(CardPresentation.thresholdLevel(.mem, mem(used: 5, total: 0), Defaults.thresholds) == .normal)
    }

    @Test func temperatureCardsShareOnePair() {
        let th = Defaults.thresholds       // temp 70/90
        let st = MetricState.value(.temperature(TemperatureSnapshot(
            cpu: .reading(TemperatureReading(celsius: 95)),     // crit
            gpu: .reading(TemperatureReading(celsius: 75)),     // warn
            battery: .reading(TemperatureReading(celsius: 30))))) // normal
        #expect(CardPresentation.thresholdLevel(.cpuTemp, st, th) == .crit)
        #expect(CardPresentation.thresholdLevel(.gpuTemp, st, th) == .warn)
        #expect(CardPresentation.thresholdLevel(.batTemp, st, th) == .normal)
    }

    @Test func temperatureNonReadingIsNil() {
        let th = Defaults.thresholds
        let st = MetricState.value(.temperature(TemperatureSnapshot(
            cpu: .unavailable(.noVerifiedProfile),
            gpu: .notPresent("x"),
            battery: .reading(TemperatureReading(celsius: 30)))))
        #expect(CardPresentation.thresholdLevel(.cpuTemp, st, th) == nil)
        #expect(CardPresentation.thresholdLevel(.gpuTemp, st, th) == nil)
        #expect(CardPresentation.thresholdLevel(.batTemp, st, th) == .normal)
    }

    @Test func powerAndBatteryAreThresholdFree() {
        let th = Defaults.thresholds
        let pwr = MetricState.value(.power(PowerSample(totalW: 99, cpuW: 0, gpuW: 0, npuW: 0)))
        let bat = MetricState.value(.battery(BatterySample(
            netW: 99, milliamps: 0, volts: 12, charging: false, externalConnected: false)))
        #expect(CardPresentation.thresholdLevel(.power, pwr, th) == nil)
        #expect(CardPresentation.thresholdLevel(.battery, bat, th) == nil)
    }

    @Test func loadingAndUnavailableAreNil() {
        let th = Defaults.thresholds
        #expect(CardPresentation.thresholdLevel(.cpu, .loading, th) == nil)
        #expect(CardPresentation.thresholdLevel(.cpu, .unavailable(.providerError("x")), th) == nil)
    }

    // MARK: clamp — edited control authoritative + integer rounding (prototype `setThreshold`)

    @Test func clampWarnDragsCritUp() {
        let r = ThresholdPair(warn: 70, crit: 90).setting(.warn, to: 95)
        #expect(r.warn == 95)
        #expect(r.crit == 95)   // crit pushed up to the new warn
    }

    @Test func clampCritDragsWarnDown() {
        let r = ThresholdPair(warn: 70, crit: 90).setting(.crit, to: 50)
        #expect(r.crit == 50)
        #expect(r.warn == 50)   // warn pushed down to the new crit
    }

    @Test func clampRoundsToWhole() {
        #expect(ThresholdPair(warn: 70, crit: 90).setting(.warn, to: 70.6).warn == 71)
        #expect(ThresholdPair(warn: 70, crit: 90).setting(.crit, to: 89.4).crit == 89)
    }

    @Test func clampLeavesTheOtherWhenStillOrdered() {
        let r = ThresholdPair(warn: 70, crit: 90).setting(.warn, to: 80)   // 80 ≤ 90 → no drag
        #expect(r.warn == 80)
        #expect(r.crit == 90)
    }

    // MARK: accessibility state word

    @Test func stateWordOnlyForWarnAndCrit() {
        #expect(ThresholdLevel.normal.stateWord == nil)
        #expect(ThresholdLevel.warn.stateWord == "주의")
        #expect(ThresholdLevel.crit.stateWord == "위험")
    }

    // MARK: helpers

    private func cpu(_ v: Double) -> MetricState { .value(.cpu(CPUSample(overall: v, perfLevels: []))) }
    private func mem(used: Double, total: Double) -> MetricState {
        .value(.memory(MemorySample(usedGB: used, totalGB: total, wiredGB: 0, compressedGB: 0)))
    }
}
