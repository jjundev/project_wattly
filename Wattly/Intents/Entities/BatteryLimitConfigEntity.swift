import Foundation
import AppIntents

public struct BatteryLimitConfigEntity: TransientAppEntity, Sendable {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "배터리 충전 제한 설정"
    public static let headerTitle: LocalizedStringResource = "배터리 충전 제한 설정"

    @Property(title: "충전 제한 활성화 여부")
    public var isEnabled: Bool

    @Property(title: "최대 충전 한도 (%)")
    public var limitPercentage: Int

    @Property(title: "Sailing 모드 활성화 여부")
    public var isSailingEnabled: Bool

    @Property(title: "Sailing 범위 (%)")
    public var sailingDelta: Int

    @Property(title: "발열 보호 활성화 여부")
    public var isHeatProtectionEnabled: Bool

    @Property(title: "한 번만 완충 활성화 여부")
    public var isTopUpActive: Bool

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: isEnabled ? "\(limitPercentage)%" : "비활성화됨"
        )
    }

    public init() {
        self.isEnabled = false
        self.limitPercentage = 80
        self.isSailingEnabled = false
        self.sailingDelta = 2
        self.isHeatProtectionEnabled = false
        self.isTopUpActive = false
    }

    public init(
        isEnabled: Bool,
        limitPercentage: Int,
        isSailingEnabled: Bool,
        sailingDelta: Int,
        isHeatProtectionEnabled: Bool,
        isTopUpActive: Bool
    ) {
        self.isEnabled = isEnabled
        self.limitPercentage = limitPercentage
        self.isSailingEnabled = isSailingEnabled
        self.sailingDelta = sailingDelta
        self.isHeatProtectionEnabled = isHeatProtectionEnabled
        self.isTopUpActive = isTopUpActive
    }
}
