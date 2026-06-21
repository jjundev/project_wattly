import SwiftUI

/// Centralised font seam. A17 is resolved = bundle **Pretendard Variable** (the
/// face the prototype actually renders with; the "JP" in the CSS stack was never
/// loaded). The variable TTF lives in `Wattly/Fonts/` and is registered at launch
/// by `FontRegistration`. If registration ever fails, `Font.custom` falls back to
/// the system font so the app still runs.
enum WattlyFont {
    static let family = "Pretendard Variable"

    static func at(_ size: CGFloat, weight: Font.Weight) -> Font {
        .custom(family, size: size).weight(weight)
    }
}
