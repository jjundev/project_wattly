import Testing
import AppIntents
import Foundation
@testable import Wattly

@Suite struct WattlyShortcutsTests {
    @Test func appShortcutsContainStandardIntents() {
        let shortcuts = WattlyShortcuts.appShortcuts
        #expect(!shortcuts.isEmpty)
        #expect(shortcuts.count == 3)
        #expect(WattlyShortcuts.shortcutTileColor == .orange)
    }
}
