import Foundation
import Observation
import AppKit

@MainActor
@Observable public final class BatteryScheduleCoordinator {
    public static let maxHistoryCount = 50

    public private(set) var schedules: [BatteryChargingSchedule] = []
    public private(set) var history: [BatteryScheduleLogEntry] = []

    private let batteryControl: BatteryControlClient
    private let defaults: UserDefaults
    nonisolated(unsafe) private var timerTask: Task<Void, Never>?

    public init(
        batteryControl: BatteryControlClient,
        defaults: UserDefaults = .standard
    ) {
        self.batteryControl = batteryControl
        self.defaults = defaults
        loadState()
        startTimer()
    }

    deinit {
        timerTask?.cancel()
    }

    // MARK: - State Management

    public func loadState() {
        if let raw = defaults.string(forKey: StorageKey.batteryChargingSchedules),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([BatteryChargingSchedule].self, from: data) {
            self.schedules = decoded
        } else {
            self.schedules = []
        }

        if let rawHist = defaults.string(forKey: StorageKey.batteryScheduleHistory),
           let dataHist = rawHist.data(using: .utf8),
           let decodedHist = try? JSONDecoder().decode([BatteryScheduleLogEntry].self, from: dataHist) {
            self.history = decodedHist
        } else {
            self.history = []
        }
    }

    private func saveSchedules() {
        if let data = try? JSONEncoder().encode(schedules),
           let string = String(data: data, encoding: .utf8) {
            defaults.set(string, forKey: StorageKey.batteryChargingSchedules)
        }
    }

    private func saveHistory() {
        let clamped = Array(history.prefix(Self.maxHistoryCount))
        if let data = try? JSONEncoder().encode(clamped),
           let string = String(data: data, encoding: .utf8) {
            defaults.set(string, forKey: StorageKey.batteryScheduleHistory)
        }
    }

    public func addSchedule(_ schedule: BatteryChargingSchedule) {
        schedules.append(schedule)
        saveSchedules()
    }

    public func updateSchedule(_ schedule: BatteryChargingSchedule) {
        if let idx = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[idx] = schedule
            saveSchedules()
        }
    }

    public func deleteSchedule(id: UUID) {
        schedules.removeAll { $0.id == id }
        saveSchedules()
    }

    public func toggleSchedule(id: UUID, isEnabled: Bool) {
        if let idx = schedules.firstIndex(where: { $0.id == id }) {
            schedules[idx].isEnabled = isEnabled
            saveSchedules()
        }
    }

    public func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    // MARK: - Evaluation & Execution

    public func evaluateSchedules(at date: Date = Date(), isWake: Bool = false, calendar: Calendar = .current) async {
        let active = schedules.filter { $0.isEnabled }
        guard !active.isEmpty else { return }

        var matching: [BatteryChargingSchedule] = []

        if isWake {
            for schedule in active {
                if Self.shouldCatchUp(schedule: schedule, wakeDate: date, calendar: calendar) {
                    matching.append(schedule)
                } else if Self.isRecentMissed(schedule: schedule, wakeDate: date, calendar: calendar) {
                    recordLog(
                        schedule: schedule,
                        status: .skipped(reason: .catchUpWindowExpired),
                        timestamp: date
                    )
                }
            }
        } else {
            let hour = calendar.component(.hour, from: date)
            let minute = calendar.component(.minute, from: date)

            for schedule in active {
                if schedule.time.hour == hour && schedule.time.minute == minute && schedule.repeatRule.matches(date: date, calendar: calendar) {
                    matching.append(schedule)
                }
            }
        }

        guard let winning = Self.resolveConflict(among: matching) else { return }

        // Record skipped for lower-priority simultaneous items
        for item in matching where item.id != winning.id {
            recordLog(
                schedule: item,
                status: .skipped(reason: .overriddenByHigherPriority),
                timestamp: date
            )
        }

        await execute(schedule: winning, at: date)
    }

    private func execute(schedule: BatteryChargingSchedule, at date: Date) async {
        let isPluggedIn = batteryControl.status.isPowerAdapterConnected

        switch schedule.action {
        case .setLimit(let pct):
            defaults.set(true, forKey: StorageKey.batteryLimitEnabled)
            defaults.set(pct, forKey: StorageKey.batteryLimitPercentage)
            let status = await batteryControl.apply(
                enabled: true,
                limitPercentage: pct,
                lowerHysteresisDelta: defaults.bool(forKey: StorageKey.batterySailingEnabled)
                    ? defaults.integer(forKey: StorageKey.batterySailingDelta) : 2,
                heatProtectionEnabled: defaults.bool(forKey: StorageKey.batteryHeatProtectionEnabled),
                heatProtectionThresholdCelsius: defaults.integer(forKey: StorageKey.batteryHeatProtectionThreshold)
            )
            if status != nil && status?.mode != .unavailable {
                recordLog(schedule: schedule, status: .success, timestamp: date)
            } else {
                recordLog(schedule: schedule, status: .failed(reason: String(localized: "도우미 연결 실패")), timestamp: date)
            }

        case .startTopUp:
            if !isPluggedIn {
                recordLog(schedule: schedule, status: .skipped(reason: .adapterDisconnected), timestamp: date)
            } else {
                let status = await batteryControl.startTopUp(
                    limitPercentage: defaults.integer(forKey: StorageKey.batteryLimitPercentage),
                    lowerHysteresisDelta: defaults.bool(forKey: StorageKey.batterySailingEnabled)
                        ? defaults.integer(forKey: StorageKey.batterySailingDelta) : 2,
                    heatProtectionEnabled: defaults.bool(forKey: StorageKey.batteryHeatProtectionEnabled),
                    heatProtectionThresholdCelsius: defaults.integer(forKey: StorageKey.batteryHeatProtectionThreshold)
                )
                if status != nil && status?.mode != .unavailable {
                    recordLog(schedule: schedule, status: .success, timestamp: date)
                } else {
                    recordLog(schedule: schedule, status: .failed(reason: String(localized: "도우미 연결 실패")), timestamp: date)
                }
            }

        case .pauseCharging:
            defaults.set(true, forKey: StorageKey.batteryLimitEnabled)
            defaults.set(50, forKey: StorageKey.batteryLimitPercentage)
            let status = await batteryControl.apply(
                enabled: true,
                limitPercentage: 50,
                lowerHysteresisDelta: 2,
                heatProtectionEnabled: defaults.bool(forKey: StorageKey.batteryHeatProtectionEnabled),
                heatProtectionThresholdCelsius: defaults.integer(forKey: StorageKey.batteryHeatProtectionThreshold)
            )
            if status != nil && status?.mode != .unavailable {
                recordLog(schedule: schedule, status: .success, timestamp: date)
            } else {
                recordLog(schedule: schedule, status: .failed(reason: String(localized: "도우미 연결 실패")), timestamp: date)
            }
        }

        // Disable one-shot schedules
        if case .once = schedule.repeatRule {
            toggleSchedule(id: schedule.id, isEnabled: false)
        }

        // Update lastTriggeredAt
        if let idx = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[idx].lastTriggeredAt = date
            saveSchedules()
        }

        // Send notification if enabled
        if defaults.bool(forKey: StorageKey.batteryScheduleNotificationsEnabled) {
            BatteryNotificationManager.postScheduleTriggeredNotification(
                scheduleName: schedule.name,
                actionSummary: schedule.action.summary
            )
        }
    }

    private func recordLog(schedule: BatteryChargingSchedule, status: BatteryScheduleLogEntry.Status, timestamp: Date) {
        let entry = BatteryScheduleLogEntry(
            scheduleId: schedule.id,
            scheduleName: schedule.name.isEmpty ? schedule.action.summary : schedule.name,
            actionSummary: schedule.action.summary,
            timestamp: timestamp,
            status: status,
            batteryPercentage: batteryControl.status.currentPercentage,
            isPluggedIn: batteryControl.status.isPowerAdapterConnected
        )
        history.insert(entry, at: 0)
        saveHistory()
    }

    // MARK: - Helper Algorithms

    public static func resolveConflict(among candidates: [BatteryChargingSchedule]) -> BatteryChargingSchedule? {
        guard !candidates.isEmpty else { return nil }

        func priority(for action: ScheduleAction) -> Int {
            switch action {
            case .pauseCharging: return 3
            case .startTopUp: return 2
            case .setLimit: return 1
            }
        }

        return candidates.max { a, b in
            let pa = priority(for: a.action)
            let pb = priority(for: b.action)
            if pa != pb { return pa < pb }
            return a.createdAt < b.createdAt
        }
    }

    public static func shouldCatchUp(
        schedule: BatteryChargingSchedule,
        wakeDate: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard case .executeIfWithin(let minutes) = schedule.catchUpPolicy else { return false }
        guard schedule.repeatRule.matches(date: wakeDate, calendar: calendar) else { return false }

        var targetComponents = calendar.dateComponents([.year, .month, .day], from: wakeDate)
        targetComponents.hour = schedule.time.hour
        targetComponents.minute = schedule.time.minute
        targetComponents.second = 0
        guard let scheduledDate = calendar.date(from: targetComponents) else { return false }

        if let last = schedule.lastTriggeredAt, last >= scheduledDate {
            return false
        }

        let diff = wakeDate.timeIntervalSince(scheduledDate)
        return diff >= 0 && diff <= Double(minutes * 60)
    }

    public static func isRecentMissed(
        schedule: BatteryChargingSchedule,
        wakeDate: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard schedule.repeatRule.matches(date: wakeDate, calendar: calendar) else { return false }

        var targetComponents = calendar.dateComponents([.year, .month, .day], from: wakeDate)
        targetComponents.hour = schedule.time.hour
        targetComponents.minute = schedule.time.minute
        targetComponents.second = 0
        guard let scheduledDate = calendar.date(from: targetComponents) else { return false }

        if let last = schedule.lastTriggeredAt, last >= scheduledDate {
            return false
        }

        let diff = wakeDate.timeIntervalSince(scheduledDate)
        let catchUpMins: Int
        if case .executeIfWithin(let m) = schedule.catchUpPolicy {
            catchUpMins = m
        } else {
            catchUpMins = 0
        }

        return diff > Double(catchUpMins * 60) && diff <= 86400
    }

    public static func nextUpcoming(
        from schedules: [BatteryChargingSchedule],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (schedule: BatteryChargingSchedule, triggerDate: Date)? {
        let active = schedules.filter { $0.isEnabled }
        var upcoming: [(schedule: BatteryChargingSchedule, triggerDate: Date)] = []

        for schedule in active {
            for dayOffset in 0...7 {
                guard let candidateDay = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
                guard schedule.repeatRule.matches(date: candidateDay, calendar: calendar) else { continue }

                var comp = calendar.dateComponents([.year, .month, .day], from: candidateDay)
                comp.hour = schedule.time.hour
                comp.minute = schedule.time.minute
                comp.second = 0

                guard let trigger = calendar.date(from: comp), trigger > now else { continue }
                upcoming.append((schedule, trigger))
                break
            }
        }

        return upcoming.min { $0.triggerDate < $1.triggerDate }
    }

    // MARK: - Timer Loop

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                let now = Date()
                let calendar = Calendar.current
                let second = calendar.component(.second, from: now)
                let nanosecond = calendar.component(.nanosecond, from: now)
                let remainingSeconds = max(0.1, Double(60 - second) - Double(nanosecond) / 1_000_000_000.0)

                // Add 0.05s buffer to prevent early tick
                try? await Task.sleep(for: .seconds(remainingSeconds + 0.05))
                guard !Task.isCancelled, let self else { return }

                await self.evaluateSchedules(at: Date(), isWake: false)
            }
        }
    }
}
