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
}
