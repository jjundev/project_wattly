import Testing
@testable import Wattly

struct FanCurvePresetTests {
    @Test func allPresetsHaveValidAnchorCountAndFiniteRPMs() {
        for preset in FanCurvePreset.allCases {
            let curve = preset.curve
            #expect(curve.rpms.count == FanCurve.anchorsCelsius.count)
            #expect(curve.rpms.allSatisfy { $0.isFinite && (0.0...20_000.0).contains($0) })
        }
    }

    @Test func balancedPresetMatchesDefaultFanCurve() {
        #expect(FanCurvePreset.balanced.curve == Defaults.fanCurve)
        #expect(FanCurvePreset.matchingPreset(for: Defaults.fanCurve) == .balanced)
    }

    @Test func silentPresetProvidesZeroRPMHoldRange() {
        let silentCurve = FanCurvePreset.silent.curve
        #expect(silentCurve.rpms.first == 0)
        #expect(FanCurveGeometry.zeroRPMHoldRange(for: silentCurve) == 48...55)
        #expect(FanCurvePreset.matchingPreset(for: silentCurve) == .silent)
    }

    @Test func performancePresetHasHigherRPMsThanBalancedAtLowTemps() {
        let perfCurve = FanCurvePreset.performance.curve
        let balancedCurve = FanCurvePreset.balanced.curve
        #expect(perfCurve.rpms[0] > balancedCurve.rpms[0])
        #expect(FanCurvePreset.matchingPreset(for: perfCurve) == .performance)
    }

    @Test func fullSpeedPresetIsMaxRPMAtAllAnchors() {
        let maxCurve = FanCurvePreset.fullSpeed.curve
        #expect(maxCurve.rpms.allSatisfy { $0 == 7400 })
        #expect(FanCurvePreset.matchingPreset(for: maxCurve) == .fullSpeed)
    }

    @Test func customCurveReturnsNilMatchingPreset() {
        let custom = FanCurve(rpms: [1000, 1100, 1200, 1300, 1400, 1500, 1600, 1700, 1800, 1900, 2000, 2100, 2200, 2300, 2400])
        #expect(FanCurvePreset.matchingPreset(for: custom) == nil)
    }

    @Test func presetTitlesIncludeDescriptions() {
        #expect(FanCurvePreset.balanced.title == "균형 (기본값)")
        #expect(FanCurvePreset.silent.title == "저소음")
        #expect(FanCurvePreset.performance.title == "성능")
        #expect(FanCurvePreset.fullSpeed.title == "최대")
    }
}
