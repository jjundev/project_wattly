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

        public var shortLabel: String {
            switch self {
            case .sunday: return "일"
            case .monday: return "월"
            case .tuesday: return "화"
            case .wednesday: return "수"
            case .thursday: return "목"
            case .friday: return "금"
            case .saturday: return "토"
            }
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

    public var summary: String {
        switch self {
        case .setLimit(let pct):
            return "충전 한도 \(pct)%"
        case .startTopUp:
            return "한 번만 100% 완충"
        case .pauseCharging:
            return "충전 일시 정지"
        }
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
