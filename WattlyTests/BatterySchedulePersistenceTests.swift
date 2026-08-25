import Foundation
import Testing
@testable import Wattly

@Suite struct BatterySchedulePersistenceTests {
    @Test func schedulesAreParsedAndSerializedInUserDefaults() {
        let suiteName = "dev.jjundev.WattlyTests.SchedulePersistence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let schedule = BatteryChargingSchedule(
            name: "테스트 스케줄",
            time: ScheduleTime(hour: 22, minute: 0),
            repeatRule: .daily,
            action: .setLimit(percentage: 80)
        )

        let encoder = JSONEncoder()
        let data = try! encoder.encode([schedule])
        let jsonString = String(data: data, encoding: .utf8)!

        defaults.set(jsonString, forKey: StorageKey.batteryChargingSchedules)
        let loadedString = defaults.string(forKey: StorageKey.batteryChargingSchedules)
        #expect(loadedString == jsonString)

        let loadedData = loadedString?.data(using: .utf8)
        let decoded = try! JSONDecoder().decode([BatteryChargingSchedule].self, from: loadedData!)
        #expect(decoded.count == 1)
        #expect(decoded.first?.name == "테스트 스케줄")
    }

    @Test func settingsResetClearsSchedulesAndHistory() {
        let suiteName = "dev.jjundev.WattlyTests.ScheduleReset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("[{\"name\":\"dummy\"}]", forKey: StorageKey.batteryChargingSchedules)
        defaults.set("[{\"scheduleName\":\"dummy\"}]", forKey: StorageKey.batteryScheduleHistory)
        defaults.set(false, forKey: StorageKey.batteryScheduleNotificationsEnabled)

        SettingsReset.applyDefaults(into: defaults)

        #expect(defaults.string(forKey: StorageKey.batteryChargingSchedules) == Defaults.batteryChargingSchedules)
        #expect(defaults.string(forKey: StorageKey.batteryScheduleHistory) == Defaults.batteryScheduleHistory)
        #expect(defaults.bool(forKey: StorageKey.batteryScheduleNotificationsEnabled) == Defaults.batteryScheduleNotificationsEnabled)
    }
}
