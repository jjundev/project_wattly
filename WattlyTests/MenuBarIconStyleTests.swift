import Testing
import Foundation
@testable import Wattly

struct MenuBarIconStyleTests {
    @Test func allIconStylesHaveValidMetadataAndFrameCounts() {
        let styles = MenuBarIconStyle.allCases
        #expect(styles.count == 5)
        for style in styles {
            #expect(!style.id.isEmpty)
            #expect(!style.label.isEmpty)
            #expect(!style.category.isEmpty)
            #expect(!style.summary.isEmpty)
            #expect(style.frameCount >= 4)
            #expect(style.staticFrame == 0)
        }
    }

    @Test func defaultIconStyleIsCoolingTurbine() {
        #expect(Defaults.menubarIconStyle == .turbine)
        #expect(StorageKey.menubarIconStyle == "menubarIconStyle")
    }

    @Test func settingsResetRestoresDefaultIconStyle() {
        let defaults = UserDefaults(suiteName: "MenuBarIconStyleTests")!
        defaults.set(MenuBarIconStyle.cube3D.rawValue, forKey: StorageKey.menubarIconStyle)
        #expect(defaults.string(forKey: StorageKey.menubarIconStyle) == MenuBarIconStyle.cube3D.rawValue)

        SettingsReset.applyDefaults(into: defaults)
        #expect(defaults.string(forKey: StorageKey.menubarIconStyle) == Defaults.menubarIconStyle.rawValue)
    }
}
