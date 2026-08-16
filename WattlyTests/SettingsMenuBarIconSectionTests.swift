import Testing
import Foundation
@testable import Wattly

struct SettingsMenuBarIconSectionTests {
    @Test func iconStylesCanBePersistedAndReadViaUserDefaults() {
        let defaults = UserDefaults(suiteName: "SettingsMenuBarIconSectionTests")!
        for style in MenuBarIconStyle.allCases {
            defaults.set(style.rawValue, forKey: StorageKey.menubarIconStyle)
            let readValue = defaults.string(forKey: StorageKey.menubarIconStyle)
            #expect(readValue == style.rawValue)
            let parsedStyle = MenuBarIconStyle(rawValue: readValue ?? "")
            #expect(parsedStyle == style)
        }
    }
}
