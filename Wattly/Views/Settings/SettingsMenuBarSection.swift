import SwiftUI

/// Menu bar settings section: Menu bar icon text toggle and metric chip multi-select grid.
struct SettingsMenuBarSection: View {
    let monitor: SystemMonitor
    @Environment(\.tokens) private var t

    @AppStorage(StorageKey.menubarTextEnabled) private var menubarText = Defaults.menubarTextEnabled

    // 메뉴바 칩 (multi-select).
    @AppStorage(StorageKey.menu(.cpu))     private var menuCPU     = Defaults.menuMetrics[.cpu]     ?? false
    @AppStorage(StorageKey.menu(.gpu))     private var menuGPU     = Defaults.menuMetrics[.gpu]     ?? false
    @AppStorage(StorageKey.menuCoreClock("S")) private var menuSClock = Defaults.menuCoreClockEnabled["S"] ?? false
    @AppStorage(StorageKey.menuCoreClock("P")) private var menuPClock = Defaults.menuCoreClockEnabled["P"] ?? false
    @AppStorage(StorageKey.menuCoreClock("E")) private var menuEClock = Defaults.menuCoreClockEnabled["E"] ?? false
    @AppStorage(StorageKey.menu(.power))   private var menuPower   = Defaults.menuMetrics[.power]   ?? false
    @AppStorage(StorageKey.menu(.battery)) private var menuBattery = Defaults.menuMetrics[.battery] ?? false
    @AppStorage(StorageKey.menuBatteryTemp) private var menuBatteryTemp = Defaults.menuBatteryTempEnabled
    @AppStorage(StorageKey.menu(.mem))     private var menuMem     = Defaults.menuMetrics[.mem]     ?? false
    @AppStorage(StorageKey.menuMemPressure) private var menuMemPressure = Defaults.menuMemPressureEnabled
    @AppStorage(StorageKey.menu(.cpuTemp)) private var menuCpuTemp = Defaults.menuMetrics[.cpuTemp] ?? false
    @AppStorage(StorageKey.menu(.gpuTemp)) private var menuGpuTemp = Defaults.menuMetrics[.gpuTemp] ?? false
    @AppStorage(StorageKey.menu(.fan))     private var menuFan     = Defaults.menuMetrics[.fan]     ?? false

    @State private var isAdvancedMenuMetricsExpanded = false

    private var hasActiveAdvancedMetrics: Bool {
        menuSClock || menuPClock || menuEClock || menuMemPressure || menuBatteryTemp
    }

    var body: some View {
        SettingsSection(title: "메뉴바") {
            SettingsCard {
                SettingsToggleRow(isOn: $menubarText, divider: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        SettingsRowTitle("텍스트 표시")
                        Text("메뉴바 아이콘 옆에 선택한 지표를 함께 표시합니다.")
                            .font(WattlyFont.at(11.5, weight: .regular))
                            .foregroundStyle(t.faint)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("표시할 지표 (복수 선택)")
                        .font(WattlyFont.at(11.5, weight: .regular))
                        .foregroundStyle(t.faint)
                    if !menubarText {
                        Text("텍스트 표시를 켜면 선택한 지표가 아이콘 옆에 표시됩니다.")
                            .font(WattlyFont.at(11.5, weight: .regular))
                            .foregroundStyle(t.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    menuChipGrid
                }
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            }
        }
        .task {
            if hasActiveAdvancedMetrics { isAdvancedMenuMetricsExpanded = true }
        }
    }

    private var menuChipGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 주요 지표 (Primary)
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    menuMetricChip(.cpu, label: "CPU (%)", isOn: menuCPU) { menuCPU.toggle() }
                    menuMetricChip(.gpu, label: "GPU (%)", isOn: menuGPU) { menuGPU.toggle() }
                    menuMetricChip(.power, label: "전력 (W)", isOn: menuPower) { menuPower.toggle() }
                }
                GridRow {
                    menuMetricChip(.battery, label: "배터리 (W)", isOn: menuBattery) { menuBattery.toggle() }
                    menuMetricChip(.mem, label: "메모리 (GB)", isOn: menuMem) { menuMem.toggle() }
                    menuMetricChip(.cpuTemp, label: "CPU 온도 (°C)", isOn: menuCpuTemp) { menuCpuTemp.toggle() }
                }
                GridRow {
                    menuMetricChip(.gpuTemp, label: "GPU 온도 (°C)", isOn: menuGpuTemp) { menuGpuTemp.toggle() }
                    menuMetricChip(.fan, label: "팬 (RPM)", isOn: menuFan) { menuFan.toggle() }
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 8).fill(t.segTrack))

            // 세부 지표 접기/펼치기 버튼
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isAdvancedMenuMetricsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isAdvancedMenuMetricsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                    Text(isAdvancedMenuMetricsExpanded ? "세부 지표 접기" : "세부 지표 (코어 클럭·메모리 압력·배터리 온도) 보기")
                        .font(WattlyFont.at(11, weight: .medium))
                }
                .foregroundStyle(t.faint)
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)

            // 세부 지표 (Advanced)
            if isAdvancedMenuMetricsExpanded {
                Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                    GridRow {
                        menuClockChip(label: "S 코어 클럭 (GHz)", isOn: menuSClock) { menuSClock.toggle() }
                        menuClockChip(label: "P 코어 클럭 (GHz)", isOn: menuPClock) { menuPClock.toggle() }
                        menuClockChip(label: "E 코어 클럭 (GHz)", isOn: menuEClock) { menuEClock.toggle() }
                    }
                    GridRow {
                        menuMetricChip(.mem, label: "메모리 압력 (%)", isOn: menuMemPressure) { menuMemPressure.toggle() }
                        WattlyChip(
                            label: "배터리 온도 (°C)",
                            isOn: menuBatteryTemp,
                            isEnabled: menubarText && monitor.isPresent(.battery),
                            disabledReason: !menubarText
                                ? "텍스트 표시를 켜면 선택한 지표가 아이콘 옆에 표시됩니다."
                                : (!monitor.isPresent(.battery) ? "이 Mac에서는 사용할 수 없습니다" : nil),
                            action: { menuBatteryTemp.toggle() }
                        )
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 8).fill(t.segTrack))
            }
        }
    }

    private func menuChipDisabledReason(for card: CardKind) -> String? {
        if !menubarText { return "텍스트 표시를 켜면 선택한 지표가 아이콘 옆에 표시됩니다." }
        if !monitor.isPresent(card) { return "이 Mac에서는 사용할 수 없습니다" }
        return nil
    }

    private func menuMetricChip(_ card: CardKind, label: String, isOn: Bool,
                                action: @escaping () -> Void) -> some View {
        let disabledReason = menuChipDisabledReason(for: card)
        return WattlyChip(label: label, isOn: isOn, isEnabled: disabledReason == nil,
                          disabledReason: disabledReason, action: action)
    }

    private func menuClockChip(label: String, isOn: Bool,
                               action: @escaping () -> Void) -> some View {
        let disabledReason = menubarText
            ? nil
            : "텍스트 표시를 켜면 선택한 지표가 아이콘 옆에 표시됩니다."
        return WattlyChip(label: label, isOn: isOn, isEnabled: disabledReason == nil,
                          disabledReason: disabledReason, action: action)
    }
}
