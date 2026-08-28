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

/// Top Up이 **스스로** 끝났을 때만 참을 반환한다.
///
/// 만료 후의 상태는 평범한 `inhibitedAtLimit`이라, 사용자가 버튼으로 취소한 경우와 상태만으로는
/// 구분할 수 없다. 그래서 헬퍼가 남긴 유지보수 레코드의 trigger를 본다. 신선도 창을 두는 이유는
/// 앱을 몇 시간 뒤에 켰을 때 헬퍼가 아직 들고 있는 오래된 레코드로 뒤늦은 알림이 뜨는 것을
/// 막기 위해서다.
public struct BatteryTopUpExpiryDetector: Sendable {
    /// 이보다 오래된 만료 레코드는 알리지 않는다.
    public static let freshnessWindow: TimeInterval = 300

    /// 신선도 창을 벗어난 레코드도 여기에 기록한다. 같은 레코드를 나중에 다시 보더라도 "새 것"으로
    /// 되살아나지 않게 하려는 것이다.
    private var lastSeenOccurredAt: TimeInterval?

    public init() {}

    public mutating func update(record: BatteryMaintenanceRecord?, now: TimeInterval) -> Bool {
        guard let record, record.trigger == .topUpExpired else { return false }
        let isNew = lastSeenOccurredAt != record.occurredAt
        lastSeenOccurredAt = record.occurredAt
        return isNew && (now - record.occurredAt) <= Self.freshnessWindow
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

    public static func topUpCompleteBody(hours: Int, locale: Locale) -> String {
        String(format: String(localized: "배터리가 100%%까지 충전되었습니다. 어댑터를 분리하거나 %lld시간이 지나면 기존 충전 제한으로 자동 복귀합니다.", locale: locale),
               locale: locale, Int64(hours))
    }

    public static func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public static func postTopUpCompleteNotification() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let appLang = UserDefaults.standard.string(forKey: StorageKey.appLanguage) ?? Defaults.appLanguage
            let locale = AppLanguage.locale(for: appLang)
            let content = UNMutableNotificationContent()
            content.title = topUpCompleteTitle(locale: locale)
            content.body = topUpCompleteBody(hours: BatteryTopUpExpiry.durationHours, locale: locale)
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "dev.jjundev.Wattly.topUpComplete",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    public static func topUpExpiredTitle(locale: Locale) -> String {
        String(localized: "한 번만 완충 자동 해제", locale: locale)
    }

    public static func topUpExpiredBody(hours: Int, locale: Locale) -> String {
        String(format: String(localized: "완충 후 %lld시간이 지나 기존 충전 제한으로 복귀했습니다.", locale: locale),
               locale: locale, Int64(hours))
    }

    public static func postTopUpExpiredNotification() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let appLang = UserDefaults.standard.string(forKey: StorageKey.appLanguage) ?? Defaults.appLanguage
            let locale = AppLanguage.locale(for: appLang)
            let content = UNMutableNotificationContent()
            content.title = topUpExpiredTitle(locale: locale)
            content.body = topUpExpiredBody(hours: BatteryTopUpExpiry.durationHours, locale: locale)
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "dev.jjundev.Wattly.topUpExpired",
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
        String(format: String(localized: "목표 잔량(%lld%%)에 도달하여 전원 어댑터 바이패스 모드로 전환되었습니다.", locale: locale), locale: locale, target)
    }

    public static func postDischargeCompleteNotification(target: Int) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let appLang = UserDefaults.standard.string(forKey: StorageKey.appLanguage) ?? Defaults.appLanguage
            let locale = AppLanguage.locale(for: appLang)
            let content = UNMutableNotificationContent()
            content.title = dischargeCompleteTitle(locale: locale)
            content.body = dischargeCompleteBody(target: target, locale: locale)
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
        return String(format: String(localized: "예약 충전: %@", locale: locale), locale: locale, scheduleName)
    }

    public static func scheduleTriggeredBody(scheduleName: String, actionSummary: String, locale: Locale) -> String {
        return String(format: String(localized: "설정된 작업이 실행되었습니다: %@", locale: locale), locale: locale, actionSummary)
    }

    public static func postScheduleTriggeredNotification(scheduleName: String, actionSummary: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let appLang = UserDefaults.standard.string(forKey: StorageKey.appLanguage) ?? Defaults.appLanguage
            let locale = AppLanguage.locale(for: appLang)
            let content = UNMutableNotificationContent()
            content.title = scheduleTriggeredTitle(scheduleName: scheduleName, actionSummary: actionSummary, locale: locale)
            content.body = scheduleTriggeredBody(scheduleName: scheduleName, actionSummary: actionSummary, locale: locale)
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

