import SwiftUI

/// The settings window (issue 13). SwiftUI `Settings` scene, native window chrome.
/// All state is `@AppStorage`, so a change reflects in the popover live and survives restart.
///
/// Groups: 일반(자동 실행·언어·되돌리기) · 표시(테마·레이아웃·표시 지표·카드 펼침 목록) · 메뉴바(아이콘·텍스트) · 동작(백그라운드 갱신·전력 표시 안정화) · 고급(상태 경고 기준·팬 커브).
struct SettingsView: View {
    @Environment(\.tokens) private var t

    let monitor: SystemMonitor
    let fanControl: FanControlClient
    let batteryControl: BatteryControlClient
    var scheduleCoordinator: BatteryScheduleCoordinator? = nil
    let calibrationCoordinator: BatteryCalibrationCoordinator

    init(
        monitor: SystemMonitor,
        fanControl: FanControlClient,
        batteryControl: BatteryControlClient,
        scheduleCoordinator: BatteryScheduleCoordinator? = nil,
        calibrationCoordinator: BatteryCalibrationCoordinator
    ) {
        self.monitor = monitor
        self.fanControl = fanControl
        self.batteryControl = batteryControl
        self.scheduleCoordinator = scheduleCoordinator
        self.calibrationCoordinator = calibrationCoordinator
    }

    @AppStorage(StorageKey.theme) private var theme = Defaults.theme
    @AppStorage(StorageKey.appLanguage) private var selectedLanguage = Defaults.appLanguage
    @AppStorage(StorageKey.loginItem) private var loginMirror = Defaults.loginItem
    private let loginItem: LoginItemControlling = LoginItem()

    @State private var updateChecker = UpdateChecker()
    @State private var autoUpdater = AutoUpdater()
    @State private var isResetConfirmationPresented = false
    @State private var isUninstallConfirmationPresented = false
    @State private var uninstallErrorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                generalGroup
                displayGroup
                menuBarGroup
                behaviorGroup
                advancedGroup
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 480, height: 560)
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
        .alert("Wattly 및 모든 데이터를 완전히 삭제할까요?",
               isPresented: $isUninstallConfirmationPresented) {
            Button("완전 삭제 및 앱 종료", role: .destructive) {
                Task {
                    do {
                        try await AppUninstaller.uninstall(
                            stopCalibration: { await calibrationCoordinator.cancel() })
                    } catch {
                        uninstallErrorMessage = error.localizedDescription
                    }
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("모든 설정값, 캐시, 백그라운드 팬 제어 도우미 및 앱이 시스템에서 완전히 제거되고 앱이 종료됩니다.")
        }
        .alert("Wattly 삭제 중단", isPresented: Binding(
            get: { uninstallErrorMessage != nil },
            set: { if !$0 { uninstallErrorMessage = nil } }
        )) {
            Button("확인", role: .cancel) { uninstallErrorMessage = nil }
        } message: {
            Text(uninstallErrorMessage ?? "")
        }
    }

    // MARK: - 일반 그룹 (로그인 · 언어 · 되돌리기)

    private var generalGroup: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroupHeader(title: "일반")
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

                // 소프트웨어 업데이트
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        SettingsRowTitle("소프트웨어 업데이트")
                        HStack(spacing: 6) {
                            Text("현재 버전 v\(updateChecker.currentVersion)")
                                .font(WattlyFont.at(11.5, weight: .regular))
                                .foregroundStyle(t.faint)

                            switch autoUpdater.state {
                            case .downloading(let fraction):
                                WattlyProgressBar(value: fraction)
                                Text("\(Int(WattlyProgressBar.clampedFraction(fraction) * 100))%")
                                    .font(WattlyFont.at(11, weight: .medium))
                                    .foregroundStyle(t.text)
                            case .extracting, .readyToRelaunch:
                                ProgressView()
                                    .scaleEffect(0.5)
                                    .frame(width: 10, height: 10)
                                Text("설치 준비 중...")
                                    .font(WattlyFont.at(11, weight: .medium))
                                    .foregroundStyle(t.faint)
                            case .failed(let reason):
                                Text("• \(reason)")
                                    .font(WattlyFont.at(11, weight: .regular))
                                    .foregroundStyle(.red)
                            case .idle:
                                switch updateChecker.status {
                                case .checking:
                                    ProgressView()
                                        .scaleEffect(0.5)
                                        .frame(width: 10, height: 10)
                                case .upToDate:
                                    Text("• 최신 버전입니다")
                                        .font(WattlyFont.at(11.5, weight: .medium))
                                        .foregroundStyle(.green)
                                case .available(let release):
                                    Text("• v\(release.version) 사용 가능")
                                        .font(WattlyFont.at(11.5, weight: .medium))
                                        .foregroundStyle(Tokens.accent)
                                case .failed(let reason):
                                    Text("• \(reason)")
                                        .font(WattlyFont.at(11, weight: .regular))
                                        .foregroundStyle(.red)
                                case .idle:
                                    EmptyView()
                                }
                            }
                        }
                    }

                    Spacer(minLength: 8)

                    updateActionButton
                }
                .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))

                Rectangle().fill(t.line).frame(height: 1)

                // 개발자에게 문의하기
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        SettingsRowTitle("개발자에게 문의하기")
                        Text("버그 제보나 기능 제안 등 피드백을 보냅니다.")
                            .font(WattlyFont.at(11.5, weight: .regular))
                            .foregroundStyle(t.faint)
                    }

                    Spacer(minLength: 8)

                    Button {
                        ContactDeveloperHelper.openContactEmailInBrowser()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "envelope")
                                .font(.system(size: 11, weight: .medium))
                            Text("문의하기")
                                .font(WattlyFont.at(12, weight: .medium))
                                .foregroundStyle(t.text)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rowBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
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

                Rectangle().fill(t.line).frame(height: 1)

                Button {
                    isUninstallConfirmationPresented = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Wattly 완전 삭제...")
                            .font(WattlyFont.at(12.5, weight: .semibold))
                    }
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var updateActionButton: some View {
        if case .available(let release) = updateChecker.status, case .idle = autoUpdater.state {
            if let asset = release.zipAsset {
                Button {
                    autoUpdater.startUpdate(asset: asset)
                } label: {
                    Text("지금 업데이트")
                        .font(WattlyFont.at(12, weight: .medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Tokens.accent)
                        )
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    NSWorkspace.shared.open(release.htmlURL)
                } label: {
                    Text("릴리즈 열기")
                        .font(WattlyFont.at(12, weight: .medium))
                        .foregroundStyle(t.text)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rowBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        } else {
            Button {
                Task {
                    await updateChecker.checkForUpdates()
                }
            } label: {
                HStack(spacing: 5) {
                    Text(updateChecker.status == .checking ? LocalizedStringKey("확인 중...") : LocalizedStringKey("업데이트 확인"))
                        .font(WattlyFont.at(12, weight: .medium))
                        .foregroundStyle(t.text)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rowBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(updateChecker.status == .checking || autoUpdater.state != .idle)
        }
    }

    private var languageMenu: some View {
        Menu {
            ForEach(AppLanguage.supportedLanguages) { lang in
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
                Text(AppLanguage.displayName(for: selectedLanguage))
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
        }
    }

    // MARK: - 메뉴바 그룹

    private var menuBarGroup: some View {
        SettingsMenuBarSection(monitor: monitor)
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
            SettingsThresholdSection(showsFan: monitor.isPresent(.fan))
            if monitor.isPresent(.fan) {
                SettingsFanCurveSection(monitor: monitor, fanControl: fanControl)
            }
            if monitor.isPresent(.battery) {
                SettingsBatterySection(batteryControl: batteryControl, scheduleCoordinator: scheduleCoordinator)
            }
        }
    }

    private func applyDefaults() {
        Task {
            await SettingsReset.resetEverything(
                login: loginItem,
                maxFanRPM: monitor.hardwareMaxFanRPM,
                stoppingCalibration: { await calibrationCoordinator.cancel() })
            loginMirror = loginItem.isEnabled
        }
    }
}
