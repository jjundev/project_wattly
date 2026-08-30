import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryNotificationManagerTests {
    @Test func notificationTitleAndBodyAreLocalized() {
        let ko = Locale(identifier: "ko")
        let en = Locale(identifier: "en")

        #expect(BatteryNotificationManager.topUpCompleteTitle(locale: ko) == "한 번만 완충 완료")
        #expect(BatteryNotificationManager.topUpCompleteTitle(locale: en) == "Top Up Complete")

        #expect(BatteryNotificationManager.topUpCompleteBody(hours: 12, locale: ko)
                == "배터리가 100%까지 충전되었습니다. 어댑터를 분리하거나 12시간이 지나면 기존 충전 제한으로 자동 복귀합니다.")
        #expect(BatteryNotificationManager.topUpCompleteBody(hours: 12, locale: en)
                == "Battery is charged to 100%. It returns to your usual charge limit when you unplug, or after 12 hours.")
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

    @Test func expiryNotificationTitleAndBodyAreLocalized() {
        let ko = Locale(identifier: "ko")
        let en = Locale(identifier: "en")

        #expect(BatteryNotificationManager.topUpExpiredTitle(locale: ko) == "한 번만 완충 자동 해제")
        #expect(BatteryNotificationManager.topUpExpiredTitle(locale: en) == "Top Up Ended Automatically")

        #expect(BatteryNotificationManager.topUpExpiredBody(hours: 12, locale: ko)
                == "완충 후 12시간이 지나 기존 충전 제한으로 복귀했습니다.")
        #expect(BatteryNotificationManager.topUpExpiredBody(hours: 12, locale: en)
                == "12 hours after reaching full charge, your usual charge limit has been restored.")
    }

    @Test func expiryDetectorFiresOnceForOneExpiryRecord() {
        var detector = BatteryTopUpExpiryDetector()
        let record = BatteryMaintenanceRecord(
            trigger: .topUpExpired, result: .applied, occurredAt: 1_000, reason: nil)

        #expect(detector.update(record: record, now: 1_000) == true)
        #expect(detector.update(record: record, now: 1_005) == false)
    }

    /// 다른 유지보수 이벤트는 알림을 만들지 않는다 — 특히 사용자가 직접 취소한 경우
    /// (`.clientConfiguration`)에 "자동 해제됐다"고 말하면 거짓말이 된다.
    @Test func expiryDetectorIgnoresOtherTriggers() {
        var detector = BatteryTopUpExpiryDetector()
        #expect(detector.update(record: nil, now: 1_000) == false)
        #expect(detector.update(record: .init(trigger: .clientConfiguration, result: .applied,
                                              occurredAt: 1_000, reason: nil),
                                now: 1_000) == false)
        #expect(detector.update(record: .init(trigger: .wake, result: .verified,
                                              occurredAt: 1_000, reason: nil),
                                now: 1_000) == false)
    }

    /// 두 번째 만료는 다시 알린다.
    @Test func expiryDetectorFiresAgainForALaterExpiry() {
        var detector = BatteryTopUpExpiryDetector()
        #expect(detector.update(record: .init(trigger: .topUpExpired, result: .applied,
                                              occurredAt: 1_000, reason: nil),
                                now: 1_000) == true)
        #expect(detector.update(record: .init(trigger: .topUpExpired, result: .applied,
                                              occurredAt: 90_000, reason: nil),
                                now: 90_010) == true)
    }

    /// 앱을 나중에 켰을 때 헬퍼가 들고 있던 오래된 만료 레코드로 뒤늦은 알림이 뜨면 안 된다.
    @Test func expiryDetectorIgnoresAStaleRecordSeenAfterRelaunch() {
        var detector = BatteryTopUpExpiryDetector()
        #expect(detector.update(record: .init(trigger: .topUpExpired, result: .applied,
                                              occurredAt: 1_000, reason: nil),
                                now: 1_000 + 3_600) == false)
    }

    @Test func onlyUserActionablePausesNotify() {
        // 열보호는 스스로 풀리고, 잠자기는 사용자가 이미 알고 한 일이다.
        #expect(BatteryNotificationManager.isActionableForNotification(.needsAdapter))
        #expect(BatteryNotificationManager.isActionableForNotification(.externalChargeBlock))
        #expect(BatteryNotificationManager.isActionableForNotification(.helperUnavailable))
        #expect(BatteryNotificationManager.isActionableForNotification(.heatProtection) == false)
        #expect(BatteryNotificationManager.isActionableForNotification(.systemSleep) == false)
    }

    @Test func finishedNotificationNeverPromisesCapacityRecovery() {
        let ko = Locale(identifier: "ko")
        let completed = CalibrationHistoryEntry(
            id: UUID(), startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 37_800),
            outcome: .completed, failure: nil,
            beginMaxCapacityMilliampHours: 6208, endMaxCapacityMilliampHours: 6243,
            beginCycleCount: 112, endCycleCount: 113)
        let title = BatteryNotificationManager.calibrationFinishedTitle(completed, locale: ko)
        #expect(title == "잔량 표시 보정 완료")
        #expect(title.contains("회복") == false)
    }

    @Test func failureNotificationNamesTheReason() {
        let ko = Locale(identifier: "ko")
        let failed = CalibrationHistoryEntry(
            id: UUID(), startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: Date(timeIntervalSince1970: 100),
            outcome: .failed, failure: .stepTimeout,
            beginMaxCapacityMilliampHours: nil, endMaxCapacityMilliampHours: nil,
            beginCycleCount: nil, endCycleCount: nil)
        let body = BatteryNotificationManager.calibrationFinishedBody(failed, locale: ko)
        #expect(body.isEmpty == false)
        // 무엇 때문에 멈췄는지 말하지 않으면 사용자가 복구할 방법이 없다.
        #expect(body != BatteryNotificationManager.calibrationFinishedBody(
            CalibrationHistoryEntry(
                id: UUID(), startedAt: Date(timeIntervalSince1970: 0),
                finishedAt: Date(timeIntervalSince1970: 100),
                outcome: .failed, failure: .pauseBudgetExhausted,
                beginMaxCapacityMilliampHours: nil, endMaxCapacityMilliampHours: nil,
                beginCycleCount: nil, endCycleCount: nil),
            locale: ko))
    }

    @Test func actionNeededBodyDiffersPerPause() {
        let ko = Locale(identifier: "ko")
        #expect(BatteryNotificationManager.calibrationActionNeededBody(.needsAdapter, locale: ko)
            != BatteryNotificationManager.calibrationActionNeededBody(.externalChargeBlock, locale: ko))
    }
}

