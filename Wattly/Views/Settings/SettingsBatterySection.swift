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
    @AppStorage(StorageKey.batterySailingEnabled) private var batterySailingEnabled = Defaults.batterySailingEnabled
    @AppStorage(StorageKey.batterySailingDelta) private var batterySailingDelta = Defaults.batterySailingDelta
    @AppStorage(StorageKey.batteryHeatProtectionEnabled) private var batteryHeatProtectionEnabled = Defaults.batteryHeatProtectionEnabled
    @AppStorage(StorageKey.batteryHeatProtectionThreshold) private var batteryHeatProtectionThreshold = Defaults.batteryHeatProtectionThreshold
    @State private var isInstallFailedAlertPresented = false
    @State private var installErrorMessage = ""
    @State private var isHelpPopoverPresented = false
    @State private var isMaintenanceHelpPopoverPresented = false
    @State private var installedOwnership = FanHelperInstaller.InstalledOwnership.notInstalled
    @State private var isOwnershipTransferConfirmationPresented = false

    private let presetLimits = [80, 85, 90, 95]
    private let sailingPresets = BatterySectionPresentation.sailingDeltaPresets

    private var effectiveDelta: Int {
        batterySailingEnabled ? batterySailingDelta : 2
    }

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
                                  divider: false,
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

                VStack(alignment: .leading, spacing: 10) {
                    if showsConfigurationControls {
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
                    }

                    // Always visible: unsupported hardware must explain itself with the same
                    // icon-and-text status interface instead of making the entire status row vanish.
                    batteryStatusIndicator

                }
                .padding(EdgeInsets(top: 0, leading: 14, bottom: 14, trailing: 14))

                if showsConfigurationControls {
                    Rectangle().fill(t.line).frame(height: 1)

                    SettingsToggleRow(isOn: $batterySailingEnabled,
                                      divider: false,
                                      isEnabled: isLimitPickerEnabled,
                                      disabledReason: BatterySectionPresentation
                                          .limitPickerDisabledReason(isLimitOn: batteryLimitEnabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            SettingsRowTitle("Sailing 모드")
                            Text("충전 상한에 도달한 후 배터리가 하한까지 자연 방전될 때까지 충전을 재개하지 않습니다.")
                                .font(WattlyFont.at(10.5, weight: .regular))
                                .foregroundStyle(t.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if batterySailingEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Sailing 범위")
                                    .font(WattlyFont.at(12, weight: .medium))
                                    .foregroundStyle(t.text)
                                Spacer()
                                Text(BatterySectionPresentation.sailingRangeDescription(
                                    limit: batteryLimitPercentage,
                                    delta: batterySailingDelta,
                                    locale: locale))
                                    .font(WattlyFont.at(10.5, weight: .medium))
                                    .foregroundStyle(t.sub)
                            }
                            .opacity(isLimitPickerEnabled ? 1 : 0.5)

                            WattlySegment(
                                selection: $batterySailingDelta,
                                options: sailingPresets.map { ($0, "\($0)%") },
                                pillVPadding: 6,
                                isEnabled: isLimitPickerEnabled,
                                disabledReason: BatterySectionPresentation
                                    .limitPickerDisabledReason(isLimitOn: batteryLimitEnabled)
                            )
                        }
                        .padding(EdgeInsets(top: 0, leading: 14, bottom: 14, trailing: 14))
                    }

                    Rectangle().fill(t.line).frame(height: 1)

                    SettingsToggleRow(isOn: $batteryHeatProtectionEnabled,
                                      divider: false,
                                      isEnabled: isToggleEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            SettingsRowTitle("발열 보호 (Heat Protection)")
                            Text("배터리 온도가 설정값을 초과하면 충전을 일시 중단하여 배터리 수명을 보호합니다.")
                                .font(WattlyFont.at(10.5, weight: .regular))
                                .foregroundStyle(t.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if batteryHeatProtectionEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("보호 시작 온도")
                                    .font(WattlyFont.at(12, weight: .medium))
                                    .foregroundStyle(t.text)
                                Spacer()
                                Text(String(format: String(localized: "%lld°C 초과 시 정지, %lld°C 이하 시 재개", locale: locale),
                                            locale: locale, Int64(batteryHeatProtectionThreshold), Int64(batteryHeatProtectionThreshold - 2)))
                                    .font(WattlyFont.at(10.5, weight: .medium))
                                    .foregroundStyle(t.sub)
                            }

                            WattlySegment(
                                selection: $batteryHeatProtectionThreshold,
                                options: BatterySectionPresentation.heatProtectionThresholdPresets.map { ($0, "\($0)°C") },
                                pillVPadding: 6,
                                isEnabled: true
                            )
                        }
                        .padding(EdgeInsets(top: 0, leading: 14, bottom: 14, trailing: 14))
                    }

                    Rectangle().fill(t.line).frame(height: 1)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            SettingsRowTitle("한 번만 완충")
                            Text(LocalizedStringKey("다음 외출이나 출장을 위해 배터리를 일회성으로 100%까지 완전 충전합니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다."))
                                .font(WattlyFont.at(10.5, weight: .regular))
                                .foregroundStyle(t.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        let isTopUp = batteryControl.status.desiredConfiguration?.topUpActive == true
                            || batteryControl.status.activity == .topUp
                        Button {
                            let limit = batteryLimitPercentage
                            let delta = effectiveDelta
                            let heatEnabled = batteryHeatProtectionEnabled
                            let heatThreshold = batteryHeatProtectionThreshold
                            Task {
                                if isTopUp {
                                    await batteryControl.cancelTopUp(
                                        limitPercentage: limit,
                                        lowerHysteresisDelta: delta,
                                        heatProtectionEnabled: heatEnabled,
                                        heatProtectionThresholdCelsius: heatThreshold)
                                } else {
                                    await batteryControl.startTopUp(
                                        limitPercentage: limit,
                                        lowerHysteresisDelta: delta,
                                        heatProtectionEnabled: heatEnabled,
                                        heatProtectionThresholdCelsius: heatThreshold)
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if isTopUp {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                Text(LocalizedStringKey(isTopUp ? "활성화됨" : "비활성화됨"))
                                    .font(WattlyFont.at(11.5, weight: .medium))
                            }
                            .foregroundStyle(isTopUp ? Tokens.statusOrange : t.text)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(isTopUp ? Tokens.statusOrange.opacity(0.15) : t.segTrack))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isTopUp ? Tokens.statusOrange.opacity(0.4) : t.rowBorder, lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!isToggleEnabled || isHardwareUnsupported)
                        .accessibilityLabel(Text(LocalizedStringKey("한 번만 완충")))
                        .accessibilityValue(Text(LocalizedStringKey(isTopUp ? "활성화됨" : "비활성화됨")))
                    }
                    .padding(EdgeInsets(top: 10, leading: 14, bottom: 14, trailing: 14))
                }
            }
            .task(id: "\(batteryLimitEnabled)-\(batteryHeatProtectionEnabled)-\(batteryControl.status.desiredConfiguration?.topUpActive == true)") {
                // One read regardless of the opt-in: a Mac with no charge register has to disable
                // its toggle before the user ever reaches for it. This is also the read that
                // decides whether the configuration controls remain visible.
                await batteryControl.refreshStatus()
                installedOwnership = FanHelperInstaller.installedOwnership()
                // Re-checked every iteration, not just once up front: the gate depends on the mode
                // the daemon just reported, and that mode can change out from under us — e.g. the
                // daemon recovers from `.inhibited`/`.unsupported` back to `.charging` once the user
                // reconnects the adapter. Re-evaluating here is what lets polling stop on its own
                // once the state settles, instead of running forever or freezing on a failure.
                let isTopUp = batteryControl.status.desiredConfiguration?.topUpActive == true
                while !Task.isCancelled,
                      BatterySectionPresentation.shouldPollStatus(isLimitOn: batteryLimitEnabled,
                                                                    isHeatProtectionOn: batteryHeatProtectionEnabled,
                                                                    isTopUpOn: isTopUp,
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
                guard isEnabled, !batteryControl.isInstallingHelper else {
                    Task {
                        await batteryControl.apply(
                            enabled: isEnabled,
                            limitPercentage: batteryLimitPercentage,
                            lowerHysteresisDelta: effectiveDelta,
                            heatProtectionEnabled: batteryHeatProtectionEnabled,
                            heatProtectionThresholdCelsius: batteryHeatProtectionThreshold)
                    }
                    return
                }
                let window = NSApp.keyWindow
                let limit = batteryLimitPercentage
                let delta = effectiveDelta
                let heatEnabled = batteryHeatProtectionEnabled
                let heatThreshold = batteryHeatProtectionThreshold
                Task {
                    let mode = batteryControl.status.mode
                    if BatteryControlPolicy.shouldRunInstaller(mode: mode) {
                        let refreshedMode = await batteryControl.refreshStatus()?.mode ?? .unavailable
                        if BatteryControlPolicy.shouldRunInstaller(mode: refreshedMode) {
                            if let failure = await batteryControl.installAndApply(
                                enabled: true,
                                limitPercentage: limit,
                                lowerHysteresisDelta: delta,
                                heatProtectionEnabled: heatEnabled,
                                heatProtectionThresholdCelsius: heatThreshold,
                                window: window) {
                                installErrorMessage = Self.message(for: failure, locale: locale)
                                isInstallFailedAlertPresented = true
                                batteryLimitEnabled = false
                            }
                            return
                        }
                    }
                    // The helper already answers — reuse it, no second admin prompt.
                    await batteryControl.apply(
                        enabled: true,
                        limitPercentage: limit,
                        lowerHysteresisDelta: delta,
                        heatProtectionEnabled: heatEnabled,
                        heatProtectionThresholdCelsius: heatThreshold)
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
            .onChange(of: batteryLimitPercentage) { _, newLimit in
                guard batteryLimitEnabled || batteryHeatProtectionEnabled else { return }
                Task {
                    await batteryControl.apply(
                        enabled: batteryLimitEnabled,
                        limitPercentage: newLimit,
                        lowerHysteresisDelta: effectiveDelta,
                        heatProtectionEnabled: batteryHeatProtectionEnabled,
                        heatProtectionThresholdCelsius: batteryHeatProtectionThreshold)
                }
            }
            .onChange(of: batterySailingEnabled) { _, isSailing in
                guard batteryLimitEnabled || batteryHeatProtectionEnabled else { return }
                let delta = isSailing ? batterySailingDelta : 2
                Task {
                    await batteryControl.apply(
                        enabled: batteryLimitEnabled,
                        limitPercentage: batteryLimitPercentage,
                        lowerHysteresisDelta: delta,
                        heatProtectionEnabled: batteryHeatProtectionEnabled,
                        heatProtectionThresholdCelsius: batteryHeatProtectionThreshold)
                }
            }
            .onChange(of: batterySailingDelta) { _, newDelta in
                guard batteryLimitEnabled, batterySailingEnabled else { return }
                Task {
                    await batteryControl.apply(
                        enabled: batteryLimitEnabled,
                        limitPercentage: batteryLimitPercentage,
                        lowerHysteresisDelta: newDelta,
                        heatProtectionEnabled: batteryHeatProtectionEnabled,
                        heatProtectionThresholdCelsius: batteryHeatProtectionThreshold)
                }
            }
            .onChange(of: batteryHeatProtectionEnabled) { _, isEnabled in
                guard isEnabled, !batteryControl.isInstallingHelper else {
                    Task {
                        await batteryControl.apply(
                            enabled: batteryLimitEnabled,
                            limitPercentage: batteryLimitPercentage,
                            lowerHysteresisDelta: effectiveDelta,
                            heatProtectionEnabled: isEnabled,
                            heatProtectionThresholdCelsius: batteryHeatProtectionThreshold)
                    }
                    return
                }
                let window = NSApp.keyWindow
                Task {
                    let mode = batteryControl.status.mode
                    if BatteryControlPolicy.shouldRunInstaller(mode: mode) {
                        let refreshedMode = await batteryControl.refreshStatus()?.mode ?? .unavailable
                        if BatteryControlPolicy.shouldRunInstaller(mode: refreshedMode) {
                            if let failure = await batteryControl.installAndApply(
                                enabled: batteryLimitEnabled,
                                limitPercentage: batteryLimitPercentage,
                                lowerHysteresisDelta: effectiveDelta,
                                heatProtectionEnabled: true,
                                heatProtectionThresholdCelsius: batteryHeatProtectionThreshold,
                                window: window) {
                                installErrorMessage = Self.message(for: failure, locale: locale)
                                isInstallFailedAlertPresented = true
                                batteryHeatProtectionEnabled = false
                            }
                            return
                        }
                    }
                    await batteryControl.apply(
                        enabled: batteryLimitEnabled,
                        limitPercentage: batteryLimitPercentage,
                        lowerHysteresisDelta: effectiveDelta,
                        heatProtectionEnabled: true,
                        heatProtectionThresholdCelsius: batteryHeatProtectionThreshold)
                    if batteryControl.status.isHardwareSupported == false {
                        batteryHeatProtectionEnabled = false
                    }
                }
            }
            .onChange(of: batteryHeatProtectionThreshold) { _, newThreshold in
                guard batteryLimitEnabled || batteryHeatProtectionEnabled else { return }
                Task {
                    await batteryControl.apply(
                        enabled: batteryLimitEnabled,
                        limitPercentage: batteryLimitPercentage,
                        lowerHysteresisDelta: effectiveDelta,
                        heatProtectionEnabled: batteryHeatProtectionEnabled,
                        heatProtectionThresholdCelsius: newThreshold)
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
        .alert("소유권 이전", isPresented: $isOwnershipTransferConfirmationPresented) {
            Button("소유권 이전", role: .destructive) {
                installCurrentConfiguration(transferringOwnership: true)
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("유지보수: 다른 사용자의 충전 정책을 해제하고 이 사용자로 소유권을 이전합니다.")
        }
    }

    @ViewBuilder
    private var batteryStatusIndicator: some View {
        let isTopUp = batteryControl.status.desiredConfiguration?.topUpActive == true
        if BatterySectionPresentation.shouldPollStatus(isLimitOn: batteryLimitEnabled,
                                                       isHeatProtectionOn: batteryHeatProtectionEnabled,
                                                       isTopUpOn: isTopUp,
                                                       mode: batteryControl.status.mode,
                                                       isHardwareSupported: batteryControl.status.isHardwareSupported) {
            // XPC polling remains on its existing five-second task. This view-local clock only
            // invalidates the status row so an old sample crosses the stale deadline on screen.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                batteryStatusRow(resolvedStatus(at: context.date))
            }
        } else {
            // Settled-off states intentionally stop XPC polling and never age into a stale label.
            batteryStatusRow(resolvedStatus(at: Date()))
        }
    }

    private func batteryStatusRow(_ resolved: BatterySectionPresentation.Status) -> some View {
        HStack(spacing: 8) {
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
            Button {
                isMaintenanceHelpPopoverPresented = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(t.faint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: BatterySectionPresentation.maintenancePopoverText(
                resolvedMaintenanceStatus, locale: locale)))
            .popover(isPresented: $isMaintenanceHelpPopoverPresented, arrowEdge: .bottom) {
                maintenanceStatusHelpPopover(resolvedMaintenanceStatus)
            }
            Spacer()
            if BatterySectionPresentation.isInstallButtonVisible(
                isLimitOn: batteryLimitEnabled,
                isHeatProtectionOn: batteryHeatProtectionEnabled,
                mode: batteryControl.status.mode
            ) {
                Button {
                    let window = NSApp.keyWindow
                    let limit = batteryLimitPercentage
                    let delta = effectiveDelta
                    let heatEnabled = batteryHeatProtectionEnabled
                    let heatThreshold = batteryHeatProtectionThreshold
                    Task {
                        if let failure = await batteryControl.installAndApply(
                            enabled: batteryLimitEnabled,
                            limitPercentage: limit,
                            lowerHysteresisDelta: delta,
                            heatProtectionEnabled: heatEnabled,
                            heatProtectionThresholdCelsius: heatThreshold,
                            window: window) {
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

    private var resolvedMaintenanceStatus: BatterySectionPresentation.MaintenanceStatus? {
        BatterySectionPresentation.maintenanceStatus(
            ownership: installedOwnership,
            currentUID: UInt32(getuid()),
            capabilities: batteryControl.status.capabilities,
            record: batteryControl.status.lastMaintenance,
            locale: locale)
    }

    @ViewBuilder
    private func maintenanceActionButton(_ action: BatterySectionPresentation.MaintenanceAction?) -> some View {
        if let action {
            let label = BatterySectionPresentation.maintenanceActionLabel(action, locale: locale)
            Button {
                switch action {
                case .retry:
                    reapplyCurrentConfiguration()
                case .updateHelper:
                    installCurrentConfiguration(transferringOwnership: false)
                case .transferOwnership:
                    isOwnershipTransferConfirmationPresented = true
                }
            } label: {
                HStack(spacing: 4) {
                    if batteryControl.isInstallingHelper {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 10, height: 10)
                    }
                    Text(verbatim: label)
                        .font(WattlyFont.at(11.5, weight: .medium))
                        .foregroundStyle(t.text)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rowBorder, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: label))
            .disabled(batteryControl.isInstallingHelper)
        }
    }

    private func reapplyCurrentConfiguration() {
        let limit = batteryLimitPercentage
        let delta = effectiveDelta
        Task {
            await batteryControl.apply(enabled: batteryLimitEnabled,
                                       limitPercentage: limit,
                                       lowerHysteresisDelta: delta,
                                       heatProtectionEnabled: batteryHeatProtectionEnabled,
                                       heatProtectionThresholdCelsius: batteryHeatProtectionThreshold)
        }
    }

    private func installCurrentConfiguration(transferringOwnership: Bool) {
        let window = NSApp.keyWindow
        let limit = batteryLimitPercentage
        let delta = effectiveDelta
        Task {
            if let failure = await batteryControl.installAndApply(
                enabled: batteryLimitEnabled,
                limitPercentage: limit,
                lowerHysteresisDelta: delta,
                heatProtectionEnabled: batteryHeatProtectionEnabled,
                heatProtectionThresholdCelsius: batteryHeatProtectionThreshold,
                transferringOwnership: transferringOwnership,
                window: window) {
                installErrorMessage = Self.message(for: failure, locale: locale)
                isInstallFailedAlertPresented = true
            }
            installedOwnership = FanHelperInstaller.installedOwnership()
        }
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

    private func maintenanceStatusHelpPopover(
        _ maintenance: BatterySectionPresentation.MaintenanceStatus?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: BatterySectionPresentation.maintenancePopoverText(maintenance, locale: locale))
                .font(WattlyFont.at(11, weight: .regular))
                .foregroundStyle(statusColor(for: maintenance?.tone ?? .faint))
                .fixedSize(horizontal: false, vertical: true)
            maintenanceActionButton(maintenance?.action)
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

    private var isHardwareUnsupported: Bool {
        batteryControl.status.isHardwareSupported == false
    }

    private var showsConfigurationControls: Bool {
        BatterySectionPresentation.showsConfigurationControls(
            isHardwareSupported: batteryControl.status.isHardwareSupported)
    }

    /// 토글이 조작 가능한지. `isHardwareUnsupported`의 단순한 반대가 아니다 — 이미 켜져 있는 값을
    /// 끌 수 있게 남겨두는 예외가 붙는다. 판단은 `BatterySectionPresentation`이 갖는다.
    private var isToggleEnabled: Bool {
        BatterySectionPresentation.isToggleEnabled(
            isHardwareSupported: batteryControl.status.isHardwareSupported,
            isLimitOn: batteryLimitEnabled,
            isHeatProtectionOn: batteryHeatProtectionEnabled)
    }

    private var isLimitPickerEnabled: Bool {
        BatterySectionPresentation.isLimitPickerEnabled(isLimitOn: batteryLimitEnabled)
    }

    private func resolvedStatus(at date: Date) -> BatterySectionPresentation.Status {
        BatterySectionPresentation.status(
            isLimitOn: batteryLimitEnabled,
            isHeatProtectionOn: batteryHeatProtectionEnabled,
            isInstalling: batteryControl.isInstallingHelper,
            mode: batteryControl.status.mode,
            reason: batteryControl.status.detailReason,
            detail: batteryControl.status.detail,
            locale: locale,
            activity: batteryControl.status.activity,
            isHardwareSupported: batteryControl.status.isHardwareSupported,
            updatedAt: batteryControl.status.updatedAt,
            now: date.timeIntervalSince1970)
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
