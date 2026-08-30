import SwiftUI
import AppKit

/// 설정 › 배터리 최하단의 "고급 · 배터리 진단" 카드.
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

    @State private var isExpanded = false
    @State private var confirmedOptimizedChargingOff = false
    @State private var confirmedDuration = false
    @State private var isCooldownConfirmationPresented = false
    @State private var isInstallFailedAlertPresented = false
    @State private var installErrorMessage = ""

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
        SettingsSection("고급 · 배터리 진단") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    header
                    if isExpanded {
                        Rectangle().fill(t.line).frame(height: 1)
                        if calibration.isRunning { progress } else { preflight }
                        if let entry = calibration.history.first { report(entry) }
                    }
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
        Button {
            isExpanded.toggle()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsRowTitle("배터리 캘리브레이션")
                    Text("배터리 셀을 회복시키는 기능이 아니라, 잔량 표시의 추정 오차를 보정하는 장시간 충·방전 절차입니다.")
                        .font(WattlyFont.at(10.5, weight: .regular))
                        .foregroundStyle(t.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(t.faint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var preflight: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("절차: 100% 충전 → 20% 방전 → 10분 대기 → 100% 재충전 → 60분 대기 → 원래 설정 복원")
                .font(WattlyFont.at(10.5, weight: .regular))
                .foregroundStyle(t.sub)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: estimateText)
                .font(WattlyFont.at(10.5, weight: .medium))
                .foregroundStyle(t.sub)

            Toggle(isOn: $confirmedDuration) {
                Text(verbatim: BatteryCalibration.blockerText(.durationUnconfirmed, locale: locale))
                    .font(WattlyFont.at(10.5, weight: .regular))
            }
            Toggle(isOn: $confirmedOptimizedChargingOff) {
                Text(verbatim: BatteryCalibration.blockerText(
                    .optimizedChargingUnconfirmed, locale: locale))
                    .font(WattlyFont.at(10.5, weight: .regular))
            }

            // 확인 항목이 아닌, 기계 상태에서 온 차단 사유만 목록으로 보여 준다.
            ForEach(blockers.filter {
                $0 != .durationUnconfirmed && $0 != .optimizedChargingUnconfirmed
            }, id: \.self) { blocker in
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

            Text("macOS는 충전 제한을 쓰는 중에도 주기적으로 100%까지 충전해 잔량 추정을 유지합니다. macOS 26.4 이상의 기본 충전 제한을 쓰신다면 이 절차는 대개 불필요합니다.")
                .font(WattlyFont.at(10, weight: .regular))
                .foregroundStyle(t.faint)
                .fixedSize(horizontal: false, vertical: true)

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
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rowBorder, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!blockers.isEmpty)
        }
    }

    @ViewBuilder
    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(CalibrationStep.allCases.filter { $0 != .preflight }, id: \.self) { step in
                HStack(spacing: 6) {
                    Image(systemName: symbol(for: step))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(step == calibration.run?.step ? Tokens.statusOrange : t.faint)
                    Text(verbatim: BatteryCalibration.stepLabel(step, locale: locale))
                        .font(WattlyFont.at(10.5,
                              weight: step == calibration.run?.step ? .semibold : .regular))
                        .foregroundStyle(step == calibration.run?.step ? t.text : t.faint)
                }
            }
            if let pause = calibration.run?.pause {
                Text(verbatim: BatteryCalibration.pauseText(pause, locale: locale))
                    .font(WattlyFont.at(10.5, weight: .medium))
                    .foregroundStyle(Tokens.statusOrange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: estimateText)
                .font(WattlyFont.at(10.5, weight: .regular))
                .foregroundStyle(t.sub)

            Button {
                Task { await calibration.cancel() }
            } label: {
                Text("중지하고 원래 설정으로 되돌리기")
                    .font(WattlyFont.at(11.5, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.segTrack))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(t.rowBorder, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func report(_ entry: CalibrationHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle().fill(t.line).frame(height: 1)
            Text(verbatim: BatteryNotificationManager.calibrationFinishedTitle(entry, locale: locale))
                .font(WattlyFont.at(11, weight: .semibold))
            Text(verbatim: BatteryNotificationManager.calibrationFinishedBody(entry, locale: locale))
                .font(WattlyFont.at(10.5, weight: .regular))
                .foregroundStyle(t.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var estimateText: String {
        let minutes = calibration.estimatedRemainingMinutes
            ?? BatteryCalibration.estimatedRemainingMinutes(
                step: .chargeToFull, soc: batteryControl.status.currentPercentage)
        return String(
            format: String(localized: "예상 남은 시간 약 %@", locale: locale),
            locale: locale,
            BatterySectionPresentation.formatDuration(minutes: minutes, locale: locale))
    }

    private func symbol(for step: CalibrationStep) -> String {
        guard let current = calibration.run?.step else { return "circle" }
        if step == current { return "arrow.triangle.2.circlepath" }
        let order = CalibrationStep.allCases
        guard let a = order.firstIndex(of: step), let b = order.firstIndex(of: current) else {
            return "circle"
        }
        return a < b ? "checkmark.circle.fill" : "circle"
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
