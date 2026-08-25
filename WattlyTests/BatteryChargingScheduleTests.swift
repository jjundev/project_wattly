import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryChargingScheduleTests {
    @Test func scheduleTimeClampsHoursAndMinutes() {
        let invalidLow = ScheduleTime(hour: -5, minute: -10)
        #expect(invalidLow.hour == 0)
        #expect(invalidLow.minute == 0)

        let invalidHigh = ScheduleTime(hour: 25, minute: 75)
        #expect(invalidHigh.hour == 23)
        #expect(invalidHigh.minute == 59)

        let valid = ScheduleTime(hour: 8, minute: 30)
        #expect(valid.hour == 8)
        #expect(valid.minute == 30)
        #expect(valid.formattedText == "08:30")
    }

    @Test func repeatRuleMatchesDaysCorrectly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        // 2026-08-24 is Monday (weekday: 2 in Gregorian)
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 24
        components.hour = 8
        components.minute = 0
        let mondayDate = calendar.date(from: components)!

        // 2026-08-30 is Sunday (weekday: 1 in Gregorian)
        components.day = 30
        let sundayDate = calendar.date(from: components)!

        #expect(ScheduleRepeatRule.daily.matches(date: mondayDate, calendar: calendar) == true)
        #expect(ScheduleRepeatRule.daily.matches(date: sundayDate, calendar: calendar) == true)

        #expect(ScheduleRepeatRule.weekdays.matches(date: mondayDate, calendar: calendar) == true)
        #expect(ScheduleRepeatRule.weekdays.matches(date: sundayDate, calendar: calendar) == false)

        #expect(ScheduleRepeatRule.weekends.matches(date: mondayDate, calendar: calendar) == false)
        #expect(ScheduleRepeatRule.weekends.matches(date: sundayDate, calendar: calendar) == true)

        let customMonWed: ScheduleRepeatRule = .custom([.monday, .wednesday])
        #expect(customMonWed.matches(date: mondayDate, calendar: calendar) == true)
        #expect(customMonWed.matches(date: sundayDate, calendar: calendar) == false)
    }

    @Test func scheduleSerializationRoundTrip() throws {
        let schedule = BatteryChargingSchedule(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "출근 전 100% 충전",
            isEnabled: true,
            time: ScheduleTime(hour: 7, minute: 30),
            repeatRule: .weekdays,
            action: .startTopUp,
            catchUpPolicy: .executeIfWithin(minutes: 30),
            createdAt: Date(timeIntervalSince1970: 1700000000),
            lastTriggeredAt: nil
        )

        let encoded = try JSONEncoder().encode([schedule])
        let decoded = try JSONDecoder().decode([BatteryChargingSchedule].self, from: encoded)

        #expect(decoded.count == 1)
        #expect(decoded.first == schedule)
    }

    @Test func logEntrySerializationRoundTrip() throws {
        let entry = BatteryScheduleLogEntry(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            scheduleId: UUID(uuidString: "11111111-2222-3333-4444-555555555555"),
            scheduleName: "야간 80% 제한",
            actionSummary: "충전 한도 80% 설정",
            timestamp: Date(timeIntervalSince1970: 1700000000),
            status: .success,
            batteryPercentage: 78,
            isPluggedIn: true
        )

        let encoded = try JSONEncoder().encode([entry])
        let decoded = try JSONDecoder().decode([BatteryScheduleLogEntry].self, from: encoded)

        #expect(decoded.count == 1)
        #expect(decoded.first == entry)
    }
}
