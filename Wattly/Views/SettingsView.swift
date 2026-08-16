import SwiftUI

/// The settings window (issue 13). SwiftUI `Settings` scene, native window chrome.
/// All state is `@AppStorage`, so a change reflects in the popover live and survives restart.
///
/// Sections: 일반 · 표시(테마·레이아웃·표시 지표·카드 펼침 목록·메뉴바) · 동작(백그라운드 갱신·전력 표시 안정화) · 고급(상태 경고 기준·팬 커브) · 되돌리기.
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                generalSection
                displayGroup
                behaviorGroup
                advancedGroup
                resetButton
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

    // MARK: - 일반 (로그인)

    private var generalSection: some View {
        SettingsSection(title: "일반") {
            SettingsCard {
                SettingsToggleRow(isOn: loginBinding, divider: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        SettingsRowTitle("로그인 시 자동 실행")
                        Text("Mac에 로그인하면 Wattly가 메뉴바에서 자동으로 시작됩니다.")
                            .font(WattlyFont.at(11.5, weight: .regular))
                            .foregroundStyle(t.faint)
                    }
                }
            }
        }
    }

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

    // MARK: - 되돌리기

    private var resetButton: some View {
        Button {
            isResetConfirmationPresented = true
        } label: {
            SettingsCard(padding: 11) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .semibold))
                    Text("기본값으로 되돌리기")
                        .font(WattlyFont.at(13, weight: .semibold))
                }
                .foregroundStyle(t.text)
                .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
    }

    private func applyDefaults() {
        SettingsReset.applyDefaults(login: loginItem)
        loginMirror = loginItem.isEnabled
    }
}
