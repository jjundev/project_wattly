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

    @Test func iconDesignThemeTranslations() {
        #expect(String(localized: "쿨링 터빈", locale: Locale(identifier: "en")) == "Cooling Turbine")
        #expect(String(localized: "쿨링 터빈", locale: Locale(identifier: "ja")) == "クーリングタービン")
        #expect(String(localized: "펄스 웨이브", locale: Locale(identifier: "en")) == "Pulse Wave")
        #expect(String(localized: "VU 파워 미터", locale: Locale(identifier: "en")) == "VU Power Meter")
        #expect(String(localized: "3D 큐브", locale: Locale(identifier: "en")) == "3D Cube")
        #expect(String(localized: "열 대류 버블", locale: Locale(identifier: "en")) == "Thermal Bubbles")
        #expect(String(localized: "디지털 이퀄라이저", locale: Locale(identifier: "en")) == "Equalizer")
        #expect(String(localized: "러너 (경사로 질주)", locale: Locale(identifier: "en")) == "Hill Runner")
    }

    @Test func advancedMetricsTranslations() {
        #expect(String(localized: "S 코어 클럭 (GHz)", locale: Locale(identifier: "en")) == "S Core Clock (GHz)")
        #expect(String(localized: "P 코어 클럭 (GHz)", locale: Locale(identifier: "en")) == "P Core Clock (GHz)")
        #expect(String(localized: "E 코어 클럭 (GHz)", locale: Locale(identifier: "en")) == "E Core Clock (GHz)")
        #expect(String(localized: "메모리 압력 (%)", locale: Locale(identifier: "en")) == "Memory Pressure (%)")
        #expect(String(localized: "배터리 온도 (°C)", locale: Locale(identifier: "en")) == "Battery Temp (°C)")
    }
}
