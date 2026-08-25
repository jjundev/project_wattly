import Foundation
import AppIntents

public struct GetBatteryLimitIntent: AppIntent {
    public static let title: LocalizedStringResource = "충전 제한 설정 가져오기"
    public static let description = IntentDescription("현재 설정된 배터리 충전 한도 및 Sailing 모드 상태를 조회합니다.")

    public init() {}

    public func perform() async throws -> some ReturnsValue<BatteryLimitConfigEntity> & ProvidesDialog {
        let bridge = BatteryIntentBridge.shared
        let config = try await bridge.fetchLimitConfig()

        let statusText = config.isEnabled ? "\(config.limitPercentage)%로 설정됨" : "비활성화됨"
        let dialogText = "배터리 충전 제한이 \(statusText)."

        return .result(value: config, dialog: IntentDialog(stringLiteral: dialogText))
    }
}
