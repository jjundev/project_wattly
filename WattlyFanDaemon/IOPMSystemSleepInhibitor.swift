import Foundation
import IOKit

// IOPMLibPrivate.h의 비공개 심볼. `pmset -a disablesleep`이 내부에서 부르는 것과 같은 함수다.
// 이 Mac(macOS 26.6.2)에서 루트만으로 성공하고 1.5초 안에 `pmset -g`·`ioreg`의 `SleepDisabled`에
// 반영됨을 2026-09-07 실측했다. 비루트는 `kIOReturnNotPrivileged`(0xE00002C1)로 거부된다.
// 별도 Swift 이름을 쓰는 이유는 `MemoryProvider`의 `memorystatus_get_level`과 같다 — 미래 SDK가
// 같은 심볼을 import해도 가리지 않도록.
@_silgen_name("IOPMSetSystemPowerSetting")
private func wattly_IOPMSetSystemPowerSetting(_ key: CFString, _ value: CFTypeRef) -> IOReturn

@_silgen_name("IOPMCopySystemPowerSettings")
private func wattly_IOPMCopySystemPowerSettings() -> Unmanaged<CFDictionary>?

/// 시스템 전역 `SleepDisabled`(`pmset -g`의 "System-wide power settings")의 읽기·쓰기.
/// 재부팅을 넘어 남는 설정이므로 이 타입은 판단하지 않는다 — 언제 켜고 끌지는 전부
/// `BatteryControlCoordinator`와 `BatteryClamshellSleepPolicy`의 몫이다.
struct IOPMSystemSleepInhibitor: SystemSleepInhibiting {
    static let key = "SleepDisabled"

    func readSleepDisabled() -> Bool? {
        guard let dictionary = wattly_IOPMCopySystemPowerSettings()?.takeRetainedValue()
                as? [String: Any] else { return nil }
        // 키가 아예 없으면 macOS 기본값(꺼짐)이다 — 실측에서는 항상 0/1로 존재했다.
        guard let raw = dictionary[Self.key] else { return false }
        if let number = raw as? NSNumber { return number.boolValue }
        return nil
    }

    func setSleepDisabled(_ disabled: Bool) -> Bool {
        let value: CFBoolean = disabled ? kCFBooleanTrue : kCFBooleanFalse
        return wattly_IOPMSetSystemPowerSetting(Self.key as CFString, value) == kIOReturnSuccess
    }
}
