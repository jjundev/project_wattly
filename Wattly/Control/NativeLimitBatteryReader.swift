import Foundation
import IOKit
import IOKit.ps

/// 네이티브 백엔드가 한 요청에 필요한 세 가지 — 잔량 %, 어댑터 연결, 배터리 전류 — 를 읽는다.
///
/// 어댑터 판정은 도우미(`WattlyFanDaemon/FanControlDaemon.swift`의 `readPowerSourceState`)와
/// 같은 OR 규칙이다: IOPS가 AC라고 하거나, 레지스트리가 `ExternalConnected`라고 하거나,
/// `AdapterDetails.Watts > 0`이면 연결이다. 전류는 레지스트리 `InstantAmperage`(macOS 27에도
/// 남아 있음, +충전/−방전)를 쓴다 — 음수는 부호 없는 64비트로 인코딩돼 오므로 `int64Value`로
/// 되돌린다.
enum NativeLimitBatteryReader {
    static func read() -> NativeLimitBatteryReading? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(snapshot, $0)?.takeUnretainedValue() as? [String: Any]
        }
        // 내장 배터리가 없으면(데스크톱) 읽을 것이 없다.
        guard let battery = descriptions.first(where: {
            ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
        }) else { return nil }

        var externalConnected: Bool?
        var adapterWatts: Int?
        var instantAmperage: Int?
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            externalConnected = property(service, "ExternalConnected") as? Bool
            adapterWatts = ((property(service, "AdapterDetails") as? [String: Any])?["Watts"] as? NSNumber)?.intValue
            instantAmperage = (property(service, "InstantAmperage") as? NSNumber).map { Int($0.int64Value) }
        }

        return reading(
            currentCapacity: battery[kIOPSCurrentCapacityKey] as? Int ?? 0,
            maxCapacity: battery[kIOPSMaxCapacityKey] as? Int ?? 100,
            isACPower: (battery[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue,
            externalConnected: externalConnected,
            adapterWatts: adapterWatts,
            instantAmperage: instantAmperage)
    }

    /// I/O 없는 조립. 테스트가 보는 것은 이 함수다.
    static func reading(
        currentCapacity: Int,
        maxCapacity: Int,
        isACPower: Bool,
        externalConnected: Bool?,
        adapterWatts: Int?,
        instantAmperage: Int?
    ) -> NativeLimitBatteryReading {
        let percentage = maxCapacity > 0
            ? Int((Double(currentCapacity) / Double(maxCapacity) * 100.0).rounded())
            : currentCapacity
        let isPluggedIn = isACPower || externalConnected == true || (adapterWatts ?? 0) > 0
        return NativeLimitBatteryReading(
            percentage: percentage,
            isPluggedIn: isPluggedIn,
            batteryMilliamps: instantAmperage)
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
