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
        if case .value(.cpu(let s)) = monitor.cardState(.cpu) {
            return "CPU \(Int(s.overall.rounded()))%"
        }
        return "CPU —"
    }
}
