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
        #expect(KineticNotchMotion.frameRate(load: 100, speed: .eco) == 3)
        #expect(KineticNotchMotion.frameRate(load: 100, speed: .standard) == 5)
        #expect(KineticNotchMotion.frameRate(load: 100, speed: .responsive) == 7)
    }

    @Test func ratesUseSquareRootProgressionAndPerPresetMinimums() {
        // 5.0095 is just above the 5% idle threshold. Its normalized distance is
        // 0.01%, so the square-root curve has advanced by 1% of each preset's range.
        let nearThreshold = 5.0095
        #expect(KineticNotchMotion.frameRate(load: 5, speed: .eco) == nil)
        #expect(KineticNotchMotion.frameRate(load: 5, speed: .standard) == nil)
        #expect(KineticNotchMotion.frameRate(load: 5, speed: .responsive) == nil)
        #expect(abs((KineticNotchMotion.frameRate(load: nearThreshold, speed: .eco) ?? 0) - 0.7725) < 1e-12)
        #expect(abs((KineticNotchMotion.frameRate(load: nearThreshold, speed: .standard) ?? 0) - 1.2875) < 1e-12)
        #expect(abs((KineticNotchMotion.frameRate(load: nearThreshold, speed: .responsive) ?? 0) - 2.05) < 1e-12)

        // 28.75% is one quarter through the load range, which square-root interpolation
        // maps to halfway through each rate range (not the linear one-quarter point).
        let interiorLoad = 28.75
        #expect(abs((KineticNotchMotion.frameRate(load: interiorLoad, speed: .eco) ?? 0) - 1.875) < 1e-12)
        #expect(abs((KineticNotchMotion.frameRate(load: interiorLoad, speed: .standard) ?? 0) - 3.125) < 1e-12)
        #expect(abs((KineticNotchMotion.frameRate(load: interiorLoad, speed: .responsive) ?? 0) - 4.5) < 1e-12)
    }

    @Test func fluxLoopUsesAStableRestFrameAndWrapsEveryPhase() {
        #expect(KineticNotchMotion.staticFrame == 0)
        #expect(KineticNotchMotion.displayedFrame(phase: 0, reduceMotion: false) == 0)
        #expect(KineticNotchMotion.displayedFrame(phase: 6, reduceMotion: false) == 6)
        #expect(KineticNotchMotion.displayedFrame(phase: 7, reduceMotion: false) == 0)
        #expect(KineticNotchMotion.displayedFrame(phase: -1, reduceMotion: false) == 6)
        #expect(KineticNotchMotion.displayedFrame(phase: 3, reduceMotion: true) == 0)
    }

    @Test func fluxLoopDwellsAtEdgesWithoutChangingAverageCadence() {
        let multipliers = (0..<KineticNotchMotion.frameCount)
            .map(KineticNotchMotion.phaseDelayMultiplier)
        #expect(KineticNotchMotion.rightEdgePhase == 2)
        #expect(KineticNotchMotion.leftEdgePhase == 5)
        #expect(multipliers == [0.92, 0.78, 1.32, 0.96, 0.78, 1.32, 0.92])
        #expect(abs(multipliers.reduce(0, +) - Double(KineticNotchMotion.frameCount)) < 1e-12)
        #expect(KineticNotchMotion.frameDelay(phase: KineticNotchMotion.rightEdgePhase, frameRate: 5) >
                KineticNotchMotion.frameDelay(phase: 1, frameRate: 5))
        #expect(KineticNotchMotion.frameDelay(phase: KineticNotchMotion.leftEdgePhase, frameRate: 5) >
                KineticNotchMotion.frameDelay(phase: 4, frameRate: 5))
        #expect(abs(KineticNotchMotion.frameDelay(phase: KineticNotchMotion.rightEdgePhase, frameRate: 5) - 0.264) < 1e-12)
        let lapDuration = multipliers.indices
            .map { KineticNotchMotion.frameDelay(phase: $0, frameRate: 5) }
            .reduce(0, +)
        #expect(abs(lapDuration - 1.4) < 1e-12)
    }
}
