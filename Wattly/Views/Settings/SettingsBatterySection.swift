import SwiftUI
import AppKit

/// Battery charge limit settings section: Toggle, limit percentage selector (80%, 85%, 90%, 95%),
/// live status indicator, and helper installation trigger.
struct SettingsBatterySection: View {
    @Environment(\.tokens) private var t
    let batteryControl: BatteryControlClient

    @AppStorage(StorageKey.batteryLimitEnabled) private var batteryLimitEnabled = Defaults.batteryLimitEnabled
    @AppStorage(StorageKey.batteryLimitPercentage) private var batteryLimitPercentage = Defaults.batteryLimitPercentage
    @State private var isInstallFailedAlertPresented = false
    @State private var installErrorMessage = ""

    private let presetLimits = [80, 85, 90, 95]

    var body: some View {
        SettingsSection(title: "배터리 충전 제어") {
            SettingsCard {
                // Leave the stored value alone. Flipping it off would look like the app undoing the
                // user's choice, and it would be wrong the moment the same preferences reach a Mac
                // that does support the limit.
                SettingsToggleRow(isOn: $batteryLimitEnabled,
                                  divider: batteryLimitEnabled && !isHardwareUnsupported,
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

                if batteryLimitEnabled && !isHardwareUnsupported {
                    VStack(alignment: .leading, spacing: 12) {
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

                        WattlySegment(
                            selection: $batteryLimitPercentage,
                            options: presetLimits.map { ($0, "\($0)%") },
                            pillVPadding: 6
                        )

                        batteryStatusIndicator

                        advisoryBanner
                    }
                    .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
                }
            }
            .task(id: batteryLimitEnabled) {
                // One read regardless of the opt-in: a Mac with no charge register has to disable
                // its toggle before the user ever reaches for it.
                await batteryControl.refreshStatus()
                guard batteryLimitEnabled else { return }
                while !Task.isCancelled {
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
                            installErrorMessage = failure.localizedDescription
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
            Text(installErrorMessage)
        }
    }

    private var batteryStatusIndicator: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(WattlyFont.at(11, weight: .regular))
                .foregroundStyle(t.sub)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if batteryControl.status.mode == .unavailable {
                Button {
                    let window = NSApp.keyWindow
                    let limit = batteryLimitPercentage
                    Task {
                        if let failure = await batteryControl.installAndApply(enabled: batteryLimitEnabled, limitPercentage: limit, window: window) {
                            installErrorMessage = failure.localizedDescription
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

    /// Only an explicit `false` disables the control. `nil` means the helper has not answered yet —
    /// or is too old to say — and a Mac must never be declared incapable on a missing answer.
    private var isHardwareUnsupported: Bool {
        batteryControl.status.isHardwareSupported == false
    }

    private var statusDotColor: Color {
        if batteryControl.isInstallingHelper {
            return Tokens.statusOrange
        }
        switch batteryControl.status.mode {
        case .inhibited:
            return Tokens.statusOrange
        case .charging:
            return Tokens.statusGreen
        case .unavailable:
            return Tokens.statusRed
        case .unsupported:
            return t.faint
        }
    }

    private var statusText: String {
        if batteryControl.isInstallingHelper {
            return "도우미 설치 중…"
        }
        return batteryControl.status.detail
    }
}
