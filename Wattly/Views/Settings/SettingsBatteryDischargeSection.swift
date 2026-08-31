import SwiftUI

/// 설정 › 배터리의 방전 카드 두 장 — 자동 방전과 수동 방전.
///
/// 충전 제한 카드에서 떼어낸 이유는 두 가지다. `SettingsBatterySection`이 970줄까지 자라
/// 한 화면에 들고 읽기 어려워졌고, 방전은 충전 제한과 다른 하드웨어 축(CHIE,
/// `isDischargeHardwareSupported`)에 걸려 있어 게이팅 조건이 애초에 다르다.
struct SettingsBatteryDischargeSection: View {
    @Environment(\.tokens) private var t
    @Environment(\.locale) private var locale
    let batteryControl: BatteryControlClient

    // `SettingsBatterySection`과 같은 키를 읽는다. `@AppStorage`는 같은 저장소를 보므로
    // 두 뷰가 같은 값을 들고 있어도 어긋나지 않는다.
    @AppStorage(StorageKey.batteryLimitEnabled) private var batteryLimitEnabled = Defaults.batteryLimitEnabled
    @AppStorage(StorageKey.batteryLimitPercentage) private var batteryLimitPercentage = Defaults.batteryLimitPercentage
    @AppStorage(StorageKey.batterySailingEnabled) private var batterySailingEnabled = Defaults.batterySailingEnabled
    @AppStorage(StorageKey.batterySailingDelta) private var batterySailingDelta = Defaults.batterySailingDelta
    @AppStorage(StorageKey.batteryHeatProtectionEnabled) private var batteryHeatProtectionEnabled = Defaults.batteryHeatProtectionEnabled
    @AppStorage(StorageKey.batteryAutoDischargeEnabled) private var autoDischargeEnabled = Defaults.batteryAutoDischargeEnabled
    @AppStorage(StorageKey.batteryManualDischargeTarget) private var manualDischargeTarget = Defaults.batteryManualDischargeTarget

    private var effectiveDelta: Int {
        batterySailingEnabled ? batterySailingDelta : 2
    }

    private var isHardwareUnsupported: Bool {
        batteryControl.status.isHardwareSupported == false
    }

    private var showsConfigurationControls: Bool {
        BatterySectionPresentation.showsConfigurationControls(
            isHardwareSupported: batteryControl.status.isHardwareSupported)
    }

    private var isToggleEnabled: Bool {
        BatterySectionPresentation.isToggleEnabled(
            isHardwareSupported: batteryControl.status.isHardwareSupported,
            isLimitOn: batteryLimitEnabled,
            isHeatProtectionOn: batteryHeatProtectionEnabled)
    }

    private var isLimitPickerEnabled: Bool {
        BatterySectionPresentation.isLimitPickerEnabled(isLimitOn: batteryLimitEnabled)
    }

    var body: some View {
        // 두 `.onChange`는 `showsConfigurationControls`와 무관하게 항상 매달려 있어야 한다.
        // 분리 전에는 늘 존재하는 카드에 체인되어 있었고, 한도·세일링·발열 보호의 형제
        // 핸들러도 같은 이유로 무조건 배선된다 — 하드웨어 미지원으로 확인된 뒤에도 이미
        // 설정된 값은 데몬과 계속 맞춰져야 하기 때문이다.
        Group {
            if showsConfigurationControls {
                VStack(alignment: .leading, spacing: 9) {
                    autoDischargeCard
                    manualDischargeCard
                }
            }
        }
        .onChange(of: autoDischargeEnabled) { _, isAutoDischarge in
            Task {
                await batteryControl.setAutoDischarge(
                    enabled: isAutoDischarge,
                    limitPercentage: batteryLimitPercentage,
                    lowerHysteresisDelta: effectiveDelta,
                    heatProtectionEnabled: batteryHeatProtectionEnabled,
                    heatProtectionThresholdCelsius: Defaults.batteryHeatProtectionThreshold,
                    limitEnabled: batteryLimitEnabled,
                    manualDischargeTarget: manualDischargeTarget
                )
            }
        }
        .onChange(of: manualDischargeTarget) { _, newTarget in
            guard batteryLimitEnabled || batteryHeatProtectionEnabled
                || batteryControl.status.desiredConfiguration?.manualDischargeActive == true
            else { return }
            Task {
                await batteryControl.reconcile(
                    enabled: batteryLimitEnabled,
                    limitPercentage: batteryLimitPercentage,
                    lowerHysteresisDelta: effectiveDelta,
                    heatProtectionEnabled: batteryHeatProtectionEnabled,
                    heatProtectionThresholdCelsius: Defaults.batteryHeatProtectionThreshold,
                    autoDischargeEnabled: autoDischargeEnabled,
                    manualDischargeActive: batteryControl.status.desiredConfiguration?.manualDischargeActive == true,
                    manualDischargeTarget: newTarget
                )
            }
        }
    }

    @ViewBuilder
    private var autoDischargeCard: some View {
        SettingsCard {
            SettingsToggleRow(
                isOn: $autoDischargeEnabled,
                divider: false,
                isEnabled: isToggleEnabled,
                disabledReason: isToggleEnabled ? nil : "이 Mac은 충전 제어를 지원하지 않습니다"
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsRowTitle("자동 방전")
                    Text("충전 한도를 현재 잔량보다 낮게 변경하면 별도 조작 없이 자동으로 한도까지 방전합니다.")
                        .font(WattlyFont.at(10.5, weight: .regular))
                        .foregroundStyle(t.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var manualDischargeCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsRowTitle("수동 방전")
                    Text("원하는 목표 잔량까지 배터리를 전원 어댑터 연결 상태에서 강제로 방전합니다.")
                        .font(WattlyFont.at(10.5, weight: .regular))
                        .foregroundStyle(t.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(EdgeInsets(top: 14, leading: 14, bottom: 0, trailing: 14))

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("목표 방전 잔량")
                            .font(WattlyFont.at(11.5, weight: .medium))
                            .foregroundStyle(t.sub)
                        Spacer()
                        Text("\(manualDischargeTarget)%")
                            .font(WattlyFont.at(13, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Tokens.statusOrange)
                    }

                    Slider(
                        value: Binding(
                            get: { Double(manualDischargeTarget) },
                            set: { manualDischargeTarget = Int($0.rounded()) }
                        ),
                        in: 50...100,
                        step: 1
                    )
                    .tint(Tokens.statusOrange)
                    .disabled(!isToggleEnabled || isHardwareUnsupported)

                    HStack {
                        Text("50%")
                        Spacer()
                        Text("60%")
                        Spacer()
                        Text("70%")
                        Spacer()
                        Text("80%")
                        Spacer()
                        Text("90%")
                        Spacer()
                        Text("100%")
                    }
                    .font(WattlyFont.at(10, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(t.faint)
                }
                .padding(EdgeInsets(top: 0, leading: 14, bottom: 8, trailing: 14))

                Rectangle().fill(t.line).frame(height: 1)

                let isDischarging = batteryControl.status.activity == .discharging
                    || batteryControl.status.desiredConfiguration?.manualDischargeActive == true
                let isPluggedIn = batteryControl.status.isPowerAdapterConnected
                let currentSoC = batteryControl.status.currentPercentage
                let canStartDischarge = isToggleEnabled && !isHardwareUnsupported && isPluggedIn && currentSoC > manualDischargeTarget

                if isDischarging {
                    let target = batteryControl.status.desiredConfiguration?.manualDischargeTarget ?? manualDischargeTarget
                    VStack(spacing: 8) {
                        HStack {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Tokens.statusOrange)
                                    .frame(width: 7, height: 7)
                                Text(LocalizedStringKey("수동 방전 진행 중"))
                                    .font(WattlyFont.at(11.5, weight: .semibold))
                                    .foregroundStyle(Tokens.statusOrange)
                            }
                            Spacer()
                            Button {
                                Task {
                                    await batteryControl.stopManualDischarge(
                                        limitPercentage: batteryLimitPercentage,
                                        lowerHysteresisDelta: effectiveDelta,
                                        heatProtectionEnabled: batteryHeatProtectionEnabled,
                                        heatProtectionThresholdCelsius: Defaults.batteryHeatProtectionThreshold,
                                        autoDischargeEnabled: autoDischargeEnabled,
                                        manualDischargeTarget: manualDischargeTarget
                                    )
                                }
                            } label: {
                                Text("방전 중지")
                                    .font(WattlyFont.at(11, weight: .semibold))
                                    .foregroundStyle(Tokens.statusRed)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Tokens.statusRed.opacity(0.15)))
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Tokens.statusRed.opacity(0.35), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }

                        HStack {
                            let estMin = max(1, (currentSoC - target) * 3)
                            Text("실시간 소모: -18.4 W")
                                .font(WattlyFont.at(10.5, weight: .regular))
                                .foregroundStyle(t.sub)
                            Spacer()
                            let durationStr = BatterySectionPresentation.formatDuration(minutes: estMin, locale: locale)
                            Text(String(format: String(localized: "예상 완료: 약 %@ 후", locale: locale), durationStr))
                                .font(WattlyFont.at(10.5, weight: .regular))
                                .foregroundStyle(t.sub)
                        }
                    }
                    .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Tokens.statusOrange.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Tokens.statusOrange.opacity(0.28), lineWidth: 1)
                    )
                    .padding(EdgeInsets(top: 0, leading: 14, bottom: 12, trailing: 14))
                } else {
                    let disabledReason = BatterySectionPresentation.manualDischargeDisabledReason(
                        isPluggedIn: isPluggedIn,
                        currentSoC: currentSoC,
                        targetSoC: manualDischargeTarget,
                        isHardwareSupported: !isHardwareUnsupported,
                        isToggleEnabled: isToggleEnabled,
                        locale: locale
                    )
                    HStack {
                        HStack(spacing: 4) {
                            Text("현재 잔량:")
                                .font(WattlyFont.at(11, weight: .regular))
                                .foregroundStyle(t.faint)
                            Text("\(currentSoC)%")
                                .font(WattlyFont.at(11, weight: .semibold))
                                .foregroundStyle(t.text)
                        }
                        Spacer()
                        Button {
                            Task {
                                await batteryControl.startManualDischarge(
                                    target: manualDischargeTarget,
                                    limitPercentage: batteryLimitPercentage,
                                    lowerHysteresisDelta: effectiveDelta,
                                    heatProtectionEnabled: batteryHeatProtectionEnabled,
                                    heatProtectionThresholdCelsius: Defaults.batteryHeatProtectionThreshold,
                                    autoDischargeEnabled: autoDischargeEnabled
                                )
                            }
                        } label: {
                            Text(verbatim: BatterySectionPresentation.startDischargeButtonText(
                                targetSoC: manualDischargeTarget,
                                locale: locale))
                                .font(WattlyFont.at(11.5, weight: .semibold))
                                .foregroundStyle(canStartDischarge ? Tokens.statusOrange : t.faint)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(canStartDischarge ? Tokens.statusOrange.opacity(0.15) : t.segTrack)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(canStartDischarge ? Tokens.statusOrange.opacity(0.35) : t.rowBorder, lineWidth: 1)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canStartDischarge)
                        .help(disabledReason ?? "")
                        .accessibilityLabel(Text(verbatim: BatterySectionPresentation.startDischargeButtonText(targetSoC: manualDischargeTarget, locale: locale)))
                        .accessibilityHint(Text(disabledReason ?? ""))
                    }
                    .padding(EdgeInsets(top: 0, leading: 14, bottom: 14, trailing: 14))
                }
            }
        }
    }
}
