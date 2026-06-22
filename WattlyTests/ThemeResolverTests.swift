import Testing
import SwiftUI
@testable import Wattly

/// Issue 11 — pure theme resolution: the forced `ColorScheme` and the token set, the only
/// theming logic worth unit-testing (live OS-appearance switching is verified on-device).
struct ThemeResolverTests {

    // MARK: preferredColorScheme — light/dark force, system follows the OS (nil)

    @Test func forcedModesForceTheScheme() {
        #expect(ThemeResolver.preferredColorScheme(.light) == .light)
        #expect(ThemeResolver.preferredColorScheme(.dark) == .dark)
        #expect(ThemeResolver.preferredColorScheme(.system) == nil)
    }

    // MARK: tokens — 3 modes × 2 resolved schemes

    @Test func lightAndDarkIgnoreTheEnvironmentScheme() {
        // Forced modes pin the token set regardless of what the OS resolved to.
        for scheme in [ColorScheme.light, .dark] {
            #expect(ThemeResolver.tokens(.light, environment: scheme) == .light)
            #expect(ThemeResolver.tokens(.dark, environment: scheme) == .dark)
        }
    }

    @Test func systemFollowsTheEnvironmentScheme() {
        // `.system` is the only mode that reads the resolved scheme.
        #expect(ThemeResolver.tokens(.system, environment: .light) == .light)
        #expect(ThemeResolver.tokens(.system, environment: .dark) == .dark)
    }
}
