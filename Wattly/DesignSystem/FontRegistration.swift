import Foundation
import CoreText

/// Registers the bundled font at launch so `WattlyFont` resolves to Pretendard
/// (A17 = bundle Pretendard Variable). Process-scoped, so no Info.plist key is
/// needed. Pretendard is OFL-licensed — see `Fonts/OFL.txt`.
enum FontRegistration {
    static func register() {
        for name in ["PretendardVariable"] {
            let url = Bundle.main.url(forResource: name, withExtension: "ttf")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
            guard let url else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
