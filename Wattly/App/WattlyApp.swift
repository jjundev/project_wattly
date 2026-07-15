import SwiftUI

/// Agent app (LSUIElement, no Dock icon): a `MenuBarExtra` in `.window` style plus
/// an empty `Settings` scene. One `SystemMonitor` is shared by both.
@main
struct WattlyApp: App {
    @State private var monitor: SystemMonitor
    @State private var fanControl = FanControlClient()

    init() {
        FontRegistration.register()   // bundle Pretendard before any view renders (A17)
        #if DEBUG
        ThermalProbe.runIfRequested()  // -WattlyThermalProbe: dump live temps and exit (plan 08 Phase 0)
        FanProbe.runIfRequested()      // -WattlyFanProbe: dump live fan RPM and exit (Phase A Phase 0)
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
            ThemedRoot {
                PopoverContentView(monitor: monitor)
            }
        } label: {
            MenuBarLabel(monitor: monitor)
                // The bridge is always alive (the label never unmounts), so it owns seeding
                // the poll policy AND starting the loop — start() lives here, nowhere else.
                .background(PollPolicyBridge(monitor: monitor))
                // The fan bridge is likewise always mounted. Closing a Settings window must
                // never release control; only disabling the persisted opt-in may do that.
                .background(FanControlBridge(client: fanControl))
        }
        .menuBarExtraStyle(.window)

        Settings {
            ThemedRoot {
                SettingsView(monitor: monitor, fanControl: fanControl)
            }
        }
        // Lock the prefs window to its 440-wide content (issue 13 §1) — a Settings NSWindow
        // is user-resizable by default, which would break the fixed-width layout.
        .windowResizability(.contentSize)
    }
}
