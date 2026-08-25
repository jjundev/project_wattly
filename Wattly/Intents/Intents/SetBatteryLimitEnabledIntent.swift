import Foundation
import AppIntents

public struct SetBatteryLimitEnabledIntent: AppIntent {
    public static let title: LocalizedStringResource = "충전 제한 켜기/끄기"
    public static let description = IntentDescription("배터리 충전 제한 기능을 켜거나 끕니다.")

    @Parameter(title: "활성화 여부")
    public var enabled: Bool

    public init() {}

    public init(enabled: Bool) {
        self.enabled = enabled
    }

    public func perform() async throws -> some ProvidesDialog {
        let bridge = BatteryIntentBridge.shared
        _ = try await bridge.applyLimit(enabled: enabled)

        let dialog: IntentDialog = enabled
            ? IntentDialog("배터리 충전 제한을 켰습니다.")
            : IntentDialog("배터리 충전 제한을 껐습니다.")
        return .result(dialog: dialog)
    }
}
