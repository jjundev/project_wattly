import SwiftUI
import AppKit

/// Fan curve settings section: Custom fan control toggle, Preset selector, Graph editor, and Live status badge.
struct SettingsFanCurveSection: View {
    let monitor: SystemMonitor
    let fanControl: FanControlClient
    @Environment(\.tokens) private var t

    @AppStorage(StorageKey.fanCurve) private var fanCurve = Defaults.fanCurve
    @AppStorage(StorageKey.fanControlEnabled) private var fanControlEnabled = Defaults.fanControlEnabled

    // A short grace window after a curve edit: re-applying the curve makes the daemon blip through
    // a transient `.failed` before it settles on `.controlling`, so within this window that one
    // mode reads as "적용 중…" instead of the alarming "제어 실패". `nil` = no edit in flight.
    @State private var editApplyDeadline: Date?

    // Keeps the zero-fan safety rules available without making the curve card's default state
    // read like a warning document.
    @State private var isZeroFanHelpPresented = false

    // The graph edits a local draft until the gesture ends. Mirror that draft for the legend and
    // help popover so all three surfaces describe exactly the same curve during a drag.
    @State private var fanCurvePreview: FanCurve?

    var body: some View {
        SettingsSection(title: "팬 커브") {
            SettingsCard {
                SettingsToggleRow(isOn: $fanControlEnabled, divider: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        SettingsRowTitle("사용자 지정 팬 제어")
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
                                .accessibilityLabel(Text(LocalizedStringKey("팬 상태 유지 구간 작동 방식 보기")))
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
            // on the opt-in; a double-apply if the bridge ever fires too is harmless.
            .onChange(of: fanCurve) { _, newCurve in
                applyCurve(newCurve)
            }
            // Turning the opt-in ON while the helper isn't installed auto-runs the in-app installer
            // (one macOS admin-auth prompt). On success the curve is applied to engage control; if
            // the user cancels the prompt, revert the toggle so it reflects reality.
            .onChange(of: fanControlEnabled) { _, enabled in
                guard enabled, !fanControl.isInstallingHelper else {
                    if !enabled {
                        Task { await fanControl.apply(enabled: false, curve: fanCurve) }
                    }
                    return
                }
                let window = NSApp.keyWindow
                Task {
                    // 1. Probe if the daemon is already alive in the system
                    let currentStatus = await fanControl.refreshStatus()
                    if let mode = currentStatus?.mode, mode != .unavailable {
                        // Daemon already running! Seamlessly apply curve without admin prompt
                        await fanControl.apply(enabled: true, curve: fanCurve)
                        editApplyDeadline = Date().addingTimeInterval(5)
                        return
                    }

                    // 2. Daemon not running or unavailable -> trigger in-app helper install
                    let success = await fanControl.installAndEngage(curve: fanCurve, window: window)
                    if !success {
                        fanControlEnabled = false
                    } else {
                        editApplyDeadline = Date().addingTimeInterval(5)
                    }
                }
            }
            // Close the grace window at its deadline so a failure that OUTLASTS the re-apply still
            // surfaces as "제어 실패" even if the daemon sends no further status report.
            .task(id: editApplyDeadline) {
                guard let deadline = editApplyDeadline else { return }
                let remaining = deadline.timeIntervalSinceNow
                if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
                if !Task.isCancelled { editApplyDeadline = nil }
            }
            .task {
                await fanControl.refreshStatus()
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
        let entry = Int64(holdRange.lowerBound)
        let exit = Int64(holdRange.upperBound)
        let recoveryBoundary = holdRange.upperBound == FanControlPolicy.zeroRPMExitCelsius
            ? String(format: String(localized: "%lld°C 이상"), exit)
            : String(format: String(localized: "%lld°C 초과"), exit)
        return VStack(alignment: .leading, spacing: 10) {
            Text(String(format: String(localized: "팬 상태 유지 구간 안내 · %lld–%lld°C"), entry, exit))
                .font(WattlyFont.at(13, weight: .semibold))
                .foregroundStyle(t.text)
            VStack(alignment: .leading, spacing: 5) {
                Text(LocalizedStringKey("• 곡선이 0 RPM을 지시할 때만 작동"))
                if holdRange.lowerBound == FanControlPolicy.zeroRPMEnterCelsius {
                    Text(LocalizedStringKey("• 48°C 미만: 팬 정지"))
                } else {
                    Text(String(format: String(localized: "• %lld°C 미만: 곡선 설정에 따라 제어"), entry))
                }
                Text(String(format: String(localized: "• %lld–%lld°C: 현재 정지·회전 상태 유지"), entry, exit))
                Text(String(format: String(localized: "• %@: 기본 최소 RPM 이상으로 복귀"), recoveryBoundary))
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

    /// Live control-state indicator: a colored dot + word driven by the opt-in and the
    /// daemon-reported `status.mode`.
    private var fanStatusIndicator: some View {
        HStack(spacing: 6) {
            Circle().fill(fanStatusColor).frame(width: 7, height: 7)
            Text(LocalizedStringKey(fanStatusText))
                .font(WattlyFont.at(11.5, weight: .medium))
                .foregroundStyle(t.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var fanStatusColor: Color {
        guard fanControlEnabled else { return t.faint }
        if fanControl.isInstallingHelper { return Tokens.statusOrange }
        // A `.failed` blip during the post-edit re-apply is recovering, not broken → keep it orange.
        if isWithinApplyGrace, fanControl.status.mode == .failed { return Tokens.statusOrange }
        switch fanControl.status.mode {
        case .controlling:          return Tokens.statusGreen
        case .engaging, .automatic: return Tokens.statusOrange
        case .unavailable, .failed: return Tokens.statusRed
        }
    }

    private var fanStatusText: String {
        guard fanControlEnabled else { return String(localized: "꺼짐 · macOS 자동 제어") }
        if fanControl.isInstallingHelper { return String(localized: "도우미 설치 중… (관리자 인증)") }
        // Just after an edit the curve re-engages, and the daemon can blip through `.failed` for a
        // second or two before `.controlling`. Within the grace window show the reassuring "적용 중…"
        // rather than the alarming "제어 실패"; a failure that outlasts the window still surfaces.
        if isWithinApplyGrace, fanControl.status.mode == .failed { return String(localized: "적용 중…") }
        switch fanControl.status.mode {
        case .controlling: return String(localized: "적용 중 · 사용자 지정 곡선으로 제어")
        case .engaging:    return String(localized: "연결 중…")
        case .automatic:   return String(localized: "대기 중 · macOS 자동 제어")
        case .unavailable: return String(localized: "도우미 미설치 — 토글을 켜면 설치됩니다")
        case .failed:      return String(localized: "제어 실패 — macOS 자동 제어로 복귀")
        }
    }

    /// The hottest live CPU sensor (°C) from the monitor, or nil when CPU temperature isn't a
    /// live reading. Read in `body` (via the preview), so the @Observable monitor re-renders it.
    private var currentHottestCPU: Double? {
        if case .value(.temperature(let s)) = monitor.cardState(.cpuTemp) { return hottestCPUCelsius(s) }
        return nil
    }
}
