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

    @Test func thresholdsEqualityIsMemberwiseNotRawValue() {
        // Regression (issue 13): `Thresholds` is RawRepresentable, so without an explicit `==`
        // it compares its JSON `rawValue` — whose dictionary key order is non-deterministic —
        // and two value-equal thresholds compare unequal almost every time. A round-trip must
        // stay equal regardless of how the rawValue's keys happened to be ordered.
        for _ in 0..<200 {
            let decoded = Thresholds(rawValue: Defaults.thresholds.rawValue)
            #expect(decoded == Defaults.thresholds)
        }
        // A genuine value difference must still register as unequal.
        var changed = Defaults.thresholds
        changed.temp.warn += 1
        #expect(changed != Defaults.thresholds)
    }

    @Test func memoryColorAlwaysUsesKernelPressure() {
        let th = Defaults.thresholds
        #expect(CardPresentation.thresholdLevel(.mem, mem(used: 8, total: 16, pressure: .critical), th) == .crit)
        #expect(CardPresentation.thresholdLevel(.mem, mem(used: 14, total: 16, pressure: .normal), th) == .normal)
        #expect(CardPresentation.thresholdLevel(.mem, mem(used: 8, total: 16, pressure: .warn), th) == .warn)
    }

    @Test func memoryColorIsNilWithoutKernelPressure() {
        #expect(CardPresentation.thresholdLevel(.mem, mem(used: 14, total: 16, pressure: nil), Defaults.thresholds) == nil)
    }

    @Test func thresholdsIgnoreRemovedMemoryFieldsWhenDecodingLegacyData() {
        let legacy = #"{"cpu":{"warn":70,"crit":90},"mem":{"warn":70,"crit":85},"temp":{"warn":70,"crit":90},"memColorByPressure":false}"#
        #expect(Thresholds(rawValue: legacy) == Thresholds(
            cpu: ThresholdPair(warn: 70, crit: 90),
            temp: ThresholdPair(warn: 70, crit: 90)))
    }

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

    // MARK: fan — % of each fan's own ceiling, ON by default (no opt-in toggle)
    //
    // The boundary cases below rely on their ratios being exactly representable as Doubles
    // (4200/6000 → exactly 70, 5400/6000 → exactly 90), which is what makes an inclusive
    // boundary testable at all. Keep any new case on an exact ratio.

    @Test func fanComparesLoadPercentAgainstItsOwnPair() {
        let th = Defaults.thresholds        // fan 70/90 (% of max RPM)
        #expect(CardPresentation.thresholdLevel(.fan, fan(actual: 1800, max: 6000), th) == .normal)  // 30 %
        #expect(CardPresentation.thresholdLevel(.fan, fan(actual: 4500, max: 6000), th) == .warn)    // 75 %
        #expect(CardPresentation.thresholdLevel(.fan, fan(actual: 5700, max: 6000), th) == .crit)    // 95 %
    }

    @Test func fanBoundariesAreInclusiveOnThePercentage() {
        let th = Defaults.thresholds        // fan 70/90
        #expect(CardPresentation.thresholdLevel(.fan, fan(actual: 4200, max: 6000), th) == .warn)    // exactly 70 %
        #expect(CardPresentation.thresholdLevel(.fan, fan(actual: 5400, max: 6000), th) == .crit)    // exactly 90 %
    }

    @Test func fanWithoutAReadableCeilingIsNil() {
        // No ceiling → no percentage → no band. The card stays neutral rather than
        // guessing, matching the memory card's behavior when kernel pressure is missing.
        let th = Defaults.thresholds
        let noCeiling = MetricState.value(.fan(FanSample(fans: [
            FanReading(index: 0, actualRPM: 3000, minRPM: 0, maxRPM: 0, targetRPM: 0)])))
        #expect(CardPresentation.thresholdLevel(.fan, noCeiling, th) == nil)
        #expect(CardPresentation.thresholdLevel(.fan, .value(.fan(FanSample(fans: []))), th) == nil)
        #expect(CardPresentation.thresholdLevel(.fan, .loading, th) == nil)
    }

    @Test func fanThresholdIsOnByDefault() {
        // Unlike the opt-in GPU pair, the fan pair is non-optional and ships enabled.
        #expect(Defaults.thresholds.fan == ThresholdPair(warn: 70, crit: 90))
    }

    @Test func fanThresholdSurvivesSerializationRoundTrip() {
        var t = Defaults.thresholds
        t.fan = ThresholdPair(warn: 55, crit: 80)
        let restored = Thresholds(rawValue: t.rawValue)
        #expect(restored?.fan == ThresholdPair(warn: 55, crit: 80))
        #expect(restored == t)
    }

    @Test func legacyPayloadWithoutFanDecodesToTheDefaultPair() {
        // Regression: every already-installed copy has a persisted blob with no "fan" key.
        // It must decode (keeping the user's cpu/temp/gpu edits) with the fan default filled
        // in — NOT fail the decode and silently reset every threshold.
        let legacy = #"{"cpu":{"warn":60,"crit":85},"temp":{"warn":72,"crit":95},"gpu":{"warn":85,"crit":95}}"#
        let decoded = Thresholds(rawValue: legacy)
        #expect(decoded?.cpu == ThresholdPair(warn: 60, crit: 85))
        #expect(decoded?.temp == ThresholdPair(warn: 72, crit: 95))
        #expect(decoded?.gpu == ThresholdPair(warn: 85, crit: 95))
        #expect(decoded?.fan == ThresholdPair(warn: 70, crit: 90))
    }

    @Test func fanDifferenceRegistersAsUnequal() {
        // The memberwise `==` must include the new field, or a fan-only edit would compare
        // equal and the settings UI would not re-render.
        var changed = Defaults.thresholds
        changed.fan.crit -= 5
        #expect(changed != Defaults.thresholds)
    }

    @Test func temperatureCardsShareOnePair() {
        let th = Defaults.thresholds       // temp 70/90
        let st = MetricState.value(.temperature(TemperatureSnapshot(
            cpu: .reading(TemperatureReading(celsius: 95)),     // crit
            gpu: .reading(TemperatureReading(celsius: 75)))))   // warn
        #expect(CardPresentation.thresholdLevel(.cpuTemp, st, th) == .crit)
        #expect(CardPresentation.thresholdLevel(.gpuTemp, st, th) == .warn)
    }

    @Test func temperatureNonReadingIsNil() {
        let th = Defaults.thresholds
        let st = MetricState.value(.temperature(TemperatureSnapshot(
            cpu: .unavailable(.noVerifiedProfile),
            gpu: .notPresent("x"))))
        #expect(CardPresentation.thresholdLevel(.cpuTemp, st, th) == nil)
        #expect(CardPresentation.thresholdLevel(.gpuTemp, st, th) == nil)
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
    private func mem(used: Double, total: Double, pressure: MemoryPressure? = nil) -> MetricState {
        .value(.memory(MemorySample(usedGB: used, totalGB: total, wiredGB: 0, compressedGB: 0, pressure: pressure)))
    }
    private func fan(actual: Double, max: Double) -> MetricState {
        .value(.fan(FanSample(fans: [
            FanReading(index: 0, actualRPM: actual, minRPM: 0, maxRPM: max, targetRPM: actual)])))
    }
}
