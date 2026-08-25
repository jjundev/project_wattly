import Foundation
import AppIntents

public struct WattlyShortcuts: AppShortcutsProvider {
    public static var shortcutTileColor: ShortcutTileColor {
        .orange
    }

    @AppShortcutsBuilder
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetBatteryStatusIntent(),
            phrases: [
                "\(.applicationName)에서 배터리 상태 확인",
                "\(.applicationName) 배터리 상태",
                "Get battery status in \(.applicationName)"
            ],
            shortTitle: "배터리 상태",
            systemImageName: "battery.100.bolt"
        )
        AppShortcut(
            intent: SetBatteryTopUpIntent(start: true),
            phrases: [
                "\(.applicationName)에서 완충 시작",
                "\(.applicationName) 한 번만 완충",
                "Top Up battery in \(.applicationName)"
            ],
            shortTitle: "한 번만 완충 시작",
            systemImageName: "bolt.fill"
        )
        AppShortcut(
            intent: SetBatteryLimitEnabledIntent(enabled: true),
            phrases: [
                "\(.applicationName) 충전 제한 켜기",
                "Turn on battery limit in \(.applicationName)"
            ],
            shortTitle: "충전 제한 켜기",
            systemImageName: "battery.75"
        )
    }
}
