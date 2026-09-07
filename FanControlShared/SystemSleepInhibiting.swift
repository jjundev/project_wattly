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
///
/// `readSleepDisabled()`가 `false`가 아니라 `nil`을 돌려주는 것이 핵심이다: `.engage`로 켜기
/// 직전의 가드(`sleepInhibitor.readSleepDisabled() == false`)는 정확히 `false`일 때만 통과한다.
/// 이 타입이 `false`를 보고하면 아무것도 지시하지 않았는데도 가드가 통과해, 이 타입으로 지은
/// 코디네이터가 실제 시스템 잠자기는 하나도 억제하지 않은 채 진짜 정책 파일에 소유 마커를 쓰고
/// `isSystemSleepInhibited == true`를 보고하게 된다. `nil`("모름")로 답하면 가드가 구조적으로
/// 막힌다 — 이 타입으로는 `.engage`에 절대 도달할 수 없다.
public struct NoopSystemSleepInhibitor: SystemSleepInhibiting {
    public init() {}
    public func readSleepDisabled() -> Bool? { nil }
    public func setSleepDisabled(_ disabled: Bool) -> Bool { true }
}
