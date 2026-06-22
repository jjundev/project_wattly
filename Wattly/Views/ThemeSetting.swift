import SwiftUI

/// The "테마" settings control (issue 11) — the 라이트/다크/시스템 segment (prototype lines
/// 243–251). Self-contained: it writes `@AppStorage(theme)`, which `WattlyApp` reads to feed
/// both scenes' `ThemedRoot`, so a change recolors the popover and settings live with no extra
/// observer. Native segmented style for now; the prototype's custom seg-pill chrome and the
/// full settings layout land in issue 13. Temporarily mounted in the skeleton `SettingsView`.
struct ThemeSetting: View {
    @Environment(\.tokens) private var t
    @AppStorage(StorageKey.theme) private var theme: ThemeMode = Defaults.theme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("테마")
                .font(WattlyFont.at(11, weight: .bold))
                .tracking(0.33)
                .foregroundStyle(t.faint)

            Picker("테마", selection: $theme) {
                ForEach(ThemeMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }
}
