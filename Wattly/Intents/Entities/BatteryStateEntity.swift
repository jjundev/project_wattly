import Foundation
import AppIntents

public struct BatteryStateEntity: TransientAppEntity, Sendable {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "배터리 상태"
    public static let headerTitle: LocalizedStringResource = "배터리 상태"

    @Property(title: "배터리 잔량 (%)")
    public var percentage: Int

    @Property(title: "충전 중 여부")
    public var isCharging: Bool

    @Property(title: "전원 어댑터 연결 여부")
    public var isPowerAdapterConnected: Bool

    @Property(title: "배터리 온도 (°C)")
    public var temperatureCelsius: Double?

    @Property(title: "순 소비 전력 (W)")
    public var netWatts: Double?

    @Property(title: "남은 사용/충전 시간 (분)")
    public var timeRemainingMinutes: Int?

    @Property(title: "배터리 수명/효율 (%)")
    public var healthPercentage: Int?

    public var displayRepresentation: DisplayRepresentation {
        let subtitle: LocalizedStringResource = isCharging
            ? "충전 중"
            : (isPowerAdapterConnected ? "전원 연결됨" : "배터리 사용 중")
        return DisplayRepresentation(
            title: "\(percentage)%",
            subtitle: subtitle
        )
    }

    public init() {
        self.percentage = 0
        self.isCharging = false
        self.isPowerAdapterConnected = false
        self.temperatureCelsius = nil
        self.netWatts = nil
        self.timeRemainingMinutes = nil
        self.healthPercentage = nil
    }

    public init(
        percentage: Int,
        isCharging: Bool,
        isPowerAdapterConnected: Bool,
        temperatureCelsius: Double? = nil,
        netWatts: Double? = nil,
        timeRemainingMinutes: Int? = nil,
        healthPercentage: Int? = nil
    ) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.isPowerAdapterConnected = isPowerAdapterConnected
        self.temperatureCelsius = temperatureCelsius
        self.netWatts = netWatts
        self.timeRemainingMinutes = timeRemainingMinutes
        self.healthPercentage = healthPercentage
    }
}
