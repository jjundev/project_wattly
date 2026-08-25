import Foundation
import AppIntents

public struct SetBatterySailingIntent: AppIntent {
    public static let title: LocalizedStringResource = "Sailing 모드 설정"
    public static let description = IntentDescription("충전 한도 도달 후 자연 방전 허용 범위(Sailing)를 설정합니다.")

    @Parameter(title: "Sailing 활성화")
    public var enabled: Bool

    @Parameter(title: "하한 범위 (% Delta)", default: 5, inclusiveRange: (1, 10))
    public var delta: Int

    public init() {}

    public init(enabled: Bool, delta: Int = 5) {
        self.enabled = enabled
        self.delta = delta
    }

    public func perform() async throws -> some ProvidesDialog {
        guard delta >= 1 && delta <= 10 else {
            throw BatteryIntentError.invalidParameter("Sailing 범위는 1%에서 10% 사이여야 합니다.")
        }
        let bridge = BatteryIntentBridge.shared
        _ = try await bridge.applySailing(enabled: enabled, delta: delta)

        let dialogText = enabled
            ? "Sailing 모드를 켰습니다 (범위: \(delta)%)."
            : "Sailing 모드를 껐습니다."

        return .result(dialog: IntentDialog(stringLiteral: dialogText))
    }
}
