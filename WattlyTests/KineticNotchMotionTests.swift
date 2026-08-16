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

    @Test func continuousFrameRateWithoutHardThreshold() {
        // At 0% load, returns exactly minimumFrameRate (continuous alive motion)
        #expect(MenuBarIconMotion.frameRate(load: 0, speed: .eco) == 6.0)
        #expect(MenuBarIconMotion.frameRate(load: 0, speed: .standard) == 8.0)
        #expect(MenuBarIconMotion.frameRate(load: 0, speed: .responsive) == 12.0)

        // At 100% load, returns maximumFrameRate
        #expect(MenuBarIconMotion.frameRate(load: 100, speed: .eco) == 36.0)
        #expect(MenuBarIconMotion.frameRate(load: 100, speed: .standard) == 48.0)
        #expect(MenuBarIconMotion.frameRate(load: 100, speed: .responsive) == 60.0)

        // At 25% load, square root interpolation gives 50% of the speed range
        #expect(abs(MenuBarIconMotion.frameRate(load: 25, speed: .eco) - 21.0) < 1e-9)
        #expect(abs(MenuBarIconMotion.frameRate(load: 25, speed: .standard) - 28.0) < 1e-9)
        #expect(abs(MenuBarIconMotion.frameRate(load: 25, speed: .responsive) - 36.0) < 1e-9)
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
            let multiplier = MenuBarIconMotion.phaseDelayMultiplier(style: style, phase: 0)
            let expectedTotalTime = (Double(style.frameCount) / 5.0) * multiplier
            #expect(abs(totalTime - expectedTotalTime) < 1e-9)
        }
    }

    @Test func vuMeterMovesFromLeftToRightWithLoad() {
        // Low load: needle stays near left edge (frames 0~3)
        let lowFrame = MenuBarIconMotion.displayedFrame(style: .vuMeter, phase: 0, load: 5.0, reduceMotion: false)
        #expect(lowFrame <= 3)

        // Mid load: needle moves toward center (frames 10~13)
        let midFrame = MenuBarIconMotion.displayedFrame(style: .vuMeter, phase: 0, load: 50.0, reduceMotion: false)
        #expect(midFrame >= 10 && midFrame <= 14)

        // High load: needle moves to far right (frames 21~23)
        let highFrame = MenuBarIconMotion.displayedFrame(style: .vuMeter, phase: 0, load: 100.0, reduceMotion: false)
        #expect(highFrame >= 21)
    }

    @Test func equalizerScalesTierWithLoad() {
        // Low load (< 25%): Tier 0 (frames 0..5)
        let lowFrame = MenuBarIconMotion.displayedFrame(style: .equalizer, phase: 2, load: 10.0, reduceMotion: false)
        #expect(lowFrame >= 0 && lowFrame <= 5)

        // Mid-low load (25~50%): Tier 1 (frames 6..11)
        let midLowFrame = MenuBarIconMotion.displayedFrame(style: .equalizer, phase: 2, load: 35.0, reduceMotion: false)
        #expect(midLowFrame >= 6 && midLowFrame <= 11)

        // Mid-high load (50~75%): Tier 2 (frames 12..17)
        let midHighFrame = MenuBarIconMotion.displayedFrame(style: .equalizer, phase: 2, load: 60.0, reduceMotion: false)
        #expect(midHighFrame >= 12 && midHighFrame <= 17)

        // High load (>= 75%): Tier 3 (frames 18..23)
        let highFrame = MenuBarIconMotion.displayedFrame(style: .equalizer, phase: 2, load: 95.0, reduceMotion: false)
        #expect(highFrame >= 18 && highFrame <= 23)
    }
}
