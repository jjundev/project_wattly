import SwiftUI
import AppKit   // NSWorkspace for per-process app icons (issue 05)

/// The "tap to reveal detail" region for `isExpandable` cards (processor-power per-app
/// top processor-power apps, battery voltage/current, CPU per-core, memory process list, CPU/GPU-temp clusters, fan
/// actual/target) — shared by mode A's stack rows (`MetricCardView`) and mode C's hero
/// card (`PopoverHeroView`, plan: hero card expand). Reads `@Environment(\.tokens)` for
/// its palette so each host supplies its own: mode A lets it track the live app theme,
/// while the hero overrides it to `Tokens.dark` (its background is fixed-dark in both
/// themes, so the live theme tokens would vanish against it — see `PopoverHeroView`).
struct CardExpandRegion: View {
    @Environment(\.tokens) private var t
    @Environment(\.locale) private var locale
    @AppStorage(StorageKey.showBatteryEfficiency) private var showBatteryEfficiency = Defaults.showBatteryEfficiency
    @AppStorage(StorageKey.batteryLimitPercentage) private var batteryLimitPercentage = Defaults.batteryLimitPercentage
    @AppStorage(StorageKey.batterySailingEnabled) private var batterySailingEnabled = Defaults.batterySailingEnabled
    @AppStorage(StorageKey.batterySailingDelta) private var batterySailingDelta = Defaults.batterySailingDelta
    @AppStorage(StorageKey.batteryHeatProtectionEnabled) private var batteryHeatProtectionEnabled = Defaults.batteryHeatProtectionEnabled
    @AppStorage(StorageKey.batteryHeatProtectionThreshold) private var batteryHeatProtectionThreshold = Defaults.batteryHeatProtectionThreshold
    @AppStorage(StorageKey.batteryManualDischargeTarget) private var manualDischargeTarget = Defaults.batteryManualDischargeTarget
    let card: CardKind
    let state: MetricState
    var thresholds: Thresholds = Defaults.thresholds
    var batteryControl: BatteryControlClient? = nil
    var scheduleCoordinator: BatteryScheduleCoordinator? = nil

    @ViewBuilder
    var body: some View {
        if card == .power, case .value(.power(let s)) = state {
            powerExpand(s)
        } else if card == .battery, case .value(.battery(let s)) = state {
            batteryExpand(s)
        } else if card == .cpu, case .value(.cpu(let s)) = state {
            cpuExpand(s)
        } else if card == .gpu, case .value(.gpu(let s)) = state {
            gpuExpand(s)
        } else if card == .mem, case .value(.memory(let s)) = state {
            memExpand(s)
        } else if card == .cpuTemp, case .value(.temperature(let s)) = state, case .reading(let r) = s.cpu {
            tempExpand(r.groups)
        } else if card == .gpuTemp, case .value(.temperature(let s)) = state, case .reading(let r) = s.gpu {
            tempExpand(r.groups)
        } else if card == .fan, case .value(.fan(let s)) = state {
            fanExpand(s)
        }
    }

    // MARK: CPU expand — per-core bars grouped by runtime perf level (prototype lines 355–372)

    private func cpuExpand(_ s: CPUSample) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(s.perfLevels.enumerated()), id: \.offset) { idx, level in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(level.name)
                            .font(WattlyFont.at(11, weight: .bold))
                            .foregroundStyle(t.sub)
                        Spacer(minLength: 8)
                        if let ghz = level.activeGHz {
                            Text(CardPresentation.ghzText(ghz))
                                .font(WattlyFont.at(11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(t.faint)
                        }
                        Text("\(Int(level.usage.rounded()))%")
                            .font(WattlyFont.at(12, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(idx == 0 ? Tokens.accent : t.sub)
                    }
                    ForEach(Array(level.cores.enumerated()), id: \.offset) { ci, usage in
                        coreRow(label: "\(CardPresentation.corePrefix(level.name))\(ci)", usage: usage, accent: idx == 0)
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    // MARK: GPU expand — Renderer, Tiler, and VRAM pipeline bars

    private func gpuExpand(_ s: GPUSample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(s.coreCount)-Core GPU")
                    .font(WattlyFont.at(11, weight: .bold))
                    .foregroundStyle(t.sub)
                Spacer(minLength: 8)
                if let ghz = s.activeGHz {
                    Text(CardPresentation.ghzText(ghz))
                        .font(WattlyFont.at(11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(t.faint)
                }
                Text("\(Int(s.overall.rounded()))%")
                    .font(WattlyFont.at(12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(t.sub)
            }
            
            gpuEngineRow(label: "렌더러", usage: s.rendererUsage)
            gpuEngineRow(label: "타일러", usage: s.tilerUsage)
            gpuMemoryRow(label: "VRAM", inUse: s.inUseMemoryBytes, alloc: s.allocMemoryBytes)
        }
        .padding(.top, 8)
    }

    private func gpuEngineRow(label: String, usage: Double) -> some View {
        HStack(spacing: 9) {
            Text(LocalizedStringKey(label))
                .font(WattlyFont.at(10.5, weight: .semibold))
                .foregroundStyle(t.faint)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(t.sparkFill)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(t.faint)
                        .frame(width: geo.size.width * min(100, max(0, usage)) / 100)
                }
            }
            .frame(height: 6)
            Text("\(Int(usage.rounded()))%")
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.sub)
                .frame(width: 32, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(Int(usage.rounded())) 퍼센트")
    }

    private func gpuMemoryRow(label: String, inUse: UInt64, alloc: UInt64) -> some View {
        let frac = CardPresentation.gpuMemoryFraction(inUse: inUse, alloc: alloc)
        let text = CardPresentation.mbText(inUse)
        return HStack(spacing: 9) {
            Text(label)
                .font(WattlyFont.at(10.5, weight: .semibold))
                .foregroundStyle(t.faint)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(t.sparkFill)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(t.faint)
                        .frame(width: geo.size.width * frac)
                }
            }
            .frame(height: 6)
            Text(text)
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.sub)
                .frame(width: 58, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(text)")
    }

    private func coreRow(label: String, usage: Double, accent: Bool) -> some View {
        HStack(spacing: 9) {
            Text(label)
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.faint)
                .frame(width: 22, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(t.sparkFill)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(accent ? Tokens.accent : t.faint)
                        .frame(width: geo.size.width * min(100, max(0, usage)) / 100)
                }
            }
            .frame(height: 6)
            Text("\(Int(usage.rounded()))%")
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.sub)
                .frame(width: 26, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(Int(usage.rounded())) 퍼센트")
    }

    // MARK: Memory expand — top processes (issue 05)

    /// Top memory processes. Bar color tracks the memory sparkline stroke (neutral
    /// at 05; threshold color once issue 10 lands — §M12). Bars are proportional to
    /// the largest process; empty → a faint line (§M16).
    @ViewBuilder
    private func memExpand(_ s: MemorySample) -> some View {
        let maxBytes = s.processes.first?.footprintBytes ?? 0
        VStack(alignment: .leading, spacing: 8) {
            if s.processes.isEmpty {
                Text(LocalizedStringKey("프로세스를 읽을 수 없음"))
                    .font(WattlyFont.at(10.5, weight: .semibold))
                    .foregroundStyle(t.faint)
            } else {
                ForEach(s.processes) { p in
                    processRow(name: p.name,
                               valueText: CardPresentation.gbText(p.footprintBytes),
                               fraction: barFraction(footprint: p.footprintBytes, maxBytes: maxBytes),
                               iconPath: p.iconPath)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: Power expand — top per-app power (issue 16 follow-up)

    /// Top power-consuming apps, symmetric with the memory process list. Three-state on
    /// `s.processes`: nil → "측정 중…" (baselining — the energy counter is cumulative, so the
    /// first sweep after expand has no rate yet); [] → "프로세스를 읽을 수 없음"; rows → configured top-N.
    /// Watts cover CPU+GPU compute only and your readable apps, so they don't sum to the
    /// card's Combined headline (label-honest, not a breakdown).
    @ViewBuilder
    private func powerExpand(_ s: PowerSample) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch s.processes {
            case .none:
                Text(LocalizedStringKey("측정 중…"))
                    .font(WattlyFont.at(10.5, weight: .semibold))
                    .foregroundStyle(t.faint)
            case .some(let procs) where procs.isEmpty:
                Text(LocalizedStringKey("프로세스를 읽을 수 없음"))
                    .font(WattlyFont.at(10.5, weight: .semibold))
                    .foregroundStyle(t.faint)
            case .some(let procs):
                let maxW = procs.first?.watts ?? 0
                ForEach(procs) { p in
                    processRow(name: p.name,
                               valueText: CardPresentation.wattText(p.watts),
                               fraction: wattFraction(watts: p.watts, maxWatts: maxW),
                               iconPath: p.iconPath)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: Battery expand — voltage/current (plan: battery stack-mode display)

    private func batteryExpand(_ s: BatterySample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // [범주 1] 전원 공급 및 소비 전력 — 물리 어댑터 연결 또는 강제 방전 중 노출
            if let flow = s.powerFlow {
                let activity = batteryControl?.status.activity
                let manualDischargeActive =
                    batteryControl?.status.desiredConfiguration?.manualDischargeActive == true
                let isDischarging = activity == .discharging
                    || manualDischargeActive
                    || flow.scenario == .activeDischarge
                let shouldShowPowerSupply =
                    BatterySectionPresentation.shouldShowPowerSupplySection(
                        sampleExternalConnected: s.externalConnected,
                        serviceAdapterConnected:
                            batteryControl?.status.isPowerAdapterConnected == true,
                        activity: activity,
                        manualDischargeActive: manualDischargeActive,
                        powerFlowScenario: flow.scenario
                    )

                if shouldShowPowerSupply {
                    let powerSourceValue = isDischarging
                        ? BatterySectionPresentation.forcedDischargeText(locale: locale)
                        : CardPresentation.powerSourceText(flow.scenario, locale: locale)
                    let adapterPowerValue = isDischarging
                        ? BatterySectionPresentation.adapterPowerBlockedText(locale: locale)
                        : CardPresentation.adapterPowerText(flow.adapterWatts)

                    VStack(alignment: .leading, spacing: 10) {
                        batteryDetailRow(
                            label: CardPresentation.powerSourceLabel,
                            value: powerSourceValue
                        )
                        batteryDetailRow(
                            label: CardPresentation.adapterPowerLabel,
                            value: adapterPowerValue
                        )
                        batteryDetailRow(
                            label: CardPresentation.systemPowerLabel,
                            value: CardPresentation.systemPowerText(flow.systemWatts)
                        )
                    }
                    Divider().background(t.line).opacity(0.6)
                }
            }

            // [범주 2] 실시간 전기 지표
            VStack(alignment: .leading, spacing: 10) {
                if let value = CardPresentation.batteryAverage1mText(s) {
                    batteryDetailRow(label: CardPresentation.batteryAverage1mLabel, value: value)
                }
                batteryDetailRow(label: "전류", value: CardPresentation.batteryCurrentText(s))
                batteryDetailRow(label: "전압", value: CardPresentation.batteryVoltageText(s))
                if let value = CardPresentation.batteryTemperatureText(s) {
                    batteryDetailRow(label: CardPresentation.batteryTemperatureLabel, value: value)
                }
            }

            // [범주 3] 배터리 팩 건강 & 용량
            if s.remainingWh != nil || (showBatteryEfficiency && s.efficiencyPercent != nil) || s.cycleCount != nil {
                Divider().background(t.line).opacity(0.6)
                VStack(alignment: .leading, spacing: 10) {
                    if let value = CardPresentation.batteryRemainingCapacityText(s) {
                        batteryDetailRow(label: CardPresentation.batteryRemainingCapacityLabel, value: value)
                    }
                    if showBatteryEfficiency, let value = CardPresentation.batteryEfficiencyText(s) {
                        batteryDetailRow(label: CardPresentation.batteryEfficiencyLabel, value: value)
                    }
                    if let value = CardPresentation.batteryCycleText(s) {
                        batteryDetailRow(label: CardPresentation.batteryCycleLabel, value: value)
                    }
                }
            }

            if let scheduleCoordinator,
               let upcoming = BatteryScheduleCoordinator.nextUpcoming(from: scheduleCoordinator.schedules) {
                if let upcomingText = BatterySectionPresentation.upcomingScheduleText(schedule: upcoming.schedule, triggerDate: upcoming.triggerDate) {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Tokens.accent)
                        Text(upcomingText)
                            .font(WattlyFont.at(10.5, weight: .medium))
                            .foregroundStyle(t.sub)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Tokens.accent.opacity(0.1)))
                }
            }

            if let batteryControl, s.charging || batteryControl.status.isPowerAdapterConnected || s.externalConnected {
                Divider().background(t.line).opacity(0.6)
                batteryTopUpRow(batteryControl, s)
                if shouldShowDischargeRow(batteryControl, s) {
                    batteryDischargeRow(batteryControl, s)
                }
            }
        }
        .padding(.top, 8)
    }

    private func shouldShowDischargeRow(_ batteryControl: BatteryControlClient, _ s: BatterySample) -> Bool {
        let isDischarging = batteryControl.status.activity == .discharging
            || batteryControl.status.desiredConfiguration?.manualDischargeActive == true
        if isDischarging { return true }
        let currentSoC = s.percentage ?? batteryControl.status.currentPercentage
        return currentSoC > manualDischargeTarget
    }

    @ViewBuilder
    private func batteryTopUpRow(_ batteryControl: BatteryControlClient, _ s: BatterySample) -> some View {
        let isTopUp = batteryControl.status.desiredConfiguration?.topUpActive == true || batteryControl.status.activity == .topUp

        HStack(alignment: .center) {
            HStack(spacing: 4) {
                Text(LocalizedStringKey("한 번만 완충"))
                    .font(WattlyFont.at(10.5, weight: .medium))
                    .foregroundStyle(t.faint)
                if isTopUp {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Tokens.statusOrange)
                }
            }
            Spacer()
            Button {
                let limit = batteryLimitPercentage
                let delta = batterySailingEnabled ? batterySailingDelta : 2
                let heatEnabled = batteryHeatProtectionEnabled
                let heatThreshold = batteryHeatProtectionThreshold
                let target = manualDischargeTarget
                Task {
                    if isTopUp {
                        await batteryControl.cancelTopUp(
                            limitPercentage: limit,
                            lowerHysteresisDelta: delta,
                            heatProtectionEnabled: heatEnabled,
                            heatProtectionThresholdCelsius: heatThreshold,
                            manualDischargeTarget: target)
                    } else {
                        await batteryControl.startTopUp(
                            limitPercentage: limit,
                            lowerHysteresisDelta: delta,
                            heatProtectionEnabled: heatEnabled,
                            heatProtectionThresholdCelsius: heatThreshold,
                            manualDischargeTarget: target)
                    }
                }
            } label: {
                Text(LocalizedStringKey(isTopUp ? "활성화됨" : "비활성화됨"))
                    .font(WattlyFont.at(10.5, weight: .medium))
                    .foregroundStyle(isTopUp ? Tokens.statusOrange : t.sub)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(isTopUp ? Tokens.statusOrange.opacity(0.15) : t.segTrack))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(isTopUp ? Tokens.statusOrange.opacity(0.4) : t.rowBorder, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(LocalizedStringKey("한 번만 완충")))
            .accessibilityValue(Text(LocalizedStringKey(isTopUp ? "활성화됨" : "비활성화됨")))
        }
    }

    @ViewBuilder
    private func batteryDischargeRow(_ batteryControl: BatteryControlClient, _ s: BatterySample) -> some View {
        let isDischarging = batteryControl.status.activity == .discharging
            || batteryControl.status.desiredConfiguration?.manualDischargeActive == true
        let currentSoC = s.percentage ?? batteryControl.status.currentPercentage
        let canStartDischarge = s.externalConnected && currentSoC > manualDischargeTarget

        HStack(alignment: .center) {
            HStack(spacing: 4) {
                Text("수동 방전 (\(manualDischargeTarget)%)")
                    .font(WattlyFont.at(10.5, weight: .medium))
                    .foregroundStyle(t.faint)
                if isDischarging {
                    Circle()
                        .fill(Tokens.statusOrange)
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            Button {
                let limit = batteryLimitPercentage
                let delta = batterySailingEnabled ? batterySailingDelta : 2
                let heatEnabled = batteryHeatProtectionEnabled
                let heatThreshold = batteryHeatProtectionThreshold
                let target = manualDischargeTarget
                Task {
                    if isDischarging {
                        await batteryControl.stopManualDischarge(
                            limitPercentage: limit,
                            lowerHysteresisDelta: delta,
                            heatProtectionEnabled: heatEnabled,
                            heatProtectionThresholdCelsius: heatThreshold,
                            manualDischargeTarget: target
                        )
                    } else {
                        await batteryControl.startManualDischarge(
                            target: target,
                            limitPercentage: limit,
                            lowerHysteresisDelta: delta,
                            heatProtectionEnabled: heatEnabled,
                            heatProtectionThresholdCelsius: heatThreshold
                        )
                    }
                }
            } label: {
                if isDischarging {
                    Text(LocalizedStringKey("방전 중지"))
                        .font(WattlyFont.at(10.5, weight: .medium))
                        .foregroundStyle(Tokens.statusRed)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Tokens.statusRed.opacity(0.15)))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Tokens.statusRed.opacity(0.4), lineWidth: 1))
                        .contentShape(Rectangle())
                } else {
                    Text(verbatim: BatterySectionPresentation.startDischargeButtonText(
                        targetSoC: manualDischargeTarget,
                        locale: locale))
                        .font(WattlyFont.at(10.5, weight: .medium))
                        .foregroundStyle(t.sub)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(t.segTrack))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(t.rowBorder, lineWidth: 1))
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .disabled(!isDischarging && !canStartDischarge)
            .accessibilityLabel(Text("수동 방전 (\(manualDischargeTarget)%)"))
            .accessibilityValue(Text(verbatim: isDischarging
                ? String(localized: "방전 중지", locale: locale)
                : BatterySectionPresentation.startDischargeButtonText(
                    targetSoC: manualDischargeTarget,
                    locale: locale)))
        }
    }

    private func batteryDetailRow(label: String, value: String) -> some View {
        HStack {
            Text(LocalizedStringKey(label))
                .font(WattlyFont.at(10.5, weight: .semibold))
                .foregroundStyle(t.faint)
            Spacer(minLength: 8)
            Text(value)
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.sub)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
    }

    // Process row, pixel-matched to the prototype (lines 138–141): name 74 ellipsis
    // · bar h6 r3 · value 46 right. Generalized over the value (bytes "GB" / watts "W") and
    // its bar fraction so memory (05) and power (16) share one row. Borrows coreRow's
    // structure, not its sizing (§M13).
    private func processRow(name: String, valueText: String, fraction: Double, iconPath: String?) -> some View {
        HStack(spacing: 9) {
            appIcon(iconPath)
                .frame(width: 15, height: 15)
            Text(name)
                .font(WattlyFont.at(11, weight: .semibold))
                .foregroundStyle(t.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 74, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(t.sparkFill)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(sparkStroke)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 6)
            Text(valueText)
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.sub)
                .frame(width: 46, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(valueText)")
    }

    /// Small app icon from the resolved bundle/executable path (NSWorkspace caches
    /// these). nil path → a faint placeholder so the rows stay aligned.
    @ViewBuilder
    private func appIcon(_ path: String?) -> some View {
        if let path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 3).fill(t.sparkFill)
        }
    }

    // MARK: Temperature expand — per-cluster summary (issue 08 follow-up)

    /// One row per cluster (P-코어 / E-코어 / GPU): a bar on a fixed 0–110 °C scale plus
    /// the cluster average and hottest sensor. The SMC exposes die-region sensors, not
    /// 1:1 cores, so a per-cluster average is the honest unit (not "per core").
    private func tempExpand(_ groups: [TemperatureGroup]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if groups.isEmpty {
                Text(LocalizedStringKey("센서를 읽을 수 없음"))
                    .font(WattlyFont.at(10.5, weight: .semibold))
                    .foregroundStyle(t.faint)
            } else {
                ForEach(groups, id: \.name) { tempGroupRow($0) }
            }
        }
        .padding(.top, 8)
    }

    private func tempGroupRow(_ g: TemperatureGroup) -> some View {
        HStack(spacing: 9) {
            Text(LocalizedStringKey(g.name))
                .font(WattlyFont.at(10.5, weight: .semibold))
                .foregroundStyle(t.faint)
                .frame(width: 78, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(t.sparkFill)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(t.spark)
                        .frame(width: geo.size.width * CardPresentation.tempBarFraction(g.average))
                }
            }
            .frame(height: 6)
            (Text("\(CardPresentation.f1(g.average))° · ") + Text("최고") + Text(" \(CardPresentation.f1(g.hottest))°"))
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.sub)
                .frame(width: 104, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(g.name), 평균 \(CardPresentation.f1(g.average))도, 최고 \(CardPresentation.f1(g.hottest))도")
    }

    // MARK: Fan expand — per-fan actual/target (Phase A)

    /// One row per physical fan: a bar on the fan's own 0–max scale plus its actual and
    /// target RPM. Single-fan Macs show one row; multi-fan Macs (some MacBook Pros) show one
    /// per fan. Mirrors `tempExpand`'s shape.
    private func fanExpand(_ s: FanSample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if s.fans.isEmpty {
                Text(LocalizedStringKey("팬을 읽을 수 없음"))
                    .font(WattlyFont.at(10.5, weight: .semibold))
                    .foregroundStyle(t.faint)
            } else {
                ForEach(s.fans) { fanRow($0) }
            }
        }
        .padding(.top, 8)
    }

    private func fanRow(_ f: FanReading) -> some View {
        HStack(spacing: 9) {
            (Text("팬") + Text(" \(f.index + 1)"))
                .font(WattlyFont.at(10.5, weight: .semibold))
                .foregroundStyle(t.faint)
                .frame(width: 44, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(t.sparkFill)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(t.spark)
                        .frame(width: geo.size.width * CardPresentation.fanBarFraction(actual: f.actualRPM, max: f.maxRPM))
                }
            }
            .frame(height: 6)
            (Text("\(Int(f.actualRPM.rounded())) RPM · ") + Text("목표") + Text(" \(Int(f.targetRPM.rounded()))"))
                .font(WattlyFont.at(10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(t.sub)
                .frame(width: 128, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("팬 \(f.index + 1), \(Int(f.actualRPM.rounded())) RPM, 목표 \(Int(f.targetRPM.rounded())) RPM")
    }

    // Same rule as MetricCardView's headline sparkline: threshold color when the card has
    // one, else neutral/accent by card family — kept in step so the process bars in mem/power
    // expand match their card's own sparkline color.
    private var sparkStroke: Color {
        if let level = CardPresentation.thresholdLevel(card, state, thresholds) { return level.stroke }
        return card.isAccented ? Tokens.accent : t.spark
    }
}
