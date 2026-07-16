import SwiftUI
import AppKit

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

    /// The concrete `NSAppearance` a hosting `NSWindow` should adopt for this mode. `nil` =
    /// follow the system, same convention as `preferredColorScheme`. SwiftUI's
    /// `.preferredColorScheme` only sets a window's appearance at window-creation time — it does
    /// not re-apply on a live theme change — so callers that need the window itself to update
    /// while already open (the Settings window) must assign this value reactively themselves.
    static func nsAppearance(_ mode: ThemeMode) -> NSAppearance? {
        switch mode {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }

    /// Resolves a mode to a CONCRETE scheme. Unlike `preferredColorScheme` (which returns `nil`
    /// for `.system`), this always yields `.light` or `.dark`, given whether the OS currently
    /// prefers dark. This is what lets `.system` drive SwiftUI's content through the same
    /// concrete-value path `.light`/`.dark` use: a `nil` `preferredColorScheme` does NOT repaint
    /// an already-forced window's content (the live-toggle bug where `.system` left the body dark),
    /// whereas a concrete one does.
    static func scheme(_ mode: ThemeMode, systemDark: Bool) -> ColorScheme {
        switch mode {
        case .light: .light
        case .dark: .dark
        case .system: systemDark ? .dark : .light
        }
    }
}

/// The current OS appearance, read independently of any per-window forced appearance.
enum SystemAppearance {
    /// Whether the OS currently prefers Dark. Reads `NSApp`'s effective appearance — the app never
    /// sets `NSApp.appearance`, so it follows the system and a per-window forced appearance (set by
    /// `WindowAppearanceSync`) does not skew this reading.
    static func isDark() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// Tracks the live OS Light/Dark preference for `.system` mode. KVO-observes `NSApp`'s effective
/// appearance (the same signal `WindowAppearanceSync` uses for the window chrome) and republishes
/// it as an observable `isDark`, so a `.system`-themed view re-renders when the user switches the
/// system appearance (or an Auto transition fires) while a window stays open.
@Observable @MainActor final class SystemAppearanceMonitor {
    var isDark: Bool = SystemAppearance.isDark()
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        observation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.isDark = SystemAppearance.isDark() }
        }
    }
}

/// Forces the theme's scheme and injects the matching tokens. `.system` resolves to a CONCRETE
/// scheme via `SystemAppearance.isDark()` (not `nil`) so that switching to it repaints the content
/// live, exactly like `.light`/`.dark` — a `nil` `preferredColorScheme` leaves an already-forced
/// window's body stuck at its previous scheme (the live-toggle bug). `@State systemDark` is seeded
/// from the OS and refreshed on `SystemAppearance.didChange`, so a `.system` window keeps following
/// the OS while it stays open.
///
/// Reads `@AppStorage(theme)` itself rather than receiving it as a prop, so a theme change
/// re-renders only this subtree instead of the App's `Scene` body. (The window's native titlebar
/// is updated separately by `WindowAppearanceSync`, since `preferredColorScheme` alone does not
/// re-resolve an already-visible `NSWindow`'s chrome on a live change.)
struct ThemedRoot<Content: View>: View {
    @AppStorage(StorageKey.theme) private var theme: ThemeMode = Defaults.theme
    @State private var systemAppearance = SystemAppearanceMonitor()
    @ViewBuilder var content: () -> Content

    private var scheme: ColorScheme {
        ThemeResolver.scheme(theme, systemDark: systemAppearance.isDark)
    }

    var body: some View {
        content()
            .environment(\.tokens, scheme == .dark ? .dark : .light)
            .preferredColorScheme(scheme)
    }
}
