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
        #expect(maxCurve.rpms.allSatisfy { $0 == FanCurvePreset.defaultMaxRPM })
        #expect(FanCurvePreset.matchingPreset(for: maxCurve) == .fullSpeed)
    }

    @Test func presetsScaleToCustomHardwareMaxRPM() {
        let maxRPM = 5800.0
        let fullSpeed = FanCurvePreset.fullSpeed.curve(forMaxRPM: maxRPM)
        #expect(fullSpeed.rpms.allSatisfy { $0 == 5800 })
        #expect(FanCurvePreset.matchingPreset(for: fullSpeed, maxRPM: maxRPM) == .fullSpeed)

        let balanced = FanCurvePreset.balanced.curve(forMaxRPM: maxRPM)
        #expect(balanced.rpms.last == 5800)
        #expect(balanced.rpms.allSatisfy { $0.truncatingRemainder(dividingBy: 100) == 0 })
        #expect(FanCurvePreset.matchingPreset(for: balanced, maxRPM: maxRPM) == .balanced)

        let silent = FanCurvePreset.silent.curve(forMaxRPM: maxRPM)
        #expect(silent.rpms[0...5].allSatisfy { $0 == 0 }) // 30..55°C = 0
        #expect(silent.rpms.last == 5800)
        #expect(FanCurvePreset.matchingPreset(for: silent, maxRPM: maxRPM) == .silent)
    }

    @Test func fanSampleComputesMaxFanRPM() {
        let sample = FanSample(fans: [
            FanReading(index: 0, actualRPM: 2000, minRPM: 1500, maxRPM: 5800, targetRPM: 2000),
            FanReading(index: 1, actualRPM: 2200, minRPM: 1500, maxRPM: 6200, targetRPM: 2200)
        ])
        #expect(sample.maxFanRPM == 6200)

        let emptySample = FanSample(fans: [])
        #expect(emptySample.maxFanRPM == nil)
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

    @Test func presetAllCasesOrderingMatchesUI() {
        #expect(FanCurvePreset.allCases == [.balanced, .silent, .performance, .fullSpeed])
        #expect(FanCurvePreset.allCases.map(\.rawValue) == ["균형", "저소음", "성능", "최대"])
    }
}
