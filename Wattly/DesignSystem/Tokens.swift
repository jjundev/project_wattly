import SwiftUI

extension Color {
    /// `#rrggbb` hex.
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self = Color(.sRGB,
                     red: Double((v >> 16) & 0xff) / 255,
                     green: Double((v >> 8) & 0xff) / 255,
                     blue: Double(v & 0xff) / 255,
                     opacity: 1)
    }

    /// `rgba(...)` with 0–255 channels and 0–1 alpha (matches the prototype).
    static func rgba(_ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }
}

/// The visual token set. Values are copied verbatim from the prototype's inline
/// `c` dictionary (lines 581–584) — the declared source of truth. Where the
/// design-system CSS disagrees, the prototype wins (L11).
struct Tokens: Sendable, Equatable {
    // Status + accent — theme-independent (prototype lines 573–577).
    static let accent = Color(hex: "#0066ff")
    static let statusGreen = Color(hex: "#00bf40")
    static let statusOrange = Color(hex: "#ff9200")
    static let statusRed = Color(hex: "#ff4242")

    // Panel shadow (plan 01 line 20):
    //   0 4px 8px -2px rgba(23,23,23,.18), 0 16px 32px rgba(23,23,23,.28)
    static let shadowNear = (color: Color.rgba(23, 23, 23, 0.18), radius: 4.0, y: 4.0)
    static let shadowFar = (color: Color.rgba(23, 23, 23, 0.28), radius: 16.0, y: 16.0)

    // Theme-dependent.
    let panelBg, panelBorder, text, sub, faint, cardBg, line, spark, sparkFill: Color
    let settingsBg, titlebar, rowBg, rowBorder, segTrack, gridBorder, cText: Color
}

extension Tokens {
    /// Dark `c` (prototype line 581, 583–584).
    static let dark = Tokens(
        panelBg: Color(hex: "#212225"),
        panelBorder: .rgba(174, 176, 182, 0.18),
        text: Color(hex: "#f7f7f8"),
        sub: .rgba(247, 247, 248, 0.6),
        faint: .rgba(247, 247, 248, 0.45),
        cardBg: .rgba(174, 176, 182, 0.10),
        line: .rgba(174, 176, 182, 0.16),
        spark: .rgba(247, 247, 248, 0.6),
        sparkFill: .rgba(174, 176, 182, 0.12),
        settingsBg: Color(hex: "#1b1c1e"),
        titlebar: Color(hex: "#242527"),
        rowBg: Color(hex: "#212225"),
        rowBorder: .rgba(174, 176, 182, 0.14),
        segTrack: .rgba(174, 176, 182, 0.12),
        gridBorder: .rgba(174, 176, 182, 0.16),
        cText: .rgba(247, 247, 248, 0.85)
    )

    /// Light `c` (prototype line 582, 583–584).
    static let light = Tokens(
        panelBg: Color(hex: "#ffffff"),
        panelBorder: .rgba(112, 115, 124, 0.22),
        text: Color(hex: "#171719"),
        sub: .rgba(46, 47, 51, 0.6),
        faint: .rgba(46, 47, 51, 0.45),
        cardBg: .rgba(112, 115, 124, 0.06),
        line: .rgba(112, 115, 124, 0.14),
        spark: .rgba(46, 47, 51, 0.6),
        sparkFill: .rgba(112, 115, 124, 0.10),
        settingsBg: Color(hex: "#f7f7f8"),
        titlebar: Color(hex: "#ececee"),
        rowBg: Color(hex: "#ffffff"),
        rowBorder: .rgba(112, 115, 124, 0.18),
        segTrack: .rgba(112, 115, 124, 0.10),
        gridBorder: .rgba(112, 115, 124, 0.16),
        cText: .rgba(46, 47, 51, 0.85)
    )
}

// MARK: - Threshold level → status colors (issue 10)

extension ThresholdLevel {
    /// Sparkline stroke for this level — the theme-independent status tokens (prototype
    /// `pickColor`). Applied to the sparkline and, via `sparkStroke`, the memory process bars.
    var stroke: Color {
        switch self {
        case .normal: Tokens.statusGreen
        case .warn: Tokens.statusOrange
        case .crit: Tokens.statusRed
        }
    }

    /// Sparkline area fill for this level — the same hue at 12% (prototype `pickColor`).
    var fill: Color {
        switch self {
        case .normal: .rgba(0, 191, 64, 0.12)
        case .warn: .rgba(255, 146, 0, 0.12)
        case .crit: .rgba(255, 66, 66, 0.12)
        }
    }
}

// MARK: - Environment injection

private struct TokensKey: EnvironmentKey {
    static let defaultValue = Tokens.dark   // default theme is dark (plan README line 83)
}

extension EnvironmentValues {
    var tokens: Tokens {
        get { self[TokensKey.self] }
        set { self[TokensKey.self] = newValue }
    }
}
