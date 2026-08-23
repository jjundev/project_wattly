import SwiftUI
import AppKit

/// Battery charge limit settings section: Toggle, limit percentage selector (80%, 85%, 90%, 95%),
/// live status indicator, and helper installation trigger.
struct SettingsBatterySection: View {
    @Environment(\.tokens) private var t
    @Environment(\.locale) private var locale
    let batteryControl: BatteryControlClient

    @AppStorage(StorageKey.batteryLimitEnabled) private var batteryLimitEnabled = Defaults.batteryLimitEnabled
    @AppStorage(StorageKey.batteryLimitPercentage) private var batteryLimitPercentage = Defaults.batteryLimitPercentage
    @State private var isInstallFailedAlertPresented = false
    @State private var installErrorMessage = ""

    private let presetLimits = [80, 85, 90, 95]

    var body: some View {
        SettingsSection(title: "배터리 충전 제어") {
            SettingsCard {
                // Rendering never writes the stored value: flipping it off here would look like the
                // app undoing the user's choice, and it would be wrong the moment the same
                // preferences reach a Mac that does support the limit. The one exception is the
                // opt-in the user just made in this session, which the toggle handler clears once
                // the helper answers that this Mac has no register — otherwise the row would
                // disable itself in the ON position with nothing left to switch it back.
                SettingsToggleRow(isOn: $batteryLimitEnabled,
                                  divider: true,
                                  isEnabled: !isHardwareUnsupported,
                                  disabledReason: isHardwareUnsupported ? "이 Mac은 충전 제어를 지원하지 않습니다" : nil) {
                    VStack(alignment: .leading, spacing: 2) {
                        SettingsRowTitle("배터리 충전 제한")
                        Text(isHardwareUnsupported
                             ? "이 Mac은 충전 제어를 지원하지 않습니다. 이 기능이 사용하는 SMC 레지스터가 없습니다."
                             : "설정한 한도에 도달하면 충전을 멈추고 전원 어댑터로만 작동하여 배터리 수명을 보호합니다.")
                            .font(WattlyFont.at(10.5, weight: .regular))
                            .foregroundStyle(t.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    if showsConfigurationControls {
                        // 헤더와 세그먼트는 같은 컨트롤로 읽히므로 같은 값(0.5)으로 함께 흐려진다.
                        // 세그먼트 자신의 불투명도는 `isEnabled`가 처리하므로 여기서 또 곱하면
                        // 0.25가 되어 너무 어두워진다 — 그래서 딤은 헤더에만 건다.
                        HStack {
                            Text("최대 충전 한도")
                                .font(WattlyFont.at(12, weight: .medium))
                                .foregroundStyle(t.text)
                            Spacer()
                            Text("\(batteryLimitPercentage)%")
                                .font(WattlyFont.at(12, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(t.text)
                        }
                        .opacity(isLimitPickerEnabled ? 1 : 0.5)

                        WattlySegment(
                            selection: $batteryLimitPercentage,
                            options: presetLimits.map { ($0, "\($0)%") },
                            pillVPadding: 6,
                            isEnabled: isLimitPickerEnabled,
                            disabledReason: BatterySectionPresentation
                                .limitPickerDisabledReason(isLimitOn: batteryLimitEnabled)
                        )
                    }

                    // Always visible: unsupported hardware must explain itself with the same
                    // icon-and-text status interface instead of making the entire status row vanish.
                    batteryStatusIndicator

                    if showsConfigurationControls {
                        advisoryBanner
                    }
                }
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
            }
            .task(id: batteryLimitEnabled) {
                // One read regardless of the opt-in: a Mac with no charge register has to disable
                // its toggle before the user ever reaches for it. This is also the read that
                // decides whether the configuration controls remain visible.
                await batteryControl.refreshStatus()
                // Re-checked every iteration, not just once up front: the gate depends on the mode
                // the daemon just reported, and that mode can change out from under us — e.g. the
                // daemon recovers from `.inhibited`/`.unsupported` back to `.charging` once the user
                // reconnects the adapter. Re-evaluating here is what lets polling stop on its own
                // once the state settles, instead of running forever or freezing on a failure.
                while !Task.isCancelled,
                      BatterySectionPresentation.shouldPollStatus(isLimitOn: batteryLimitEnabled,
                                                                   mode: batteryControl.status.mode) {
                    try? await Task.sleep(for: .seconds(BatteryControlPolicy.statusPollInterval))
                    guard !Task.isCancelled else { return }
                    await batteryControl.refreshStatus()
                }
            }
            // Turning the opt-in on installs the helper if it is missing (one macOS admin-auth
            // prompt) and pushes the limit either way, so the helper never sits at its disabled
            // default while this toggle reads ON. If the user cancels the prompt, revert the toggle
            // so it reflects reality.
            .onChange(of: batteryLimitEnabled) { _, isEnabled in
                guard isEnabled, !batteryControl.isInstallingHelper else { return }
                let window = NSApp.keyWindow
                let limit = batteryLimitPercentage
                Task {
                    let mode = await batteryControl.refreshStatus()?.mode ?? .unavailable
                    if BatteryControlPolicy.shouldRunInstaller(mode: mode) {
                        if let failure = await batteryControl.installAndApply(enabled: true, limitPercentage: limit, window: window) {
                            installErrorMessage = Self.message(for: failure, locale: locale)
                            isInstallFailedAlertPresented = true
                            batteryLimitEnabled = false
                        }
                    } else {
                        // The helper already answers — reuse it, no second admin prompt.
                        await batteryControl.apply(enabled: true, limitPercentage: limit)
                    }
                    // The helper has now answered. If it says this Mac has no charge register, undo
                    // the opt-in the user just made — otherwise the row disables itself in the ON
                    // position with nothing left to switch it back. This clears only a value set in
                    // this session and just proven impossible; a `true` carried in from a supported
                    // Mac is never touched, because that path never reaches this handler.
                    if batteryControl.status.isHardwareSupported == false {
                        batteryLimitEnabled = false
                    }
                }
            }
        }
        .alert("도우미 설치 실패", isPresented: $isInstallFailedAlertPresented) {
            Button("확인", role: .cancel) {}
        } message: {
            // 이미 `Self.message(for:locale:)`로 해석된 문자열이다. `LocalizedStringKey`로
            // 감싸면 두 번 조회하게 되고, 보간된 문장은 키가 없어 그대로 통과할 뿐이다.
            Text(verbatim: installErrorMessage)
        }
    }

    private var batteryStatusIndicator: some View {
        let resolved = resolvedStatus
        return HStack(spacing: 8) {
            Image(systemName: resolved.indicator.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(statusColor(for: resolved.indicator.tone))
                // The localized status text carries the meaning; hiding the decorative symbol
                // prevents VoiceOver from reading an English SF Symbol name before it.
                .accessibilityHidden(true)
            Text(verbatim: resolved.text)
                .font(WattlyFont.at(11, weight: .regular))
                .foregroundStyle(t.sub)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if BatterySectionPresentation.isInstallButtonVisible(isLimitOn: batteryLimitEnabled,
                                                                 mode: batteryControl.status.mode) {
                Button {
                    let window = NSApp.keyWindow
                    let limit = batteryLimitPercentage
                    Task {
                        if let failure = await batteryControl.installAndApply(enabled: batteryLimitEnabled, limitPercentage: limit, window: window) {
                            installErrorMessage = Self.message(for: failure, locale: locale)
                            isInstallFailedAlertPresented = true
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if batteryControl.isInstallingHelper {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 10, height: 10)
                        }
                        Text("도우미 설치")
                            .font(WattlyFont.at(11.5, weight: .medium))
                            .foregroundStyle(t.text)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rowBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(batteryControl.isInstallingHelper)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var advisoryBanner: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.statusOrange)
            Text("원활한 동작을 위해 시스템 설정 > 배터리의 '최적화된 배터리 충전'을 꺼두는 것을 권장합니다.")
                .font(WattlyFont.at(10.5, weight: .regular))
                .foregroundStyle(t.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isHardwareUnsupported: Bool {
        batteryControl.status.isHardwareSupported == false
    }

    private var showsConfigurationControls: Bool {
        BatterySectionPresentation.showsConfigurationControls(
            isHardwareSupported: batteryControl.status.isHardwareSupported)
    }

    private var isLimitPickerEnabled: Bool {
        BatterySectionPresentation.isLimitPickerEnabled(isLimitOn: batteryLimitEnabled)
    }

    private var resolvedStatus: BatterySectionPresentation.Status {
        BatterySectionPresentation.status(
            isLimitOn: batteryLimitEnabled,
            isInstalling: batteryControl.isInstallingHelper,
            mode: batteryControl.status.mode,
            reason: batteryControl.status.detailReason,
            detail: batteryControl.status.detail,
            locale: locale,
            activity: batteryControl.status.activity,
            updatedAt: batteryControl.status.updatedAt,
            now: Date().timeIntervalSince1970)
    }

    /// 설치 실패 문구. `.install`은 설치기 자신의 오류(카탈로그 키이거나 macOS가 이미 현지화한
    /// 문장)이고, `.configureRejected`는 도우미 상태를 문장 안에 끼워 넣어야 한다.
    private static func message(for failure: BatteryControlClient.InstallFailure,
                                locale: Locale) -> String {
        switch failure {
        case .install(let error):
            return String(localized: error.localizedDescription, locale: locale)
        case .configureRejected(let reason, let detail):
            return BatteryStatusText.installFailureMessage(reason: reason, detail: detail,
                                                           locale: locale)
        }
    }

    /// 의미 → 색. 색을 순수 타입에 넣지 않는 이유는 `t.faint`가 테마 토큰이라
    /// `@Environment`에서만 읽히기 때문이다.
    private func statusColor(for tone: BatterySectionPresentation.Tone) -> Color {
        switch tone {
        case .green: return Tokens.statusGreen
        case .orange: return Tokens.statusOrange
        case .red: return Tokens.statusRed
        case .faint: return t.faint
        }
    }
}
