import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryNotificationManagerTests {
    @Test func notificationTitleAndBodyAreLocalized() {
        let ko = Locale(identifier: "ko")
        let en = Locale(identifier: "en")

        #expect(BatteryNotificationManager.topUpCompleteTitle(locale: ko) == "한 번만 완충 완료")
        #expect(BatteryNotificationManager.topUpCompleteTitle(locale: en) == "Top Up Complete")

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

    @Test func scheduleTriggeredNotificationIsLocalized() {
        let ko = Locale(identifier: "ko")
        let en = Locale(identifier: "en")

        let titleKo = BatteryNotificationManager.scheduleTriggeredTitle(
            scheduleName: "출근 준비",
            actionSummary: "한 번만 100% 완충",
            locale: ko)
        let bodyKo = BatteryNotificationManager.scheduleTriggeredBody(
            scheduleName: "출근 준비",
            actionSummary: "한 번만 100% 완충",
            locale: ko)

        #expect(titleKo.contains("출근 준비") || titleKo.contains("예약 충전"))
        #expect(bodyKo.contains("한 번만 100% 완충"))

        let titleEn = BatteryNotificationManager.scheduleTriggeredTitle(
            scheduleName: "Morning Commute",
            actionSummary: "Top Up to 100%",
            locale: en)
        let bodyEn = BatteryNotificationManager.scheduleTriggeredBody(
            scheduleName: "Morning Commute",
            actionSummary: "Top Up to 100%",
            locale: en)

        #expect(titleEn.contains("Scheduled Charge") || titleEn.contains("Morning Commute"))
        #expect(bodyEn.contains("Top Up to 100%"))
    }
}

