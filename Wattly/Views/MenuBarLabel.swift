import SwiftUI
import AppKit

/// The always-present menubar item: the brand lightning glyph plus, optionally, the
/// user-selected metrics as compact text (issue 14). Clicking toggles the popover.
///
/// The text is assembled by the pure `MenuBarText` (its own per-metric format, not the
/// card's) from the `menu.<card>` selection. Turning the text off — or selecting no
/// metric — leaves the glyph alone. `monitor.cardState` is read inside `body` (via the
/// `assembled` computed property), so the always-alive label re-renders every poll as
/// the `@Observable` monitor updates.
struct MenuBarLabel: View {
    let monitor: SystemMonitor

    @AppStorage(StorageKey.menubarTextEnabled) private var textEnabled = Defaults.menubarTextEnabled
    @AppStorage(StorageKey.powerSmoothed)      private var powerSmoothed = Defaults.powerSmoothed
    @AppStorage(StorageKey.menu(.cpu))     private var menuCPU     = Defaults.menuMetrics[.cpu]     ?? false
    @AppStorage(StorageKey.menu(.power))   private var menuPower   = Defaults.menuMetrics[.power]   ?? false
    @AppStorage(StorageKey.menu(.mem))     private var menuMem     = Defaults.menuMetrics[.mem]     ?? false
    @AppStorage(StorageKey.menu(.cpuTemp)) private var menuCpuTemp = Defaults.menuMetrics[.cpuTemp] ?? false
    @AppStorage(StorageKey.menu(.gpuTemp)) private var menuGpuTemp = Defaults.menuMetrics[.gpuTemp] ?? false
    @AppStorage(StorageKey.menu(.batTemp)) private var menuBatTemp = Defaults.menuMetrics[.batTemp] ?? false

    var body: some View {
        let label = assembled
        // A MenuBarExtra label renders Image/Text reliably but NOT a live SwiftUI Shape
        // (the status item captures it as a template bitmap), so the glyph is a rasterized
        // template image; if rasterization ever fails, fall back to an SF Symbol so the
        // icon is never blank.
        let glyph = MenuBarGlyph.template.map(Image.init(nsImage:)) ?? Image(systemName: "bolt.fill")
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
    }

    /// The VoiceOver label for the status item — selected metrics in canonical order, always
    /// assembled (unlike `assembled`, which gates on `textEnabled`). "Wattly" when nothing is
    /// selected (decision A).
    private var accessibilityLabel: String {
        let states = Dictionary(uniqueKeysWithValues:
            selected.map { ($0, monitor.cardState($0, smoothed: powerSmoothed)) })
        return Accessibility.menuBarLabel(selected: selected, states: states)
    }

    /// The composed menubar string, or nil → icon only (text off, or no metric selected).
    /// Power reads the smoothed card value when `powerSmoothed` is on; `smoothed:` is a
    /// no-op for the other menu metrics (the `isSmoothable` guard), so the call is uniform.
    private var assembled: String? {
        guard textEnabled else { return nil }
        let states = Dictionary(uniqueKeysWithValues:
            selected.map { ($0, monitor.cardState($0, smoothed: powerSmoothed)) })
        return MenuBarText.assemble(selected: selected, states: states)
    }

    /// Selected menubar metrics, from the per-chip flags (mirrors the settings grid).
    private var selected: Set<CardKind> {
        var s = Set<CardKind>()
        if menuCPU     { s.insert(.cpu) }
        if menuPower   { s.insert(.power) }
        if menuMem     { s.insert(.mem) }
        if menuCpuTemp { s.insert(.cpuTemp) }
        if menuGpuTemp { s.insert(.gpuTemp) }
        if menuBatTemp { s.insert(.batTemp) }
        return s
    }
}

/// The brand lightning mark rasterized once to a template `NSImage` for the menubar.
/// `LightningGlyph` is the pixel-faithful prototype polygon (stroked, prototype line 53);
/// rendering it to a template image (rather than drawing the `Shape` live in the label)
/// is what makes it actually appear in the status bar and tint for light/dark + the
/// open-panel highlight. Built lazily on the main actor, cached for the process.
@MainActor
enum MenuBarGlyph {
    static let template: NSImage? = render()

    private static func render() -> NSImage? {
        let renderer = ImageRenderer(content:
            LightningGlyph()
                .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .frame(width: 13, height: 13)
                .padding(1.5)                 // keep the stroke off the bitmap edge
                .foregroundStyle(.black))     // template ⇒ only the alpha mask matters
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true               // let the menubar tint it (light/dark + highlight)
        return image
    }
}
