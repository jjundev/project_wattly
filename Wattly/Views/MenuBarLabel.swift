import SwiftUI
import AppKit

/// The always-present menubar item: dynamic icon glyph plus, optionally, the
/// user-selected metrics as compact text (issue 14). Clicking toggles the popover.
///
/// The text is assembled by the pure `MenuBarText` (its own per-metric format, not the
/// card's) from the `menu.<card>` selection. Turning the text off — or selecting no
/// metric — leaves the glyph alone. `monitor.cardState` is read inside `body` (via the
/// `assembled` computed property), so the always-alive label re-renders every poll as
/// the `@Observable` monitor updates.
struct MenuBarLabel: View {
    let monitor: SystemMonitor

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibilitySettings = VisibilitySettings.shared
    @State private var displayedFrameIndex: Int = 0
    @AppStorage(StorageKey.menubarTextEnabled) private var textEnabled = Defaults.menubarTextEnabled
    @AppStorage(StorageKey.powerSmoothed)      private var powerSmoothed = Defaults.powerSmoothed
    @AppStorage(StorageKey.kineticNotchMotionEnabled) private var kineticNotchMotionEnabled = Defaults.kineticNotchMotionEnabled
    @AppStorage(StorageKey.kineticNotchSource) private var kineticNotchSource = Defaults.kineticNotchSource
    @AppStorage(StorageKey.kineticNotchSpeed) private var kineticNotchSpeed = Defaults.kineticNotchSpeed
    @AppStorage(StorageKey.menubarIconStyle) private var iconStyle = Defaults.menubarIconStyle

    var body: some View {
        let label = assembled
        let trailingMargin: CGFloat = (label != nil) ? 5.0 : 0.0
        let glyph = MenuBarGlyph.template(style: iconStyle, frame: displayedFrameIndex, trailingPadding: trailingMargin).map(Image.init(nsImage:)) ?? Image(systemName: "waveform.path")
        return HStack(spacing: 0) {
            glyph
            if let label {
                Text(label)
                    .font(WattlyFont.at(11, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .task(id: "\(iconStyle.rawValue)-\(kineticNotchMotionEnabled)-\(kineticNotchSpeed.rawValue)-\(reduceMotion)") {
            guard kineticNotchMotionEnabled, !reduceMotion else { return }
            var continuousPhase = 0.0
            var currentRPS = 0.50
            var lastInstant = CACurrentMediaTime()

            while !Task.isCancelled {
                let load = kineticNotchLoad ?? 0.0
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
                if newFrame != displayedFrameIndex {
                    displayedFrameIndex = newFrame
                }

                let delay = MenuBarIconMotion.interFrameDelay(
                    rps: currentRPS,
                    speed: kineticNotchSpeed,
                    isACConnected: isACConnected,
                    isLowPowerMode: isLowPowerMode,
                    isForeground: monitor.isPanelVisible,
                    frameCount: iconStyle.frameCount,
                    style: iconStyle
                )
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private var accessibilityLabel: String {
        Accessibility.menuBarLabel(items: items, states: activeStates)
    }

    private var assembled: String? {
        guard textEnabled else { return nil }
        return MenuBarText.assemble(items: items, states: activeStates)
    }

    private var items: [MenuBarItem] {
        visibilitySettings.menuItems
    }

    private var activeStates: [CardKind: MetricState] {
        let kinds = Set(items.map(\.requiredCard))
        return Dictionary(uniqueKeysWithValues:
            kinds.map { ($0, monitor.cardState($0, smoothed: powerSmoothed)) })
    }

    private var isACConnected: Bool {
        HardwarePowerSource.isACConnected()
    }

    private var isLowPowerMode: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private var kineticNotchLoad: Double? {
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

}

@MainActor
public enum MenuBarGlyph {
    private static var multiStyleCache: [String: [Int: NSImage]] = [:]

    public static func template(style: MenuBarIconStyle = .hillRunner, frame: Int, trailingPadding: CGFloat = 0.0) -> NSImage? {
        let index = min(max(frame, 0), style.frameCount - 1)
        let cacheKey = "\(style.rawValue)-\(Int(trailingPadding))"
        if let cached = multiStyleCache[cacheKey]?[index] { return cached }

        let content = HStack(spacing: 0) {
            DynamicMenuBarIconMark(style: style, frame: index, markerColor: .black)
                .frame(width: 18, height: 18)
            if trailingPadding > 0 {
                Color.clear
                    .frame(width: trailingPadding, height: 18)
            }
        }
        .foregroundStyle(.black)

        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true

        if multiStyleCache[cacheKey] == nil {
            multiStyleCache[cacheKey] = [:]
        }
        multiStyleCache[cacheKey]?[index] = image
        return image
    }

    public static func template(frame: Int) -> NSImage? {
        template(style: .hillRunner, frame: frame, trailingPadding: 0.0)
    }
}
