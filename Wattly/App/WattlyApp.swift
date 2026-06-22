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
        // TEMP: faster refresh (1s instead of the 2s default) to eyeball live values.
        // Revert by dropping `interval:` (back to the .seconds(2) default) once the
        // PollInterval setting is wired in (plan 09).
        _monitor = State(initialValue: SystemMonitor(providers: FakeProviders.all(scenario: scenario),
                                                     interval: .seconds(1)))
    }

    var body: some Scene {
        MenuBarExtra {
            ThemedRoot(theme: theme) {
                PopoverContentView(monitor: monitor)
            }
        } label: {
            MenuBarLabel(monitor: monitor)
                .task { monitor.start() }   // begin polling at launch
        }
        .menuBarExtraStyle(.window)

        Settings {
            ThemedRoot(theme: theme) {
                SettingsView()
            }
        }
    }
}
