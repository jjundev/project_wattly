import SwiftUI
import AppKit

/// The always-present menubar item: the Kinetic Notch glyph plus, optionally, the
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
    @State private var kineticNotchPhase = 0
    @AppStorage(StorageKey.menubarTextEnabled) private var textEnabled = Defaults.menubarTextEnabled
    @AppStorage(StorageKey.powerSmoothed)      private var powerSmoothed = Defaults.powerSmoothed
    @AppStorage(StorageKey.kineticNotchMotionEnabled) private var kineticNotchMotionEnabled = Defaults.kineticNotchMotionEnabled
    @AppStorage(StorageKey.kineticNotchSource) private var kineticNotchSource = Defaults.kineticNotchSource
    @AppStorage(StorageKey.kineticNotchSpeed) private var kineticNotchSpeed = Defaults.kineticNotchSpeed

    var body: some View {
        let label = assembled
        // A MenuBarExtra label renders Image/Text reliably but NOT a live SwiftUI Shape
        // (the status item captures it as a template bitmap), so the glyph is a rasterized
        // template image; if rasterization ever fails, fall back to an SF Symbol so the
        // icon is never blank.
        let glyph = MenuBarGlyph.template(frame: kineticNotchFrame).map(Image.init(nsImage:)) ?? Image(systemName: "waveform.path")
        return HStack(spacing: 4) {
            glyph
            if let label {
                Text(label)
                    .font(WattlyFont.at(11, weight: .semibold))
                    .monospacedDigit()
            }
        }
        // a11y label is computed from the selection REGARDLESS of `textEnabled` (issue 15 §1):
        // a VoiceOver user hears the selected metrics even when the visible text is off; an
        // empty selection reads just "Wattly" (decision A). Reuses the #14 assembler so the
        // spoken copy matches the menubar text exactly.
        // NOTE: MenuBarExtra renders this label as an NSStatusItem, so this SwiftUI
        // `.accessibilityLabel` may not surface to VoiceOver — verify on-device; if it does
        // not announce, set the status button's accessibility label via AppKit (issue 15 §메모).
        .accessibilityLabel(accessibilityLabel)
        .task(id: "\(kineticNotchMotionEnabled)-\(kineticNotchSource.rawValue)-\(kineticNotchSpeed.rawValue)-\(reduceMotion)-\(kineticNotchFrameRate ?? 0)") {
            guard let frameRate = kineticNotchFrameRate else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1 / frameRate))
                guard !Task.isCancelled else { return }
                kineticNotchPhase = (kineticNotchPhase + 1) % KineticNotchMotion.frameCount
            }
        }
    }

    /// The VoiceOver label for the status item — selected metrics in canonical order, always
    /// assembled (unlike `assembled`, which gates on `textEnabled`). "Wattly" when nothing is
    /// selected (decision A).
    private var accessibilityLabel: String {
        Accessibility.menuBarLabel(items: items, states: activeStates)
    }

    /// The composed menubar string, or nil → icon only (text off, or no metric selected).
    /// Power reads the smoothed card value when `powerSmoothed` is on; `smoothed:` is a
    /// no-op for the other menu metrics (the `isSmoothable` guard), so the call is uniform.
    private var assembled: String? {
        guard textEnabled else { return nil }
        return MenuBarText.assemble(items: items, states: activeStates)
    }

    /// Selected menubar items in canonical order.
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

    private var kineticNotchFrame: Int {
        KineticNotchMotion.displayedFrame(load: kineticNotchLoad ?? 0, phase: kineticNotchPhase,
                                          reduceMotion: reduceMotion || !kineticNotchMotionEnabled)
    }

    private var kineticNotchFrameRate: Double? {
        guard kineticNotchMotionEnabled, !reduceMotion, let kineticNotchLoad else { return nil }
        return KineticNotchMotion.frameRate(load: kineticNotchLoad, speed: kineticNotchSpeed)
    }

}

/// Kinetic Notch frames rasterized once each as template `NSImage`s for the menubar.
/// Rendering the `Shape` to template images (rather than drawing it live in the label)
/// is what makes it actually appear in the status bar and tint for light/dark + the
/// open-panel highlight. Built lazily on the main actor, cached for the process.
@MainActor
enum MenuBarGlyph {
    static var templates = Array<NSImage?>(repeating: nil, count: KineticNotchMotion.frameCount)

    static func template(frame: Int) -> NSImage? {
        let index = min(max(frame, 0), KineticNotchMotion.frameCount - 1)
        if let image = templates[index] { return image }
        let renderer = ImageRenderer(content: KineticNotchMark(frame: index, markerColor: .black)
            .frame(width: 16, height: 14)
            .padding(1.5)
            .foregroundStyle(.black))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        templates[index] = image
        return image
    }
}
