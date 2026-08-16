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

    @Test func stringCatalogTranslationsAcrossLocales() {
        #expect(String(localized: "일반", locale: Locale(identifier: "en")) == "General")
        #expect(String(localized: "일반", locale: Locale(identifier: "ja")) == "一般")
        #expect(String(localized: "일반", locale: Locale(identifier: "de")) == "Allgemein")
        #expect(String(localized: "일반", locale: Locale(identifier: "zh-Hans")) == "通用")
        #expect(String(localized: "일반", locale: Locale(identifier: "fr")) == "Général")
        #expect(String(localized: "일반", locale: Locale(identifier: "es")) == "General")
        #expect(String(localized: "일반", locale: Locale(identifier: "ru")) == "Основные")

        #expect(String(localized: "로그인 시 자동 실행", locale: Locale(identifier: "en")) == "Launch at Login")
        #expect(String(localized: "로그인 시 자동 실행", locale: Locale(identifier: "ja")) == "ログイン時に起動")
        #expect(String(localized: "로그인 시 자동 실행", locale: Locale(identifier: "de")) == "Beim Anmelden starten")

        #expect(String(localized: "기본값으로 되돌리기", locale: Locale(identifier: "en")) == "Reset to Defaults")
        #expect(String(localized: "기본값으로 되돌리기", locale: Locale(identifier: "ja")) == "デフォルトに戻す")

        #expect(String(localized: "전력 소비 (권장)", locale: Locale(identifier: "en")) == "Power Consumption (Recommended)")
        #expect(String(localized: "스마트 (권장)", locale: Locale(identifier: "en")) == "Smart (Recommended)")
    }
}
