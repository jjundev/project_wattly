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

    /// 배너 제목/본문은 이미 로케일을 받고 있었지만, 그 안에 끼워 넣는 `actionSummary`가
    /// 코디네이터에서 한국어로 굳어 오고 있었다. 코디네이터가 지금 넘기는 것과 같은 방식으로
    /// — `ScheduleAction.summary(locale:)`로 — 조립했을 때 본문 전체가 그 언어인지 본다.
    @Test func scheduleTriggeredBodyCarriesLocalizedActionSummary() {
        func body(_ action: ScheduleAction, _ identifier: String) -> String {
            let locale = Locale(identifier: identifier)
            return BatteryNotificationManager.scheduleTriggeredBody(
                scheduleName: "",
                actionSummary: action.summary(locale: locale),
                locale: locale)
        }

        #expect(body(.setLimit(percentage: 80), "ko") == "설정된 작업이 실행되었습니다: 충전 한도 80%")
        #expect(body(.setLimit(percentage: 80), "en") == "Scheduled action executed: Charge Limit 80%")
        #expect(body(.startTopUp, "en") == "Scheduled action executed: Top Up to 100%")
        #expect(body(.pauseCharging, "en") == "Scheduled action executed: Pause Charging")
        #expect(body(.setLimit(percentage: 80), "ja") == "設定されたタスクが実行されました: 充電上限 80%")

        // 이름 없는 일정의 제목은 요약을 쓰지 않지만, 같은 로케일을 받는지 함께 확인한다.
        #expect(BatteryNotificationManager.scheduleTriggeredTitle(
            scheduleName: "", actionSummary: "", locale: Locale(identifier: "en"))
                == "Scheduled Charge Triggered")
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

    private static func dischargeStatus(
        kind: BatteryControlStatusReason.Kind,
        target: Int,
        sessionOpen: Bool
    ) -> BatteryControlServiceStatus {
        BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: target,
            isPowerAdapterConnected: true,
            detail: "",
            updatedAt: 1,
            detailReason: .init(kind: kind, limitPercentage: target),
            desiredConfiguration: BatteryControlConfiguration(
                enabled: true,
                limitPercentage: 80,
                manualDischargeActive: sessionOpen,
                manualDischargeTarget: target))
    }

    @Test func dischargeCompletionFiresOnceWhenTheManualSessionReachesItsTarget() {
        var detector = BatteryDischargeTransitionDetector()
        let running = Self.dischargeStatus(kind: .dischargingManual, target: 70, sessionOpen: true)
        let reached = Self.dischargeStatus(kind: .inhibitedAtLimit, target: 70, sessionOpen: true)

        #expect(detector.update(status: running) == nil)
        #expect(detector.update(status: reached) == 70)
        // 같은 상태가 반복돼도 다시 알리지 않는다.
        #expect(detector.update(status: reached) == nil)
    }

    @Test func userStoppingTheDischargeDoesNotAnnounceCompletion() {
        var detector = BatteryDischargeTransitionDetector()
        let running = Self.dischargeStatus(kind: .dischargingManual, target: 70, sessionOpen: true)
        // "방전 중지"를 누르면 세션 플래그가 같은 틱에 내려간다.
        let stopped = Self.dischargeStatus(kind: .inhibitedAtLimit, target: 80, sessionOpen: false)

        #expect(detector.update(status: running) == nil)
        #expect(detector.update(status: stopped) == nil)
    }

    @Test func autoDischargeReachingTheLimitIsNotAnnounced() {
        var detector = BatteryDischargeTransitionDetector()
        let running = Self.dischargeStatus(kind: .dischargingToTarget, target: 80, sessionOpen: false)
        let reached = Self.dischargeStatus(kind: .inhibitedAtLimit, target: 80, sessionOpen: false)

        #expect(detector.update(status: running) == nil)
        #expect(detector.update(status: reached) == nil)
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

