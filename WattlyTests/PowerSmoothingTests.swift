import Testing
import Foundation
@testable import Wattly

/// Display-only EMA for the SoC-power card (matches MX Power Gadget's damped readout
/// without touching the exact measurement). Pure math — no hardware, no clock.
struct PowerSmoothingTests {

    private func p(_ t: Double, _ c: Double = 0, _ g: Double = 0, _ n: Double = 0) -> PowerSample {
        PowerSample(totalW: t, cpuW: c, gpuW: g, npuW: n)
    }

    // MARK: alpha — continuous-time factor, interval-independent

    @Test func alphaBounds() {
        #expect(PowerSmoothing.alpha(dt: 0) == 1)        // degenerate dt → no smoothing
        #expect(PowerSmoothing.alpha(dt: 1, tau: 0) == 1) // degenerate τ → no smoothing
        let a = PowerSmoothing.alpha(dt: 4, tau: 4)       // dt == τ → ~0.632
        #expect(abs(a - (1 - exp(-1.0))) < 1e-12)
        #expect(a > 0 && a < 1)
    }

    // MARK: step — re-seed, convergence, multi-field

    @Test func firstSampleSeedsToRaw() {
        let s = PowerSmoothing.step(previous: nil, raw: p(10), dt: 1)
        #expect(s == p(10))                               // no prior → show the real value at once
    }

    @Test func largeGapReseeds() {
        // Sleep/wake or missed polls: don't average a stale pre-gap value back in.
        let s = PowerSmoothing.step(previous: p(2), raw: p(40), dt: 120)
        #expect(s == p(40))
    }

    @Test func stepDampsTowardRaw() {
        // One 1 s step at τ=4 moves ~22% of the way from 10 → 20.
        let s = PowerSmoothing.step(previous: p(10), raw: p(20), dt: 1, tau: 4)
        let a = PowerSmoothing.alpha(dt: 1, tau: 4)
        #expect(abs(s.totalW - (10 + a * 10)) < 1e-12)
        #expect(s.totalW > 10 && s.totalW < 20)           // damped, not the full jump
    }

    @Test func allFieldsSmoothedIndependently() {
        let s = PowerSmoothing.step(previous: p(10, 8, 1, 0.5), raw: p(20, 16, 3, 1.5), dt: 1, tau: 4)
        let a = PowerSmoothing.alpha(dt: 1, tau: 4)
        #expect(abs(s.cpuW - (8 + a * 8)) < 1e-12)
        #expect(abs(s.gpuW - (1 + a * 2)) < 1e-12)
        #expect(abs(s.npuW - (0.5 + a * 1.0)) < 1e-12)
    }

    @Test func intervalIndependenceForConstantInput() {
        // Two 1 s steps must land exactly where one 2 s step does, for a held input —
        // the property that makes the smoothing immune to the poll rate.
        let raw = p(30)
        let oneTwoSecond = PowerSmoothing.step(previous: p(0), raw: raw, dt: 2, tau: 4)
        let firstSecond = PowerSmoothing.step(previous: p(0), raw: raw, dt: 1, tau: 4)
        let twoOneSecond = PowerSmoothing.step(previous: firstSecond, raw: raw, dt: 1, tau: 4)
        #expect(abs(oneTwoSecond.totalW - twoOneSecond.totalW) < 1e-12)
    }

    @Test func repeatedStepsConvergeToRaw() {
        var s = p(0)
        for _ in 0..<200 { s = PowerSmoothing.step(previous: s, raw: p(15), dt: 1, tau: 4) }
        #expect(abs(s.totalW - 15) < 1e-6)
    }

    // MARK: emaStep — scalar variant (battery netW), same re-seed + damping contract

    @Test func emaStepScalar() {
        #expect(PowerSmoothing.emaStep(previous: nil, raw: 17, dt: 1) == 17)        // seed
        #expect(PowerSmoothing.emaStep(previous: 10, raw: 40, dt: 120) == 40)       // gap re-seed
        let a = PowerSmoothing.alpha(dt: 1, tau: 4)
        #expect(abs(PowerSmoothing.emaStep(previous: 16, raw: 22, dt: 1, tau: 4) - (16 + a * 6)) < 1e-12)
    }

    @Test func emaStepHandlesNegative() {
        // Battery netW is negative while charging — EMA must work across negatives
        // within one regime (the caller resets across a plug/unplug).
        let s = PowerSmoothing.emaStep(previous: -10, raw: -20, dt: 1, tau: 4)
        #expect(s < -10 && s > -20)
    }
}
