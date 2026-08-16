import SwiftUI
import AppKit

/// Reactively syncs the Settings window's own `NSAppearance` to the theme setting.
/// `.preferredColorScheme` (applied by `ThemedRoot.body`) only sets the color-scheme
/// trait SwiftUI content renders with — it does NOT re-resolve an already-visible `NSWindow`'s
/// AppKit-drawn chrome (the native titlebar) after the theme changes; that chrome only picks up
/// the new value the next time the window is created. That gap is exactly why toggling the theme
/// previously required closing and reopening Settings. Assigning `.appearance` on the hosting
/// window directly, on every reactive update, fixes it. Deliberately scoped to the Settings
/// window only — the `MenuBarExtra` popover paints its own background from tokens (plan 11), so
/// it doesn't need this and is left untouched.
///
/// `.system` needs its OWN concrete `NSAppearance`, not `nil`: on-device testing showed that once
/// the window's appearance has been explicitly forced (light or dark), reassigning `nil` — "no
/// override, follow the app" — does not reliably repaint the already-visible chrome back to the
/// system value (forced-to-forced transitions repaint fine; forced-to-nil does not). So `.system`
/// resolves to whichever concrete appearance the OS currently prefers, via the same code path that
/// already works, and re-resolves live off `NSApp.effectiveAppearance` — which is KVO-observable
/// and is Apple's documented way to detect system Light/Dark/Auto changes — so a `.system` window
/// left open keeps following the OS instead of freezing at the value snapshotted on toggle.
private final class WindowAppearanceSyncView: NSView {
    var mode: ThemeMode = .system {
        didSet { applyAppearance() }
    }

    private var systemAppearanceObservation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAppearance()
        // Follow the OS live in `.system` mode: re-apply whenever the app's effective appearance
        // changes (system Light/Dark toggle or an Auto transition) while the window stays open.
        systemAppearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyAppearance() }
        }
    }

    private func applyAppearance() {
        // `.system` needs a CONCRETE appearance, not `nil`: reassigning `nil` to an already-forced
        // window does not reliably repaint its chrome back to the system value. Resolve `.system`
        // to whatever the OS currently prefers — the same concrete path `.light`/`.dark` use.
        let resolved: NSAppearance? = mode == .system
            ? NSAppearance(named: SystemAppearance.isDark() ? .darkAqua : .aqua)
            : ThemeResolver.nsAppearance(mode)
        window?.appearance = resolved
    }
}

private struct WindowAppearanceSync: NSViewRepresentable {
    let mode: ThemeMode

    func makeNSView(context: Context) -> WindowAppearanceSyncView {
        WindowAppearanceSyncView()
    }

    func updateNSView(_ nsView: WindowAppearanceSyncView, context: Context) {
        nsView.mode = mode
    }
}

/// The settings window (issue 13). SwiftUI `Settings` scene, native window
/// chrome (the prototype's fake traffic-light titlebar is a web-prototype artifact — a real
/// prefs window already draws exactly close-enabled + disabled minimize/zoom; grill #1). All
/// state is `@AppStorage`, so a change reflects in the popover live and survives restart.
///
/// Sections (그룹 순서, settings-card-unification): 일반 · 표시(테마·레이아웃·표시 지표·
/// 카드 펼침 목록·메뉴바) · 동작(백그라운드 갱신·전력 표시 안정화) · 고급(상태 경고 기준·팬 커브) · 되돌리기.
/// 팬 커브는 팬이 없는 Mac(desktop)에서 여전히 조건부로 숨는다(`monitor.isPresent(.fan)`).
struct SettingsView: View {
    @Environment(\.tokens) private var t

    /// The shared monitor supplies hardware availability and fan telemetry. The rest of the
    /// window is `@AppStorage`; the poll keeps running via the always-alive `PollPolicyBridge`.
    let monitor: SystemMonitor
    let fanControl: FanControlClient

    init(monitor: SystemMonitor, fanControl: FanControlClient) {
        self.monitor = monitor
        self.fanControl = fanControl
    }

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
    @AppStorage(StorageKey.showBatteryEfficiency) private var showBatteryEfficiency = Defaults.showBatteryEfficiency
    @AppStorage(StorageKey.memoryProcessLimit) private var memoryProcessLimit = Defaults.memoryProcessLimit
    @AppStorage(StorageKey.powerProcessLimit) private var powerProcessLimit = Defaults.powerProcessLimit
    @AppStorage(StorageKey.menubarTextEnabled) private var menubarText = Defaults.menubarTextEnabled
    @AppStorage(StorageKey.thresholds) private var thresholds = Defaults.thresholds
    @AppStorage(StorageKey.fanCurve) private var fanCurve = Defaults.fanCurve
    @AppStorage(StorageKey.fanControlEnabled) private var fanControlEnabled = Defaults.fanControlEnabled

    // 표시 지표 — one flag per card (mirrors PollPolicyBridge; gating is automatic).
    @AppStorage(StorageKey.show(.power))   private var showPower   = Defaults.show[.power]   ?? true
    @AppStorage(StorageKey.show(.battery)) private var showBattery = Defaults.show[.battery] ?? true
    @AppStorage(StorageKey.show(.cpu))     private var showCPU     = Defaults.show[.cpu]     ?? true
    @AppStorage(StorageKey.show(.gpu))     private var showGPU     = Defaults.show[.gpu]     ?? true
    @AppStorage(StorageKey.show(.mem))     private var showMem     = Defaults.show[.mem]     ?? true
    @AppStorage(StorageKey.show(.cpuTemp)) private var showCpuTemp = Defaults.show[.cpuTemp] ?? true
    @AppStorage(StorageKey.show(.gpuTemp)) private var showGpuTemp = Defaults.show[.gpuTemp] ?? true
    @AppStorage(StorageKey.show(.batTemp)) private var showBatTemp = Defaults.show[.batTemp] ?? true
    @AppStorage(StorageKey.show(.fan))     private var showFan     = Defaults.show[.fan]     ?? true

    // 메뉴바 칩 (multi-select). Persisted now; the visible menubar effect lands with issue 14.
    @AppStorage(StorageKey.menu(.cpu))     private var menuCPU     = Defaults.menuMetrics[.cpu]     ?? false
    @AppStorage(StorageKey.menu(.gpu))     private var menuGPU     = Defaults.menuMetrics[.gpu]     ?? false
    @AppStorage(StorageKey.menuCoreClock("S")) private var menuSClock = Defaults.menuCoreClockEnabled["S"] ?? false
    @AppStorage(StorageKey.menuCoreClock("P")) private var menuPClock = Defaults.menuCoreClockEnabled["P"] ?? false
    @AppStorage(StorageKey.menuCoreClock("E")) private var menuEClock = Defaults.menuCoreClockEnabled["E"] ?? false
    @AppStorage(StorageKey.menu(.power))   private var menuPower   = Defaults.menuMetrics[.power]   ?? false
    @AppStorage(StorageKey.menu(.battery)) private var menuBattery = Defaults.menuMetrics[.battery] ?? false
    @AppStorage(StorageKey.menu(.mem))     private var menuMem     = Defaults.menuMetrics[.mem]     ?? false
    @AppStorage(StorageKey.menuMemPressure) private var menuMemPressure = Defaults.menuMemPressureEnabled
    @AppStorage(StorageKey.menu(.cpuTemp)) private var menuCpuTemp = Defaults.menuMetrics[.cpuTemp] ?? false
    @AppStorage(StorageKey.menu(.gpuTemp)) private var menuGpuTemp = Defaults.menuMetrics[.gpuTemp] ?? false
    @AppStorage(StorageKey.menu(.batTemp)) private var menuBatTemp = Defaults.menuMetrics[.batTemp] ?? false
    @AppStorage(StorageKey.menu(.fan))     private var menuFan     = Defaults.menuMetrics[.fan]     ?? false

    // Login item: @AppStorage is the display MIRROR; `loginItem` (SMAppService) is authoritative.
    @AppStorage(StorageKey.loginItem) private var loginMirror = Defaults.loginItem
    private let loginItem: LoginItemControlling = LoginItem()


    // A short grace window after a curve edit: re-applying the curve makes the daemon blip through
    // a transient `.failed` before it settles on `.controlling`, so within this window that one
    // mode reads as "적용 중…" instead of the alarming "제어 실패". `nil` = no edit in flight.
    @State private var editApplyDeadline: Date?

    // True while the privileged helper install (admin auth prompt) is running.
    @State private var installingHelper = false

    // Keeps the zero-fan safety rules available without making the curve card's default state
    // read like a warning document.
    @State private var isZeroFanHelpPresented = false

    // The graph edits a local draft until the gesture ends. Mirror that draft for the legend and
    // help popover so all three surfaces describe exactly the same curve during a drag.
    @State private var fanCurvePreview: FanCurve?

    @State private var isResetConfirmationPresented = false
    @State private var isAdvancedMenuMetricsExpanded = false

    private var hasActiveAdvancedMetrics: Bool {
        menuSClock || menuPClock || menuEClock || menuMemPressure || menuBatTemp
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                generalSection
                displayGroup
                behaviorGroup
                advancedGroup
                resetButton
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 440, height: 560)
        .background(t.settingsBg)
        .background(WindowAppearanceSync(mode: theme))
        // Reconcile the display mirror with the real registration on open (F1).
        .task {
            loginMirror = loginItem.isEnabled
            if hasActiveAdvancedMetrics { isAdvancedMenuMetricsExpanded = true }
        }
        .alert("모든 Wattly 설정을 기본값으로 되돌릴까요?",
               isPresented: $isResetConfirmationPresented) {
            Button("기본값으로 되돌리기", role: .destructive) { applyDefaults() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("카드 표시, 메뉴바, 경고 기준, 팬 커브 및 자동 실행 설정이 초기화됩니다.")
        }
    }

    // MARK: 표시 (그룹)

    /// 표시 그룹: 테마 · 레이아웃 · 표시 지표 · 카드 펼침 목록 · 메뉴바 — 화면에 무엇이 보이는지를 다루는
    /// 섹션들. `시스템` 그룹(아래 `generalSection`, `body`)은 섹션이 하나뿐이라 그룹 헤더를
    /// 붙이지 않고 자신의 `SettingsSection` 캡션만 쓰지만, 이 그룹은 5개라 헤더가 붙는다.
    private var displayGroup: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroupHeader(title: "표시")
            themeSection
            layoutSection
            showSection
            cardProcessLimitSection
            menubarSection
        }
    }

    // MARK: 동작 (그룹)

    private var behaviorGroup: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroupHeader(title: "동작")
            backgroundUpdateSection
            smoothingSection
        }
    }

    private var advancedGroup: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroupHeader(title: "고급")
            thresholdSection
            if monitor.isPresent(.fan) { fanCurveSection }
        }
    }

    // MARK: 일반 (로그인)

    private var generalSection: some View {
        SettingsSection(title: "일반") {
            SettingsCard {
                SettingsToggleRow(isOn: loginBinding, divider: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        rowTitle("로그인 시 자동 실행")
                        Text("Mac에 로그인하면 Wattly가 메뉴바에서 자동으로 시작됩니다.")
                            .font(WattlyFont.at(11.5, weight: .regular))
                            .foregroundStyle(t.faint)
                    }
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
            SettingsCard(padding: Tokens.cardPadding) {
                WattlySegment(selection: $theme, options: [
                    (.light, "라이트"), (.dark, "다크"), (.system, "시스템 설정"),
                ])
            }
        }
    }

    // MARK: 레이아웃 (issue 19 + plan 20)

    /// Popover layout picker (A·B·C). When mode C is selected, a hero-metric sub-picker appears
    /// beneath the segment — a single-select grid over the visible cards, writing the same
    /// `heroMetric` key the popover row-tap does (plan 20). The window is a `ScrollView`, so the
    /// extra section scrolls rather than overflowing.
    private var layoutSection: some View {
        SettingsSection(title: "레이아웃") {
            SettingsCard(padding: Tokens.cardPadding) {
                VStack(alignment: .leading, spacing: 10) {
                    WattlySegment(selection: $panelMode, options: [
                        (.a, PanelMode.a.label), (.b, PanelMode.b.label), (.c, PanelMode.c.label),
                    ])
                    Text(layoutDescription)
                        .font(WattlyFont.at(11.5, weight: .regular))
                        .foregroundStyle(t.faint)
                        .fixedSize(horizontal: false, vertical: true)
                    if panelMode == .c { heroPicker }
                }
            }
        }
    }

    private var layoutDescription: String {
        switch panelMode {
        case .a:
            "모든 지표를 카드 형태로 세로 배치합니다. 세부 정보 펼침과 순서 변경을 지원합니다."
        case .b:
            "2열 그리드로 지표를 콤팩트하게 배치하여 한눈에 확인하기 좋습니다."
        case .c:
            "주요 지표 하나를 상단에 강조하고 나머지는 목록으로 표시합니다."
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
        case .gpu: showGPU
        case .mem: showMem
        case .cpuTemp: showCpuTemp
        case .gpuTemp: showGpuTemp
        case .batTemp: showBatTemp
        case .fan: showFan
        }
    }

    // MARK: 표시 지표

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
                            rowTitle("배터리 효율 보기")
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
                }
                metricToggle(.cpu, isOn: $showCPU, divider: true, title: "CPU 사용률")
                metricToggle(.gpu, isOn: $showGPU, divider: true, title: "GPU 사용률")
                metricToggle(.mem, isOn: $showMem, divider: true, title: "메모리")
                metricToggle(.cpuTemp, isOn: $showCpuTemp, divider: true, title: "CPU 온도")
                metricToggle(.gpuTemp, isOn: $showGpuTemp, divider: true, title: "GPU 온도")
                metricToggle(.batTemp, isOn: $showBatTemp, divider: true, title: "배터리 온도")
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
                if let suffix { rowTitleWithSuffix(title, suffix) } else { rowTitle(title) }
                if !isAvailable {
                    Text("이 Mac에서는 사용할 수 없습니다")
                        .font(WattlyFont.at(11.5, weight: .regular))
                        .foregroundStyle(t.faint)
                }
            }
        }
    }

    // MARK: 카드 펼침 목록

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

    // MARK: 전력 표시 안정화

    private var smoothingSection: some View {
        SettingsSection(title: "전력 표시 안정화") {
            SettingsCard {
                SettingsToggleRow(isOn: $powerSmoothed, divider: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        rowTitle("전력 표시 안정화")
                        Text("순간적인 변동을 줄여 지속적인 전력 사용량을 보기 쉽게 표시합니다. 측정 방식은 바뀌지 않습니다.")
                            .font(WattlyFont.at(11.5, weight: .regular))
                            .foregroundStyle(t.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: 상태 경고 기준

    private var thresholdSection: some View {
        SettingsSection(title: "상태 경고 기준") {
            SettingsCard(padding: Tokens.cardPadding) {
                VStack(alignment: .leading, spacing: 16) {
                    thresholdBlock(title: "CPU 사용률 (%)", keyPath: \.cpu,
                                   warnRange: 10...95, critRange: 20...100, suffix: "%")
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

    // MARK: 팬 커브

    private var fanCurveSection: some View {
        SettingsSection(title: "팬 커브") {
            // Card padding stays 0: the toggle row self-pads (its own 14) so its divider spans the
            // full card width, and the graph block below adds a matching 14 inset — otherwise the
            // padded card double-insets the toggle row and misaligns it against the graph.
            SettingsCard {
                SettingsToggleRow(isOn: $fanControlEnabled, divider: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        rowTitle("사용자 지정 팬 제어")
                        Text("Wattly가 macOS 기본 제어 대신 아래 곡선을 적용합니다. 처음 켤 때 관리자 인증이 필요합니다.")
                            .font(WattlyFont.at(10.5, weight: .regular))
                            .foregroundStyle(t.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        fanStatusIndicator
                        Spacer()
                        if let holdRange = FanCurveGeometry.zeroRPMHoldRange(for: fanCurvePreview ?? fanCurve) {
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Tokens.statusOrange.opacity(0.12))
                                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Tokens.statusOrange.opacity(0.8), lineWidth: 1))
                                    .frame(width: 14, height: 10)
                                Text("팬 상태 유지 구간")
                                    .font(WattlyFont.at(10.5, weight: .regular))
                                    .foregroundStyle(t.faint)
                                Button { isZeroFanHelpPresented = true } label: {
                                    Image(systemName: "questionmark.circle")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(t.faint)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("팬 상태 유지 구간 작동 방식 보기")
                                .popover(isPresented: $isZeroFanHelpPresented, arrowEdge: .bottom) {
                                    zeroFanHelpPopover(for: holdRange)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    WattlySegment(
                        selection: selectedPresetBinding,
                        options: FanCurvePreset.allCases.map { (Optional($0), $0.rawValue) },
                        pillVPadding: 6
                    )
                    FanCurveEditor(
                        curve: $fanCurve,
                        previewCurve: $fanCurvePreview,
                        currentCPU: currentHottestCPU,
                        rpmMax: activeMaxFanRPM
                    )
                }
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
            }
            // Live-apply: the fan bridge observes `fanCurve` through an @AppStorage of a custom
            // RawRepresentable type, whose `onChange` does NOT fire on THIS window's writes (the
            // Bool `enabled` toggle does — hence toggling re-applied but editing didn't). Push the
            // edited curve to the client from here, the instance that actually mutates it. Guarded
            // on the opt-in; a double-apply if the bridge ever fires too is harmless (the client's
            .onChange(of: fanCurve) { _, newCurve in
                applyCurve(newCurve)
            }
            // Turning the opt-in ON while the helper isn't installed auto-runs the in-app installer
            // (one macOS admin-auth prompt). On success the curve is applied to engage control; if
            // the user cancels the prompt, revert the toggle so it reflects reality.
            .onChange(of: fanControlEnabled) { _, enabled in
                guard enabled, fanControl.status.mode == .unavailable, !installingHelper else { return }
                // Capture the Settings window HERE, synchronously — the toggle lives in it, so it is
                // the key window right now. Reading it later (inside the async task) can race.
                let window = NSApp.keyWindow
                Task { await installHelperThenEngage(settingsWindow: window) }
            }
            // Close the grace window at its deadline so a failure that OUTLASTS the re-apply still
            // surfaces as "제어 실패" even if the daemon sends no further status report (the state
            // change drives the re-render). Restarts on each edit; cancels cleanly on window change.
            .task(id: editApplyDeadline) {
                guard let deadline = editApplyDeadline else { return }
                let remaining = deadline.timeIntervalSinceNow
                if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
                if !Task.isCancelled { editApplyDeadline = nil }
            }
        }
    }

    private func applyCurve(_ newCurve: FanCurve) {
        guard fanControlEnabled else { return }
        editApplyDeadline = Date().addingTimeInterval(5)
        Task {
            await fanControl.apply(enabled: true, curve: newCurve)
            await monitor.pollScheduled(forceProviders: [.fan])
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(500))
                await monitor.pollScheduled(forceProviders: [.fan])
            }
        }
    }

    private var activeMaxFanRPM: Double {
        monitor.hardwareMaxFanRPM ?? FanCurvePreset.defaultMaxRPM
    }

    private var selectedPresetBinding: Binding<FanCurvePreset?> {
        Binding(
            get: { FanCurvePreset.matchingPreset(for: fanCurvePreview ?? fanCurve, maxRPM: activeMaxFanRPM) },
            set: { newPreset in
                guard let preset = newPreset else { return }
                fanCurvePreview = nil
                let newCurve = preset.curve(forMaxRPM: activeMaxFanRPM)
                fanCurve = newCurve
                applyCurve(newCurve)
            }
        )
    }

    private func zeroFanHelpPopover(for holdRange: ClosedRange<Double>) -> some View {
        let entry = Int(holdRange.lowerBound)
        let exit = Int(holdRange.upperBound)
        let recoveryBoundary = holdRange.upperBound == FanControlPolicy.zeroRPMExitCelsius
            ? "\(exit)°C 이상"
            : "\(exit)°C 초과"
        return VStack(alignment: .leading, spacing: 10) {
            Text("팬 상태 유지 구간 안내 · \(entry)–\(exit)°C")
                .font(WattlyFont.at(13, weight: .semibold))
                .foregroundStyle(t.text)
            VStack(alignment: .leading, spacing: 5) {
                Text("• 곡선이 0 RPM을 지시할 때만 작동")
                if holdRange.lowerBound == FanControlPolicy.zeroRPMEnterCelsius {
                    Text("• 48°C 미만: 팬 정지")
                } else {
                    Text("• \(entry)°C 미만: 곡선 설정에 따라 제어")
                }
                Text("• \(entry)–\(exit)°C: 현재 정지·회전 상태 유지")
                Text("• \(recoveryBoundary): 기본 최소 RPM 이상으로 복귀")
            }
            .font(WattlyFont.at(11, weight: .regular))
            .foregroundStyle(t.sub)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
        .background(t.cardBg)
    }

    /// True while the post-edit grace window is still open.
    private var isWithinApplyGrace: Bool {
        (editApplyDeadline?.timeIntervalSinceNow ?? -1) > 0
    }

    /// Installs the privileged helper via one admin-auth prompt, then applies the current curve to
    /// engage control. If the user cancels the prompt (or it fails), revert the opt-in so the toggle
    /// doesn't claim control that isn't running.
    ///
    /// Window-survival: this is an accessory (LSUIElement) app, and the admin-auth dialog
    /// deactivates it long enough (on the success path, while the root script runs) for macOS to
    /// destroy the Settings window — reopening it afterward proved unreliable. So instead we hold a
    /// **regular activation policy for the duration of the install**: a regular app keeps its windows
    /// when deactivated, so the Settings window is never torn down. The menubar-only policy (and its
    /// absent Dock icon) is restored once the window is back up front.
    @MainActor private func installHelperThenEngage(settingsWindow: NSWindow?) async {
        installingHelper = true
        // Hold a regular activation policy across the whole flow: it keeps the Settings window
        // alive through the auth-dialog deactivation AND lets it layer like a normal app's window
        // while we re-raise it (an accessory app's window sinks behind the active app).
        let priorPolicy = NSApp.activationPolicy()
        let raised = priorPolicy != .regular
        if raised { NSApp.setActivationPolicy(.regular) }

        // Keep the Settings window visible UNDER the auth panel for the whole prompt + script run
        // (~seconds): order it front every 0.4s so it doesn't sink behind other apps. Crucially this
        // uses `orderFrontRegardless` only — NOT `activate`, which would steal keyboard focus from the
        // password field. `install()` runs its `osascript` on a background thread, so the main actor
        // is free to run this loop while we await it.
        let keepVisible = Task { @MainActor in
            while !Task.isCancelled {
                settingsWindow?.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }

        var installed = true
        do {
            try await FanHelperInstaller.install()
        } catch {
            fanControlEnabled = false
            installed = false
        }
        keepVisible.cancel()
        installingHelper = false

        // Re-raise Settings the INSTANT the auth dialog is gone — before the XPC `apply` below.
        // `apply` connects to the just-started daemon and can stall for several seconds; doing it
        // first was what left the window sunk for ~10s. `activate` only raises the app, so drive the
        // captured window itself with `orderFrontRegardless`.
        raiseFront(settingsWindow)

        if installed {
            editApplyDeadline = Date().addingTimeInterval(5)
            await fanControl.apply(enabled: true, curve: fanCurve)
        }

        // Drop the transient Dock icon, then re-front once more (restoring `.accessory` while another
        // app is active can sink the window), with a couple of retries to win any late focus steal.
        if raised { NSApp.setActivationPolicy(priorPolicy) }
        for _ in 0..<3 {
            raiseFront(settingsWindow)
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    @MainActor private func raiseFront(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    /// Live control-state indicator: a colored dot + word driven by the opt-in and the
    /// daemon-reported `status.mode`, so the user can tell whether the current curve is actually
    /// being applied (green 적용 중) — not just when something is wrong. Reading `fanControl.status`
    /// in `body` tracks the @Observable client's updates.
    private var fanStatusIndicator: some View {
        HStack(spacing: 6) {
            Circle().fill(fanStatusColor).frame(width: 7, height: 7)
            Text(fanStatusText)
                .font(WattlyFont.at(11.5, weight: .medium))
                .foregroundStyle(t.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var fanStatusColor: Color {
        guard fanControlEnabled else { return t.faint }
        if installingHelper { return Tokens.statusOrange }
        // A `.failed` blip during the post-edit re-apply is recovering, not broken → keep it orange.
        if isWithinApplyGrace, fanControl.status.mode == .failed { return Tokens.statusOrange }
        switch fanControl.status.mode {
        case .controlling:          return Tokens.statusGreen
        case .engaging, .automatic: return Tokens.statusOrange
        case .unavailable, .failed: return Tokens.statusRed
        }
    }

    private var fanStatusText: String {
        guard fanControlEnabled else { return "꺼짐 · macOS 자동 제어" }
        if installingHelper { return "도우미 설치 중… (관리자 인증)" }
        // Just after an edit the curve re-engages, and the daemon can blip through `.failed` for a
        // second or two before `.controlling`. Within the grace window show the reassuring "적용 중…"
        // rather than the alarming "제어 실패"; a failure that outlasts the window still surfaces.
        if isWithinApplyGrace, fanControl.status.mode == .failed { return "적용 중…" }
        switch fanControl.status.mode {
        case .controlling: return "적용 중 · 커브대로 제어"
        case .engaging:    return "연결 중…"
        case .automatic:   return "대기 중 · macOS 자동 제어"
        case .unavailable: return "도우미 미설치 — 토글을 켜면 설치됩니다"
        case .failed:      return "제어 실패 — macOS 자동 제어로 복귀"
        }
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

    /// The hottest live CPU sensor (°C) from the monitor, or nil when CPU temperature isn't a
    /// live reading. Read in `body` (via the preview), so the @Observable monitor re-renders it.
    private var currentHottestCPU: Double? {
        if case .value(.temperature(let s)) = monitor.cardState(.cpuTemp) { return hottestCPUCelsius(s) }
        return nil
    }

    // MARK: 메뉴바

    private var menubarSection: some View {
        SettingsSection(title: "메뉴바") {
            SettingsCard {
                SettingsToggleRow(isOn: $menubarText, divider: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        rowTitle("텍스트 표시")
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

    private var menuChipGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)
        return VStack(alignment: .leading, spacing: 8) {
            // 주요 지표 (Primary)
            LazyVGrid(columns: columns, spacing: 4) {
                menuMetricChip(.cpu, label: "CPU (%)", isOn: menuCPU) { menuCPU.toggle() }
                menuMetricChip(.gpu, label: "GPU (%)", isOn: menuGPU) { menuGPU.toggle() }
                menuMetricChip(.power, label: "전력 (W)", isOn: menuPower) { menuPower.toggle() }
                menuMetricChip(.battery, label: "배터리 (W)", isOn: menuBattery) { menuBattery.toggle() }
                menuMetricChip(.mem, label: "메모리 (GB)", isOn: menuMem) { menuMem.toggle() }
                menuMetricChip(.cpuTemp, label: "CPU 온도 (°C)", isOn: menuCpuTemp) { menuCpuTemp.toggle() }
                menuMetricChip(.gpuTemp, label: "GPU 온도 (°C)", isOn: menuGpuTemp) { menuGpuTemp.toggle() }
                menuMetricChip(.fan, label: "팬 (RPM)", isOn: menuFan) { menuFan.toggle() }
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
                LazyVGrid(columns: columns, spacing: 4) {
                    menuClockChip(label: "S 코어 클럭 (GHz)", isOn: menuSClock) { menuSClock.toggle() }
                    menuClockChip(label: "P 코어 클럭 (GHz)", isOn: menuPClock) { menuPClock.toggle() }
                    menuClockChip(label: "E 코어 클럭 (GHz)", isOn: menuEClock) { menuEClock.toggle() }
                    menuMetricChip(.mem, label: "메모리 압력 (%)", isOn: menuMemPressure) { menuMemPressure.toggle() }
                    menuMetricChip(.batTemp, label: "배터리 온도 (°C)", isOn: menuBatTemp) { menuBatTemp.toggle() }
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

    // MARK: 백그라운드 갱신

    private var refreshPresetBinding: Binding<BackgroundRefreshPreset> {
        Binding(
            get: {
                BackgroundRefreshPreset.resolve(interval: pollInterval, mode: powerMode)
            },
            set: { newPreset in
                switch newPreset {
                case .eco:
                    powerMode = .eco
                    pollInterval = .auto
                case .performance:
                    powerMode = .performance
                    pollInterval = .auto
                case .custom:
                    if pollInterval == .auto {
                        pollInterval = .s2
                    }
                }
            }
        )
    }

    private var backgroundUpdateSection: some View {
        SettingsSection(title: "백그라운드 갱신") {
            SettingsCard(padding: Tokens.cardPadding) {
                VStack(alignment: .leading, spacing: 10) {
                    WattlySegment(selection: refreshPresetBinding, options: [
                        (.eco, BackgroundRefreshPreset.eco.label),
                        (.performance, BackgroundRefreshPreset.performance.label),
                        (.custom, BackgroundRefreshPreset.custom.label),
                    ])

                    if pollInterval != .auto {
                        Rectangle().fill(t.line).frame(height: 1)
                        Text("갱신 주기")
                            .font(WattlyFont.at(11.5, weight: .regular))
                            .foregroundStyle(t.faint)
                        WattlySegment(selection: $pollInterval,
                                      options: PollInterval.allCases.filter { $0 != .auto }.map { ($0, $0.label) },
                                      pillVPadding: 6)
                    }

                    Text(pollingDescription(for: pollInterval, mode: powerMode))
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
            isResetConfirmationPresented = true
        } label: {
            SettingsCard(padding: 11) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .semibold))
                    Text("기본값으로 되돌리기")
                        .font(WattlyFont.at(13, weight: .semibold))
                }
                .foregroundStyle(t.text)
                .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.plain)
    }

    private func applyDefaults() {
        SettingsReset.applyDefaults(login: loginItem)
        loginMirror = loginItem.isEnabled
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
