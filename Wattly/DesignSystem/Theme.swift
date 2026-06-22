import SwiftUI

/// Three-way theme (plan 11). `system` follows the OS; `light`/`dark` force it
/// regardless of the OS — which is exactly why tokens are a value type selected
/// by a resolver rather than an asset catalog (L10).
enum ThemeMode: String, CaseIterable, Identifiable, Sendable {
    case light, dark, system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: "라이트"
        case .dark: "다크"
        case .system: "시스템"
        }
    }
}

enum ThemeResolver {
    /// Forced scheme for `.preferredColorScheme`. `nil` = follow the system.
    static func preferredColorScheme(_ mode: ThemeMode) -> ColorScheme? {
        switch mode {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }

    /// Tokens to inject, given the mode and the *resolved* environment scheme.
    static func tokens(_ mode: ThemeMode, environment scheme: ColorScheme) -> Tokens {
        let dark = switch mode {
            case .light: false
            case .dark: true
            case .system: scheme == .dark
        }
        return dark ? .dark : .light
    }
}

/// Applies the theme's forced scheme and injects the matching tokens. Reads the
/// resolved `colorScheme` *inside* the forced subtree so `system` picks up the OS
/// value while `light`/`dark` see what they forced.
///
/// Reads `@AppStorage(theme)` itself rather than receiving it as a prop, so a theme
/// change re-renders only this subtree instead of the App's `Scene` body. (Note: this
/// is NOT what fixes the "popover closes on settings change" report — that closure is
/// `openSettings()` opening a key window, which dismisses the `.window` popover
/// regardless of theme.)
struct ThemedRoot<Content: View>: View {
    @AppStorage(StorageKey.theme) private var theme: ThemeMode = Defaults.theme
    @ViewBuilder var content: () -> Content

    var body: some View {
        Resolver(theme: theme, content: content)
            .preferredColorScheme(ThemeResolver.preferredColorScheme(theme))
    }

    private struct Resolver<C: View>: View {
        let theme: ThemeMode
        @ViewBuilder var content: () -> C
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            content()
                .environment(\.tokens, ThemeResolver.tokens(theme, environment: scheme))
        }
    }
}
