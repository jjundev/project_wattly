import SwiftUI

/// The always-present menubar item: a template lightning glyph plus, by default,
/// the CPU metric as text (plan README — default menubar metric is CPU). The full
/// multi-metric assembly is issue 14.
struct MenuBarLabel: View {
    let monitor: SystemMonitor
    @AppStorage(StorageKey.menubarTextEnabled) private var textEnabled = Defaults.menubarTextEnabled

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
            if textEnabled {
                Text(cpuText)
            }
        }
        .accessibilityLabel("Wattly\(textEnabled ? " · " + cpuText : "")")
    }

    private var cpuText: String {
        // Reuse the card's presentation rules (rounding/format) — the menubar just
        // composes them into its compact form; "CPU 42%" / "CPU —" preserved.
        let state = monitor.cardState(.cpu)
        let d = CardPresentation.display(.cpu, state)
        if case .value = state { return "\(d.label) \(d.valueText)\(d.unitText)" }
        return "\(d.label) \(d.valueText)"
    }
}
