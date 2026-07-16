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
/// Sections (prototype order): 일반(로그인) · 테마 · 표시 지표 · 전력 표시(EMA) · 그래프 임곗값 ·
/// 메뉴바 · 동작 모드 · 업데이트 주기 · 되돌리기 · 푸터.
struct SettingsView: View {
    @Environment(\.tokens) private var t

    /// The shared monitor — read only for the footer's live self-power (issue 16). The
    /// rest of the window is `@AppStorage`. Observing it across the separate `Settings`
    /// scene is reliable (same `@Observable` instance, read in `body`); the poll keeps
    /// running via the always-alive `PollPolicyBridge`, independent of which window is open.
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
    @AppStorage(StorageKey.menubarTextEnabled) private var menubarText = Defaults.menubarTextEnabled
    @AppStorage(StorageKey.thresholds) private var thresholds = Defaults.thresholds
    @AppStorage(StorageKey.fanCurve) private var fanCurve = Defaults.fanCurve
    @AppStorage(StorageKey.fanControlEnabled) private var fanControlEnabled = Defaults.fanControlEnabled

    // 표시 지표 — one flag per card (mirrors PollPolicyBridge; gating is automatic).
    @AppStorage(StorageKey.show(.power))   private var showPower   = Defaults.show[.power]   ?? true
    @AppStorage(StorageKey.show(.battery)) private var showBattery = Defaults.show[.battery] ?? true
    @AppStorage(StorageKey.show(.cpu))     private var showCPU     = Defaults.show[.cpu]     ?? true
    @AppStorage(StorageKey.show(.mem))     private var showMem     = Defaults.show[.mem]     ?? true
    @AppStorage(StorageKey.show(.cpuTemp)) private var showCpuTemp = Defaults.show[.cpuTemp] ?? true
    @AppStorage(StorageKey.show(.gpuTemp)) private var showGpuTemp = Defaults.show[.gpuTemp] ?? true
    @AppStorage(StorageKey.show(.batTemp)) private var showBatTemp = Defaults.show[.batTemp] ?? true
    @AppStorage(StorageKey.show(.fan))     private var showFan     = Defaults.show[.fan]     ?? true

    // 메뉴바 칩 (multi-select). Persisted now; the visible menubar effect lands with issue 14.
    @AppStorage(StorageKey.menu(.cpu))     private var menuCPU     = Defaults.menuMetrics[.cpu]     ?? false
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                generalSection
                themeSection
                layoutSection
                showSection
                smoothingSection
                thresholdSection
                if monitor.isPresent(.fan) { fanCurveSection }
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
        .background(WindowAppearanceSync(mode: theme))
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
                    if panelMode == .c { heroPicker }
                }
            }
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
        case .fan: showFan
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
                SettingsToggleRow(isOn: $showBatTemp, divider: true) { rowTitle("배터리 온도") }
                SettingsToggleRow(isOn: $showFan, divider: false) { rowTitle("팬 속도") }
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

    // MARK: 팬 커브

    private var fanCurveSection: some View {
        SettingsSection(title: "팬 커브") {
            // Card padding stays 0: the toggle row self-pads (its own 14) so its divider spans the
            // full card width, and the graph block below adds a matching 14 inset — otherwise the
            // padded card double-insets the toggle row and misaligns it against the graph.
            SettingsCard {
                SettingsToggleRow(isOn: $fanControlEnabled, divider: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        rowTitle("팬 커브 실제 적용")
                        Text("Wattly가 macOS 기본 최소 RPM 이상으로만 팬을 제어합니다. Macs Fan Control은 종료해야 합니다.")
                            .font(WattlyFont.at(11.5, weight: .regular))
                            .foregroundStyle(t.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    fanStatusIndicator
                    HStack {
                        Text("온도 → 팬 속도")
                            .font(WattlyFont.at(12, weight: .semibold))
                            .foregroundStyle(t.sub)
                        Spacer()
                        Button { fanCurve = Defaults.fanCurve } label: {
                            Text("기본값")
                                .font(WattlyFont.at(11, weight: .semibold))
                                .foregroundStyle(t.sub)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6).fill(t.cardBg))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(t.rowBorder, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("팬 커브 기본값으로 되돌리기")
                    }
                    FanCurveEditor(curve: $fanCurve, currentCPU: currentHottestCPU)
                }
                .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
            }
            // Live-apply: the fan bridge observes `fanCurve` through an @AppStorage of a custom
            // RawRepresentable type, whose `onChange` does NOT fire on THIS window's writes (the
            // Bool `enabled` toggle does — hence toggling re-applied but editing didn't). Push the
            // edited curve to the client from here, the instance that actually mutates it. Guarded
            // on the opt-in; a double-apply if the bridge ever fires too is harmless (the client's
            // commands are generation-stamped, last-write-wins).
            .onChange(of: fanCurve) { _, newCurve in
                guard fanControlEnabled else { return }
                editApplyDeadline = Date().addingTimeInterval(5)
                Task { await fanControl.apply(enabled: true, curve: newCurve) }
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
            WattlyChip(label: "S 코어 클럭 (GHz)", isOn: menuSClock) { menuSClock.toggle() }
            WattlyChip(label: "P 코어 클럭 (GHz)", isOn: menuPClock) { menuPClock.toggle() }
            WattlyChip(label: "E 코어 클럭 (GHz)", isOn: menuEClock) { menuEClock.toggle() }
            WattlyChip(label: "전력 (W)", isOn: menuPower) { menuPower.toggle() }
            WattlyChip(label: "배터리 (W)", isOn: menuBattery) { menuBattery.toggle() }
            WattlyChip(label: "메모리 (GB)", isOn: menuMem) { menuMem.toggle() }
            WattlyChip(label: "메모리 압력 (%)", isOn: menuMemPressure) { menuMemPressure.toggle() }
            WattlyChip(label: "CPU 온도 (°C)", isOn: menuCpuTemp) { menuCpuTemp.toggle() }
            WattlyChip(label: "GPU 온도 (°C)", isOn: menuGpuTemp) { menuGpuTemp.toggle() }
            WattlyChip(label: "배터리 온도 (°C)", isOn: menuBatTemp) { menuBatTemp.toggle() }
            WattlyChip(label: "팬 (RPM)", isOn: menuFan) { menuFan.toggle() }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(t.segTrack))
    }

    // MARK: 동작 모드

    private var powerModeSection: some View {
        SettingsSection(title: "동작 모드") {
            SettingsCard(padding: Tokens.cardPadding) {
                VStack(alignment: .leading, spacing: 10) {
                    WattlySegment(selection: $powerMode, options: [
                        (.eco, PowerMode.eco.label), (.performance, PowerMode.performance.label),
                    ])
                    Text(powerModeDescription)
                        .font(WattlyFont.at(11.5, weight: .regular))
                        .foregroundStyle(t.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
