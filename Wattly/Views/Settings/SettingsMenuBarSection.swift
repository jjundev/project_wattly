import SwiftUI

/// Menu bar settings: a group containing icon-motion and text-metric sections.
struct SettingsMenuBarSection: View {
    let monitor: SystemMonitor
    @Environment(\.tokens) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage(StorageKey.menubarTextEnabled) private var menubarText = Defaults.menubarTextEnabled
    @AppStorage(StorageKey.kineticNotchMotionEnabled) private var kineticNotchMotionEnabled = Defaults.kineticNotchMotionEnabled
    @AppStorage(StorageKey.kineticNotchSource) private var kineticNotchSource = Defaults.kineticNotchSource
    @AppStorage(StorageKey.kineticNotchSpeed) private var kineticNotchSpeed = Defaults.kineticNotchSpeed

    @AppStorage(StorageKey.menubarIconStyle) private var iconStyle = Defaults.menubarIconStyle

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
    @State private var displayedPreviewFrame: Int = 0
    @State private var liveACConnected: Bool = HardwarePowerSource.isACConnected()

    private var hasActiveAdvancedMetrics: Bool {
        menuSClock || menuPClock || menuEClock || menuMemPressure || menuBatteryTemp
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroupHeader(title: "메뉴바")

            SettingsSection(title: "아이콘") {
                SettingsCard {
                    kineticNotchControls
                }
            }

            SettingsSection(title: "텍스트") {
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
        }
        .task {
            if hasActiveAdvancedMetrics { isAdvancedMenuMetricsExpanded = true }
        }
    }

    private var kineticNotchControls: some View {
        VStack(spacing: 0) {
            SettingsToggleRow(isOn: $kineticNotchMotionEnabled, divider: true) {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsRowTitle("부하에 맞춰 아이콘 움직이기")
                    Text("선택한 부하가 높을수록 메뉴바 아이콘의 움직임 속도가 빨라집니다.")
                        .font(WattlyFont.at(11.5, weight: .regular))
                        .foregroundStyle(t.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                kineticNotchField(title: "아이콘 디자인 테마") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(MenuBarIconStyle.allCases) { style in
                            iconStyleButton(for: style)
                        }
                    }
                }

                if kineticNotchMotionEnabled {
                    kineticNotchField(title: "부하 원본") {
                        VStack(alignment: .leading, spacing: 8) {
                            WattlySegment(selection: $kineticNotchSource,
                                          options: KineticNotchSource.allCases.map { ($0, $0.label) },
                                          fontSize: 11.5, pillVPadding: 6)
                            Text(LocalizedStringKey(kineticNotchSource.description))
                                .font(WattlyFont.at(11.5, weight: .regular))
                                .foregroundStyle(t.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    kineticNotchField(title: "움직임 속도") {
                        VStack(alignment: .leading, spacing: 8) {
                            WattlySegment(selection: $kineticNotchSpeed,
                                          options: KineticNotchSpeed.allCases.map { ($0, $0.label) },
                                          fontSize: 11.5, pillVPadding: 6)
                            Text(LocalizedStringKey(kineticNotchSpeed.description))
                                .font(WattlyFont.at(11.5, weight: .regular))
                                .foregroundStyle(t.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    kineticNotchField(title: "실시간 속도") {
                        HStack(spacing: 8) {
                            if let previewLoad {
                                let rps = MenuBarIconMotion.revolutionsPerSecond(load: previewLoad)
                                let fps = MenuBarIconMotion.effectiveFrameRate(
                                    load: previewLoad,
                                    speed: kineticNotchSpeed,
                                    isACConnected: isACConnected,
                                    isLowPowerMode: isLowPowerMode,
                                    isForeground: true,
                                    frameCount: iconStyle.frameCount
                                )
                                let fpsText: String = if kineticNotchSpeed == .smart {
                                    "\(Int(previewLoad.rounded()))% · \(String(format: "%.2f", rps)) rps (활성 [\(powerStateTag)]: \(Int(fps.rounded())) fps)"
                                } else {
                                    "\(Int(previewLoad.rounded()))% · \(String(format: "%.2f", rps)) rps (활성: \(Int(fps.rounded())) fps)"
                                }
                                Text(fpsText)
                                    .font(WattlyFont.at(11.5, weight: .medium))
                                    .foregroundStyle(t.faint)
                            } else {
                                Text("선택한 부하를 읽는 동안 아이콘은 정지합니다.")
                                    .font(WattlyFont.at(11.5, weight: .regular))
                                    .foregroundStyle(t.faint)
                            }
                        }
                    }
                }
            }
            .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            .task(id: "\(iconStyle.rawValue)-\(kineticNotchMotionEnabled)-\(kineticNotchSpeed.rawValue)-\(reduceMotion)") {
                guard kineticNotchMotionEnabled, !reduceMotion else {
                    displayedPreviewFrame = iconStyle.staticFrame
                    return
                }
                var continuousPhase = 0.0
                var currentRPS = 0.50
                var lastInstant = CACurrentMediaTime()

                while !Task.isCancelled {
                    let load = previewLoad ?? 0.0
                    let targetRPS = MenuBarIconMotion.revolutionsPerSecond(load: load)

                    let now = CACurrentMediaTime()
                    let dt = min(max(now - lastInstant, 0.001), 1.0)
                    lastInstant = now

                    currentRPS = MenuBarIconMotion.smoothedRPS(current: currentRPS, target: targetRPS, dt: dt)
                    continuousPhase = MenuBarIconMotion.advancePhase(currentPhase: continuousPhase, rps: currentRPS, dt: dt)

                    let newFrame = MenuBarIconMotion.displayedFrame(
                        style: iconStyle,
                        phase: continuousPhase,
                        load: load,
                        reduceMotion: reduceMotion || !kineticNotchMotionEnabled
                    )
                    if newFrame != displayedPreviewFrame {
                        displayedPreviewFrame = newFrame
                    }

                    let ac = HardwarePowerSource.isACConnected()
                    if ac != liveACConnected {
                        liveACConnected = ac
                    }

                    let delay = MenuBarIconMotion.interFrameDelay(
                        rps: currentRPS,
                        speed: kineticNotchSpeed,
                        isACConnected: liveACConnected,
                        isLowPowerMode: isLowPowerMode,
                        isForeground: true,
                        frameCount: iconStyle.frameCount,
                        style: iconStyle
                    )
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
    }

    private func iconStyleButton(for style: MenuBarIconStyle) -> some View {
        let isSelected = iconStyle == style
        let previewFrame = isSelected ? displayedPreviewFrame : MenuBarIconMotion.displayedFrame(
            style: style,
            phase: 0.0,
            load: previewLoad,
            reduceMotion: true
        )
        let fgColor = isSelected ? Tokens.accent : t.text
        let labelColor = isSelected ? t.text : t.faint
        let bgColor = isSelected ? Tokens.accent.opacity(0.12) : t.rowBg
        let strokeColor = isSelected ? Tokens.accent : t.rowBorder
        let strokeWidth: CGFloat = isSelected ? 1.5 : 1.0

        return Button {
            iconStyle = style
        } label: {
            VStack(spacing: 6) {
                DynamicMenuBarIconMark(
                    style: style,
                    frame: previewFrame,
                    markerColor: fgColor
                )
                .frame(width: 28, height: 24)
                .foregroundStyle(fgColor)

                Text(LocalizedStringKey(style.label))
                    .font(WattlyFont.at(11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(labelColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .allowsTightening(true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(bgColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(strokeColor, lineWidth: strokeWidth)
            )
        }
        .buttonStyle(.plain)
    }

    private func kineticNotchField<Content: View>(title: String,
                                                   @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title))
                .font(WattlyFont.at(11.5, weight: .regular))
                .foregroundStyle(t.faint)
            content()
        }
    }

    private var isACConnected: Bool {
        liveACConnected
    }

    private var isLowPowerMode: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private var powerStateTag: String {
        if isLowPowerMode { return "저전력" }
        return isACConnected ? "AC" : "배터리"
    }

    private var previewLoad: Double? {
        let power: Double?
        if case .value(.power(let sample)) = monitor.cardState(.power) {
            power = sample.totalW
        } else {
            power = nil
        }

        let cpuClockGHz: Double?
        let cpu: Double?
        if case .value(.cpu(let sample)) = monitor.cardState(.cpu) {
            cpu = sample.overall
            cpuClockGHz = sample.perfLevels.compactMap(\.activeGHz).first
        } else {
            cpu = nil
            cpuClockGHz = nil
        }

        let gpu: Double?
        let gpuCores: Int?
        if case .value(.gpu(let sample)) = monitor.cardState(.gpu) {
            gpu = sample.overall
            gpuCores = sample.coreCount
        } else {
            gpu = nil
            gpuCores = nil
        }

        let fanCount: Int?
        if case .value(.fan(let sample)) = monitor.cardState(.fan) {
            fanCount = sample.fans.count
        } else {
            fanCount = nil
        }

        return kineticNotchSource.load(
            power: power,
            cpuClockGHz: cpuClockGHz,
            cpu: cpu,
            gpu: gpu,
            gpuCores: gpuCores,
            fanCount: fanCount
        )
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
