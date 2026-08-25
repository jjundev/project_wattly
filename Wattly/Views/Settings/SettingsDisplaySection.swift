import SwiftUI

/// Display settings section: Theme picker, Popover layout mode, Card visibility toggles, and Card process count limit.
struct SettingsDisplaySection: View {
    let monitor: SystemMonitor
    @Environment(\.tokens) private var t

    @AppStorage(StorageKey.theme) private var theme = Defaults.theme
    @AppStorage(StorageKey.panelMode) private var panelMode = Defaults.panelMode
    @AppStorage(StorageKey.showBatteryEfficiency) private var showBatteryEfficiency = Defaults.showBatteryEfficiency
    @AppStorage(StorageKey.showBatteryTopUp) private var showBatteryTopUp = Defaults.showBatteryTopUp
    @AppStorage(StorageKey.showBatteryManualDischarge) private var showBatteryManualDischarge = Defaults.showBatteryManualDischarge
    @AppStorage(StorageKey.memoryProcessLimit) private var memoryProcessLimit = Defaults.memoryProcessLimit
    @AppStorage(StorageKey.powerProcessLimit) private var powerProcessLimit = Defaults.powerProcessLimit

    // 표시 지표 — one flag per card (mirrors PollPolicyBridge; gating is automatic).
    @AppStorage(StorageKey.show(.power))   private var showPower   = Defaults.show[.power]   ?? true
    @AppStorage(StorageKey.show(.battery)) private var showBattery = Defaults.show[.battery] ?? true
    @AppStorage(StorageKey.show(.cpu))     private var showCPU     = Defaults.show[.cpu]     ?? true
    @AppStorage(StorageKey.show(.gpu))     private var showGPU     = Defaults.show[.gpu]     ?? true
    @AppStorage(StorageKey.show(.mem))     private var showMem     = Defaults.show[.mem]     ?? true
    @AppStorage(StorageKey.show(.cpuTemp)) private var showCpuTemp = Defaults.show[.cpuTemp] ?? true
    @AppStorage(StorageKey.show(.gpuTemp)) private var showGpuTemp = Defaults.show[.gpuTemp] ?? true
    @AppStorage(StorageKey.show(.fan))     private var showFan     = Defaults.show[.fan]     ?? true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            themeSection
            layoutSection
            showSection
            cardProcessLimitSection
        }
    }

    // MARK: - 테마

    private var themeSection: some View {
        SettingsSection(title: "테마") {
            SettingsCard(padding: Tokens.cardPadding) {
                WattlySegment(selection: $theme, options: ThemeMode.allCases.map { ($0, $0.label) })
            }
        }
    }

    // MARK: - 레이아웃

    private var layoutSection: some View {
        SettingsSection(title: "레이아웃") {
            SettingsCard(padding: Tokens.cardPadding) {
                VStack(alignment: .leading, spacing: 10) {
                    WattlySegment(selection: $panelMode, options: [
                        (.a, PanelMode.a.label), (.c, PanelMode.c.label), (.b, PanelMode.b.label),
                    ])
                    Text(LocalizedStringKey(layoutDescription))
                        .font(WattlyFont.at(11.5, weight: .regular))
                        .foregroundStyle(t.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var layoutDescription: String {
        switch panelMode {
        case .a:
            "모든 지표를 카드로 세로 배치하며 세부 펼침과 순서 변경을 지원합니다."
        case .b:
            "2열 그리드로 지표를 콤팩트하게 배치하여 한눈에 확인하기 좋습니다."
        case .c:
            "주요 지표 하나를 상단에 강조하고 나머지는 목록으로 표시합니다."
        }
    }

    // MARK: - 표시 지표

    private var showSection: some View {
        SettingsSection(title: "표시 지표") {
            SettingsCard {
                metricToggle(.power, isOn: $showPower, divider: true, title: "프로세서 전력")
                metricToggle(.battery, isOn: $showBattery, divider: true, title: "배터리")
                if showBattery {
                    SettingsToggleRow(isOn: $showBatteryEfficiency, divider: true,
                                      isEnabled: monitor.isPresent(.battery),
                                      disabledReason: monitor.isPresent(.battery) ? nil : "이 Mac에서는 사용할 수 없습니다") {
                        VStack(alignment: .leading, spacing: 2) {
                            SettingsRowTitle("배터리 효율 보기")
                            Text("배터리 효율 수치가 신경 쓰인다면, 필요할 때만 표시하세요.")
                                .font(WattlyFont.at(11.5, weight: .regular))
                                .foregroundStyle(t.faint)
                            if !monitor.isPresent(.battery) {
                                Text("이 Mac에서는 사용할 수 없습니다")
                                    .font(WattlyFont.at(11.5, weight: .regular))
                                    .foregroundStyle(t.faint)
                            }
                        }
                    }
                    .padding(.leading, 14)

                    SettingsToggleRow(isOn: $showBatteryTopUp, divider: true,
                                      isEnabled: monitor.isPresent(.battery),
                                      disabledReason: monitor.isPresent(.battery) ? nil : "이 Mac에서는 사용할 수 없습니다") {
                        VStack(alignment: .leading, spacing: 2) {
                            SettingsRowTitle("한 번만 완충 보기")
                            Text("배터리 카드에서 일회성 100% 충전 버튼을 표시합니다.")
                                .font(WattlyFont.at(11.5, weight: .regular))
                                .foregroundStyle(t.faint)
                            if !monitor.isPresent(.battery) {
                                Text("이 Mac에서는 사용할 수 없습니다")
                                    .font(WattlyFont.at(11.5, weight: .regular))
                                    .foregroundStyle(t.faint)
                            }
                        }
                    }
                    .padding(.leading, 14)

                    SettingsToggleRow(isOn: $showBatteryManualDischarge, divider: true,
                                      isEnabled: monitor.isPresent(.battery),
                                      disabledReason: monitor.isPresent(.battery) ? nil : "이 Mac에서는 사용할 수 없습니다") {
                        VStack(alignment: .leading, spacing: 2) {
                            SettingsRowTitle("수동 방전 보기")
                            Text("배터리 카드에서 목표 잔량까지 수동 방전 버튼을 표시합니다.")
                                .font(WattlyFont.at(11.5, weight: .regular))
                                .foregroundStyle(t.faint)
                            if !monitor.isPresent(.battery) {
                                Text("이 Mac에서는 사용할 수 없습니다")
                                    .font(WattlyFont.at(11.5, weight: .regular))
                                    .foregroundStyle(t.faint)
                            }
                        }
                    }
                    .padding(.leading, 14)
                }
                metricToggle(.cpu, isOn: $showCPU, divider: true, title: "CPU 사용률")
                metricToggle(.gpu, isOn: $showGPU, divider: true, title: "GPU 사용률")
                metricToggle(.mem, isOn: $showMem, divider: true, title: "메모리")
                metricToggle(.cpuTemp, isOn: $showCpuTemp, divider: true, title: "CPU 온도")
                metricToggle(.gpuTemp, isOn: $showGpuTemp, divider: true, title: "GPU 온도")
                metricToggle(.fan, isOn: $showFan, divider: false, title: "팬 속도")
            }
        }
    }

    private func metricToggle(_ card: CardKind, isOn: Binding<Bool>, divider: Bool,
                              title: String, suffix: String? = nil) -> some View {
        let isAvailable = monitor.isPresent(card)
        return SettingsToggleRow(isOn: isOn, divider: divider, isEnabled: isAvailable,
                                 disabledReason: isAvailable ? nil : "이 Mac에서는 사용할 수 없습니다") {
            VStack(alignment: .leading, spacing: 2) {
                SettingsRowTitle(title, suffix: suffix)
                if !isAvailable {
                    Text("이 Mac에서는 사용할 수 없습니다")
                        .font(WattlyFont.at(11.5, weight: .regular))
                        .foregroundStyle(t.faint)
                }
            }
        }
    }

    // MARK: - 카드 펼침 목록

    private var unifiedProcessLimitBinding: Binding<Int> {
        Binding(
            get: { memoryProcessLimit },
            set: { val in
                memoryProcessLimit = val
                powerProcessLimit = val
            }
        )
    }

    private var cardProcessLimitSection: some View {
        SettingsSection(title: "카드 펼침 목록") {
            SettingsCard(padding: Tokens.cardPadding) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("표시할 앱 수")
                        .font(WattlyFont.at(11.5, weight: .regular))
                        .foregroundStyle(t.faint)
                    WattlySegment(selection: unifiedProcessLimitBinding, options: [
                        (3, "3개"), (5, "5개"), (7, "7개"),
                    ], fontSize: 11.5, pillVPadding: 6)
                    Text("메모리 및 프로세서 전력 카드를 펼쳤을 때 사용량이 큰 앱부터 표시합니다.")
                        .font(WattlyFont.at(11.5, weight: .regular))
                        .foregroundStyle(t.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
