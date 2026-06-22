import SwiftUI

/// Agent app (LSUIElement, no Dock icon): a `MenuBarExtra` in `.window` style plus
/// an empty `Settings` scene. One `SystemMonitor` is shared by both.
@main
struct WattlyApp: App {
    @State private var monitor: SystemMonitor
    @AppStorage(StorageKey.theme) private var theme = Defaults.theme

    init() {
        FontRegistration.register()   // bundle Pretendard before any view renders (A17)
        #if DEBUG
        ThermalProbe.runIfRequested()  // -WattlyThermalProbe: dump live temps and exit (plan 08 Phase 0)
        #endif
        // CPU/memory/power/battery/temperature are all real providers now; the dev
        // `-WattlyScenario` harness shapes only the remaining fault/desktop-demo fakes.
        let scenario = Scenario.fromLaunchArguments()
        // Cadence is adaptive now (issue 09): `PollPolicyBridge` seeds the user's PollInterval
        // setting + starts the loop, which runs at 1 s open / 2–5 s closed under `.auto`.
        _monitor = State(initialValue: SystemMonitor(providers: FakeProviders.all(scenario: scenario)))
    }

    var body: some Scene {
        MenuBarExtra {
            ThemedRoot(theme: theme) {
                PopoverContentView(monitor: monitor)
            }
        } label: {
            MenuBarLabel(monitor: monitor)
                // The bridge is always alive (the label never unmounts), so it owns seeding
                // the poll policy AND starting the loop — start() lives here, nowhere else.
                .background(PollPolicyBridge(monitor: monitor))
        }
        .menuBarExtraStyle(.window)

        Settings {
            ThemedRoot(theme: theme) {
                SettingsView()
            }
        }
    }
}
