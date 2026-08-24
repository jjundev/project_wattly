import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryNotificationManagerTests {
    @Test func notificationTitleAndBodyAreLocalized() {
        let ko = Locale(identifier: "ko")
        let en = Locale(identifier: "en")

        #expect(BatteryNotificationManager.topUpCompleteTitle(locale: ko) == "한 번만 완충 완료")
        #expect(BatteryNotificationManager.topUpCompleteTitle(locale: en) == "One-Time Full Charge Complete")

        #expect(BatteryNotificationManager.topUpCompleteBody(locale: ko) == "배터리가 100%까지 충전되었습니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다.")
        #expect(BatteryNotificationManager.topUpCompleteBody(locale: en) == "Battery is charged to 100%. Normal limit will restore automatically when unplugged.")
    }

    @Test func transitionDetectionFiresOnlyOnTransitionToComplete() {
        var detector = BatteryTopUpTransitionDetector()

        // 1. Initial charging state: no notification
        #expect(detector.update(reasonKind: .topUpCharging) == false)

        // 2. Still charging: no notification
        #expect(detector.update(reasonKind: .topUpCharging) == false)

        // 3. Transition to complete: notification FIRES
        #expect(detector.update(reasonKind: .topUpComplete) == true)

        // 4. Continued complete state: notification does NOT repeat
        #expect(detector.update(reasonKind: .topUpComplete) == false)

        // 5. Unplugged / reset to normal limit: detector resets
        #expect(detector.update(reasonKind: .inhibitedAtLimit) == false)

        // 6. Next top up complete transition can fire again
        #expect(detector.update(reasonKind: .topUpCharging) == false)
        #expect(detector.update(reasonKind: .topUpComplete) == true)
    }
}
