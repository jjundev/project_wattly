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
        #expect(MenuBarIconMotion.frameRate(load: 5, speed: .standard) == nil)
        #expect(MenuBarIconMotion.frameRate(load: 100, speed: .eco) == 36)
        #expect(MenuBarIconMotion.frameRate(load: 100, speed: .standard) == 48)
        #expect(MenuBarIconMotion.frameRate(load: 100, speed: .responsive) == 60)
    }

    @Test func ratesUseSquareRootProgressionAndPerPresetMinimums() {
        // 5.0095 is just above the 5% idle threshold. Its normalized distance is
        // 0.01%, so the square-root curve has advanced by 1% of each preset's range.
        let nearThreshold = 5.0095
        #expect(MenuBarIconMotion.frameRate(load: 5, speed: .eco) == nil)
        #expect(MenuBarIconMotion.frameRate(load: 5, speed: .standard) == nil)
        #expect(MenuBarIconMotion.frameRate(load: 5, speed: .responsive) == nil)
        #expect(abs((MenuBarIconMotion.frameRate(load: nearThreshold, speed: .eco) ?? 0) - 6.30) < 1e-12)
        #expect(abs((MenuBarIconMotion.frameRate(load: nearThreshold, speed: .standard) ?? 0) - 8.40) < 1e-12)
        #expect(abs((MenuBarIconMotion.frameRate(load: nearThreshold, speed: .responsive) ?? 0) - 12.48) < 1e-12)

        // 28.75% is one quarter through the load range, which square-root interpolation
        // maps to halfway through each rate range (not the linear one-quarter point).
        let interiorLoad = 28.75
        #expect(abs((MenuBarIconMotion.frameRate(load: interiorLoad, speed: .eco) ?? 0) - 21.0) < 1e-12)
        #expect(abs((MenuBarIconMotion.frameRate(load: interiorLoad, speed: .standard) ?? 0) - 28.0) < 1e-12)
        #expect(abs((MenuBarIconMotion.frameRate(load: interiorLoad, speed: .responsive) ?? 0) - 36.0) < 1e-12)
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
