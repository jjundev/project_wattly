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

    @Test func frameSelectionClampsAndReduceMotionIsStatic() {
        #expect(KineticNotchMotion.restFrame(load: -1) == 0)
        #expect(KineticNotchMotion.restFrame(load: 100) == 6)
        #expect(KineticNotchMotion.displayedFrame(load: 50, phase: 3, reduceMotion: true) == KineticNotchMotion.restFrame(load: 50))
        #expect((0...6).contains(KineticNotchMotion.displayedFrame(load: 100, phase: 0, reduceMotion: false)))
    }
}
