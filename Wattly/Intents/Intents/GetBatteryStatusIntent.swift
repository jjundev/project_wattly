import Foundation
import AppIntents

public struct GetBatteryStatusIntent: AppIntent {
    public static let title: LocalizedStringResource = "배터리 상태 가져오기"
    public static let description = IntentDescription("현재 배터리 잔량, 충전 상태, 전력, 온도 등을 조회합니다.")

    public init() {}

    public func perform() async throws -> some ReturnsValue<BatteryStateEntity> & ProvidesDialog {
        let bridge = BatteryIntentBridge.shared
        let state = try await bridge.fetchBatteryState()

        let dialog: IntentDialog
        if let temp = state.temperatureCelsius {
            let tempString = String(format: "%.1f", temp)
            dialog = IntentDialog("현재 배터리 잔량은 \(state.percentage)%이며, 온도는 \(tempString)°C입니다.")
        } else {
            dialog = IntentDialog("현재 배터리 잔량은 \(state.percentage)%입니다.")
        }

        return .result(value: state, dialog: dialog)
    }
}
