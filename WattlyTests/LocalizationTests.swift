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

        #expect(String(localized: "전력 소비", locale: Locale(identifier: "en")) == "Power")
        #expect(String(localized: "전력 소비", locale: Locale(identifier: "ja")) == "消費電力")
        #expect(String(localized: "전력 소비", locale: Locale(identifier: "de")) == "Stromverbrauch")
        #expect(String(localized: "전력 소비", locale: Locale(identifier: "fr")) == "Consommation")
        #expect(String(localized: "전력 소비", locale: Locale(identifier: "zh-Hans")) == "功耗")

        #expect(String(localized: "스마트", locale: Locale(identifier: "en")) == "Smart")
        #expect(String(localized: "스마트", locale: Locale(identifier: "ja")) == "スマート")
        #expect(String(localized: "스마트", locale: Locale(identifier: "de")) == "Smart")
        #expect(String(localized: "스마트", locale: Locale(identifier: "fr")) == "Intelligent")
        #expect(String(localized: "스마트", locale: Locale(identifier: "zh-Hans")) == "智能")

        #expect(String(localized: "(권장) SoC 전체 전력 소비량(W)에 비례하여 움직입니다. 시스템의 실제 작업 부하를 가장 정확하게 반영합니다.", locale: Locale(identifier: "en")).hasPrefix("(Recommended)"))
        #expect(String(localized: "(권장) 메뉴바 상주 시에는 ProMotion 절전을 위해 24 fps로 고정되며, 팝오버를 열거나 설정창을 볼 때는 전원 상태(AC 60 fps / 배터리 24 fps)에 따라 부드럽게 동작합니다.", locale: Locale(identifier: "en")).hasPrefix("(Recommended)"))
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
