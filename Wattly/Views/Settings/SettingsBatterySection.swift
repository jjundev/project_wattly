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
    @State private var isHelpPopoverPresented = false

    private let presetLimits = [80, 85, 90, 95]

    var body: some View {
        SettingsSection(title: "배터리 충전 제어") {
            SettingsCard {
                // Rendering never writes the stored value: flipping it off here would look like the
                // app undoing the user's choice, and it would be wrong the moment the same
                // preferences reach a Mac that does support the limit. Two things keep that from
                // stranding anyone. The toggle handler clears the opt-in the user just made once
                // the helper answers that this Mac has no register; and `isToggleEnabled` leaves
                // the row switchable while it reads ON, so a `true` that arrived some other way —
                // a firmware update that took the register away under a working Mac — can still be
                // switched off by hand. Turning it back on stays impossible, so the exit is
                // one-way.
                SettingsToggleRow(isOn: $batteryLimitEnabled,
                                  divider: areDetailsVisible,
                                  isEnabled: isToggleEnabled,
                                  disabledReason: isToggleEnabled ? nil : "이 Mac은 충전 제어를 지원하지 않습니다") {
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

                if areDetailsVisible {
                    VStack(alignment: .leading, spacing: 12) {
                        // 헤더와 세그먼트는 같은 컨트롤로 읽히므로 같은 값(0.5)으로 함께 흐려진다.
                        // 세그먼트 자신의 불투명도는 `isEnabled`가 처리하므로 여기서 또 곱하면
                        // 0.25가 되어 너무 어두워진다 — 그래서 딤은 헤더에만 건다.
                        HStack {
                            Text("최대 충전 한도")
                                .font(WattlyFont.at(12, weight: .medium))
                                .foregroundStyle(t.text)
                            Spacer()
                            Button {
                                isHelpPopoverPresented = true
                            } label: {
                                Image(systemName: "exclamationmark.circle")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(t.faint)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("배터리 충전 최적화 안내 보기")
                            .popover(isPresented: $isHelpPopoverPresented, arrowEdge: .bottom) {
                                batteryHelpPopover
                            }
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

                        batteryStatusIndicator
                    }
                    .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
                }
            }
            .task(id: batteryLimitEnabled) {
                // One read regardless of the opt-in: a Mac with no charge register has to disable
                // its toggle before the user ever reaches for it. This is also the read that
                // decides `areDetailsVisible`.
                await batteryControl.refreshStatus()
                // Re-checked every iteration, not just once up front: the gate depends on the mode
                // the daemon just reported, and that mode can change out from under us — e.g. the
                // daemon recovers from `.inhibited`/`.unsupported` back to `.charging` once the user
                // reconnects the adapter. Re-evaluating here is what lets polling stop on its own
                // once the state settles, instead of running forever or freezing on a failure.
                while !Task.isCancelled,
                      BatterySectionPresentation.shouldPollStatus(isLimitOn: batteryLimitEnabled,
                                                                   mode: batteryControl.status.mode,
                                                                   isHardwareSupported: batteryControl.status.isHardwareSupported) {
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
            Circle()
                .fill(dotColor(for: resolved.dot))
                .frame(width: 7, height: 7)
            // `BatterySectionPresentation.status(…)`가 로케일까지 반영해 만든 최종 문자열이다.
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

    private var batteryHelpPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("배터리 충전 최적화 안내")
                .font(WattlyFont.at(13, weight: .semibold))
                .foregroundStyle(t.text)
            Text("Wattly의 충전 제한 기능이 원활하게 작동하려면 macOS 시스템 설정의 '최적화된 배터리 충전'을 꺼두는 것을 권장합니다.")
                .font(WattlyFont.at(11, weight: .regular))
                .foregroundStyle(t.sub)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 5) {
                Text("1. 아래 버튼으로 시스템 설정 > 배터리 이동")
                Text("2. '충전' 항목 우측의 ⓘ (정보) 버튼 클릭")
                Text("3. '최적화된 배터리 충전' 끄기")
            }
            .font(WattlyFont.at(10.5, weight: .regular))
            .foregroundStyle(t.faint)
            .fixedSize(horizontal: false, vertical: true)
            Button {
                isHelpPopoverPresented = false
                openSystemBatterySettings()
            } label: {
                HStack(spacing: 5) {
                    Text("시스템 배터리 설정 열기")
                        .font(WattlyFont.at(11.5, weight: .medium))
                        .foregroundStyle(t.text)
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10))
                        .foregroundStyle(t.faint)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rowBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 270, alignment: .leading)
        .background(t.cardBg)
    }

    private func openSystemBatterySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension"),
           NSWorkspace.shared.open(url) {
            return
        }
        if let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
            NSWorkspace.shared.open(fallback)
        }
    }

    /// Only an explicit `false` disables the control. `nil` means the helper has not answered yet —
    /// or is too old to say — and a Mac must never be declared incapable on a missing answer.
    /// Derived from `areDetailsVisible` rather than `isHardwareSupported` directly, so the `nil`
    /// policy has exactly one place to change.
    private var isHardwareUnsupported: Bool { !areDetailsVisible }

    /// 토글이 조작 가능한지. `isHardwareUnsupported`의 단순한 반대가 아니다 — 이미 켜져 있는 값을
    /// 끌 수 있게 남겨두는 예외가 붙는다. 판단은 `BatterySectionPresentation`이 갖는다.
    private var isToggleEnabled: Bool {
        BatterySectionPresentation.isToggleEnabled(
            isHardwareSupported: batteryControl.status.isHardwareSupported,
            isLimitOn: batteryLimitEnabled)
    }

    /// 하위 항목(한도 선택기 · 상태 줄)을 그릴지. 토글의 ON/OFF와는 무관하다 —
    /// 꺼져 있어도 이 기능이 무엇을 하는지는 보여야 한다. 숨기는 경우는 이 Mac에 충전 제어
    /// 레지스터가 아예 없다고 도우미가 명시적으로 답했을 때뿐이다.
    private var areDetailsVisible: Bool {
        BatterySectionPresentation.areDetailsVisible(
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
            locale: locale)
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
    private func dotColor(for dot: BatterySectionPresentation.Dot) -> Color {
        switch dot {
        case .green: return Tokens.statusGreen
        case .orange: return Tokens.statusOrange
        case .red: return Tokens.statusRed
        case .faint: return t.faint
        }
    }
}
