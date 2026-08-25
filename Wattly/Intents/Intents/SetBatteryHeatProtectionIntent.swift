import Foundation
import AppIntents

public struct SetBatteryHeatProtectionIntent: AppIntent {
    public static let title: LocalizedStringResource = "발열 보호 설정"
    public static let description = IntentDescription("배터리 과열 방지를 위해 임계 온도 도달 시 충전을 일시 중단합니다.")

    @Parameter(title: "발열 보호 활성화")
    public var enabled: Bool

    @Parameter(title: "임계 온도 (°C)", default: 35, inclusiveRange: (30, 45))
    public var thresholdCelsius: Int

    public init() {}

    public init(enabled: Bool, thresholdCelsius: Int = 35) {
        self.enabled = enabled
        self.thresholdCelsius = thresholdCelsius
    }

    public func perform() async throws -> some ProvidesDialog {
        guard thresholdCelsius >= 30 && thresholdCelsius <= 45 else {
            throw BatteryIntentError.invalidParameter(String(localized: "발열 보호 온도는 30°C에서 45°C 사이여야 합니다."))
        }
        let bridge = BatteryIntentBridge.shared
        _ = try await bridge.applyHeatProtection(enabled: enabled, thresholdCelsius: thresholdCelsius)

        let dialog: IntentDialog = enabled
            ? IntentDialog("발열 보호를 켰습니다 (임계 온도: \(thresholdCelsius)°C).")
            : IntentDialog("발열 보호를 껐습니다.")

        return .result(dialog: dialog)
    }
}
