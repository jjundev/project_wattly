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
    private let isCalibrationRunning: @MainActor () -> Bool
    nonisolated(unsafe) private var timerTask: Task<Void, Never>?

    public init(
        batteryControl: BatteryControlClient,
        defaults: UserDefaults = .standard,
        isCalibrationRunning: @escaping @MainActor () -> Bool = { false }
    ) {
        self.batteryControl = batteryControl
        self.defaults = defaults
        self.isCalibrationRunning = isCalibrationRunning
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

        // 캘리브레이션 중에는 발화하지 않는다. `execute`가 `defaults.set`으로 사용자 설정
        // 자체를 덮어쓰기 때문에, 절차 시작 시점 스냅샷과 저장값이 갈라지고 원복이 잘못된
        // 값을 되돌린다. 조용히 넘기지 않고 사유를 이력에 남긴다.
        guard !isCalibrationRunning() else {
            recordLog(schedule: winning, status: .skipped(reason: .calibrationRunning),
                      timestamp: date)
            return
        }

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

    /// 알림 배너와 실행 이력에 남길 문자열을 확정할 로케일.
    ///
    /// 이 코디네이터는 SwiftUI 뷰가 아니라 `@Observable` 클래스라 `@Environment(\.locale)`을 받을 수
    /// 없다. 그래서 `BatteryNotificationManager`가 쓰는 방식 그대로 저장된 앱 언어에서 로케일을
    /// 되살린다. 다만 `.standard`를 직접 읽지 않고 주입된 `defaults`를 읽는다 — 운영에서는 둘이
    /// 같은 저장소이고(`@AppStorage`도 `.standard`에 쓴다), 테스트는 언어를 격리해 제어할 수 있다.
    ///
    /// 이력 항목은 `actionSummary`를 **문자열 그대로** 저장하므로, 여기서 고른 언어가 그 항목의
    /// 언어로 영구히 굳는다. 나중에 앱 언어를 바꿔도 지난 기록은 실행 당시 언어로 남는다.
    var activeLocale: Locale {
        AppLanguage.locale(for: defaults.string(forKey: StorageKey.appLanguage) ?? Defaults.appLanguage)
    }

    /// "충전 일시 정지"가 내리는 한도. 편집기의 경고 문구와 실제 실행이 같은 숫자를 봐야 하므로
    /// 리터럴로 두지 않는다.
    public nonisolated static let pauseChargingLimitPercentage = 50

    /// "충전 일시 정지"는 한도를 낮추는 것으로 구현돼 있어서, 자동 방전이 켜져 있으면 그
    /// 한도 변경이 곧 강제 방전 명령이 된다. 라벨은 "정지"인데 실제로는 배터리를 태워 내리는
    /// 셈이므로 편집기와 실행 알림 양쪽에서 같은 문장으로 알린다. 동작 자체는 바꾸지 않는다.
    public nonisolated static func autoDischargeWarning(
        action: ScheduleAction,
        isAutoDischargeEnabled: Bool,
        locale: Locale
    ) -> String? {
        guard action == .pauseCharging, isAutoDischargeEnabled else { return nil }
        return String(
            format: String(localized: "자동 방전이 켜져 있어 이 스케줄은 배터리를 %lld%%까지 방전합니다.", locale: locale),
            locale: locale,
            Int64(pauseChargingLimitPercentage))
    }

    /// `defaults.integer(forKey:)` returns `0` for an absent key, but `Defaults.batteryManualDischargeTarget`
    /// is `80` — a bare read would send `0`, which the daemon clamps to 50 and silently overwrites a
    /// user-configured target. Guard on presence instead, the same way `BatteryIntentBridge` does.
    private var effectiveManualDischargeTarget: Int {
        defaults.object(forKey: StorageKey.batteryManualDischargeTarget) != nil
            ? defaults.integer(forKey: StorageKey.batteryManualDischargeTarget)
            : Defaults.batteryManualDischargeTarget
    }

    /// `defaults.integer(forKey:)` returns `0` for an absent key. `batteryHeatProtectionThreshold`
    /// has no control in the battery settings UI — only `SettingsReset` and an App Intent that
    /// supplies a threshold ever write it — so on most Macs the key is absent and a bare read would
    /// send `0`, which the daemon clamps to 30 instead of the intended
    /// `Defaults.batteryHeatProtectionThreshold` (35), inhibiting charging 5°C early. Guard on
    /// presence instead, the same way `effectiveManualDischargeTarget` above does.
    private var effectiveHeatProtectionThreshold: Int {
        defaults.object(forKey: StorageKey.batteryHeatProtectionThreshold) != nil
            ? defaults.integer(forKey: StorageKey.batteryHeatProtectionThreshold)
            : Defaults.batteryHeatProtectionThreshold
    }

    /// `defaults.integer(forKey:)` returns `0` for an absent key, but `Defaults.batteryLimitPercentage`
    /// is not `0` — if this coordinator ever runs before the user has touched the limit slider (the
    /// key absent), a bare read would send `0` to the daemon instead of the intended default. Guard
    /// on presence instead, the same way `effectiveManualDischargeTarget` above does.
    private var effectiveLimitPercentage: Int {
        defaults.object(forKey: StorageKey.batteryLimitPercentage) != nil
            ? defaults.integer(forKey: StorageKey.batteryLimitPercentage)
            : Defaults.batteryLimitPercentage
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
                heatProtectionThresholdCelsius: effectiveHeatProtectionThreshold,
                autoDischargeEnabled: defaults.bool(forKey: StorageKey.batteryAutoDischargeEnabled),
                manualDischargeTarget: effectiveManualDischargeTarget
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
                    limitPercentage: effectiveLimitPercentage,
                    lowerHysteresisDelta: defaults.bool(forKey: StorageKey.batterySailingEnabled)
                        ? defaults.integer(forKey: StorageKey.batterySailingDelta) : 2,
                    heatProtectionEnabled: defaults.bool(forKey: StorageKey.batteryHeatProtectionEnabled),
                    heatProtectionThresholdCelsius: effectiveHeatProtectionThreshold,
                    autoDischargeEnabled: defaults.bool(forKey: StorageKey.batteryAutoDischargeEnabled),
                    manualDischargeTarget: effectiveManualDischargeTarget
                )
                if status != nil && status?.mode != .unavailable {
                    recordLog(schedule: schedule, status: .success, timestamp: date)
                } else {
                    recordLog(schedule: schedule, status: .failed(reason: String(localized: "도우미 연결 실패")), timestamp: date)
                }
            }

        case .pauseCharging:
            defaults.set(true, forKey: StorageKey.batteryLimitEnabled)
            defaults.set(Self.pauseChargingLimitPercentage, forKey: StorageKey.batteryLimitPercentage)
            let status = await batteryControl.apply(
                enabled: true,
                limitPercentage: Self.pauseChargingLimitPercentage,
                lowerHysteresisDelta: 2,
                heatProtectionEnabled: defaults.bool(forKey: StorageKey.batteryHeatProtectionEnabled),
                heatProtectionThresholdCelsius: effectiveHeatProtectionThreshold,
                autoDischargeEnabled: defaults.bool(forKey: StorageKey.batteryAutoDischargeEnabled),
                manualDischargeTarget: effectiveManualDischargeTarget
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
            let locale = activeLocale
            BatteryNotificationManager.postScheduleTriggeredNotification(
                scheduleName: schedule.name,
                actionSummary: schedule.action.summary(locale: locale),
                locale: locale,
                // 편집기 경고를 못 보고 저장한 스케줄도 있을 수 있으므로 실행 시점에 한 번 더 알린다.
                note: Self.autoDischargeWarning(
                    action: schedule.action,
                    isAutoDischargeEnabled: defaults.bool(forKey: StorageKey.batteryAutoDischargeEnabled),
                    locale: locale)
            )
        }
    }

    private func recordLog(schedule: BatteryChargingSchedule, status: BatteryScheduleLogEntry.Status, timestamp: Date) {
        let summary = schedule.action.summary(locale: activeLocale)
        let entry = BatteryScheduleLogEntry(
            scheduleId: schedule.id,
            scheduleName: schedule.name.isEmpty ? summary : schedule.name,
            actionSummary: summary,
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
