import Foundation

public struct ScheduleTime: Codable, Equatable, Hashable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = max(0, min(23, hour))
        self.minute = max(0, min(59, minute))
    }

    public var formattedText: String {
        String(format: "%02d:%02d", hour, minute)
    }
}

public enum ScheduleRepeatRule: Codable, Equatable, Hashable, Sendable {
    case once(Date)
    case daily
    case weekdays
    case weekends
    case custom(Set<Weekday>)

    public enum Weekday: Int, Codable, CaseIterable, Sendable, Comparable {
        case sunday = 1, monday = 2, tuesday = 3, wednesday = 4, thursday = 5, friday = 6, saturday = 7

        public static func < (lhs: Weekday, rhs: Weekday) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public func shortLabel(locale: Locale = Locale(identifier: "ko")) -> String {
            switch self {
            case .sunday: return String(localized: "일", locale: locale)
            case .monday: return String(localized: "월", locale: locale)
            case .tuesday: return String(localized: "화", locale: locale)
            case .wednesday: return String(localized: "수", locale: locale)
            case .thursday: return String(localized: "목", locale: locale)
            case .friday: return String(localized: "금", locale: locale)
            case .saturday: return String(localized: "토", locale: locale)
            }
        }

        public var shortLabel: String {
            shortLabel()
        }
    }

    public func matches(date: Date, calendar: Calendar = .current) -> Bool {
        switch self {
        case .once(let targetDate):
            return calendar.isDate(date, inSameDayAs: targetDate)
        case .daily:
            return true
        case .weekdays:
            let weekday = calendar.component(.weekday, from: date)
            return (2...6).contains(weekday)
        case .weekends:
            let weekday = calendar.component(.weekday, from: date)
            return weekday == 1 || weekday == 7
        case .custom(let set):
            let weekdayRaw = calendar.component(.weekday, from: date)
            guard let weekday = Weekday(rawValue: weekdayRaw) else { return false }
            return set.contains(weekday)
        }
    }
}

public enum ScheduleAction: Codable, Equatable, Hashable, Sendable {
    case setLimit(percentage: Int)
    case startTopUp
    case pauseCharging

    public func summary(locale: Locale = Locale(identifier: "ko")) -> String {
        switch self {
        case .setLimit(let pct):
            return String(format: String(localized: "충전 한도 %lld%%", locale: locale), locale: locale, Int64(pct))
        case .startTopUp:
            return String(localized: "한 번만 100% 완충", locale: locale)
        case .pauseCharging:
            return String(localized: "충전 일시 정지", locale: locale)
        }
    }

    public var summary: String {
        summary()
    }
}

public enum ScheduleCatchUpPolicy: Codable, Equatable, Hashable, Sendable {
    case executeIfWithin(minutes: Int)
    case skip
}

public struct BatteryChargingSchedule: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var time: ScheduleTime
    public var repeatRule: ScheduleRepeatRule
    public var action: ScheduleAction
    public var catchUpPolicy: ScheduleCatchUpPolicy
    public var createdAt: Date
    public var lastTriggeredAt: Date?

    public init(
        id: UUID = UUID(),
        name: String = "",
        isEnabled: Bool = true,
        time: ScheduleTime,
        repeatRule: ScheduleRepeatRule = .daily,
        action: ScheduleAction = .setLimit(percentage: 80),
        catchUpPolicy: ScheduleCatchUpPolicy = .executeIfWithin(minutes: 30),
        createdAt: Date = Date(),
        lastTriggeredAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.time = time
        self.repeatRule = repeatRule
        self.action = action
        self.catchUpPolicy = catchUpPolicy
        self.createdAt = createdAt
        self.lastTriggeredAt = lastTriggeredAt
    }
}
