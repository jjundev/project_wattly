import Foundation
import AppIntents

public struct SetBatteryLimitIntent: AppIntent {
    public static let title: LocalizedStringResource = "충전 한도 설정"
    public static let description = IntentDescription("배터리 최대 충전 한도(%)를 설정하고 충전 제한을 적용합니다.")

    @Parameter(title: "충전 한도 (%)", default: 80, inclusiveRange: (50, 100))
    public var limit: Int

    @Parameter(title: "충전 제한 활성화", default: true)
    public var enableLimit: Bool

    public init() {}

    public init(limit: Int, enableLimit: Bool = true) {
        self.limit = limit
        self.enableLimit = enableLimit
    }

    public func perform() async throws -> some ProvidesDialog {
        guard limit >= 50 && limit <= 100 else {
            throw BatteryIntentError.invalidParameter(String(localized: "충전 한도는 50%에서 100% 사이여야 합니다."))
        }
        let bridge = BatteryIntentBridge.shared
        _ = try await bridge.applyLimit(enabled: enableLimit, limitPercentage: limit)

        let dialog: IntentDialog = enableLimit
            ? IntentDialog("배터리 충전 한도를 \(limit)%로 설정했습니다.")
            : IntentDialog("배터리 충전 한도를 \(limit)%로 변경하고 비활성화했습니다.")

        return .result(dialog: dialog)
    }
}
