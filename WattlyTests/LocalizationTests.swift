import Testing
import Foundation
@testable import Wattly

struct LocalizationTests {
    @Test func appLanguageLocaleResolution() {
        #expect(AppLanguage.locale(for: "system") == Locale.autoupdatingCurrent)
        #expect(AppLanguage.locale(for: "en").identifier.hasPrefix("en"))
        #expect(AppLanguage.locale(for: "ja").identifier.hasPrefix("ja"))
        #expect(AppLanguage.supportedLanguages.count >= 31)
    }
}
