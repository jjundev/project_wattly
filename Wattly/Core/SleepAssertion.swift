import Foundation
import IOKit.pwr_mgt

/// idle sleep을 막는 `IOPMAssertion` RAII 래퍼. 캘리브레이션의 **방전 단계에서만** 잡는다.
///
/// 근거는 실측이다: clamshell sleep 602초 동안 SoC가 −0.01%p 움직였다 — 깨어 있었으면
/// −2.37%p였을 구간이다. 강제 방전은 자면 사실상 정지하므로, 7시간짜리 방전 단계는 깨워
/// 둬야 끝난다. 충전·안정화 단계는 자도 진행되므로(15분에 +11%p) 여기서 assertion을 잡지
/// 않는다 — 전 과정 sleep 차단은 참조 구현이 사용자 이탈을 겪은 지점이다.
///
/// **뚜껑 닫힘은 이걸로 못 막는다.** `PreventUserIdleSystemSleep`은 lid close를 막지 않고,
/// 실기에서 `caffeinate -i`가 살아 있는 채로도 뚜껑을 닫자 잠겼다. 그래서 FSM은 sleep을
/// 감지해 `paused(systemSleep)`로 전환하고, 안내 문구도 "화면은 꺼져도 되지만 방전 구간
/// 약 7시간 동안은 뚜껑을 열어 두세요"다.
///
/// 생성·해제를 주입받는 이유는 테스트 때문이다. `IOPMAssertionCreateWithName`은 단위
/// 테스트에서 실제 전원 관리 상태를 건드리므로 더블로 대체할 수 있어야 한다.
final class SleepAssertion: @unchecked Sendable {
    typealias Creator = @Sendable (String) -> UInt32?
    typealias Releaser = @Sendable (UInt32) -> Void

    private let create: Creator
    private let releaseAssertion: Releaser
    private let lock = NSLock()
    private var identifier: UInt32?

    init(
        create: @escaping Creator = SleepAssertion.systemCreate,
        release: @escaping Releaser = SleepAssertion.systemRelease
    ) {
        self.create = create
        self.releaseAssertion = release
    }

    var isHeld: Bool {
        lock.lock(); defer { lock.unlock() }
        return identifier != nil
    }

    func acquire(reason: String) {
        lock.lock(); defer { lock.unlock() }
        guard identifier == nil else { return }
        identifier = create(reason)
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        guard let identifier else { return }
        releaseAssertion(identifier)
        self.identifier = nil
    }

    deinit {
        // 잠금 없이 읽는다: deinit 시점에는 이 인스턴스를 참조하는 다른 스레드가 없다.
        if let identifier { releaseAssertion(identifier) }
    }

    static let systemCreate: Creator = { reason in
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id)
        guard result == kIOReturnSuccess else { return nil }
        return UInt32(id)
    }

    static let systemRelease: Releaser = { id in
        IOPMAssertionRelease(IOPMAssertionID(id))
    }
}
