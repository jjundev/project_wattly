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
    @State private var dynamicIconPhase = 0
    @AppStorage(StorageKey.menubarTextEnabled) private var textEnabled = Defaults.menubarTextEnabled
    @AppStorage(StorageKey.powerSmoothed)      private var powerSmoothed = Defaults.powerSmoothed
    @AppStorage(StorageKey.kineticNotchMotionEnabled) private var kineticNotchMotionEnabled = Defaults.kineticNotchMotionEnabled
    @AppStorage(StorageKey.kineticNotchSource) private var kineticNotchSource = Defaults.kineticNotchSource
    @AppStorage(StorageKey.kineticNotchSpeed) private var kineticNotchSpeed = Defaults.kineticNotchSpeed
    @AppStorage(StorageKey.menubarIconStyle) private var iconStyle = Defaults.menubarIconStyle

    var body: some View {
        let label = assembled
        let glyph = MenuBarGlyph.template(style: iconStyle, frame: currentFrame).map(Image.init(nsImage:)) ?? Image(systemName: "waveform.path")
        return HStack(spacing: 4) {
            glyph
            if let label {
                Text(label)
                    .font(WattlyFont.at(11, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .task(id: "\(iconStyle.rawValue)-\(kineticNotchMotionEnabled)-\(kineticNotchSource.rawValue)-\(kineticNotchSpeed.rawValue)-\(reduceMotion)-\(dynamicIconFrameRate ?? 0)") {
            guard let frameRate = dynamicIconFrameRate else { return }
            while !Task.isCancelled {
                let phase = dynamicIconPhase
                let delay = MenuBarIconMotion.frameDelay(style: iconStyle, phase: phase, frameRate: frameRate)
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                dynamicIconPhase = (phase + 1) % iconStyle.frameCount
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

    private var kineticNotchLoad: Double? {
        let cpu: Double?
        if case .value(.cpu(let sample)) = monitor.cardState(.cpu) {
            cpu = sample.overall
        } else {
            cpu = nil
        }

        let gpu: Double?
        if case .value(.gpu(let sample)) = monitor.cardState(.gpu) {
            gpu = sample.overall
        } else {
            gpu = nil
        }
        return kineticNotchSource.load(cpu: cpu, gpu: gpu)
    }

    private var currentFrame: Int {
        MenuBarIconMotion.displayedFrame(
            style: iconStyle,
            phase: dynamicIconPhase,
            reduceMotion: reduceMotion || dynamicIconFrameRate == nil
        )
    }

    private var dynamicIconFrameRate: Double? {
        guard kineticNotchMotionEnabled, !reduceMotion, let kineticNotchLoad else { return nil }
        return MenuBarIconMotion.frameRate(load: kineticNotchLoad, speed: kineticNotchSpeed)
    }
}

@MainActor
public enum MenuBarGlyph {
    private static var multiStyleCache: [MenuBarIconStyle: [Int: NSImage]] = [:]

    public static func template(style: MenuBarIconStyle = .turbine, frame: Int) -> NSImage? {
        let index = min(max(frame, 0), style.frameCount - 1)
        if let cached = multiStyleCache[style]?[index] { return cached }

        let renderer = ImageRenderer(content:
            DynamicMenuBarIconMark(style: style, frame: index, markerColor: .black)
                .frame(width: 18, height: 18)
                .foregroundStyle(.black)
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true

        if multiStyleCache[style] == nil {
            multiStyleCache[style] = [:]
        }
        multiStyleCache[style]?[index] = image
        return image
    }

    public static func template(frame: Int) -> NSImage? {
        template(style: .turbine, frame: frame)
    }
}
