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
}
