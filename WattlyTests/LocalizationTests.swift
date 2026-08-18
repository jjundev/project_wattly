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

    @Test func menuMetricChipsAndThresholdTranslations() {
        #expect(String(localized: "전력 (W)", locale: Locale(identifier: "ja")) == "電力 (W)")
        #expect(String(localized: "배터리 (W)", locale: Locale(identifier: "ja")) == "バッテリー (W)")
        #expect(String(localized: "메모리 (GB)", locale: Locale(identifier: "ja")) == "メモリ (GB)")
        #expect(String(localized: "CPU 온도 (°C)", locale: Locale(identifier: "ja")) == "CPU温度 (°C)")
        #expect(String(localized: "GPU 온도 (°C)", locale: Locale(identifier: "ja")) == "GPU温度 (°C)")
        #expect(String(localized: "팬 (RPM)", locale: Locale(identifier: "ja")) == "ファン (RPM)")

        #expect(String(localized: "CPU 사용률 (%)", locale: Locale(identifier: "ja")) == "CPU使用率 (%)")
        #expect(String(localized: "GPU 사용률 (%)", locale: Locale(identifier: "ja")) == "GPU使用率 (%)")

        #expect(String(localized: "활성", locale: Locale(identifier: "ja")) == "アクティブ")
        #expect(String(localized: "저전력", locale: Locale(identifier: "ja")) == "低電力")
        #expect(String(localized: "AC", locale: Locale(identifier: "ja")) == "AC")
    }

    @Test func popoverCardAndExpandTranslations() {
        #expect(String(localized: "렌더러", locale: Locale(identifier: "ja")) == "レンダラー")
        #expect(String(localized: "타일러", locale: Locale(identifier: "ja")) == "タイラー")
        #expect(String(localized: "전류", locale: Locale(identifier: "ja")) == "電流")
        #expect(String(localized: "전압", locale: Locale(identifier: "ja")) == "電圧")
        #expect(String(localized: "1분 평균", locale: Locale(identifier: "ja")) == "1分平均")
        #expect(String(localized: "남은 용량", locale: Locale(identifier: "ja")) == "残り容量")
        #expect(String(localized: "배터리 효율", locale: Locale(identifier: "ja")) == "バッテリー状態")
        #expect(String(localized: "사이클", locale: Locale(identifier: "ja")) == "充放電回数")
        #expect(String(localized: "배터리 온도", locale: Locale(identifier: "ja")) == "バッテリー温度")
        #expect(String(localized: "완충까지 남은 시간", locale: Locale(identifier: "ja")) == "フル充電までの時間")
        #expect(String(localized: "프로세스를 읽을 수 없음", locale: Locale(identifier: "ja")) == "プロセスを読み込めません")
        #expect(String(localized: "센서를 읽을 수 없음", locale: Locale(identifier: "ja")) == "センサーを読み込めません")
        #expect(String(localized: "팬을 읽을 수 없음", locale: Locale(identifier: "ja")) == "ファンを読み込めません")
        #expect(String(localized: "편집", locale: Locale(identifier: "ja")) == "編集")
        #expect(String(localized: "종료", locale: Locale(identifier: "ja")) == "終了")
        #expect(String(localized: "정상", locale: Locale(identifier: "ja")) == "正常")
    }

    @Test func clusterAndBatteryTimeRemainingTranslations() {
        #expect(String(localized: "S-코어", locale: Locale(identifier: "ja")) == "Sコア")
        #expect(String(localized: "P-코어", locale: Locale(identifier: "ja")) == "Pコア")
        #expect(String(localized: "E-코어", locale: Locale(identifier: "ja")) == "Eコア")

        #expect(String(localized: "S-코어", locale: Locale(identifier: "en")) == "S-Core")
        #expect(String(localized: "P-코어", locale: Locale(identifier: "en")) == "P-Core")
        #expect(String(localized: "E-코어", locale: Locale(identifier: "en")) == "E-Core")
    }

    @Test func softwareUpdateTranslations() {
        #expect(String(localized: "소프트웨어 업데이트", locale: Locale(identifier: "en")) == "Software Update")
        #expect(String(localized: "소프트웨어 업데이트", locale: Locale(identifier: "ja")) == "ソフトウェアアップデート")
        #expect(String(localized: "소프트웨어 업데이트", locale: Locale(identifier: "zh-Hans")) == "软件更新")
        #expect(String(localized: "소프트웨어 업데이트", locale: Locale(identifier: "de")) == "Softwareupdate")
        #expect(String(localized: "소프트웨어 업데이트", locale: Locale(identifier: "fr")) == "Mise à jour de logiciels")

        #expect(String(localized: "최신 버전입니다", locale: Locale(identifier: "en")) == "Wattly is up to date")
        #expect(String(localized: "최신 버전입니다", locale: Locale(identifier: "ja")) == "最新バージョンです")
        #expect(String(localized: "최신 버전입니다", locale: Locale(identifier: "de")) == "Wattly ist auf dem neuesten Stand")

        #expect(String(localized: "업데이트 확인", locale: Locale(identifier: "en")) == "Check for Updates")
        #expect(String(localized: "업데이트 확인", locale: Locale(identifier: "ja")) == "アップデートを確認")
        #expect(String(localized: "업데이트 확인", locale: Locale(identifier: "zh-Hans")) == "检查更新")

        #expect(String(localized: "확인 중...", locale: Locale(identifier: "en")) == "Checking...")
        #expect(String(localized: "확인 중...", locale: Locale(identifier: "ja")) == "確認中...")

        #expect(String(localized: "지금 업데이트", locale: Locale(identifier: "en")) == "Update Now")
        #expect(String(localized: "지금 업데이트", locale: Locale(identifier: "ja")) == "今すぐアップデート")

        #expect(String(localized: "릴리즈 열기", locale: Locale(identifier: "en")) == "Open Release")
        #expect(String(localized: "릴리즈 열기", locale: Locale(identifier: "ja")) == "リリースを開く")

        #expect(String(localized: "설치 준비 중...", locale: Locale(identifier: "en")) == "Preparing to install...")
        #expect(String(localized: "설치 준비 중...", locale: Locale(identifier: "ja")) == "インストール準備中...")

        #expect(String(localized: "현재 버전 v%@", locale: Locale(identifier: "en")) == "Current version v%@")
        #expect(String(localized: "현재 버전 v%@", locale: Locale(identifier: "ja")) == "現在のバージョン v%@")
        #expect(String(localized: "v%@ 사용 가능", locale: Locale(identifier: "en")) == "v%@ available")
        #expect(String(localized: "v%@ 사용 가능", locale: Locale(identifier: "ja")) == "v%@ が利用可能")
    }

    @Test func contactDeveloperTranslations() {
        #expect(String(localized: "개발자에게 문의하기", locale: Locale(identifier: "en")) == "Contact Developer")
        #expect(String(localized: "개발자에게 문의하기", locale: Locale(identifier: "ja")) == "開発者に問い合わせ")
        #expect(String(localized: "개발자에게 문의하기", locale: Locale(identifier: "zh-Hans")) == "联系开发者")
        #expect(String(localized: "개발자에게 문의하기", locale: Locale(identifier: "zh-Hant")) == "聯絡開發者")
        #expect(String(localized: "개발자에게 문의하기", locale: Locale(identifier: "de")) == "Entwickler kontaktieren")
        #expect(String(localized: "개발자에게 문의하기", locale: Locale(identifier: "fr")) == "Contacter le développeur")
        #expect(String(localized: "개발자에게 문의하기", locale: Locale(identifier: "es")) == "Contactar al desarrollador")

        #expect(String(localized: "문의하기", locale: Locale(identifier: "en")) == "Contact")
        #expect(String(localized: "문의하기", locale: Locale(identifier: "ja")) == "問い合わせ")
        #expect(String(localized: "문의하기", locale: Locale(identifier: "zh-Hans")) == "联系")
        #expect(String(localized: "문의하기", locale: Locale(identifier: "zh-Hant")) == "聯絡")
        #expect(String(localized: "문의하기", locale: Locale(identifier: "de")) == "Kontaktieren")
        #expect(String(localized: "문의하기", locale: Locale(identifier: "fr")) == "Contacter")
    }
}

