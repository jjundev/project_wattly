import Testing
import AppKit
@testable import Wattly

struct MenuBarGlyphTests {
    @Test @MainActor func templatesAreGeneratedAndMarkedAsTemplateImage() {
        for style in MenuBarIconStyle.allCases {
            for frame in 0..<style.frameCount {
                let image = MenuBarGlyph.template(style: style, frame: frame)
                #expect(image != nil)
                #expect(image?.isTemplate == true)
            }
        }
    }

    @Test @MainActor func templatesAreCachedInMemory() {
        let firstCall = MenuBarGlyph.template(style: .turbine, frame: 0)
        let secondCall = MenuBarGlyph.template(style: .turbine, frame: 0)
        #expect(firstCall === secondCall)
    }
}
