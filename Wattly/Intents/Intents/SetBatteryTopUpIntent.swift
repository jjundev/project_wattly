import Foundation
import AppIntents

public struct SetBatteryTopUpIntent: AppIntent {
    public static let title: LocalizedStringResource = "한 번만 완충 (Top Up)"
    public static let description = IntentDescription("다음 외출을 위해 배터리를 100%까지 1회성으로 완전 충전합니다.")

    @Parameter(title: "완충 시작 여부 (false는 취소)", default: true)
    public var start: Bool

    public init() {}

    public init(start: Bool) {
        self.start = start
    }

    public func perform() async throws -> some ProvidesDialog {
        let bridge = BatteryIntentBridge.shared
        _ = try await bridge.applyTopUp(start: start)

        let dialogText = start
            ? "한 번만 완충을 시작했습니다 (100% 도달 후 어댑터 분리 시 원래 한도로 복귀)."
            : "한 번만 완충을 취소하고 원래 충전 한도로 복귀했습니다."

        return .result(dialog: IntentDialog(stringLiteral: dialogText))
    }
}
