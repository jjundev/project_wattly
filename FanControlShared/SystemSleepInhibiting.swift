import Foundation

/// 시스템 전역 잠자기 억제(`pmset disablesleep`과 같은 `SleepDisabled` 설정)의 읽기·쓰기.
///
/// 실제 구현은 루트 데몬에만 있다(`IOPMSystemSleepInhibitor`). 앱은 비루트라 호출 자체가
/// `kIOReturnNotPrivileged`로 거부되므로 이 프로토콜을 구현하지 않는다. 코디네이터는 이 뒤에서
/// 판정만 하고, 테스트는 스파이로 대체한다.
public protocol SystemSleepInhibiting: Sendable {
    /// 현재 값. 읽기 자체가 실패하면 `nil` — "꺼져 있음"으로 오해하면 사용자가 직접 켜둔
    /// 값을 Wattly가 소유해 버리므로, 호출자는 `nil`을 `false`와 다르게 다뤄야 한다.
    func readSleepDisabled() -> Bool?
    /// 쓰기 성공 여부.
    func setSleepDisabled(_ disabled: Bool) -> Bool
}

/// 아무것도 하지 않는 기본 구현. 코디네이터 생성자의 기본값이라 기존 호출부·테스트가 그대로
/// 컴파일되고, 잠자기 억제와 무관한 테스트는 스파이를 만들 필요가 없다.
public struct NoopSystemSleepInhibitor: SystemSleepInhibiting {
    public init() {}
    public func readSleepDisabled() -> Bool? { false }
    public func setSleepDisabled(_ disabled: Bool) -> Bool { true }
}
