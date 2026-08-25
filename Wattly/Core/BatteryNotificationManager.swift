import Foundation
import UserNotifications

public struct BatteryTopUpTransitionDetector: Sendable {
    private var lastReasonKind: BatteryControlStatusReason.Kind?

    public init() {}

    public mutating func update(reasonKind: BatteryControlStatusReason.Kind?) -> Bool {
        defer { lastReasonKind = reasonKind }
        guard let reasonKind else { return false }
        if lastReasonKind == .topUpCharging && reasonKind == .topUpComplete {
            return true
        }
        return false
    }
}

public struct BatteryDischargeTransitionDetector: Sendable {
    private var lastReasonKind: BatteryControlStatusReason.Kind?
    private var lastActivity: BatteryControlActivity?

    public init() {}

    public mutating func update(reasonKind: BatteryControlStatusReason.Kind?) -> Bool {
        defer { lastReasonKind = reasonKind }
        guard let reasonKind else { return false }
        let wasDischarging = lastReasonKind == .dischargingManual || lastReasonKind == .dischargingToTarget
        let isComplete = reasonKind == .inhibitedAtLimit || reasonKind == .topUpComplete || reasonKind == .topUpHeldAtMax
        if wasDischarging && isComplete {
            return true
        }
        return false
    }

    public mutating func update(activity: BatteryControlActivity?) -> Bool {
        defer { lastActivity = activity }
        guard let activity else { return false }
        let wasDischarging = lastActivity == .discharging
        let isComplete = activity == .holdingAtLimit || activity == .topUp
        if wasDischarging && isComplete {
            return true
        }
        return false
    }

    public mutating func update(status: BatteryControlServiceStatus) -> Bool {
        if let reasonKind = status.detailReason?.kind {
            return update(reasonKind: reasonKind)
        }
        if let activity = status.activity {
            return update(activity: activity)
        }
        return false
    }
}

public enum BatteryNotificationManager {
    public static func topUpCompleteTitle(locale: Locale) -> String {
        String(localized: "한 번만 완충 완료", locale: locale)
    }

    public static func topUpCompleteBody(locale: Locale) -> String {
        String(localized: "배터리가 100%까지 충전되었습니다. 어댑터를 분리하면 기존 충전 제한으로 자동 복귀합니다.", locale: locale)
    }

    public static func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public static func postTopUpCompleteNotification() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = topUpCompleteTitle(locale: .current)
            content.body = topUpCompleteBody(locale: .current)
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "dev.jjundev.Wattly.topUpComplete",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    public static func dischargeCompleteTitle(locale: Locale) -> String {
        String(localized: "방전 완료 (목표 도달)", locale: locale)
    }

    public static func dischargeCompleteBody(target: Int, locale: Locale) -> String {
        String(format: String(localized: "목표 잔량(%lld%%)에 도달하여 전원 어댑터 바이패스 모드로 전환되었습니다.", locale: locale), target)
    }

    public static func postDischargeCompleteNotification(target: Int) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = dischargeCompleteTitle(locale: .current)
            content.body = dischargeCompleteBody(target: target, locale: .current)
            content.sound = .default
            content.categoryIdentifier = "dev.jjundev.Wattly.dischargeComplete"

            let request = UNNotificationRequest(
                identifier: "dev.jjundev.Wattly.dischargeComplete",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    public static func notifyDischargeCompleted(target: Int) {
        postDischargeCompleteNotification(target: target)
    }

    public static func scheduleTriggeredTitle(scheduleName: String, actionSummary: String, locale: Locale) -> String {
        if scheduleName.isEmpty {
            return String(localized: "예약 충전 실행됨", locale: locale)
        }
        return String(localized: "예약 충전: \(scheduleName)", locale: locale)
    }

    public static func scheduleTriggeredBody(scheduleName: String, actionSummary: String, locale: Locale) -> String {
        return String(localized: "설정된 작업이 실행되었습니다: \(actionSummary)", locale: locale)
    }

    public static func postScheduleTriggeredNotification(scheduleName: String, actionSummary: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = scheduleTriggeredTitle(scheduleName: scheduleName, actionSummary: actionSummary, locale: .current)
            content.body = scheduleTriggeredBody(scheduleName: scheduleName, actionSummary: actionSummary, locale: .current)
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "dev.jjundev.Wattly.scheduleTriggered.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }
}

