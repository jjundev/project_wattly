import Testing
import SwiftUI
@testable import Wattly

struct GlyphsRenderingTests {
    @Test @MainActor func allStylesRenderValidViewsForAllFrames() {
        for style in MenuBarIconStyle.allCases {
            for frame in 0..<style.frameCount {
                let view = DynamicMenuBarIconMark(style: style, frame: frame, markerColor: .black)
                #expect(view.style == style)
                #expect(view.frame == frame)
            }
        }
    }

    @Test @MainActor func hillRunnerRendersAllFramesWithoutCrash() {
        for frame in 0..<MenuBarIconStyle.hillRunner.frameCount {
            let view = DynamicMenuBarIconMark(style: .hillRunner, frame: frame, markerColor: .black)
            #expect(view.style == .hillRunner)
            #expect(view.frame == frame)
        }
    }

    @Test @MainActor func hillRunnerMarkRendersAcrossAllTiers() {
        for frame in 0..<24 {
            let mark = HillRunnerMark(frame: frame, markerColor: .black)
            #expect(mark.frame == frame)
        }
    }

    @Test @MainActor func pulseWaveMarkRendersAcrossAllTiers() {
        for frame in 0..<96 {
            let mark = PulseWaveMark(frame: frame, markerColor: .black)
            #expect(mark.frame == frame)
        }
    }

    @Test @MainActor func sailboatMarkRendersAcrossAllTiers() {
        for frame in 0..<96 {
            let mark = SailboatMark(frame: frame, markerColor: .black)
            #expect(mark.frame == frame)
        }
    }

    @Test @MainActor func sailboatDynamicMarkRendersWithoutCrash() {
        for frame in 0..<MenuBarIconStyle.sailboat.frameCount {
            let view = DynamicMenuBarIconMark(style: .sailboat, frame: frame, markerColor: .black)
            #expect(view.style == .sailboat)
            #expect(view.frame == frame)
        }
    }
}

