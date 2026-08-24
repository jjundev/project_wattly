import Testing
import Foundation
@testable import Wattly

struct MenuBarIconStyleTests {
    @Test func allIconStylesHaveValidMetadataAndFrameCounts() {
        let styles = MenuBarIconStyle.allCases
        #expect(styles.count == 7)
        for style in styles {
            #expect(!style.id.isEmpty)
            #expect(!style.label.isEmpty)
            #expect(!style.category.isEmpty)
            #expect(!style.summary.isEmpty)
            #expect(style.frameCount >= 4)
            #expect(style.staticFrame >= 0 && style.staticFrame < style.frameCount)
        }
    }

    @Test func sailboatHasSpecificMetadata() {
        let boat = MenuBarIconStyle.sailboat
        #expect(boat.rawValue == "sailboat")
        #expect(boat.label == "종이배 (파도 항해)")
        #expect(boat.category == "캐릭터 / 라이프")
        #expect(!boat.summary.isEmpty)
        #expect(boat.frameCount == 96)
        #expect(boat.staticFrame == 0)
    }

    @Test func hillRunnerHasSpecificMetadata() {
        let runner = MenuBarIconStyle.hillRunner
        #expect(runner.rawValue == "hillRunner")
        #expect(runner.label == "러너 (경사로 질주)")
        #expect(runner.category == "캐릭터 / 라이프")
        #expect(!runner.summary.isEmpty)
        #expect(runner.frameCount == 24)
        #expect(runner.staticFrame == 8)
    }

    @Test func defaultIconStyleIsHillRunner() {
        #expect(Defaults.menubarIconStyle == .hillRunner)
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

