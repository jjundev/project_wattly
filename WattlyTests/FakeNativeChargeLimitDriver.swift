import Foundation
@testable import Wattly

/// 네이티브 제한을 흉내 내는 테스트 더블. 실측 거동을 그대로 옮겼다: 목록 밖 값은 Code 4로
/// 거부, 100은 스스로 꺼짐, 일시 해제 중 제한은 100으로 가려진다.
final class FakeNativeChargeLimitDriver: NativeChargeLimitDriving, @unchecked Sendable {
    var isSupported = true
    var limits = [80, 85, 90, 95, 100]
    var current = NativeLimitSnapshot(limit: 100, state: .off)
    var writes: [String] = []
    var failWrites = false
    var failReads = false

    func availableLimits() throws -> [Int] {
        if failReads { throw NativeChargeLimitError.unavailable }
        return limits
    }

    func snapshot() throws -> NativeLimitSnapshot {
        if failReads { throw NativeChargeLimitError.unavailable }
        return current
    }

    func setLimit(_ percentage: Int) throws {
        if failWrites { throw NativeChargeLimitError.callFailed(selector: "setMCLLimit:error:", code: 1) }
        guard limits.contains(percentage) else {
            throw NativeChargeLimitError.callFailed(selector: "setMCLLimit:error:", code: 4)
        }
        writes.append("set:\(percentage)")
        current = .init(limit: percentage, state: percentage >= 100 ? .off : .on)
    }

    func temporarilyDisable() throws {
        if failWrites { throw NativeChargeLimitError.callFailed(selector: "temporarilyDisableMCL:", code: 1) }
        writes.append("tempDisable")
        current = .init(limit: 100, state: .temporarilyDisabled)
    }
}
