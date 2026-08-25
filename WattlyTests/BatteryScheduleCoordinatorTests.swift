import Foundation
import Testing
@testable import Wattly

private actor MockBatteryState {
    var lastAppliedConfig: BatteryControlConfiguration?
    var mode: BatteryControlServiceMode = .inhibited
    var percentage: Int = 75
    var isPowerAdapterConnected: Bool = true
    var shouldFail: Bool = false

    func setAdapterConnected(_ connected: Bool) {
        self.isPowerAdapterConnected = connected
    }

    func setShouldFail(_ fail: Bool) {
        self.shouldFail = fail
    }

    func applyConfig(_ config: BatteryControlConfiguration) -> BatteryControlServiceStatus? {
        if shouldFail { return nil }
        self.lastAppliedConfig = config
        return BatteryControlServiceStatus(
            mode: mode,
            currentPercentage: percentage,
            isPowerAdapterConnected: isPowerAdapterConnected,
            detail: "OK",
            updatedAt: Date().timeIntervalSince1970
        )
    }

    func getStatus() -> BatteryControlServiceStatus {
        BatteryControlServiceStatus(
            mode: mode,
            currentPercentage: percentage,
            isPowerAdapterConnected: isPowerAdapterConnected,
            detail: "OK",
            updatedAt: Date().timeIntervalSince1970
        )
    }
}

@MainActor
private func makeMockClient(state: MockBatteryState) -> BatteryControlClient {
    BatteryControlClient { request in
        switch request {
        case .configure(let data):
            guard let req = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data) else {
                return (nil, NSError(domain: "test", code: -1))
            }
            let status = await state.applyConfig(req.configuration)
            if let status {
                let resData = try? BatteryControlCodec.encode(status)
                return (resData, nil)
            } else {
                return (nil, NSError(domain: "test", code: -1))
            }
        case .status:
            let status = await state.getStatus()
            let resData = try? BatteryControlCodec.encode(status)
            return (resData, nil)
        }
    }
}

private func makeIsolatedDefaults() -> UserDefaults {
    let suiteName = "BatteryScheduleCoordinatorTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

@Suite struct BatteryScheduleCoordinatorTests {
    @Test @MainActor func conflictResolutionPicksHighestPriority() {
        let scheduleLimit = BatteryChargingSchedule(
            name: "80% 한도",
            time: ScheduleTime(hour: 8, minute: 0),
            action: .setLimit(percentage: 80)
        )
        let scheduleTopUp = BatteryChargingSchedule(
            name: "완충",
            time: ScheduleTime(hour: 8, minute: 0),
            action: .startTopUp
        )
        let schedulePause = BatteryChargingSchedule(
            name: "일시정지",
            time: ScheduleTime(hour: 8, minute: 0),
            action: .pauseCharging
        )

        let winner1 = BatteryScheduleCoordinator.resolveConflict(among: [scheduleLimit, scheduleTopUp])
        #expect(winner1?.action == .startTopUp)

        let winner2 = BatteryScheduleCoordinator.resolveConflict(among: [scheduleLimit, scheduleTopUp, schedulePause])
        #expect(winner2?.action == .pauseCharging)
    }

    @Test @MainActor func catchUpEvaluatesWithinWindowAndSkipsExpired() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let schedule = BatteryChargingSchedule(
            name: "오전 8시 충전",
            time: ScheduleTime(hour: 8, minute: 0),
            repeatRule: .daily,
            action: .setLimit(percentage: 80),
            catchUpPolicy: .executeIfWithin(minutes: 30)
        )

        // Wake at 08:15 (within 30 mins) -> Should execute
        let wakeAt815 = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 8, minute: 15))!
        let result815 = BatteryScheduleCoordinator.shouldCatchUp(
            schedule: schedule,
            wakeDate: wakeAt815,
            calendar: calendar
        )
        #expect(result815 == true)

        // Wake at 09:15 (75 mins late) -> Should NOT execute
        let wakeAt915 = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 9, minute: 15))!
        let result915 = BatteryScheduleCoordinator.shouldCatchUp(
            schedule: schedule,
            wakeDate: wakeAt915,
            calendar: calendar
        )
        #expect(result915 == false)
    }

    @Test @MainActor func isRecentMissedDoesNotTriggerForCompletedSchedule() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var schedule = BatteryChargingSchedule(
            name: "오전 8시 충전",
            time: ScheduleTime(hour: 8, minute: 0),
            repeatRule: .daily,
            action: .setLimit(percentage: 80),
            catchUpPolicy: .executeIfWithin(minutes: 30)
        )

        // Schedule ran successfully at 08:00
        let triggerAt800 = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 8, minute: 0))!
        schedule.lastTriggeredAt = triggerAt800

        // Wake at 14:00 (6 hours later) -> Should NOT be marked as missed
        let wakeAt1400 = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 14, minute: 0))!
        let missed = BatteryScheduleCoordinator.isRecentMissed(
            schedule: schedule,
            wakeDate: wakeAt1400,
            calendar: calendar
        )
        #expect(missed == false)
    }

    @Test @MainActor func nextUpcomingScheduleCalculation() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let scheduleDaily8 = BatteryChargingSchedule(
            name: "매일 8시",
            time: ScheduleTime(hour: 8, minute: 0),
            repeatRule: .daily
        )
        let scheduleDaily20 = BatteryChargingSchedule(
            name: "매일 20시",
            time: ScheduleTime(hour: 20, minute: 0),
            repeatRule: .daily
        )

        let now10 = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 10, minute: 0))!
        let upcoming = BatteryScheduleCoordinator.nextUpcoming(
            from: [scheduleDaily8, scheduleDaily20],
            now: now10,
            calendar: calendar
        )

        #expect(upcoming?.schedule.name == "매일 20시")
    }

    @Test @MainActor func crudOperationsAndPersistence() {
        let defaults = makeIsolatedDefaults()
        let state = MockBatteryState()
        let client = makeMockClient(state: state)
        let coordinator = BatteryScheduleCoordinator(batteryControl: client, defaults: defaults)

        #expect(coordinator.schedules.isEmpty)
        #expect(coordinator.history.isEmpty)

        let schedule1 = BatteryChargingSchedule(
            name: "일과 시작",
            time: ScheduleTime(hour: 9, minute: 0),
            repeatRule: .weekdays,
            action: .setLimit(percentage: 80)
        )
        coordinator.addSchedule(schedule1)
        #expect(coordinator.schedules.count == 1)
        #expect(coordinator.schedules[0].name == "일과 시작")

        // Update schedule
        var updated = schedule1
        updated.name = "업무 시작 80%"
        coordinator.updateSchedule(updated)
        #expect(coordinator.schedules.count == 1)
        #expect(coordinator.schedules[0].name == "업무 시작 80%")

        // Toggle schedule
        coordinator.toggleSchedule(id: schedule1.id, isEnabled: false)
        #expect(coordinator.schedules[0].isEnabled == false)

        // Reload state to verify persistence
        let coordinator2 = BatteryScheduleCoordinator(batteryControl: client, defaults: defaults)
        #expect(coordinator2.schedules.count == 1)
        #expect(coordinator2.schedules[0].name == "업무 시작 80%")
        #expect(coordinator2.schedules[0].isEnabled == false)

        // Delete schedule
        coordinator2.deleteSchedule(id: schedule1.id)
        #expect(coordinator2.schedules.isEmpty)

        let coordinator3 = BatteryScheduleCoordinator(batteryControl: client, defaults: defaults)
        #expect(coordinator3.schedules.isEmpty)
    }

    @Test @MainActor func evaluationExecutesWinningScheduleAndLogsSkipped() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let defaults = makeIsolatedDefaults()
        let state = MockBatteryState()
        let client = makeMockClient(state: state)
        let coordinator = BatteryScheduleCoordinator(batteryControl: client, defaults: defaults)

        // Pre-configure client status
        _ = await client.refreshStatus()

        let scheduleLimit = BatteryChargingSchedule(
            name: "80% 한도",
            time: ScheduleTime(hour: 8, minute: 0),
            repeatRule: .daily,
            action: .setLimit(percentage: 80)
        )
        let scheduleTopUp = BatteryChargingSchedule(
            name: "완충",
            time: ScheduleTime(hour: 8, minute: 0),
            repeatRule: .daily,
            action: .startTopUp
        )

        coordinator.addSchedule(scheduleLimit)
        coordinator.addSchedule(scheduleTopUp)

        let testDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 8, minute: 0))!
        await coordinator.evaluateSchedules(at: testDate, isWake: false, calendar: calendar)

        // Top-up should win and succeed
        #expect(coordinator.history.count == 2)
        let winnerLog = coordinator.history.first { $0.scheduleId == scheduleTopUp.id }
        #expect(winnerLog?.status == BatteryScheduleLogEntry.Status.success)

        let loserLog = coordinator.history.first { $0.scheduleId == scheduleLimit.id }
        #expect(loserLog?.status == BatteryScheduleLogEntry.Status.skipped(reason: .overriddenByHigherPriority))

        #expect(coordinator.schedules.first(where: { $0.id == scheduleTopUp.id })?.lastTriggeredAt == testDate)
    }

    @Test @MainActor func topUpSkippedWhenAdapterDisconnected() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let defaults = makeIsolatedDefaults()
        let state = MockBatteryState()
        await state.setAdapterConnected(false)
        let client = makeMockClient(state: state)
        _ = await client.refreshStatus()

        let coordinator = BatteryScheduleCoordinator(batteryControl: client, defaults: defaults)

        let scheduleTopUp = BatteryChargingSchedule(
            name: "완충",
            time: ScheduleTime(hour: 8, minute: 0),
            repeatRule: .daily,
            action: .startTopUp
        )
        coordinator.addSchedule(scheduleTopUp)

        let testDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 8, minute: 0))!
        await coordinator.evaluateSchedules(at: testDate, isWake: false, calendar: calendar)

        #expect(coordinator.history.count == 1)
        #expect(coordinator.history[0].status == BatteryScheduleLogEntry.Status.skipped(reason: .adapterDisconnected))
    }

    @Test @MainActor func wakeCatchUpLogsExpiredWhenOutOfWindow() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let defaults = makeIsolatedDefaults()
        let state = MockBatteryState()
        let client = makeMockClient(state: state)
        _ = await client.refreshStatus()

        let coordinator = BatteryScheduleCoordinator(batteryControl: client, defaults: defaults)

        let schedule = BatteryChargingSchedule(
            name: "오전 8시 충전",
            time: ScheduleTime(hour: 8, minute: 0),
            repeatRule: .daily,
            action: .setLimit(percentage: 80),
            catchUpPolicy: .executeIfWithin(minutes: 30)
        )
        coordinator.addSchedule(schedule)

        // Wake at 09:15 (75 mins late -> expired)
        let wakeAt915 = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 9, minute: 15))!
        await coordinator.evaluateSchedules(at: wakeAt915, isWake: true, calendar: calendar)

        #expect(coordinator.history.count == 1)
        #expect(coordinator.history[0].status == BatteryScheduleLogEntry.Status.skipped(reason: .catchUpWindowExpired))
    }

    @Test @MainActor func oneShotScheduleAutoDisablesAfterExecution() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let defaults = makeIsolatedDefaults()
        let state = MockBatteryState()
        let client = makeMockClient(state: state)
        _ = await client.refreshStatus()

        let coordinator = BatteryScheduleCoordinator(batteryControl: client, defaults: defaults)

        let testDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 8, minute: 0))!
        let onceSchedule = BatteryChargingSchedule(
            name: "오늘 한번만",
            time: ScheduleTime(hour: 8, minute: 0),
            repeatRule: .once(testDate),
            action: .setLimit(percentage: 90)
        )
        coordinator.addSchedule(onceSchedule)

        await coordinator.evaluateSchedules(at: testDate, isWake: false, calendar: calendar)

        #expect(coordinator.history.count == 1)
        #expect(coordinator.history[0].status == BatteryScheduleLogEntry.Status.success)
        #expect(coordinator.schedules[0].isEnabled == false)
    }

    @Test @MainActor func clearHistoryRemovesAllEntries() {
        let defaults = makeIsolatedDefaults()
        let state = MockBatteryState()
        let client = makeMockClient(state: state)
        let coordinator = BatteryScheduleCoordinator(batteryControl: client, defaults: defaults)

        let schedule = BatteryChargingSchedule(
            name: "테스트",
            time: ScheduleTime(hour: 8, minute: 0),
            repeatRule: .daily,
            action: .setLimit(percentage: 80)
        )
        coordinator.addSchedule(schedule)

        // Clear history
        coordinator.clearHistory()
        #expect(coordinator.history.isEmpty)
    }
}
