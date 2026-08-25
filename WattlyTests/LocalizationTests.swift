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
        #expect(String(localized: "러너", locale: Locale(identifier: "en")) == "Runner")
        #expect(String(localized: "종이배", locale: Locale(identifier: "en")) == "Paper Boat")
        #expect(String(localized: "종이배", locale: Locale(identifier: "ja")) == "紙の船")
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
        #expect(String(localized: "팬 속도 (최대 RPM 대비 %)", locale: Locale(identifier: "ja")) == "ファン回転数 最大比 (%)")
        #expect(String(localized: "팬 속도 (최대 RPM 대비 %)", locale: Locale(identifier: "en")) == "Fan Speed vs. Max RPM (%)")

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

        #expect(String(localized: "버그 제보나 기능 제안 등 피드백을 보냅니다.", locale: Locale(identifier: "en")) == "Send feedback, report bugs, or suggest features.")
        #expect(String(localized: "버그 제보나 기능 제안 등 피드백을 보냅니다.", locale: Locale(identifier: "ja")) == "バグ報告や機能の提案などのフィードバックを送信します。")
    }

    // MARK: - 배터리 충전 제한 (plan 2026-08-23)

    @Test func batteryStatusReasonTranslations() {
        #expect(String(localized: "이 Mac은 충전 제어를 지원하지 않습니다", locale: Locale(identifier: "en"))
                == "This Mac does not support charge control")
        #expect(String(localized: "이 Mac은 충전 제어를 지원하지 않습니다", locale: Locale(identifier: "ja"))
                == "このMacは充電制御に対応していません")
        #expect(String(localized: "이 Mac은 충전 제어를 지원하지 않습니다", locale: Locale(identifier: "de"))
                == "Dieser Mac unterstützt keine Ladesteuerung")
        #expect(String(localized: "이 Mac은 충전 제어를 지원하지 않습니다", locale: Locale(identifier: "zh-Hans"))
                == "此 Mac 不支持充电控制")

        #expect(String(localized: "충전 제한 비활성화됨", locale: Locale(identifier: "en")) == "Charge limit off")
        #expect(String(localized: "충전 제한 비활성화됨", locale: Locale(identifier: "ja")) == "充電上限オフ")
        #expect(String(localized: "충전 제한 비활성화됨", locale: Locale(identifier: "de")) == "Ladelimit aus")
        #expect(String(localized: "충전 제한 비활성화됨", locale: Locale(identifier: "zh-Hans")) == "充电上限已关闭")

        #expect(String(localized: "배터리 전원으로 구동 중", locale: Locale(identifier: "en")) == "Running on battery")
        #expect(String(localized: "초기화 중", locale: Locale(identifier: "en")) == "Initializing")
        #expect(String(localized: "전원 소스를 읽을 수 없습니다", locale: Locale(identifier: "en"))
                == "Cannot read power source")
        #expect(String(localized: "이 Mac에서 충전 제어를 적용하지 못했습니다", locale: Locale(identifier: "en"))
                == "Could not apply charge control on this Mac")
        #expect(String(localized: "충전을 다시 시작하지 못했습니다 (전원 어댑터를 다시 연결해 보세요)",
                       locale: Locale(identifier: "en"))
                == "Could not resume charging (try reconnecting the power adapter)")

        #expect(BatteryStatusText.text(
            reason: .init(kind: .persistenceReadFailed), detail: "", locale: Locale(identifier: "en"))
                == "Stored charge policy could not be read; charging will be restored")
        #expect(BatteryStatusText.text(
            reason: .init(kind: .persistenceWriteFailed), detail: "", locale: Locale(identifier: "en"))
                == "Charge policy could not be saved safely")
        #expect(BatteryStatusText.text(
            reason: .init(kind: .policyOwnerMismatch), detail: "", locale: Locale(identifier: "en"))
                == "Another user manages this Mac's charge policy")
        #expect(BatteryStatusText.text(
            reason: .init(kind: .hardwareReadbackFailed), detail: "", locale: Locale(identifier: "en"))
                == "Charge-control hardware state could not be verified")
    }

    /// 서식 지정자가 어긋나면 조회는 조용히 실패하고 한국어로 되돌아간다. 지정자 자체를 못박아 둔다.
    @Test func batteryFormatKeysKeepTheirSpecifiers() {
        for lang in ["ko", "en", "ja", "de", "fr", "zh-Hans", "ar", "he", "hi"] {
            let inhibited = String(localized: "충전 제한 %lld%% 도달 (전원 어댑터 바이패스 구동)",
                                   locale: Locale(identifier: lang))
            #expect(inhibited.contains("%lld"), "\(lang): %lld 유실")
            #expect(inhibited.contains("%%"), "\(lang): %% 유실")

            let charging = String(localized: "목표치(%lld%%)까지 충전 중", locale: Locale(identifier: lang))
            #expect(charging.contains("%lld"), "\(lang): %lld 유실")
            #expect(charging.contains("%%"), "\(lang): %% 유실")

            let installFailed = String(localized: "도우미는 설치했지만 충전 제한을 적용하지 못했습니다: %@",
                                       locale: Locale(identifier: lang))
            #expect(installFailed.contains("%@"), "\(lang): %@ 유실")

            let sailing = String(localized: "Sailing 중 (%lld%% 도달 시 재충전)",
                                 locale: Locale(identifier: lang))
            #expect(sailing.contains("%lld"), "\(lang): %lld 유실")
            #expect(sailing.contains("%%"), "\(lang): %% 유실")

            let holding = String(localized: "%lld%% 한도 유지 중", locale: Locale(identifier: lang))
            #expect(holding.contains("%lld"), "\(lang): %lld 유실")
            #expect(holding.contains("%%"), "\(lang): %% 유실")
        }

        #expect(String(localized: "%lld%% 한도 유지 중", locale: Locale(identifier: "en"))
                == "Holding at %lld%% Limit")
        #expect(String(localized: "충전 제한 %lld%% 도달 (전원 어댑터 바이패스 구동)", locale: Locale(identifier: "en"))
                == "Charge limit %lld%% reached (running on adapter bypass)")
        #expect(String(localized: "목표치(%lld%%)까지 충전 중", locale: Locale(identifier: "en"))
                == "Charging to %lld%%")
        #expect(String(localized: "Sailing 중 (%lld%% 도달 시 재충전)", locale: Locale(identifier: "en"))
                == "Sailing (recharging at %lld%%)")
        #expect(String(localized: "Sailing 중 (%lld%% 도달 시 재충전)", locale: Locale(identifier: "ko"))
                == "Sailing 중 (%lld%% 도달 시 재충전)")
    }

    @Test func batterySettingsSectionTranslations() {
        #expect(String(localized: "배터리 충전 제어", locale: Locale(identifier: "en")) == "Battery Charge Control")
        #expect(String(localized: "배터리 충전 제어", locale: Locale(identifier: "ja")) == "バッテリー充電制御")
        #expect(String(localized: "배터리 충전 제어", locale: Locale(identifier: "de")) == "Batterieladesteuerung")
        #expect(String(localized: "배터리 충전 제어", locale: Locale(identifier: "zh-Hans")) == "电池充电控制")

        #expect(String(localized: "배터리 충전 제한", locale: Locale(identifier: "en")) == "Battery Charge Limit")
        #expect(String(localized: "배터리 충전 제한", locale: Locale(identifier: "fr"))
                == "Limite de charge de la batterie")

        #expect(String(localized: "최대 충전 한도", locale: Locale(identifier: "en")) == "Maximum Charge Limit")
        #expect(String(localized: "도우미 설치", locale: Locale(identifier: "en")) == "Install Helper")
        #expect(String(localized: "도우미 설치 실패", locale: Locale(identifier: "en")) == "Helper Installation Failed")
        #expect(String(localized: "도우미 설치 중…", locale: Locale(identifier: "en")) == "Installing helper…")
        #expect(String(localized: "확인", locale: Locale(identifier: "en")) == "OK")
        #expect(String(localized: "충전 제한을 켜면 한도를 조절할 수 있습니다.", locale: Locale(identifier: "en"))
                == "Turn on the charge limit to adjust the maximum.")
    }

    @Test func batteryMaintenanceTranslations() {
        let en = Locale(identifier: "en")
        #expect(String(localized: "마지막 확인: %@ · 성공 · %@", locale: en)
                == "Last check: %@ · succeeded · %@")
        #expect(String(localized: "충전 정책 확인 전", locale: en) == "Charge policy not checked yet")
        #expect(String(localized: "앱 종료·Sleep 유지를 사용하려면 도우미 업데이트가 필요합니다.", locale: en)
                == "Update the helper to keep charge control active after app exit and during sleep.")
        #expect(String(localized: "도우미 업데이트", locale: en) == "Update Helper")
        #expect(String(localized: "다시 확인", locale: en) == "Check Again")
        #expect(String(localized: "다른 사용자의 충전 정책을 해제하고 이 사용자로 소유권을 이전합니다.", locale: en)
                == "Release the other user's charge policy and transfer ownership to this user.")
        #expect(String(localized: "소유권 이전", locale: en) == "Transfer Ownership")
        #expect(String(localized: "Wattly 삭제 중단", locale: en) == "Wattly Removal Stopped")
        #expect(String(localized: "설치된 도우미의 소유자 정보를 확인할 수 없습니다.", locale: en)
                == "Could not verify the installed helper's ownership.")
    }

    @Test func sharedControlAccessibilityTranslations() {
        #expect(String(localized: "켜짐", locale: Locale(identifier: "en")) == "On")
        #expect(String(localized: "꺼짐", locale: Locale(identifier: "en")) == "Off")
        #expect(String(localized: "켜짐", locale: Locale(identifier: "de")) == "Ein")
        #expect(String(localized: "꺼짐", locale: Locale(identifier: "de")) == "Aus")
        #expect(String(localized: "사용할 수 없습니다", locale: Locale(identifier: "en")) == "Unavailable")
    }

    @Test func helperInstallErrorTranslations() {
        #expect(String(localized: "앱 번들에서 도우미 실행 파일을 찾을 수 없습니다.", locale: Locale(identifier: "en"))
                == "Could not find the helper executable in the app bundle.")
        #expect(String(localized: "관리자 인증이 취소되었거나 실패했습니다.", locale: Locale(identifier: "en"))
                == "Administrator authentication was cancelled or failed.")
        #expect(String(localized: "도우미에 연결되지 않음", locale: Locale(identifier: "en"))
                == "Not connected to helper")
        #expect(String(localized: "도우미 응답 오류", locale: Locale(identifier: "en")) == "Helper response error")
    }

    @Test func heatProtectionTranslationsAcrossLocales() {
        #expect(String(localized: "발열 보호", locale: Locale(identifier: "en")) == "Heat Protection")
        #expect(String(localized: "배터리 온도가 35°C를 초과하면 충전을 일시 중단하고, 33°C 이하로 냉각되면 재개합니다.", locale: Locale(identifier: "en")) != "")
    }

    @Test func topUpTranslations() {
        let en = Locale(identifier: "en")
        let ko = Locale(identifier: "ko")

        #expect(String(localized: "한 번만 완충", locale: en) == "Top Up")
        #expect(String(localized: "한 번만 완충 중 (100%까지 충전)", locale: en) == "Top Up in progress (Charging to 100%)")
        #expect(String(localized: "한 번만 완충 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)", locale: en) == "Top Up complete (Holding at 100%, normal limit restores on unplug)")
        #expect(String(localized: "한 번만 완충 완료", locale: en) == "Top Up Complete")
        #expect(String(localized: "활성화됨", locale: en) == "Enabled")
        #expect(String(localized: "비활성화됨", locale: en) == "Disabled")
        #expect(String(localized: "다음 외출이나 출장을 위해 배터리를 일회성으로 100%까지 완전 충전합니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다.", locale: en) == "Charges to 100% once before heading out, then automatically restores your charge limit when unplugged.")
        #expect(String(localized: "배터리가 100%까지 충전되었습니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다.", locale: en) == "Battery is charged to 100%. Normal limit will restore automatically when unplugged.")

        #expect(String(localized: "한 번만 완충", locale: ko) == "한 번만 완충")
        #expect(String(localized: "한 번만 완충 중 (100%까지 충전)", locale: ko) == "한 번만 완충 중 (100%까지 충전)")
        #expect(String(localized: "한 번만 완충 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)", locale: ko) == "한 번만 완충 완료 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)")
        #expect(String(localized: "한 번만 완충 완료", locale: ko) == "한 번만 완충 완료")
        #expect(String(localized: "활성화됨", locale: ko) == "활성화됨")
        #expect(String(localized: "비활성화됨", locale: ko) == "비활성화됨")
        #expect(String(localized: "다음 외출이나 출장을 위해 배터리를 일회성으로 100%까지 완전 충전합니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다.", locale: ko) == "다음 외출이나 출장을 위해 배터리를 일회성으로 100%까지 완전 충전합니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다.")
        #expect(String(localized: "배터리가 100%까지 충전되었습니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다.", locale: ko) == "배터리가 100%까지 충전되었습니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다.")
    }

    @Test func dynamicChargeTimeTranslations() {
        let sample85 = BatterySample(
            netW: -20.0,
            milliamps: 1500,
            volts: 12.5,
            charging: true,
            externalConnected: true,
            projectedTimeRemainingMinutes: 25,
            targetPercentage: 85
        )
        let sample100 = BatterySample(
            netW: -20.0,
            milliamps: 1500,
            volts: 12.5,
            charging: true,
            externalConnected: true,
            projectedTimeRemainingMinutes: 70,
            targetPercentage: 100
        )
        let sampleDischarge = BatterySample(
            netW: 15.0,
            milliamps: 1200,
            volts: 12.5,
            charging: false,
            externalConnected: false,
            projectedTimeRemainingMinutes: 140,
            targetPercentage: 85
        )

        // Korean
        let ko = Locale(identifier: "ko")
        #expect(CardPresentation.batteryRemainingTimeSummary(sample85, locale: ko) == "85%까지 약 25분 남음")
        #expect(CardPresentation.batteryRemainingTimeSummary(sample100, locale: ko) == "완충까지 약 1시간 10분 남음")
        #expect(CardPresentation.batteryRemainingTimeSummary(sampleDischarge, locale: ko) == "약 2시간 20분 남음")
        #expect(CardPresentation.batteryTimeToFullLabel(targetPercentage: 85, locale: ko) == "85%까지 남은 시간")
        #expect(CardPresentation.batteryTimeToFullLabel(targetPercentage: 100, locale: ko) == "완충까지 남은 시간")
        #expect(CardPresentation.batteryTimeToFullText(sample85, locale: ko) == "약 25분 남음")

        // English
        let en = Locale(identifier: "en")
        #expect(CardPresentation.batteryRemainingTimeSummary(sample85, locale: en) == "About 25 min to 85%")
        #expect(CardPresentation.batteryRemainingTimeSummary(sample100, locale: en) == "About 1 hr 10 min until full")
        #expect(CardPresentation.batteryRemainingTimeSummary(sampleDischarge, locale: en) == "About 2 hr 20 min remaining")
        #expect(CardPresentation.batteryTimeToFullLabel(targetPercentage: 85, locale: en) == "Time to 85%")
        #expect(CardPresentation.batteryTimeToFullLabel(targetPercentage: 100, locale: en) == "Time to Full")
        #expect(CardPresentation.batteryTimeToFullText(sample85, locale: en) == "About 25 min remaining")

        // Japanese
        let ja = Locale(identifier: "ja")
        #expect(CardPresentation.batteryRemainingTimeSummary(sample85, locale: ja) == "85%まで約25分")
        #expect(CardPresentation.batteryRemainingTimeSummary(sample100, locale: ja) == "フル充電まで約1時間 10分")
        #expect(CardPresentation.batteryRemainingTimeSummary(sampleDischarge, locale: ja) == "残り約2時間 20分")
        #expect(CardPresentation.batteryTimeToFullLabel(targetPercentage: 85, locale: ja) == "85%までの時間")
        #expect(CardPresentation.batteryTimeToFullLabel(targetPercentage: 100, locale: ja) == "フル充電までの時間")
        #expect(CardPresentation.batteryTimeToFullText(sample85, locale: ja) == "残り約25分")

        // German
        let de = Locale(identifier: "de")
        #expect(CardPresentation.batteryRemainingTimeSummary(sample85, locale: de) == "Noch ca. 25 Min. bis 85 %")
        #expect(CardPresentation.batteryRemainingTimeSummary(sample100, locale: de) == "Noch ca. 1 Std. 10 Min. bis voll")
        #expect(CardPresentation.batteryTimeToFullLabel(targetPercentage: 85, locale: de) == "Zeit bis 85 %")
        #expect(CardPresentation.batteryTimeToFullLabel(targetPercentage: 100, locale: de) == "Zeit bis voll")

        // Simplified Chinese
        let zhHans = Locale(identifier: "zh-Hans")
        #expect(CardPresentation.batteryRemainingTimeSummary(sample85, locale: zhHans) == "距离充至 85% 约剩余 25分钟")
        #expect(CardPresentation.batteryRemainingTimeSummary(sample100, locale: zhHans) == "距离充满约剩余 1小时 10分钟")
        #expect(CardPresentation.batteryTimeToFullLabel(targetPercentage: 85, locale: zhHans) == "充至 85% 剩余时间")
        #expect(CardPresentation.batteryTimeToFullLabel(targetPercentage: 100, locale: zhHans) == "充满剩余时间")
    }

    @Test func batteryZeroWattStatusLocalization() {
        let ko = Locale(identifier: "ko")
        let en = Locale(identifier: "en")
        let ja = Locale(identifier: "ja")
        let de = Locale(identifier: "de")
        let zhHans = Locale(identifier: "zh-Hans")

        let fullyCharged = BatterySample(netW: 0.0, milliamps: 0, volts: 12.0, charging: false, externalConnected: true, remainingWh: 60.0, maxWh: 60.0, targetPercentage: 100)
        let limit80 = BatterySample(netW: 0.0, milliamps: 0, volts: 12.0, charging: false, externalConnected: true, remainingWh: 48.0, maxWh: 60.0, targetPercentage: 80)
        let passthrough = BatterySample(netW: 0.0, milliamps: 0, volts: 12.0, charging: false, externalConnected: true, remainingWh: 30.0, maxWh: 60.0, targetPercentage: 100)
        let standby = BatterySample(netW: 0.0, milliamps: 0, volts: 12.0, charging: false, externalConnected: false, remainingWh: 30.0, maxWh: 60.0, targetPercentage: 100)

        // Korean
        #expect(CardPresentation.batteryRemainingTimeSummary(fullyCharged, locale: ko) == "완충됨 (전원 어댑터 사용)")
        #expect(CardPresentation.batteryRemainingTimeSummary(limit80, locale: ko) == "80% 한도 유지 중")
        #expect(CardPresentation.batteryRemainingTimeSummary(passthrough, locale: ko) == "전원 어댑터로 작동 중")
        #expect(CardPresentation.batteryRemainingTimeSummary(standby, locale: ko) == "대기 모드")

        // English
        #expect(CardPresentation.batteryRemainingTimeSummary(fullyCharged, locale: en) == "Fully Charged (On AC Power)")
        #expect(CardPresentation.batteryRemainingTimeSummary(limit80, locale: en) == "Holding at 80% Limit")
        #expect(CardPresentation.batteryRemainingTimeSummary(passthrough, locale: en) == "Powered by Power Adapter")
        #expect(CardPresentation.batteryRemainingTimeSummary(standby, locale: en) == "Standby")

        // Japanese
        #expect(CardPresentation.batteryRemainingTimeSummary(fullyCharged, locale: ja) == "充電完了 (電源アダプタ使用)")
        #expect(CardPresentation.batteryRemainingTimeSummary(limit80, locale: ja) == "80%制限を維持中")
        #expect(CardPresentation.batteryRemainingTimeSummary(passthrough, locale: ja) == "電源アダプタで給電中")
        #expect(CardPresentation.batteryRemainingTimeSummary(standby, locale: ja) == "スタンバイ")

        // German
        #expect(CardPresentation.batteryRemainingTimeSummary(fullyCharged, locale: de) == "Vollständig geladen (Netzbetrieb)")
        #expect(CardPresentation.batteryRemainingTimeSummary(limit80, locale: de) == "80 %-Limit gehalten")
        #expect(CardPresentation.batteryRemainingTimeSummary(passthrough, locale: de) == "Stromversorgung über Netzteil")
        #expect(CardPresentation.batteryRemainingTimeSummary(standby, locale: de) == "Standby-Modus")

        // Chinese Simplified
        #expect(CardPresentation.batteryRemainingTimeSummary(fullyCharged, locale: zhHans) == "已充满 (使用电源适配器)")
        #expect(CardPresentation.batteryRemainingTimeSummary(limit80, locale: zhHans) == "保持在 80% 限制")
        #expect(CardPresentation.batteryRemainingTimeSummary(passthrough, locale: zhHans) == "由电源适配器供电")
        #expect(CardPresentation.batteryRemainingTimeSummary(standby, locale: zhHans) == "待机模式")
    }

    @Test func appShortcutsAndIntentsTranslations() {
        let en = Locale(identifier: "en")
        let ja = Locale(identifier: "ja")

        #expect(String(localized: "배터리 상태 가져오기", locale: en) == "Get Battery Status")
        #expect(String(localized: "배터리 상태 가져오기", locale: ja) == "バッテリー状態を取得")
        #expect(String(localized: "충전 제한 설정 가져오기", locale: en) == "Get Charge Limit Settings")
        #expect(String(localized: "충전 한도 설정", locale: en) == "Set Charge Limit")
        #expect(String(localized: "충전 제한 켜기/끄기", locale: en) == "Toggle Charge Limit")
        #expect(String(localized: "Sailing 모드 설정", locale: en) == "Set Sailing Mode")
        #expect(String(localized: "한 번만 완충 (Top Up)", locale: en) == "Top Up (100% Once)")
        #expect(String(localized: "발열 보호 설정", locale: en) == "Set Heat Protection")

        #expect(String(localized: "한 번만 완충 시작", locale: en) == "Start Top Up")
        #expect(String(localized: "충전 제한 켜기", locale: en) == "Turn On Charge Limit")

        #expect(String(localized: "Wattly 도우미가 설치되지 않았습니다. Wattly 앱 설정에서 도우미를 먼저 설치해주세요.", locale: en)
                == "Wattly helper is not installed. Please install the helper from Wattly settings first.")
        #expect(String(localized: "이 Mac은 배터리 충전 제어를 지원하지 않는 하드웨어입니다.", locale: en)
                == "This Mac hardware does not support battery charge control.")
    }

    @Test func dischargeTranslations() {
        let en = Locale(identifier: "en")
        let ko = Locale(identifier: "ko")

        #expect(String(localized: "수동 방전", locale: en) == "Manual Discharge")
        #expect(String(localized: "수동 방전", locale: ko) == "수동 방전")

        #expect(String(localized: "자동 방전", locale: en) == "Auto Discharge")
        #expect(String(localized: "자동 방전", locale: ko) == "자동 방전")

        #expect(String(localized: "충전 한도를 현재 잔량보다 낮게 변경하면 별도 조작 없이 자동으로 한도까지 방전합니다.", locale: en)
                == "Automatically discharge to the limit when a lower charge limit is set.")
        #expect(String(localized: "원하는 목표 잔량까지 배터리를 전원 어댑터 연결 상태에서 강제로 방전합니다.", locale: en)
                == "Forcefully discharge the battery to your target while connected to power adapter.")

        #expect(String(localized: "목표 방전 잔량", locale: en) == "Target Discharge Level")
        #expect(String(localized: "목표 방전 잔량", locale: ko) == "목표 방전 잔량")

        #expect(String(localized: "%d%%까지 방전 시작", locale: en) == "Start discharge to %d%%")
        #expect(String(localized: "%d%%까지 방전 시작", locale: ko) == "%d%%까지 방전 시작")

        #expect(String(localized: "방전 시작", locale: en) == "Start Discharge")
        #expect(String(localized: "방전 시작", locale: ko) == "방전 시작")

        #expect(String(localized: "방전 중지", locale: en) == "Stop Discharge")
        #expect(String(localized: "방전 중지", locale: ko) == "방전 중지")

        #expect(String(localized: "수동 방전 진행 중 (%d%% → %d%%)", locale: en) == "Discharging in progress (%d%% → %d%%)")
        #expect(String(localized: "수동 방전 진행 중 (%d%% → %d%%)", locale: ko) == "수동 방전 진행 중 (%d%% → %d%%)")

        #expect(String(localized: "목표치(%d%%)까지 방전 중", locale: en) == "Discharging to target (%d%%)")
        #expect(String(localized: "목표치(%d%%)까지 방전 중", locale: ko) == "목표치(%d%%)까지 방전 중")

        #expect(String(localized: "배터리 강제 방전 중 ⚡", locale: en) == "Forced Battery Discharge ⚡")
        #expect(String(localized: "배터리 강제 방전 중 ⚡", locale: ko) == "배터리 강제 방전 중 ⚡")

        #expect(String(localized: "0.0 W (차단됨)", locale: en) == "0.0 W (Blocked)")
        #expect(String(localized: "0.0 W (차단됨)", locale: ko) == "0.0 W (차단됨)")

        #expect(String(localized: "완충 완료 (어댑터 전원 구동)", locale: en) == "Top-Up Complete (Adapter Power)")
        #expect(String(localized: "완충 완료 (어댑터 전원 구동)", locale: ko) == "완충 완료 (어댑터 전원 구동)")

        #expect(String(localized: "한 번만 완충 유지 중 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)", locale: en)
                == "Top Up held at 100% (Holding at 100%, normal limit restores on unplug)")
        #expect(String(localized: "한 번만 완충 유지 중 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)", locale: ko)
                == "한 번만 완충 유지 중 (100% 유지 중, 어댑터 분리 시 원래 한도로 복귀)")
    }
}


