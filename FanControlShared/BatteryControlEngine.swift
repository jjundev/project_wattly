import Foundation

public protocol BatteryControlHardwareProtocol: Sendable {
    var isAppleSilicon: Bool { get }
    func setChargingInhibited(_ inhibited: Bool, targetLimit: Int) -> Bool
}

public final class BatteryControlEngine: @unchecked Sendable {
    private let hardware: BatteryControlHardwareProtocol
    private var config: BatteryControlConfiguration
    private var isCurrentlyInhibited: Bool = false
    private var hasInitializedState: Bool = false
    private var lastTargetLimit: Int = 100

    public init(hardware: BatteryControlHardwareProtocol, initialConfig: BatteryControlConfiguration = .init()) {
        self.hardware = hardware
        self.config = initialConfig
    }

    public func configure(_ newConfig: BatteryControlConfiguration) {
        if self.config.enabled && !newConfig.enabled && isCurrentlyInhibited {
            _ = hardware.setChargingInhibited(false, targetLimit: 100)
            isCurrentlyInhibited = false
        }
        self.config = newConfig
    }

    public func update(currentSoC: Int, isPluggedIn: Bool) -> BatteryControlServiceStatus {
        guard config.enabled && isPluggedIn else {
            if isCurrentlyInhibited || !hasInitializedState {
                _ = hardware.setChargingInhibited(false, targetLimit: 100)
                isCurrentlyInhibited = false
                hasInitializedState = true
            }
            return BatteryControlServiceStatus(
                mode: .charging,
                currentPercentage: currentSoC,
                isPowerAdapterConnected: isPluggedIn,
                detail: config.enabled ? "배터리 전원으로 구동 중" : "충전 제한 비활성화됨",
                updatedAt: Date().timeIntervalSince1970
            )
        }

        hasInitializedState = true
        let target = config.clampedLimitPercentage
        let resume = config.resumePercentage

        if isCurrentlyInhibited {
            if currentSoC <= resume {
                // Resume charging
                _ = hardware.setChargingInhibited(false, targetLimit: 100)
                isCurrentlyInhibited = false
            }
        } else {
            if currentSoC >= target {
                // Inhibit charging (AC passthrough)
                _ = hardware.setChargingInhibited(true, targetLimit: target)
                isCurrentlyInhibited = true
                lastTargetLimit = target
            }
        }

        let mode: BatteryControlServiceMode = isCurrentlyInhibited ? .inhibited : .charging
        let detail = isCurrentlyInhibited
            ? "충전 제한 \(target)% 도달 (전원 어댑터 바이패스 구동)"
            : "목표치(\(target)%)까지 충전 중"

        return BatteryControlServiceStatus(
            mode: mode,
            currentPercentage: currentSoC,
            isPowerAdapterConnected: isPluggedIn,
            detail: detail,
            updatedAt: Date().timeIntervalSince1970
        )
    }

    public func release() {
        if isCurrentlyInhibited {
            _ = hardware.setChargingInhibited(false, targetLimit: 100)
            isCurrentlyInhibited = false
        }
    }
}
