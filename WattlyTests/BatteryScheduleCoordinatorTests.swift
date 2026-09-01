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

    /// Regression for the missing-argument bug: `execute(schedule:at:)` must thread the user's
    /// auto-discharge opt-in and manual-discharge target through to the client on the `.setLimit`
    /// path, not silently reset them to `apply`'s defaults (`false` / `80`).
    @Test @MainActor func setLimitCarriesAutoDischargeAndManualDischargeTarget() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: StorageKey.batteryAutoDischargeEnabled)
        defaults.set(70, forKey: StorageKey.batteryManualDischargeTarget)

        let state = MockBatteryState()
        let client = makeMockClient(state: state)
        _ = await client.refreshStatus()
        let coordinator = BatteryScheduleCoordinator(batteryControl: client, defaults: defaults)

        let schedule = BatteryChargingSchedule(
            name: "80% 한도",
            time: ScheduleTime(hour: 8, minute: 0),
            repeatRule: .daily,
            action: .setLimit(percentage: 80)
        )
        coordinator.addSchedule(schedule)

        let testDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 8, minute: 0))!
        await coordinator.evaluateSchedules(at: testDate, isWake: false, calendar: calendar)

        let applied = await state.lastAppliedConfig
        #expect(applied?.autoDischargeEnabled == true)
        #expect(applied?.manualDischargeTarget == 70)
    }

    /// Same regression, `.startTopUp` path.
    @Test @MainActor func startTopUpCarriesAutoDischargeAndManualDischargeTarget() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let defaults = makeIsolatedDefaults()
        defaults.set(true, forKey: StorageKey.batteryAutoDischargeEnabled)
        defaults.set(70, forKey: StorageKey.batteryManualDischargeTarget)

        let state = MockBatteryState()
        let client = makeMockClient(state: state)
        _ = await client.refreshStatus()
        let coordinator = BatteryScheduleCoordinator(batteryControl: client, defaults: defaults)

        let schedule = BatteryChargingSchedule(
            name: "완충",
            time: ScheduleTime(hour: 8, minute: 0),
            repeatRule: .daily,
            action: .startTopUp
        )
        coordinator.addSchedule(schedule)

        let testDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 8, minute: 0))!
        await coordinator.evaluateSchedules(at: testDate, isWake: false, calendar: calendar)

        let applied = await state.lastAppliedConfig
        #expect(applied?.autoDischargeEnabled == true)
        #expect(applied?.manualDischargeTarget == 70)
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

    @MainActor @Test func schedulesAreSkippedAndLoggedWhileCalibrating() async {
        let name = "schedule.calibration"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(true, forKey: StorageKey.batteryLimitEnabled)
        defaults.set(80, forKey: StorageKey.batteryLimitPercentage)

        let client = BatteryControlClient { _ in (nil, nil) }
        let coordinator = BatteryScheduleCoordinator(
            batteryControl: client,
            defaults: defaults,
            isCalibrationRunning: { true })

        coordinator.addSchedule(BatteryChargingSchedule(
            name: "밤",
            isEnabled: true,
            time: ScheduleTime(hour: 3, minute: 0),
            repeatRule: .daily,
            action: .setLimit(percentage: 60)))

        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 30
        components.hour = 3; components.minute = 0
        let fireDate = Calendar.current.date(from: components)!
        await coordinator.evaluateSchedules(at: fireDate)

        // 스케줄이 사용자 설정을 덮어쓰면 절차 스냅샷과 저장값이 갈라진다.
        #expect(defaults.integer(forKey: StorageKey.batteryLimitPercentage) == 80)
        #expect(coordinator.history.first?.status == .skipped(reason: .calibrationRunning))
    }

    // MARK: - Locale (i18n)

    /// 코디네이터는 뷰가 아니라 `@Environment(\.locale)`을 못 받는다. 대신 주입된 `defaults`에
    /// 저장된 앱 언어에서 로케일을 되살리는 것이 이 계약이다.
    @Test @MainActor func activeLocaleFollowsStoredAppLanguage() {
        let defaults = makeIsolatedDefaults()
        let client = makeMockClient(state: MockBatteryState())
        let coordinator = BatteryScheduleCoordinator(batteryControl: client, defaults: defaults)

        // 키가 없으면 `Defaults.appLanguage`("system") — 시스템 로케일을 따라간다.
        #expect(coordinator.activeLocale == Locale.autoupdatingCurrent)

        defaults.set("en", forKey: StorageKey.appLanguage)
        #expect(coordinator.activeLocale.identifier.hasPrefix("en"))

        defaults.set("ja", forKey: StorageKey.appLanguage)
        #expect(coordinator.activeLocale.identifier.hasPrefix("ja"))

        defaults.set("ko", forKey: StorageKey.appLanguage)
        #expect(coordinator.activeLocale.identifier.hasPrefix("ko"))
    }

    /// 이력 항목은 `actionSummary`를 문자열 그대로 저장한다. 한국어로 굳어 버리면 다른 언어
    /// 사용자의 "실행 이력" 팝오버가 영구히 한국어로 남는다.
    @Test @MainActor func recordLogWritesActionSummaryInAppLanguage() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let testDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 8, minute: 0))!

        // 이름 없는 일정: `scheduleName`도 요약으로 대체되므로 두 필드 모두 번역돼야 한다.
        func summaries(appLanguage: String) async -> (scheduleName: String, actionSummary: String) {
            let defaults = makeIsolatedDefaults()
            defaults.set(appLanguage, forKey: StorageKey.appLanguage)
            let state = MockBatteryState()
            let client = makeMockClient(state: state)
            _ = await client.refreshStatus()
            let coordinator = BatteryScheduleCoordinator(batteryControl: client, defaults: defaults)
            coordinator.addSchedule(BatteryChargingSchedule(
                name: "",
                time: ScheduleTime(hour: 8, minute: 0),
                repeatRule: .daily,
                action: .setLimit(percentage: 80)
            ))
            await coordinator.evaluateSchedules(at: testDate, isWake: false, calendar: calendar)
            let entry = coordinator.history[0]
            #expect(entry.status == BatteryScheduleLogEntry.Status.success)
            return (entry.scheduleName, entry.actionSummary)
        }

        let ko = await summaries(appLanguage: "ko")
        #expect(ko.actionSummary == "충전 한도 80%")
        #expect(ko.scheduleName == "충전 한도 80%")

        let en = await summaries(appLanguage: "en")
        #expect(en.actionSummary == "Charge Limit 80%")
        #expect(en.scheduleName == "Charge Limit 80%")

        let ja = await summaries(appLanguage: "ja")
        #expect(ja.actionSummary == "充電上限 80%")
        #expect(ja.scheduleName == "充電上限 80%")
    }

    /// 이름이 있으면 그 이름은 사용자가 쓴 그대로 두고, 요약만 번역한다.
    @Test @MainActor func recordLogKeepsCustomNameButLocalizesSummary() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let defaults = makeIsolatedDefaults()
        defaults.set("en", forKey: StorageKey.appLanguage)
        let state = MockBatteryState()
        let client = makeMockClient(state: state)
        _ = await client.refreshStatus()
        let coordinator = BatteryScheduleCoordinator(batteryControl: client, defaults: defaults)

        coordinator.addSchedule(BatteryChargingSchedule(
            name: "Morning Commute",
            time: ScheduleTime(hour: 8, minute: 0),
            repeatRule: .daily,
            action: .pauseCharging
        ))

        let testDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 8, minute: 0))!
        await coordinator.evaluateSchedules(at: testDate, isWake: false, calendar: calendar)

        #expect(coordinator.history[0].scheduleName == "Morning Commute")
        #expect(coordinator.history[0].actionSummary == "Pause Charging")
    }

    /// 건너뛴 항목도 같은 `recordLog`를 지나므로 함께 번역된다.
    @Test @MainActor func skippedLogAlsoUsesAppLanguage() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let defaults = makeIsolatedDefaults()
        defaults.set("en", forKey: StorageKey.appLanguage)
        let state = MockBatteryState()
        await state.setAdapterConnected(false)
        let client = makeMockClient(state: state)
        _ = await client.refreshStatus()
        let coordinator = BatteryScheduleCoordinator(batteryControl: client, defaults: defaults)

        coordinator.addSchedule(BatteryChargingSchedule(
            name: "",
            time: ScheduleTime(hour: 8, minute: 0),
            repeatRule: .daily,
            action: .startTopUp
        ))

        let testDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 25, hour: 8, minute: 0))!
        await coordinator.evaluateSchedules(at: testDate, isWake: false, calendar: calendar)

        #expect(coordinator.history[0].status
                == BatteryScheduleLogEntry.Status.skipped(reason: .adapterDisconnected))
        #expect(coordinator.history[0].actionSummary == "Top Up to 100%")
        #expect(coordinator.history[0].scheduleName == "Top Up to 100%")
    }
}
