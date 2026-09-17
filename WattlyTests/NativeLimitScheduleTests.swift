import Foundation
import Testing
@testable import Wattly

/// 네이티브 충전 제한 백엔드에서 "충전 일시 정지" 예약이 어떻게 되는지.
///
/// 이 백엔드는 상한 하나가 전부라 50%를 쓰면 80%로 스냅된다 — 예약은 "성공"이라고 기록하고
/// 알림까지 띄우면서 배터리는 80%까지 충전된다. 그래서 아예 실행하지 않고 사유를 남긴다.
@Suite struct NativeLimitScheduleTests {
    private actor RequestLog {
        private(set) var configureCount = 0
        func countConfigure() { configureCount += 1 }
    }

    /// `controlBackend: .nativeLimit`을 답하는 클라이언트. `configure`도 받아 주지만, 이 테스트의
    /// 요점은 **오지 않는다**는 것이라 횟수만 센다.
    @MainActor
    private func makeNativeLimitClient(log: RequestLog) -> BatteryControlClient {
        BatteryControlClient { request in
            if case .configure = request { await log.countConfigure() }
            let status = BatteryControlServiceStatus(
                mode: .inhibited,
                currentPercentage: 75,
                isPowerAdapterConnected: true,
                detail: "OK",
                updatedAt: Date().timeIntervalSince1970,
                controlBackend: .nativeLimit)
            return (try? BatteryControlCodec.encode(status), nil)
        }
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "NativeLimitScheduleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test @MainActor func pauseChargingIsSkippedOnTheNativeBackend() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let defaults = isolatedDefaults()
        defaults.set(true, forKey: StorageKey.batteryLimitEnabled)
        defaults.set(90, forKey: StorageKey.batteryLimitPercentage)

        let log = RequestLog()
        let client = makeNativeLimitClient(log: log)
        _ = await client.refreshStatus()
        let configuresBefore = await log.configureCount

        let coordinator = BatteryScheduleCoordinator(batteryControl: client, defaults: defaults)
        let schedule = BatteryChargingSchedule(
            name: "충전 정지",
            time: ScheduleTime(hour: 8, minute: 0),
            repeatRule: .daily,
            action: .pauseCharging)
        coordinator.addSchedule(schedule)

        let testDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 8, minute: 0))!
        await coordinator.evaluateSchedules(at: testDate, isWake: false, calendar: calendar)

        #expect(coordinator.history.count == 1)
        #expect(coordinator.history[0].status
                == BatteryScheduleLogEntry.Status.skipped(reason: .unsupportedOnNativeLimit))
        // 환경설정을 건드리지 않았다 — 50%로 내려가지도, 한도가 켜지지도 않았다.
        #expect(defaults.integer(forKey: StorageKey.batteryLimitPercentage) == 90)
        let configuresAfter = await log.configureCount
        #expect(configuresAfter == configuresBefore)
    }

    @Test @MainActor func setLimitSchedulesStillRunOnTheNativeBackend() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let defaults = isolatedDefaults()
        let log = RequestLog()
        let client = makeNativeLimitClient(log: log)
        _ = await client.refreshStatus()

        let coordinator = BatteryScheduleCoordinator(batteryControl: client, defaults: defaults)
        coordinator.addSchedule(BatteryChargingSchedule(
            name: "85% 한도",
            time: ScheduleTime(hour: 8, minute: 0),
            repeatRule: .daily,
            action: .setLimit(percentage: 85)))

        let testDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 8, minute: 0))!
        await coordinator.evaluateSchedules(at: testDate, isWake: false, calendar: calendar)

        #expect(coordinator.history.count == 1)
        #expect(coordinator.history[0].status == BatteryScheduleLogEntry.Status.success)
        #expect(defaults.integer(forKey: StorageKey.batteryLimitPercentage) == 85)
    }

    @Test func pauseChargingIsOfferedOnlyWhenTheBackendCanExpressIt() {
        #expect(ScheduleEditorSheet.actionOptions(isPauseChargingAvailable: true).count == 3)
        #expect(ScheduleEditorSheet.actionOptions(isPauseChargingAvailable: false).count == 2)
        #expect(ScheduleEditorSheet.actionOptions(isPauseChargingAvailable: false)
                .contains { $0.value == 2 } == false)
    }
}
