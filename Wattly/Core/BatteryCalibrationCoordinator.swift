import Foundation
import Observation

/// 캘리브레이션 절차를 소유하는 얇은 코디네이터.
///
/// 판단은 전부 `BatteryCalibration`(순수)에 있고 여기는 세 가지만 한다: 10초마다 사실을
/// 모으고, 결정을 XPC 호출로 번역하고, 상태를 디스크에 남긴다.
///
/// 데몬이 아니라 앱이 절차를 소유하는 이유: 데몬으로 옮기면 앱 없이도 완주하지만 root 코드에
/// 단계·타이머·정책 파일 schema v2가 들어간다. 앱 소유라면 root 변경이 필드 2개와 분기
/// 하나로 끝나고, 앱이 죽었을 때의 최악은 엔진 하한 가드가 만드는 "하한 도달 후 홀드"라는
/// 설계된 안전 상태다. 그 상태도 12시간 뒤에는 `handleAppLaunch`의 고아 처리나 데몬의 Top Up
/// 만료가 정리한다.
@MainActor
@Observable public final class BatteryCalibrationCoordinator {
    /// 10초. 5초짜리 데몬 샘플보다 성기게 두는 이유는, 이 루프가 10시간 동안 돌면서
    /// XPC 왕복과 IOKit 판독을 매 tick 수행하기 때문이다.
    public static let tickInterval: TimeInterval = 10
    public static let maxHistoryCount = 5

    public private(set) var run: CalibrationRunState?
    public private(set) var history: [CalibrationHistoryEntry] = []
    public private(set) var lastReading = CalibrationBatteryReading()

    private let batteryControl: BatteryControlClient
    private let defaults: UserDefaults
    private let readBattery: @Sendable () async -> CalibrationBatteryReading
    private let sleepAssertion: SleepAssertion
    /// 알림 호출을 주입받는 이유는 테스트다. `UNUserNotificationCenter`를 건드리면 단위
    /// 테스트가 실제 알림 권한 상태에 의존하게 된다.
    private let notifyPause: @MainActor (CalibrationPause) -> Void
    private let notifyFinished: @MainActor (CalibrationHistoryEntry) -> Void
    private let clock: @Sendable () -> Date
    private var observedDischargeRate: Double?
    nonisolated(unsafe) private var timerTask: Task<Void, Never>?

    public init(
        batteryControl: BatteryControlClient,
        defaults: UserDefaults = .standard,
        readBattery: (@Sendable () async -> CalibrationBatteryReading)? = nil,
        sleepAssertion: SleepAssertion = SleepAssertion(),
        // 실제 알림 기본값(BatteryNotificationManager.postCalibrationActionNeeded /
        // postCalibrationFinished)은 아직 없다 — 알림 태스크(Task 17)가 추가하며 이 자리를
        // 되살린다. 그때까지는 no-op.
        notifyPause: @escaping @MainActor (CalibrationPause) -> Void = { _ in },
        // 위와 동일한 이유로 no-op. 알림 태스크가 postCalibrationFinished로 되살린다.
        notifyFinished: @escaping @MainActor (CalibrationHistoryEntry) -> Void = { _ in },
        clock: @escaping @Sendable () -> Date = { Date() },
        startsTimer: Bool = true
    ) {
        self.batteryControl = batteryControl
        self.defaults = defaults
        let reader = AppleSmartBatteryReader()
        self.readBattery = readBattery ?? { await reader.read() }
        self.sleepAssertion = sleepAssertion
        self.notifyPause = notifyPause
        self.notifyFinished = notifyFinished
        self.clock = clock
        loadState()
        if startsTimer { startTimer() }
    }

    deinit { timerTask?.cancel() }

    public var isRunning: Bool { run != nil }

    /// 이력에서 유도한다 — 별도 키를 두면 두 값이 어긋날 수 있다.
    public var lastCompleted: CalibrationHistoryEntry? {
        history.first { $0.outcome == .completed }
    }

    public var estimatedRemainingMinutes: Int? {
        guard let run else { return nil }
        return BatteryCalibration.estimatedRemainingMinutes(
            step: run.step,
            soc: batteryControl.status.currentPercentage,
            chargeRatePercentPerMinute: nil,
            dischargeRatePercentPerMinute: observedDischargeRate)
    }

    public var isWithinCooldown: Bool {
        BatteryCalibration.isWithinCooldown(
            lastCompletedAt: lastCompleted?.finishedAt,
            cycleCountAtLastCompletion: lastCompleted?.endCycleCount,
            currentCycleCount: lastReading.cycleCount,
            now: clock())
    }

    // MARK: - 수명주기

    public func start() async {
        guard run == nil else { return }
        await batteryControl.refreshStatus()
        let reading = await readBattery()
        lastReading = reading
        let now = clock()
        run = CalibrationRunState(
            id: UUID(),
            startedAt: now,
            step: .preflight,
            timers: CalibrationTimers(),
            pause: nil,
            snapshot: currentSnapshot(),
            beginMaxCapacityMilliampHours: reading.maxCapacityMilliampHours,
            beginCycleCount: reading.cycleCount,
            lastProgressAt: now,
            lastTickAt: now,
            appliedPrimitive: nil)
        observedDischargeRate = nil
        saveState()
        // 첫 tick이 preflight → chargeToFull 전이를 수행한다.
        await evaluate(at: now)
    }

    public func cancel() async {
        guard run != nil else { return }
        await finish(outcome: .cancelled, failure: nil, at: clock())
    }

    /// 앱 시작 시 한 번. 저장 상태와 데몬 상태를 대조한다.
    public func handleAppLaunch() async {
        loadState()
        await batteryControl.refreshStatus()
        if run == nil {
            if batteryControl.status.desiredConfiguration?.calibrationActive == true {
                // 고아 상태. 저장된 절차 없이 데몬만 캘리브레이션을 들고 있으면 충전 억제가
                // 무기한 남는다 — 무조건 끊는다.
                await batteryControl.applyCalibration(
                    primitive: .restore, snapshot: currentSnapshot())
            }
            return
        }
        await evaluate(at: clock())
    }

    // MARK: - Tick

    public func evaluate(at now: Date) async {
        guard var state = run else { return }
        await batteryControl.refreshStatus()
        let status = batteryControl.status
        let reading = await readBattery()
        lastReading = reading

        let elapsed = now.timeIntervalSince(state.lastTickAt)
        let isSleepGap = elapsed > BatteryCalibration.sleepGapSeconds
        let soc = status.currentPercentage
        let previousSoC = state.timers.lastSoC
        let isFullSettled = soc >= 100 && reading.isCharging == false
        // 어댑터 판정에 `AdapterDetails.Watts`가 반드시 들어간다. CHIE 강제 방전 중에는
        // `isPowerAdapterConnected`가 거짓말한다.
        let adapterPresent = reading.isAdapterPresent || status.isPowerAdapterConnected

        // 진행 판정은 **깨어 있고 일시정지도 아닌** tick에서만 한다.
        //
        // `tick`의 일시정지 분기는 `lastSoC`를 갱신하지 않은 채 조기 반환한다. 그래서 일시정지
        // 중에 SoC가 1%라도 흘러가면 `lastSoC != soc`가 그 뒤 **매 tick** 참이 되고,
        // `lastProgressAt`이 계속 갱신돼 12시간 무진행 취소가 영영 발동하지 않는다. 방전 단계에서
        // 그 조합은 최악이다 — 코디네이터는 `.pause`에서 아무것도 쓰지 않으므로 CHIE 방전 명령이
        // 그대로 걸린 채 하한 아래로 계속 내려간다.
        let isActiveTick = !isSleepGap && state.pause?.consumesBudget != true
        if isActiveTick, let previousSoC, previousSoC != soc {
            if state.step == .dischargeToFloor, previousSoC > soc {
                let minutes = (state.timers.socUnchangedSeconds + elapsed) / 60
                if minutes > 0 {
                    observedDischargeRate = BatteryCalibration.blendedRate(
                        previous: observedDischargeRate,
                        sample: Double(previousSoC - soc) / minutes)
                }
            }
            state.lastProgressAt = now
        }

        state.timers = BatteryCalibration.tick(
            state.timers,
            elapsed: elapsed,
            isSleepGap: isSleepGap,
            isPaused: state.pause?.consumesBudget == true,
            soc: soc,
            isFullSettled: isFullSettled,
            isChargeStalled: reading.isChargeStalled)
        state.lastTickAt = now

        let decision = BatteryCalibration.decide(CalibrationInput(
            step: state.step,
            timers: state.timers,
            soc: soc,
            isAdapterPresent: adapterPresent,
            isHeatProtected: status.activity == .heatProtection,
            helperReady: status.mode != .unavailable,
            dischargeSupported: status.isDischargeHardwareSupported != false,
            isSleepGap: isSleepGap,
            isChargeStalled: reading.isChargeStalled,
            secondsSinceProgress: now.timeIntervalSince(state.lastProgressAt)))

        switch decision {
        case .hold(let primitive):
            state.pause = nil
            run = state
            updateSleepAssertion(for: state.step)
            await applyIfChanged(primitive)

        case .advance(let next, let primitive):
            state.step = next
            state.timers = state.timers.resetForNewStep()
            state.pause = nil
            state.lastProgressAt = now
            run = state
            updateSleepAssertion(for: next)
            await applyIfChanged(primitive)

        case .pause(let reason):
            // 일시정지에서는 아무것도 쓰지 않는다. 데몬은 마지막 원시 명령을 그대로 들고
            // 있어야 하고, 재개는 다음 tick의 `.hold`가 처리한다.
            let isNewReason = state.pause != reason
            state.pause = reason
            run = state
            sleepAssertion.release()
            saveState()
            // 같은 사유로 매 tick 알리지 않는다. 10시간짜리 절차에서 그건 알림 폭탄이다.
            if isNewReason { notifyPause(reason) }

        case .finish(let outcome, let failure):
            run = state
            await finish(outcome: outcome, failure: failure, at: now)
        }
    }

    // MARK: - 내부

    /// 같은 원시 명령을 다시 쓰지 않는다. 전이가 아닌 반복 write는 SMC 트래픽 규칙이 금지하고,
    /// 헬퍼가 재시작해 상태를 잃는 경우는 `BatteryControlBridge`의 reconcile 루프가 고친다.
    private func applyIfChanged(_ primitive: CalibrationPrimitive) async {
        guard var state = run else { return }
        guard state.appliedPrimitive != primitive else { saveState(); return }
        await batteryControl.applyCalibration(primitive: primitive, snapshot: state.snapshot)
        state.appliedPrimitive = primitive
        run = state
        saveState()
    }

    private func finish(outcome: CalibrationOutcome, failure: CalibrationFailure?, at now: Date) async {
        guard let state = run else { return }
        sleepAssertion.release()
        await batteryControl.applyCalibration(primitive: .restore, snapshot: state.snapshot)
        let reading = await readBattery()
        lastReading = reading
        let entry = CalibrationHistoryEntry(
            id: state.id,
            startedAt: state.startedAt,
            finishedAt: now,
            outcome: outcome,
            failure: failure,
            beginMaxCapacityMilliampHours: state.beginMaxCapacityMilliampHours,
            endMaxCapacityMilliampHours: reading.maxCapacityMilliampHours,
            beginCycleCount: state.beginCycleCount,
            endCycleCount: reading.cycleCount)
        history.insert(entry, at: 0)
        history = Array(history.prefix(Self.maxHistoryCount))
        run = nil
        observedDischargeRate = nil
        saveState()
        notifyFinished(entry)
    }

    private func updateSleepAssertion(for step: CalibrationStep) {
        if step == .dischargeToFloor {
            sleepAssertion.acquire(reason: "Wattly battery calibration discharge")
        } else {
            sleepAssertion.release()
        }
    }

    private func startTimer() {
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(BatteryCalibrationCoordinator.tickInterval))
                guard !Task.isCancelled, let self else { return }
                await self.evaluate(at: self.clockNow())
            }
        }
    }

    private func clockNow() -> Date { clock() }

    // MARK: - 지속 저장

    /// 시작 시점의 사용자 설정. `defaults.integer(forKey:)`가 없는 키에 `0`을 돌려주므로
    /// 존재 여부를 먼저 확인한다 — `BatteryScheduleCoordinator`와 같은 이유다.
    public func currentSnapshot() -> CalibrationSnapshot {
        func int(_ key: String, _ fallback: Int) -> Int {
            defaults.object(forKey: key) != nil ? defaults.integer(forKey: key) : fallback
        }
        return CalibrationSnapshot(
            limitEnabled: defaults.bool(forKey: StorageKey.batteryLimitEnabled),
            limitPercentage: int(StorageKey.batteryLimitPercentage, Defaults.batteryLimitPercentage),
            sailingEnabled: defaults.bool(forKey: StorageKey.batterySailingEnabled),
            sailingDelta: int(StorageKey.batterySailingDelta, Defaults.batterySailingDelta),
            heatProtectionEnabled: defaults.bool(forKey: StorageKey.batteryHeatProtectionEnabled),
            heatProtectionThresholdCelsius: int(
                StorageKey.batteryHeatProtectionThreshold, Defaults.batteryHeatProtectionThreshold),
            autoDischargeEnabled: defaults.bool(forKey: StorageKey.batteryAutoDischargeEnabled),
            manualDischargeTarget: int(
                StorageKey.batteryManualDischargeTarget, Defaults.batteryManualDischargeTarget))
    }

    public func loadState() {
        run = decode(CalibrationRunState.self, forKey: StorageKey.batteryCalibrationState)
        history = decode([CalibrationHistoryEntry].self,
                         forKey: StorageKey.batteryCalibrationHistory) ?? []
    }

    private func saveState() {
        encode(run, forKey: StorageKey.batteryCalibrationState)
        encode(history, forKey: StorageKey.batteryCalibrationHistory)
    }

    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let raw = defaults.string(forKey: key), let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T?, forKey key: String) {
        guard let value,
              let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            defaults.set("", forKey: key)
            return
        }
        defaults.set(string, forKey: key)
    }
}
