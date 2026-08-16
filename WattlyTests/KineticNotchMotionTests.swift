import Testing
@testable import Wattly

struct KineticNotchMotionTests {
    @Test func sourceRequirementsAndLabels() {
        #expect(KineticNotchSource.power.requiredCards == [.power])
        #expect(KineticNotchSource.cpuClock.requiredCards == [.cpu])
        #expect(KineticNotchSource.compute.requiredCards == [.cpu, .gpu])

        #expect(KineticNotchSource.power.label == "전력 소비")
        #expect(KineticNotchSource.cpuClock.label == "CPU 클럭")
        #expect(KineticNotchSource.compute.label == "CPU + GPU")
    }

    @Test func targetWattsByFormFactor() {
        // MacBook Air (fanCount == 0) -> 20W
        #expect(KineticNotchSource.targetWatts(gpuCores: 8, fanCount: 0) == 20.0)
        #expect(KineticNotchSource.targetWatts(gpuCores: 10, fanCount: 0) == 20.0)

        // Base MacBook Pro / Mac mini (fanCount >= 1, gpuCores <= 10) -> 30W
        #expect(KineticNotchSource.targetWatts(gpuCores: 10, fanCount: 1) == 30.0)

        // Pro chip (gpuCores 14~20) -> 55W
        #expect(KineticNotchSource.targetWatts(gpuCores: 16, fanCount: 2) == 55.0)

        // Max chip (gpuCores 24~40) -> 100W
        #expect(KineticNotchSource.targetWatts(gpuCores: 32, fanCount: 2) == 100.0)

        // Ultra chip (gpuCores >= 48) -> 200W
        #expect(KineticNotchSource.targetWatts(gpuCores: 64, fanCount: 2) == 200.0)
    }

    @Test func powerLoadNormalization() {
        #expect(KineticNotchSource.power.load(power: 0.0, gpuCores: 8, fanCount: 0) == 0.0)
        #expect(KineticNotchSource.power.load(power: 10.0, gpuCores: 8, fanCount: 0) == 50.0)
        #expect(KineticNotchSource.power.load(power: 20.0, gpuCores: 8, fanCount: 0) == 100.0)
        #expect(KineticNotchSource.power.load(power: 35.0, gpuCores: 8, fanCount: 0) == 100.0) // clamped
        #expect(KineticNotchSource.power.load(power: .nan, gpuCores: 8, fanCount: 0) == nil)
    }

    @Test func cpuClockLoadNormalization() {
        #expect(KineticNotchSource.cpuClock.load(cpuClockGHz: 0.8) == 0.0)
        #expect(abs((KineticNotchSource.cpuClock.load(cpuClockGHz: 2.4) ?? 0) - 50.0) < 1e-9)
        #expect(KineticNotchSource.cpuClock.load(cpuClockGHz: 4.0) == 100.0)
        #expect(KineticNotchSource.cpuClock.load(cpuClockGHz: 4.5) == 100.0) // clamped
        #expect(KineticNotchSource.cpuClock.load(cpuClockGHz: .nan) == nil)
    }

    @Test func computeLoadNormalization() {
        #expect(KineticNotchSource.compute.load(cpu: 20, gpu: 80) == 50.0)
        #expect(KineticNotchSource.compute.load(cpu: 0, gpu: 0) == 0.0)
        #expect(KineticNotchSource.compute.load(cpu: 100, gpu: 100) == 100.0)
        #expect(KineticNotchSource.compute.load(cpu: 40, gpu: nil) == nil)
        #expect(KineticNotchSource.compute.load(cpu: .nan, gpu: 0) == nil)
    }

    @Test func physicalRevolutionsPerSecondIsStrictlyBoundToLoad() {
        // Physical RPS is identical regardless of presets
        #expect(MenuBarIconMotion.revolutionsPerSecond(load: 0.0) == 0.25)
        #expect(MenuBarIconMotion.revolutionsPerSecond(load: 100.0) == 2.50)
        // 25% load -> sqrt(0.25) = 0.5 progression -> midpoint = 0.25 + 2.25 * 0.5 = 1.375
        #expect(abs(MenuBarIconMotion.revolutionsPerSecond(load: 25.0) - 1.375) < 1e-9)
    }

    @Test func presetTargetFPSAndEffectiveRates() {
        #expect(KineticNotchSpeed.eco.targetFPS == 15.0)
        #expect(KineticNotchSpeed.standard.targetFPS == 30.0)
        #expect(KineticNotchSpeed.responsive.targetFPS == 60.0)

        // At full load (2.5 RPS, 24 frames -> 60 visual FPS):
        #expect(MenuBarIconMotion.effectiveFrameRate(load: 100, speed: .eco, frameCount: 24) == 15.0)
        #expect(MenuBarIconMotion.effectiveFrameRate(load: 100, speed: .standard, frameCount: 24) == 30.0)
        #expect(MenuBarIconMotion.effectiveFrameRate(load: 100, speed: .responsive, frameCount: 24) == 60.0)
    }

    @Test func timeBasedPhaseAdvancePreservesContinuity() {
        var phase = 0.0
        // Advance 1 second at 1.0 RPS -> wraps to 0.0
        phase = MenuBarIconMotion.advancePhase(currentPhase: phase, rps: 1.0, dt: 1.0)
        #expect(phase == 0.0)

        // Advance 0.25s at 1.0 RPS -> 0.25
        phase = MenuBarIconMotion.advancePhase(currentPhase: phase, rps: 1.0, dt: 0.25)
        #expect(abs(phase - 0.25) < 1e-9)

        // Sleep/wake clamp test: a 10-second sleep is clamped to 1.0s max
        let wrapped = MenuBarIconMotion.advancePhase(currentPhase: 0.2, rps: 0.5, dt: 10.0)
        #expect(abs(wrapped - 0.7) < 1e-9) // 0.2 + (0.5 * 1.0) = 0.7
    }

    @Test func motionCalculatesDisplayedFrameForContinuousPhase() {
        for style in MenuBarIconStyle.allCases {
            #expect(MenuBarIconMotion.displayedFrame(style: style, phase: 0.0, reduceMotion: false) == 0)
            #expect(MenuBarIconMotion.displayedFrame(style: style, phase: 0.999, reduceMotion: false) == style.frameCount - 1)
            #expect(MenuBarIconMotion.displayedFrame(style: style, phase: 1.0, reduceMotion: false) == 0)
            #expect(MenuBarIconMotion.displayedFrame(style: style, phase: 0.5, reduceMotion: true) == style.staticFrame)
        }
    }

    @Test func vuMeterMovesFromLeftToRightWithLoad() {
        let lowFrame = MenuBarIconMotion.displayedFrame(style: .vuMeter, phase: 0.0, load: 5.0, reduceMotion: false)
        #expect(lowFrame <= 3)

        let midFrame = MenuBarIconMotion.displayedFrame(style: .vuMeter, phase: 0.0, load: 50.0, reduceMotion: false)
        #expect(midFrame >= 10 && midFrame <= 14)

        let highFrame = MenuBarIconMotion.displayedFrame(style: .vuMeter, phase: 0.0, load: 100.0, reduceMotion: false)
        #expect(highFrame >= 21)
    }

    @Test func equalizerScalesTierWithLoad() {
        let lowFrame = MenuBarIconMotion.displayedFrame(style: .equalizer, phase: 0.3, load: 10.0, reduceMotion: false)
        #expect(lowFrame >= 0 && lowFrame <= 5)

        let midLowFrame = MenuBarIconMotion.displayedFrame(style: .equalizer, phase: 0.3, load: 35.0, reduceMotion: false)
        #expect(midLowFrame >= 6 && midLowFrame <= 11)

        let midHighFrame = MenuBarIconMotion.displayedFrame(style: .equalizer, phase: 0.3, load: 60.0, reduceMotion: false)
        #expect(midHighFrame >= 12 && midHighFrame <= 17)

        let highFrame = MenuBarIconMotion.displayedFrame(style: .equalizer, phase: 0.3, load: 95.0, reduceMotion: false)
        #expect(highFrame >= 18 && highFrame <= 23)
    }
}
