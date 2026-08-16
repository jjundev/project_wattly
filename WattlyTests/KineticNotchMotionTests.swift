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

    @Test func frameSelectionClampsAndReduceMotionIsStatic() {
        #expect(KineticNotchMotion.restFrame(load: -1) == 0)
        #expect(KineticNotchMotion.restFrame(load: 100) == 6)
        #expect(KineticNotchMotion.displayedFrame(load: 50, phase: 3, reduceMotion: true) == KineticNotchMotion.restFrame(load: 50))
        #expect((0...6).contains(KineticNotchMotion.displayedFrame(load: 100, phase: 0, reduceMotion: false)))
    }
}
