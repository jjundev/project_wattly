import Testing
@testable import Wattly

struct KineticNotchMotionTests {
    @Test func sourceRequirementsAndLoadsAreExact() {
        #expect(KineticNotchSource.cpu.requiredCards == [.cpu])
        #expect(KineticNotchSource.gpu.requiredCards == [.gpu])
        #expect(KineticNotchSource.cpuGPU.requiredCards == [.cpu, .gpu])
        #expect(KineticNotchSource.cpu.load(cpu: 40, gpu: 80) == 40)
        #expect(KineticNotchSource.gpu.load(cpu: 40, gpu: 80) == 80)
        #expect(KineticNotchSource.cpuGPU.load(cpu: 40, gpu: 80) == 60)
        #expect(KineticNotchSource.cpuGPU.load(cpu: 40, gpu: nil) == nil)
    }

    @Test func idleInvalidAndMaximumRatesAreSafe() {
        #expect(KineticNotchSource.cpu.load(cpu: .nan, gpu: 0) == nil)
        #expect(KineticNotchMotion.frameRate(load: 5, speed: .standard) == nil)
        #expect(KineticNotchMotion.frameRate(load: 100, speed: .eco) == 36)
        #expect(KineticNotchMotion.frameRate(load: 100, speed: .standard) == 48)
        #expect(KineticNotchMotion.frameRate(load: 100, speed: .responsive) == 60)
    }

    @Test func ratesUseSquareRootProgressionAndPerPresetMinimums() {
        // 5.0095 is just above the 5% idle threshold. Its normalized distance is
        // 0.01%, so the square-root curve has advanced by 1% of each preset's range.
        let nearThreshold = 5.0095
        #expect(KineticNotchMotion.frameRate(load: 5, speed: .eco) == nil)
        #expect(KineticNotchMotion.frameRate(load: 5, speed: .standard) == nil)
        #expect(KineticNotchMotion.frameRate(load: 5, speed: .responsive) == nil)
        #expect(abs((KineticNotchMotion.frameRate(load: nearThreshold, speed: .eco) ?? 0) - 6.30) < 1e-12)
        #expect(abs((KineticNotchMotion.frameRate(load: nearThreshold, speed: .standard) ?? 0) - 8.40) < 1e-12)
        #expect(abs((KineticNotchMotion.frameRate(load: nearThreshold, speed: .responsive) ?? 0) - 12.48) < 1e-12)

        // 28.75% is one quarter through the load range, which square-root interpolation
        // maps to halfway through each rate range (not the linear one-quarter point).
        let interiorLoad = 28.75
        #expect(abs((KineticNotchMotion.frameRate(load: interiorLoad, speed: .eco) ?? 0) - 21.0) < 1e-12)
        #expect(abs((KineticNotchMotion.frameRate(load: interiorLoad, speed: .standard) ?? 0) - 28.0) < 1e-12)
        #expect(abs((KineticNotchMotion.frameRate(load: interiorLoad, speed: .responsive) ?? 0) - 36.0) < 1e-12)
    }

    @Test func fluxLoopUsesAStableRestFrameAndWrapsEveryPhase() {
        #expect(KineticNotchMotion.staticFrame == 0)
        #expect(KineticNotchMotion.displayedFrame(phase: 0, reduceMotion: false) == 0)
        #expect(KineticNotchMotion.displayedFrame(phase: 13, reduceMotion: false) == 13)
        #expect(KineticNotchMotion.displayedFrame(phase: 14, reduceMotion: false) == 0)
        #expect(KineticNotchMotion.displayedFrame(phase: -1, reduceMotion: false) == 13)
        #expect(KineticNotchMotion.displayedFrame(phase: 3, reduceMotion: true) == 0)
    }

    @Test func fluxLoopDwellsAtEdgesWithoutChangingAverageCadence() {
        let multipliers = (0..<KineticNotchMotion.frameCount)
            .map(KineticNotchMotion.phaseDelayMultiplier)
        #expect(KineticNotchMotion.rightEdgePhase == 4)
        #expect(KineticNotchMotion.leftEdgePhase == 10)
        #expect(multipliers == [0.92, 0.92, 0.78, 0.78, 1.32, 1.32, 0.96, 0.96, 0.78, 0.78, 1.32, 1.32, 0.92, 0.92])
        #expect(abs(multipliers.reduce(0, +) - Double(KineticNotchMotion.frameCount)) < 1e-12)
        #expect(KineticNotchMotion.frameDelay(phase: KineticNotchMotion.rightEdgePhase, frameRate: 5) >
                KineticNotchMotion.frameDelay(phase: 2, frameRate: 5))
        #expect(KineticNotchMotion.frameDelay(phase: KineticNotchMotion.leftEdgePhase, frameRate: 5) >
                KineticNotchMotion.frameDelay(phase: 8, frameRate: 5))
        #expect(abs(KineticNotchMotion.frameDelay(phase: KineticNotchMotion.rightEdgePhase, frameRate: 5) - 0.264) < 1e-12)
        let lapDuration = multipliers.indices
            .map { KineticNotchMotion.frameDelay(phase: $0, frameRate: 5) }
            .reduce(0, +)
        #expect(abs(lapDuration - 2.8) < 1e-12)
    }

    @Test func motionCalculatesDisplayedFrameForVariousStyles() {
        for style in MenuBarIconStyle.allCases {
            #expect(MenuBarIconMotion.displayedFrame(style: style, phase: 0, reduceMotion: false) == 0)
            #expect(MenuBarIconMotion.displayedFrame(style: style, phase: style.frameCount - 1, reduceMotion: false) == style.frameCount - 1)
            #expect(MenuBarIconMotion.displayedFrame(style: style, phase: style.frameCount, reduceMotion: false) == 0)
            #expect(MenuBarIconMotion.displayedFrame(style: style, phase: -1, reduceMotion: false) == style.frameCount - 1)
            #expect(MenuBarIconMotion.displayedFrame(style: style, phase: 3, reduceMotion: true) == style.staticFrame)
        }
    }

    @Test func frameDelaysSumToCycleTime() {
        for style in MenuBarIconStyle.allCases {
            let delays = (0..<style.frameCount).map {
                MenuBarIconMotion.frameDelay(style: style, phase: $0, frameRate: 5.0)
            }
            let totalTime = delays.reduce(0, +)
            let expectedTotalTime = Double(style.frameCount) / 5.0
            #expect(abs(totalTime - expectedTotalTime) < 1e-9)
        }
    }
}
