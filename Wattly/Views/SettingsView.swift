import SwiftUI

/// The settings window (issue 13). SwiftUI `Settings` scene, native window
/// chrome (the prototype's fake traffic-light titlebar is a web-prototype artifact — a real
/// prefs window already draws exactly close-enabled + disabled minimize/zoom; grill #1). All
/// state is `@AppStorage`, so a change reflects in the popover live and survives restart.
///
/// Sections (prototype order): 일반(로그인) · 테마 · 표시 지표 · 전력 표시(EMA) · 그래프 임곗값 ·
/// 메뉴바 · 동작 모드 · 업데이트 주기 · 되돌리기 · 푸터.
struct SettingsView: View {
    @Environment(\.tokens) private var t

    /// The shared monitor — read only for the footer's live self-power (issue 16). The
    /// rest of the window is `@AppStorage`. Observing it across the separate `Settings`
    /// scene is reliable (same `@Observable` instance, read in `body`); the poll keeps
    /// running via the always-alive `PollPolicyBridge`, independent of which window is open.
    let monitor: SystemMonitor

    init(monitor: SystemMonitor) { self.monitor = monitor }

    // Theme / poll / smoothing / menubar text.
    @AppStorage(StorageKey.theme) private var theme = Defaults.theme
    @AppStorage(StorageKey.panelMode) private var panelMode = Defaults.panelMode
    // Mode C: the hero metric + the card order, so the hero picker can resolve the same visible
    // set the popover shows (plan 20). Shared keys → the picker and the popover row-tap sync free.
    @AppStorage(StorageKey.heroMetric) private var heroMetric = Defaults.heroMetric
    @AppStorage(StorageKey.cardOrder) private var cardOrder = Defaults.cardOrder
    @AppStorage(StorageKey.pollInterval) private var pollInterval = Defaults.pollInterval
    @AppStorage(StorageKey.powerMode) private var powerMode = Defaults.powerMode
    @AppStorage(StorageKey.powerSmoothed) private var powerSmoothed = Defaults.powerSmoothed
    @AppStorage(StorageKey.menubarTextEnabled) private var menubarText = Defaults.menubarTextEnabled
    @AppStorage(StorageKey.thresholds) private var thresholds = Defaults.thresholds

    // 표시 지표 — one flag per card (mirrors PollPolicyBridge; gating is automatic).
    @AppStorage(StorageKey.show(.power))   private var showPower   = Defaults.show[.power]   ?? true
    @AppStorage(StorageKey.show(.battery)) private var showBattery = Defaults.show[.battery] ?? true
    @AppStorage(StorageKey.show(.cpu))     private var showCPU     = Defaults.show[.cpu]     ?? true
    @AppStorage(StorageKey.show(.mem))     private var showMem     = Defaults.show[.mem]     ?? true
    @AppStorage(StorageKey.show(.cpuTemp)) private var showCpuTemp = Defaults.show[.cpuTemp] ?? true
    @AppStorage(StorageKey.show(.gpuTemp)) private var showGpuTemp = Defaults.show[.gpuTemp] ?? true
    @AppStorage(StorageKey.show(.batTemp)) private var showBatTemp = Defaults.show[.batTemp] ?? true

    // 메뉴바 칩 (multi-select). Persisted now; the visible menubar effect lands with issue 14.
    @AppStorage(StorageKey.menu(.cpu))     private var menuCPU     = Defaults.menuMetrics[.cpu]     ?? false
    @AppStorage(StorageKey.menu(.power))   private var menuPower   = Defaults.menuMetrics[.power]   ?? false
    @AppStorage(StorageKey.menu(.mem))     private var menuMem     = Defaults.menuMetrics[.mem]     ?? false
    @AppStorage(StorageKey.menu(.cpuTemp)) private var menuCpuTemp = Defaults.menuMetrics[.cpuTemp] ?? false
    @AppStorage(StorageKey.menu(.gpuTemp)) private var menuGpuTemp = Defaults.menuMetrics[.gpuTemp] ?? false
    @AppStorage(StorageKey.menu(.batTemp)) private var menuBatTemp = Defaults.menuMetrics[.batTemp] ?? false

    // Login item: @AppStorage is the display MIRROR; `loginItem` (SMAppService) is authoritative.
    @AppStorage(StorageKey.loginItem) private var loginMirror = Defaults.loginItem
    private let loginItem: LoginItemControlling = LoginItem()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                generalSection
                themeSection
                layoutSection
                showSection
                smoothingSection
                thresholdSection
                menubarSection
                powerModeSection
                pollSection
                resetButton
                footer
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 440, height: 560)
        .background(t.settingsBg)
        // Reconcile the display mirror with the real registration on open (F1).
        .task { loginMirror = loginItem.isEnabled }
    }

    // MARK: 일반 (로그인)

    private var generalSection: some View {
        SettingsSection(title: "일반") {
            SettingsCard {
                SettingsToggleRow(isOn: loginBinding, divider: false) {
                    rowTitle("로그인 시 자동 실행")
                }
            }
        }
    }

    /// Drives the real `SMAppService` and reverts the mirror if registration throws (grill #8).
    private var loginBinding: Binding<Bool> {
        Binding(
            get: { loginMirror },
            set: { want in
                do {
                    try loginItem.setEnabled(want)
                    loginMirror = want
                } catch {
                    loginMirror = loginItem.isEnabled   // registration failed — show real state
                }
            }
        )
    }

    // MARK: 테마

    private var themeSection: some View {
        SettingsSection(title: "테마") {
            WattlySegment(selection: $theme, options: [
                (.light, "라이트"), (.dark, "다크"), (.system, "시스템 설정"),
            ])
        }
    }

    // MARK: 레이아웃 (issue 19 + plan 20)

    /// Popover layout picker (A·B·C). When mode C is selected, a hero-metric sub-picker appears
    /// beneath the segment — a single-select grid over the visible cards, writing the same
    /// `heroMetric` key the popover row-tap does (plan 20). The window is a `ScrollView`, so the
    /// extra section scrolls rather than overflowing.
    private var layoutSection: some View {
        SettingsSection(title: "레이아웃") {
            WattlySegment(selection: $panelMode, options: [
                (.a, PanelMode.a.label), (.b, PanelMode.b.label), (.c, PanelMode.c.label),
            ])
            if panelMode == .c { heroPicker }
        }
    }

    /// Mode-C hero-metric picker: single-select over the visible cards. Highlights the RESOLVED
    /// hero (`resolveHero`), so a hidden persisted pick shows the live fallback — matching the
    /// popover — and a tap writes the raw `heroMetric`.
    private var heroPicker: some View {
        let visible = visibleCards
        let resolved = CardPresentation.resolveHero(persisted: heroMetric, visible: visible)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 2)
        return VStack(alignment: .leading, spacing: 8) {
            Text("히어로 지표")
                .font(WattlyFont.at(11.5, weight: .regular))
                .foregroundStyle(t.faint)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(visible) { card in
                    WattlyChip(label: CardPresentation.label(card), isOn: resolved == card) {
                        heroMetric = card
                    }
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 8).fill(t.segTrack))
        }
    }

    /// The cards the popover would show, computed through the shared `CardOrder.visible` so the
    /// picker can't drift from the live panel (desktop battery/batTemp drop out via `isPresent`).
    private var visibleCards: [CardKind] {
        cardOrder.visible(present: { monitor.isPresent($0) }, shown: { isShown($0) })
    }

    private func isShown(_ card: CardKind) -> Bool {
        switch card {
        case .power: showPower
        case .battery: showBattery
        case .cpu: showCPU
        case .mem: showMem
        case .cpuTemp: showCpuTemp
        case .gpuTemp: showGpuTemp
        case .batTemp: showBatTemp
        }
    }

    // MARK: 표시 지표

    private var showSection: some View {
        SettingsSection(title: "표시 지표") {
            SettingsCard {
                SettingsToggleRow(isOn: $showPower, divider: true) { rowTitle("SoC 전력 (IOReport)") }
                SettingsToggleRow(isOn: $showBattery, divider: true) { rowTitle("배터리") }
                SettingsToggleRow(isOn: $showCPU, divider: true) { rowTitle("CPU 사용률") }
                SettingsToggleRow(isOn: $showMem, divider: true) { rowTitle("메모리") }
                SettingsToggleRow(isOn: $showCpuTemp, divider: true) { rowTitleWithSuffix("CPU 온도", "· 최고값") }
                SettingsToggleRow(isOn: $showGpuTemp, divider: true) { rowTitleWithSuffix("GPU 온도", "· 최고값") }
                SettingsToggleRow(isOn: $showBatTemp, divider: false) { rowTitle("배터리 온도") }
            }
        }
    }

    // MARK: 전력 표시 (EMA)

    private var smoothingSection: some View {
        SettingsSection(title: "전력 표시") {
            SettingsCard {
                SettingsToggleRow(isOn: $powerSmoothed, divider: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        rowTitle("전력 평활 (EMA)")
                        Text("값을 부드럽게 평균내 표시(실제 지속 소모에 맞게). 측정 정확도는 그대로")
                            .font(WattlyFont.at(11.5, weight: .regular))
                            .foregroundStyle(t.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: 그래프 임곗값

    private var thresholdSection: some View {
        SettingsSection(title: "그래프 임곗값") {
            SettingsCard(padding: 14) {
                VStack(alignment: .leading, spacing: 16) {
                    thresholdBlock(title: "CPU 사용률 (%)", keyPath: \.cpu,
                                   warnRange: 10...95, critRange: 20...100, suffix: "%")
                    thresholdDivider
                    memoryThresholdBlock
                    thresholdDivider
                    thresholdBlock(title: "온도 · CPU·GPU·배터리 (°C)", keyPath: \.temp,
                                   warnRange: 40...100, critRange: 50...110, suffix: "°")
                }
            }
        }
    }

    private var thresholdDivider: some View {
        Rectangle().fill(t.line).frame(height: 1)
    }

    /// Memory block: a pressure toggle on top, and the occupancy warn/crit sliders only when
    /// the toggle is off (in pressure mode the % thresholds don't drive the color, so showing
    /// them would be a tombstoned knob).
    private var memoryThresholdBlock: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("메모리")
                .font(WattlyFont.at(12.5, weight: .semibold))
                .foregroundStyle(t.text)
            SettingsToggleRow(isOn: memPressureBinding, divider: false) {
                VStack(alignment: .leading, spacing: 2) {
                    rowTitle("압력 기준 색상")
                    Text("macOS '활성 상태 보기'처럼 점유율이 아닌 시스템 메모리 압력으로 색을 정합니다")
                        .font(WattlyFont.at(11.5, weight: .regular))
                        .foregroundStyle(t.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !thresholds.memColorByPressure {
                thresholdRow(dot: Tokens.statusOrange, label: "주의",
                             binding: thresholdBinding(\.mem, .warn), range: 10...95, suffix: "%")
                thresholdRow(dot: Tokens.statusRed, label: "위험",
                             binding: thresholdBinding(\.mem, .crit), range: 20...100, suffix: "%")
            }
        }
    }

    /// Toggle binding into `thresholds.memColorByPressure`. Reassigns the whole `thresholds`
    /// so the `@AppStorage` re-encodes (same idiom as `thresholdBinding`).
    private var memPressureBinding: Binding<Bool> {
        Binding(
            get: { thresholds.memColorByPressure },
            set: { newValue in
                var next = thresholds
                next.memColorByPressure = newValue
                thresholds = next
            }
        )
    }

    private func thresholdBlock(title: String, keyPath: WritableKeyPath<Thresholds, ThresholdPair>,
                                warnRange: ClosedRange<Double>, critRange: ClosedRange<Double>,
                                suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(WattlyFont.at(12.5, weight: .semibold))
                .foregroundStyle(t.text)
            thresholdRow(dot: Tokens.statusOrange, label: "주의",
                         binding: thresholdBinding(keyPath, .warn), range: warnRange, suffix: suffix)
            thresholdRow(dot: Tokens.statusRed, label: "위험",
                         binding: thresholdBinding(keyPath, .crit), range: critRange, suffix: suffix)
        }
    }

    private func thresholdRow(dot: Color, label: String, binding: Binding<Double>,
                              range: ClosedRange<Double>, suffix: String) -> some View {
        HStack(spacing: 9) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(label)
                .font(WattlyFont.at(12, weight: .regular))
                .foregroundStyle(t.sub)
                .frame(width: 30, alignment: .leading)
            Slider(value: binding, in: range, step: 1).tint(dot)
            Text("\(Int(binding.wrappedValue))\(suffix)")
                .font(WattlyFont.at(12, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(t.text)
                .frame(width: 40, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    /// Clamping `Double` binding into one (metric, control); `ThresholdPair.setting` rounds and
    /// clamps (warn ≤ crit, edited control wins). Reassigns the whole `thresholds` so the
    /// `@AppStorage` re-encodes (issue 10 seam).
    private func thresholdBinding(_ keyPath: WritableKeyPath<Thresholds, ThresholdPair>,
                                  _ control: ThresholdPair.Control) -> Binding<Double> {
        Binding(
            get: {
                let pair = thresholds[keyPath: keyPath]
                return control == .warn ? pair.warn : pair.crit
            },
            set: { newValue in
                var next = thresholds
                next[keyPath: keyPath] = next[keyPath: keyPath].setting(control, to: newValue)
                thresholds = next
            }
        )
    }

    // MARK: 메뉴바

    private var menubarSection: some View {
        SettingsSection(title: "메뉴바") {
            SettingsCard {
                SettingsToggleRow(isOn: $menubarText, divider: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        rowTitle("텍스트 표시")
                        Text("아이콘 옆에 선택한 지표를 함께 표시")
                            .font(WattlyFont.at(11.5, weight: .regular))
                            .foregroundStyle(t.faint)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("표시할 지표 (복수 선택)")
                        .font(WattlyFont.at(11.5, weight: .regular))
                        .foregroundStyle(t.faint)
                    menuChipGrid
                }
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
            }
        }
    }

    private var menuChipGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)
        return LazyVGrid(columns: columns, spacing: 4) {
            WattlyChip(label: "CPU (%)", isOn: menuCPU) { menuCPU.toggle() }
            WattlyChip(label: "전력 (W)", isOn: menuPower) { menuPower.toggle() }
            WattlyChip(label: "메모리 (GB)", isOn: menuMem) { menuMem.toggle() }
            WattlyChip(label: "CPU 온도 (°C)", isOn: menuCpuTemp) { menuCpuTemp.toggle() }
            WattlyChip(label: "GPU 온도 (°C)", isOn: menuGpuTemp) { menuGpuTemp.toggle() }
            WattlyChip(label: "배터리 온도 (°C)", isOn: menuBatTemp) { menuBatTemp.toggle() }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(t.segTrack))
    }

    // MARK: 동작 모드

    private var powerModeSection: some View {
        SettingsSection(title: "동작 모드") {
            WattlySegment(selection: $powerMode, options: [
                (.eco, PowerMode.eco.label), (.performance, PowerMode.performance.label),
            ])
            Text(powerModeDescription)
                .font(WattlyFont.at(11.5, weight: .regular))
                .foregroundStyle(t.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var powerModeDescription: String {
        switch powerMode {
        case .eco:
            "패널을 닫으면 백그라운드 지표 읽기를 줄입니다. 다시 열 때는 최신 값과 그래프 샘플을 새로 얻을 수 있습니다."
        case .performance:
            "활성 지표를 백그라운드에서도 계속 갱신합니다. 더 많은 전력을 사용하지만, 패널 값과 그래프를 더 빨리 준비할 수 있습니다."
        }
    }

    // MARK: 업데이트 주기

    private var pollSection: some View {
        SettingsSection(title: "업데이트 주기") {
            SettingsCard(padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    WattlySegment(selection: $pollInterval,
                                  options: PollInterval.allCases.map { ($0, $0.label) },
                                  pillVPadding: 6)
                    Text(pollingDescription(for: powerMode))
                        .font(WattlyFont.at(11.5, weight: .regular))
                        .foregroundStyle(t.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: 되돌리기

    private var resetButton: some View {
        Button {
            SettingsReset.applyDefaults(login: loginItem)
            loginMirror = loginItem.isEnabled
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 13, weight: .semibold))
                Text("기본값으로 되돌리기")
                    .font(WattlyFont.at(13, weight: .semibold))
            }
            .foregroundStyle(t.text)
            .frame(maxWidth: .infinity)
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 10).fill(t.rowBg))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(t.rowBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: 푸터

    /// "X.XX W" (2 decimals, prototype-faithful) when a self-power reading exists, else "—".
    private var selfPowerText: String {
        monitor.selfPower.map { String(format: "%.2f W", $0) } ?? "—"
    }

    private var footer: some View {
        VStack(spacing: 6) {
            // Live self-power (issue 16): "X.XX W" when warm, "—" until the first valid
            // interval. Reading monitor.selfPower in body tracks the @Observable update.
            (Text("Wattly 1.0 · 자체 소비 ") + Text(selfPowerText).foregroundColor(t.sub))
                .font(WattlyFont.at(11.5, weight: .regular))
                .foregroundStyle(t.faint)
            Text("Created by jjundev")
                .font(WattlyFont.at(11, weight: .regular))
                .foregroundStyle(t.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    // MARK: Row label helpers

    private func rowTitle(_ s: String) -> some View {
        Text(s).font(WattlyFont.at(13.5, weight: .semibold)).foregroundStyle(t.text)
    }

    private func rowTitleWithSuffix(_ s: String, _ suffix: String) -> some View {
        (Text(s).font(WattlyFont.at(13.5, weight: .semibold)).foregroundColor(t.text)
            + Text(" \(suffix)").font(WattlyFont.at(11.5, weight: .regular)).foregroundColor(t.faint))
    }
}
