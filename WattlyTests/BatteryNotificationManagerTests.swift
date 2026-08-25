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

    @Test func dischargeNotificationTitleAndBodyAreLocalized() {
        let ko = Locale(identifier: "ko")
        let en = Locale(identifier: "en")

        #expect(BatteryNotificationManager.dischargeCompleteTitle(locale: ko) == "방전 완료 (목표 도달)")
        #expect(BatteryNotificationManager.dischargeCompleteTitle(locale: en) == "Discharge Complete (Target Reached)")

        let bodyKo = BatteryNotificationManager.dischargeCompleteBody(target: 80, locale: ko)
        #expect(bodyKo == "목표 잔량(80%)에 도달하여 전원 어댑터 바이패스 모드로 전환되었습니다.")

        let bodyEn = BatteryNotificationManager.dischargeCompleteBody(target: 80, locale: en)
        #expect(bodyEn == "Reached target level (80%). Switched to power adapter bypass mode.")
    }

    @Test func dischargeTransitionDetectionFiresOnlyOnTransitionToComplete() {
        var detector = BatteryDischargeTransitionDetector()

        // 1. Initial manual discharge state: no notification
        #expect(detector.update(reasonKind: .dischargingManual) == false)

        // 2. Still manual discharging: no notification
        #expect(detector.update(reasonKind: .dischargingManual) == false)

        // 3. Transition to inhibitedAtLimit (holding bypass): notification FIRES
        #expect(detector.update(reasonKind: .inhibitedAtLimit) == true)

        // 4. Continued inhibited state: does not repeat
        #expect(detector.update(reasonKind: .inhibitedAtLimit) == false)

        // 5. Transition to auto discharging
        #expect(detector.update(reasonKind: .dischargingToTarget) == false)

        // 6. Transition to inhibitedAtLimit: FIRES again
        #expect(detector.update(reasonKind: .inhibitedAtLimit) == true)

        // 7. Unplugged does not trigger completion
        #expect(detector.update(reasonKind: .dischargingManual) == false)
        #expect(detector.update(reasonKind: .onBatteryPower) == false)

        // 8. Heat protection does not trigger completion
        #expect(detector.update(reasonKind: .dischargingManual) == false)
        #expect(detector.update(reasonKind: .heatProtectionActive) == false)
    }

    @Test func dischargeTransitionDetectionWithActivityAndStatus() {
        var detector = BatteryDischargeTransitionDetector()

        // Using activity directly
        #expect(detector.update(activity: .discharging) == false)
        #expect(detector.update(activity: .holdingAtLimit) == true)
        #expect(detector.update(activity: .holdingAtLimit) == false)

        // Using status
        let dischargingStatus = BatteryControlServiceStatus(
            mode: .charging,
            currentPercentage: 85,
            isPowerAdapterConnected: true,
            detail: "목표치(80%)까지 방전 중",
            updatedAt: 1.0,
            detailReason: .init(kind: .dischargingToTarget, limitPercentage: 80),
            activity: .discharging
        )
        let completeStatus = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 80,
            isPowerAdapterConnected: true,
            detail: "충전 제한 80% 도달 (전원 어댑터 바이패스 구동)",
            updatedAt: 2.0,
            detailReason: .init(kind: .inhibitedAtLimit, limitPercentage: 80),
            activity: .holdingAtLimit
        )

        var statusDetector = BatteryDischargeTransitionDetector()
        #expect(statusDetector.update(status: dischargingStatus) == false)
        #expect(statusDetector.update(status: completeStatus) == true)
        #expect(statusDetector.update(status: completeStatus) == false)
    }
}

