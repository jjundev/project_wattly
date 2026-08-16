import SwiftUI

/// The settings window (issue 13). SwiftUI `Settings` scene, native window chrome.
/// All state is `@AppStorage`, so a change reflects in the popover live and survives restart.
///
/// Sections: 일반(자동 실행·언어·되돌리기) · 표시(테마·레이아웃·표시 지표·카드 펼침 목록·메뉴바) · 동작(백그라운드 갱신·전력 표시 안정화) · 고급(상태 경고 기준·팬 커브).
struct SettingsView: View {
    @Environment(\.tokens) private var t

    let monitor: SystemMonitor
    let fanControl: FanControlClient

    init(monitor: SystemMonitor, fanControl: FanControlClient) {
        self.monitor = monitor
        self.fanControl = fanControl
    }

    @AppStorage(StorageKey.theme) private var theme = Defaults.theme
    @AppStorage(StorageKey.loginItem) private var loginMirror = Defaults.loginItem
    private let loginItem: LoginItemControlling = LoginItem()

    @State private var isResetConfirmationPresented = false
    @State private var selectedLanguage: String = "ko"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                generalSection
                displayGroup
                behaviorGroup
                advancedGroup
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 440, height: 560)
        .background(t.settingsBg)
        .background(WindowAppearanceSync(mode: theme))
        .task {
            loginMirror = loginItem.isEnabled
        }
        .alert("모든 Wattly 설정을 기본값으로 되돌릴까요?",
               isPresented: $isResetConfirmationPresented) {
            Button("기본값으로 되돌리기", role: .destructive) { applyDefaults() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("카드 표시, 메뉴바, 경고 기준, 팬 커브 및 자동 실행 설정이 초기화됩니다.")
        }
    }

    // MARK: - 일반 (로그인 · 언어 · 되돌리기)

    private var generalSection: some View {
        SettingsSection(title: "일반") {
            SettingsCard {
                SettingsToggleRow(isOn: loginBinding, divider: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        SettingsRowTitle("로그인 시 자동 실행")
                        Text("Mac에 로그인하면 Wattly가 메뉴바에서 자동으로 시작됩니다.")
                            .font(WattlyFont.at(11.5, weight: .regular))
                            .foregroundStyle(t.faint)
                    }
                }

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        SettingsRowTitle("언어")
                        Text("앱의 표시 언어를 선택합니다.")
                            .font(WattlyFont.at(11.5, weight: .regular))
                            .foregroundStyle(t.faint)
                    }
                    Spacer(minLength: 8)
                    languageMenu
                }
                .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))

                Rectangle().fill(t.line).frame(height: 1)

                Button {
                    isResetConfirmationPresented = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 12, weight: .semibold))
                        Text("기본값으로 되돌리기")
                            .font(WattlyFont.at(12.5, weight: .semibold))
                    }
                    .foregroundStyle(t.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var languageMenu: some View {
        Menu {
            ForEach(Self.supportedLanguages) { lang in
                Button {
                    selectedLanguage = lang.id
                } label: {
                    if selectedLanguage == lang.id {
                        Label(lang.displayName, systemImage: "checkmark")
                    } else {
                        Text(lang.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentLanguageDisplayName)
                    .font(WattlyFont.at(12, weight: .medium))
                    .foregroundStyle(t.text)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(t.faint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(t.segTrack)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(t.rowBorder, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var currentLanguageDisplayName: String {
        Self.supportedLanguages.first(where: { $0.id == selectedLanguage })?.displayName ?? "한국어"
    }

    private struct LanguageOption: Identifiable {
        let id: String
        let displayName: String
    }

    private static let supportedLanguages: [LanguageOption] = [
        LanguageOption(id: "system", displayName: "시스템"),
        LanguageOption(id: "ko", displayName: "한국어"),
        LanguageOption(id: "en", displayName: "English"),
        LanguageOption(id: "ja", displayName: "日本語"),
        LanguageOption(id: "zh-Hans", displayName: "简体中文"),
        LanguageOption(id: "zh-Hant", displayName: "繁體中文"),
        LanguageOption(id: "de", displayName: "Deutsch"),
        LanguageOption(id: "fr", displayName: "Français"),
        LanguageOption(id: "es", displayName: "Español"),
        LanguageOption(id: "it", displayName: "Italiano"),
        LanguageOption(id: "pt-BR", displayName: "Português (Brasil)"),
        LanguageOption(id: "pt-PT", displayName: "Português (Portugal)"),
        LanguageOption(id: "ru", displayName: "Русский"),
        LanguageOption(id: "pl", displayName: "Polski"),
        LanguageOption(id: "nl", displayName: "Nederlands"),
        LanguageOption(id: "sv", displayName: "Svenska"),
        LanguageOption(id: "tr", displayName: "Türkçe"),
        LanguageOption(id: "ar", displayName: "العربية"),
        LanguageOption(id: "th", displayName: "ไทย"),
        LanguageOption(id: "vi", displayName: "Tiếng Việt"),
        LanguageOption(id: "id", displayName: "Bahasa Indonesia"),
        LanguageOption(id: "hi", displayName: "हिन्दी"),
        LanguageOption(id: "uk", displayName: "Українська"),
        LanguageOption(id: "cs", displayName: "Čeština"),
        LanguageOption(id: "da", displayName: "Dansk"),
        LanguageOption(id: "fi", displayName: "Suomi"),
        LanguageOption(id: "nb", displayName: "Norsk Bokmål"),
        LanguageOption(id: "el", displayName: "Ελληνικά"),
        LanguageOption(id: "he", displayName: "עברית"),
        LanguageOption(id: "ro", displayName: "Română"),
        LanguageOption(id: "hu", displayName: "Magyar"),
    ]

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { loginMirror },
            set: { want in
                do {
                    try loginItem.setEnabled(want)
                    loginMirror = want
                } catch {
                    loginMirror = loginItem.isEnabled
                }
            }
        )
    }

    // MARK: - 표시 그룹

    private var displayGroup: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroupHeader(title: "표시")
            SettingsDisplaySection(monitor: monitor)
            SettingsMenuBarSection(monitor: monitor)
        }
    }

    // MARK: - 동작 그룹

    private var behaviorGroup: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroupHeader(title: "동작")
            SettingsBehaviorSection()
        }
    }

    // MARK: - 고급 그룹

    private var advancedGroup: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroupHeader(title: "고급")
            SettingsThresholdSection()
            if monitor.isPresent(.fan) {
                SettingsFanCurveSection(monitor: monitor, fanControl: fanControl)
            }
        }
    }

    private func applyDefaults() {
        SettingsReset.applyDefaults(login: loginItem)
        loginMirror = loginItem.isEnabled
    }
}
