import SwiftUI
import AppKit

/// 설정 › 배터리 최하단의 "진단" 카드.
///
/// 헬퍼 능력 게이팅을 **이 카드 안에서만** 하는 것이 중요하다.
/// `BatterySectionPresentation.maintenanceStatus`의 전역 `requiredCapabilities`에
/// `.calibrationV1`을 넣으면, 캘리브레이션을 쓰지 않는 전 사용자가 "도우미 업데이트 필요"
/// 상태가 된다. 반대로 기존 재설치 버튼은 `mode == .unavailable`일 때만 뜨므로, 응답은 잘
/// 하는 구버전 헬퍼는 영원히 교체되지 않는다 — 그래서 여기에 인라인 업데이트 버튼을 둔다.
struct SettingsBatteryCalibrationSection: View {
    @Environment(\.tokens) private var t
    @Environment(\.locale) private var locale
    let batteryControl: BatteryControlClient
    let calibration: BatteryCalibrationCoordinator

    @State private var confirmedOptimizedChargingOff = false
    @State private var confirmedDuration = false
    @State private var isCooldownConfirmationPresented = false
    @State private var isInstallFailedAlertPresented = false
    @State private var installErrorMessage = ""
    @State private var isHelpPopoverPresented = false
    @State private var isHistoryPopoverPresented = false

    private var blockers: [CalibrationBlocker] {
        BatteryCalibration.preflightBlockers(
            helperMode: batteryControl.status.mode,
            capabilities: batteryControl.status.capabilities,
            isHardwareSupported: batteryControl.status.isHardwareSupported,
            isDischargeHardwareSupported: batteryControl.status.isDischargeHardwareSupported,
            isAdapterPresent: calibration.lastReading.isAdapterPresent
                || batteryControl.status.isPowerAdapterConnected,
            isHeatProtected: batteryControl.status.activity == .heatProtection,
            isTopUpActive: batteryControl.status.desiredConfiguration?.topUpActive == true,
            isManualDischargeActive:
                batteryControl.status.desiredConfiguration?.manualDischargeActive == true,
            hasConfirmedOptimizedChargingOff: confirmedOptimizedChargingOff,
            hasConfirmedDuration: confirmedDuration)
    }

    var body: some View {
        SettingsSection("진단") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    Rectangle().fill(t.line).frame(height: 1)
                    if calibration.isRunning { progress } else { preflight }
                }
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
            }
        }
        .alert("도우미 업데이트에 실패했습니다", isPresented: $isInstallFailedAlertPresented) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(verbatim: installErrorMessage)
        }
        .confirmationDialog("최근에 캘리브레이션을 실행했습니다", isPresented: $isCooldownConfirmationPresented) {
            Button("그래도 실행", role: .destructive) {
                // 조건이 바뀔 수 있으므로(예: Optimized Battery Charging이 다시 켜질 수 있음)
                // 매 실행마다 확인을 다시 받는다.
                confirmedDuration = false
                confirmedOptimizedChargingOff = false
                Task { await calibration.start() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("정상적인 배터리에 반복 실행은 권장하지 않습니다. 90일 또는 40 사이클마다 한 번이면 충분합니다.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                SettingsRowTitle("배터리 캘리브레이션")
                Text("배터리 잔량 표시의 추정 오차를 보정합니다.")
                    .font(WattlyFont.at(10.5, weight: .regular))
                    .foregroundStyle(t.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button {
                isHelpPopoverPresented = true
            } label: {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(t.faint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(LocalizedStringKey("배터리 캘리브레이션 안내 보기")))
            .popover(isPresented: $isHelpPopoverPresented, arrowEdge: .bottom) {
                helpPopover
            }
        }
    }

    @ViewBuilder
    private var preflight: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Confirmation checkboxes container
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $confirmedDuration) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("방전 중 Mac 사용 권장 확인")
                            .font(WattlyFont.at(11, weight: .medium))
                            .foregroundStyle(t.text)
                        Text("방전 구간에는 뚜껑을 열고 Mac을 사용 중인 상태로 두어야 합니다.")
                            .font(WattlyFont.at(10, weight: .regular))
                            .foregroundStyle(t.faint)
                    }
                }
                .toggleStyle(.checkbox)

                Rectangle().fill(t.line).frame(height: 1)

                HStack(alignment: .center) {
                    Toggle(isOn: $confirmedOptimizedChargingOff) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("최적화된 배터리 충전 비활성화 확인")
                                .font(WattlyFont.at(11, weight: .medium))
                                .foregroundStyle(t.text)
                            Text("시스템 설정 › 배터리에서 '최적화된 배터리 충전'이 꺼져 있어야 합니다.")
                                .font(WattlyFont.at(10, weight: .regular))
                                .foregroundStyle(t.faint)
                        }
                    }
                    .toggleStyle(.checkbox)

                    Spacer()

                    Button {
                        openSystemBatterySettings()
                    } label: {
                        Text("설정 ↗")
                            .font(WattlyFont.at(10.5, weight: .medium))
                            .foregroundStyle(Tokens.statusOrange)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(t.segTrack))

            // Hardware / Runtime Blockers list
            let runtimeBlockers = blockers.filter {
                $0 != .durationUnconfirmed && $0 != .optimizedChargingUnconfirmed
            }
            if !runtimeBlockers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(runtimeBlockers, id: \.self) { blocker in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Tokens.statusOrange)
                            Text(verbatim: BatteryCalibration.blockerText(blocker, locale: locale))
                                .font(WattlyFont.at(10.5, weight: .regular))
                                .foregroundStyle(t.sub)
                                .fixedSize(horizontal: false, vertical: true)
                            if blocker == .helperTooOld {
                                Button("도우미 업데이트") { updateHelper() }
                                    .buttonStyle(.plain)
                                    .font(WattlyFont.at(10.5, weight: .semibold))
                                    .foregroundStyle(Tokens.statusOrange)
                            }
                        }
                    }
                }
            }

            // Bottom Action Row
            HStack(alignment: .center) {
                if let entry = calibration.history.first {
                    Button {
                        isHistoryPopoverPresented = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 10))
                            Text("최근 보정 이력 (\(calibration.history.count))")
                                .font(WattlyFont.at(10.5, weight: .regular))
                        }
                        .foregroundStyle(t.faint)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $isHistoryPopoverPresented, arrowEdge: .bottom) {
                        historyPopover(entry)
                    }
                }

                Spacer()

                Text(verbatim: estimateText)
                    .font(WattlyFont.at(10.5, weight: .regular))
                    .foregroundStyle(t.faint)

                Button {
                    if calibration.isWithinCooldown {
                        isCooldownConfirmationPresented = true
                    } else {
                        // 조건이 바뀔 수 있으므로(예: Optimized Battery Charging이 다시 켜질 수 있음)
                        // 매 실행마다 확인을 다시 받는다.
                        confirmedDuration = false
                        confirmedOptimizedChargingOff = false
                        Task { await calibration.start() }
                    }
                } label: {
                    Text("캘리브레이션 시작")
                        .font(WattlyFont.at(11.5, weight: .semibold))
                        .foregroundStyle(blockers.isEmpty ? Tokens.statusOrange : t.faint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(blockers.isEmpty ? Tokens.statusOrange.opacity(0.15) : t.segTrack)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    blockers.isEmpty ? Tokens.statusOrange.opacity(0.35) : t.rowBorder,
                                    lineWidth: 1
                                )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!blockers.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Highlight box
            VStack(alignment: .leading, spacing: 8) {
                // Top row
                HStack(spacing: 6) {
                    Circle()
                        .fill(Tokens.statusOrange)
                        .frame(width: 6, height: 6)
                    if let step = calibration.run?.step {
                        Text(verbatim: BatteryCalibration.stepLabel(step, locale: locale))
                            .font(WattlyFont.at(11, weight: .semibold))
                            .foregroundStyle(Tokens.statusOrange)
                    }
                    Spacer()
                    Text(verbatim: estimateText)
                        .font(WattlyFont.at(10.5, weight: .regular))
                        .foregroundStyle(t.faint)
                }

                // Step progression list
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(CalibrationStep.allCases.filter { $0 != .preflight && $0 != .restoring }, id: \.self) { step in
                        HStack(spacing: 6) {
                            Image(systemName: symbol(for: step))
                                .font(.system(size: 10, weight: status(for: step) == .active ? .semibold : .regular))
                                .foregroundStyle(stepColor(for: step))
                            Text(verbatim: BatteryCalibration.stepLabel(step, locale: locale))
                                .font(WattlyFont.at(10.5, weight: status(for: step) == .active ? .semibold : .regular))
                                .foregroundStyle(stepColor(for: step))
                        }
                    }
                }

                if let pause = calibration.run?.pause {
                    Text(verbatim: BatteryCalibration.pauseText(pause, locale: locale))
                        .font(WattlyFont.at(10.5, weight: .medium))
                        .foregroundStyle(Tokens.statusOrange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if calibration.isDischargeTooSlow {
                    Text(verbatim: BatteryCalibration.slowDischargeText(locale: locale))
                        .font(WattlyFont.at(10.5, weight: .medium))
                        .foregroundStyle(Tokens.statusOrange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Tokens.statusOrange.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Tokens.statusOrange.opacity(0.28), lineWidth: 1)
            )

            // Stop button
            HStack {
                Spacer()
                Button {
                    Task { await calibration.cancel() }
                } label: {
                    Text("중지하고 원래 설정으로 되돌리기")
                        .font(WattlyFont.at(11, weight: .semibold))
                        .foregroundStyle(Tokens.statusRed)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Tokens.statusRed.opacity(0.15))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Tokens.statusRed.opacity(0.35), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var helpPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("배터리 캘리브레이션 안내")
                .font(WattlyFont.at(11.5, weight: .semibold))
                .foregroundStyle(t.text)

            Text("배터리 셀 수명을 복원하는 것이 아니라, 배터리 관리 시스템(BMS)의 충전 잔량 추정 오차를 보정하기 위한 절차입니다.")
                .font(WattlyFont.at(10.5, weight: .regular))
                .foregroundStyle(t.sub)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("진행 절차:")
                    .font(WattlyFont.at(10.5, weight: .medium))
                    .foregroundStyle(t.text)
                Text("1. 100%까지 완충")
                Text("2. 20%까지 방전 (Mac 사용 권장)")
                Text("3. 저잔량 안정화 (10분 대기)")
                Text("4. 다시 100%까지 재충전")
                Text("5. 최종 안정화 (60분 대기) 후 원래 설정 복원")
            }
            .font(WattlyFont.at(10.5, weight: .regular))
            .foregroundStyle(t.faint)

            Text("macOS는 충전 제한을 쓰는 중에도 주기적으로 100%까지 충전해 잔량 추정을 유지합니다. macOS 26.4 이상의 기본 충전 제한을 쓰신다면 이 절차는 대개 불필요합니다.")
                .font(WattlyFont.at(10, weight: .regular))
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
        .frame(width: 280, alignment: .leading)
        .background(t.cardBg)
    }

    private func historyPopover(_ entry: CalibrationHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("최근 캘리브레이션 결과")
                .font(WattlyFont.at(11.5, weight: .semibold))
                .foregroundStyle(t.text)

            HStack {
                Text("완료 일시")
                    .font(WattlyFont.at(10.5, weight: .medium))
                    .foregroundStyle(t.sub)
                Spacer()
                Text(entry.finishedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(WattlyFont.at(10.5, weight: .regular))
                    .foregroundStyle(t.faint)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: BatteryCalibration.completionHeadline(locale: locale))
                    .font(WattlyFont.at(11, weight: .medium))
                    .foregroundStyle(Tokens.statusGreen)

                if let note = BatteryCalibration.capacityNote(
                    beginMilliampHours: entry.beginMaxCapacityMilliampHours,
                    endMilliampHours: entry.endMaxCapacityMilliampHours,
                    locale: locale) {
                    Text(verbatim: note)
                        .font(WattlyFont.at(10.5, weight: .regular))
                        .foregroundStyle(t.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("측정된 용량 변화는 자연 변동폭(약 \(BatteryCalibration.naturalCapacityDriftMilliampHours) mAh) 내에 있을 수 있으며, 이 절차의 주 목적은 BMS의 잔량 표시 보정입니다.")
                .font(WattlyFont.at(10, weight: .regular))
                .foregroundStyle(t.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background(t.cardBg)
    }

    private var estimateText: String {
        let minutes = calibration.estimatedRemainingMinutes
            ?? BatteryCalibration.estimatedRemainingMinutes(
                step: .chargeToFull, soc: batteryControl.status.currentPercentage)
        let formatKey = calibration.isRunning ? "예상 남은 시간 약 %@" : "예상 소요 시간 약 %@"
        return String(
            format: String(localized: String.LocalizationValue(formatKey), locale: locale),
            locale: locale,
            BatterySectionPresentation.formatDuration(minutes: minutes, locale: locale))
    }

    private enum StepStatus {
        case completed
        case active
        case pending
    }

    private func status(for step: CalibrationStep) -> StepStatus {
        guard let current = calibration.run?.step else { return .pending }
        if step == current { return .active }
        let order = CalibrationStep.allCases
        guard let a = order.firstIndex(of: step), let b = order.firstIndex(of: current) else {
            return .pending
        }
        return a < b ? .completed : .pending
    }

    private func symbol(for step: CalibrationStep) -> String {
        switch status(for: step) {
        case .completed: return "checkmark.circle.fill"
        case .active: return "arrow.triangle.2.circlepath"
        case .pending: return "circle"
        }
    }

    private func stepColor(for step: CalibrationStep) -> Color {
        switch status(for: step) {
        case .completed: return Tokens.statusGreen
        case .active: return Tokens.statusOrange
        case .pending: return t.faint
        }
    }

    private func openSystemBatterySettings() {
        let center = NSWorkspace.shared.notificationCenter
        var observer: NSObjectProtocol?
        observer = center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notif in
            guard let app = notif.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.systempreferences" || app.bundleIdentifier == "com.apple.SystemSettings"
            else { return }
            if let obs = observer {
                center.removeObserver(obs)
            }
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.isVisible && !window.className.contains("MenuBarExtra") {
                    window.orderFrontRegardless()
                }
            }
        }

        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension"),
           NSWorkspace.shared.open(url) {
            return
        }
        if let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.battery") {
            NSWorkspace.shared.open(fallback)
        }
    }

    private func updateHelper() {
        let window = NSApp.keyWindow
        let defaults = UserDefaults.standard
        func int(_ key: String, _ fallback: Int) -> Int {
            defaults.object(forKey: key) != nil ? defaults.integer(forKey: key) : fallback
        }
        Task {
            // 기존 재설치 경로를 그대로 재사용한다. 설치된 헬퍼를 덮어쓰는 것이 정상 동작이며
            // 사용자에게 인증을 다시 묻는다.
            // `installAndApply`의 `autoDischargeEnabled` 및 `lowerHysteresisDelta` 기본값은
            // `true`/`2`다. 생략하면 도우미 업데이트가 사용자의 자동 방전 설정과 Sailing 델타를
            // 몰래 바꿔 버린다 — 반드시 저장값을 넘긴다.
            let sailingEnabled = defaults.bool(forKey: StorageKey.batterySailingEnabled)
            let sailingDelta = int(StorageKey.batterySailingDelta, Defaults.batterySailingDelta)
            let effectiveDelta = sailingEnabled ? sailingDelta : 2
            if let failure = await batteryControl.installAndApply(
                enabled: defaults.bool(forKey: StorageKey.batteryLimitEnabled),
                limitPercentage: int(StorageKey.batteryLimitPercentage,
                                     Defaults.batteryLimitPercentage),
                lowerHysteresisDelta: effectiveDelta,
                heatProtectionEnabled: defaults.bool(
                    forKey: StorageKey.batteryHeatProtectionEnabled),
                heatProtectionThresholdCelsius: int(
                    StorageKey.batteryHeatProtectionThreshold,
                    Defaults.batteryHeatProtectionThreshold),
                autoDischargeEnabled: defaults.bool(
                    forKey: StorageKey.batteryAutoDischargeEnabled),
                manualDischargeTarget: int(StorageKey.batteryManualDischargeTarget,
                                           Defaults.batteryManualDischargeTarget),
                transferringOwnership: false,
                window: window) {
                installErrorMessage = SettingsBatterySection.message(for: failure, locale: locale)
                isInstallFailedAlertPresented = true
            }
            await batteryControl.refreshStatus()
        }
    }
}

