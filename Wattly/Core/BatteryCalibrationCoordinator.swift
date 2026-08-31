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
    /// `evaluate`가 `await` 사이에서 재진입하지 못하게 막는다. `cancel()`/`start()`는 이
    /// 가드를 우회할 수 있는 별도 진입점이므로, 이 플래그만으로는 부족해 각 `await` 뒤에
    /// `run` identity도 다시 확인한다.
    private var isEvaluating = false

    public init(
        batteryControl: BatteryControlClient,
        defaults: UserDefaults = .standard,
        readBattery: (@Sendable () async -> CalibrationBatteryReading)? = nil,
        sleepAssertion: SleepAssertion = SleepAssertion(),
        notifyPause: @escaping @MainActor (CalibrationPause) -> Void =
            BatteryNotificationManager.postCalibrationActionNeeded,
        notifyFinished: @escaping @MainActor (CalibrationHistoryEntry) -> Void =
            BatteryNotificationManager.postCalibrationFinished,
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

    /// 방전이 너무 느려 제한 시간 안에 끝날 수 없다는 **관측**. 절차를 멈추지 않는다 —
    /// 사용자가 Mac을 쓰기 시작하면 속도가 회복되어 그대로 완주할 수 있기 때문이다.
    public var isDischargeTooSlow: Bool {
        guard let run else { return false }
        return BatteryCalibration.isDischargeTooSlowToFinish(
            step: run.step,
            soc: batteryControl.status.currentPercentage,
            observedRatePercentPerMinute: observedDischargeRate,
            stepActiveSeconds: run.timers.stepActiveSeconds)
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
        // 10시간 뒤에 뜰 완료 알림의 권한을 지금 받아 둔다. 거부되면 카드에 명시적으로 안내한다.
        BatteryNotificationManager.requestAuthorization()
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
            // 실행 중인 절차가 없어도 쿨다운의 "40 사이클" 판정이 `lastReading.cycleCount`를
            // 읽는다. 여기서 한 번 채워 두지 않으면 그 값이 영영 비어 있어 판정이 날짜만으로
            // 좁아진다.
            lastReading = await readBattery()
            if batteryControl.status.desiredConfiguration?.calibrationActive == true {
                // 고아 상태. 저장된 절차 없이 데몬만 캘리브레이션을 들고 있으면 충전 억제가
                // 무기한 남는다 — 무조건 끊는다.
                await batteryControl.applyCalibration(
                    primitive: .restore, snapshot: currentSnapshot())
            }
            return
        }
        if batteryControl.status.desiredConfiguration?.calibrationActive != true {
            // 반대 방향의 고아: 저장된 절차는 있는데 데몬이 캘리브레이션을 잊었다(재시작 등).
            // `appliedPrimitive`가 이미 목표와 같다고 믿으면 `applyIfChanged`가 재전송을
            // 건너뛰어 절차가 단계 타임아웃까지 idle 데몬을 향해 맹목적으로 흘러간다.
            run?.appliedPrimitive = nil
        }
        await evaluate(at: clock())
    }

    // MARK: - Tick

    public func evaluate(at now: Date) async {
        guard !isEvaluating else { return }
        isEvaluating = true
        defer { isEvaluating = false }

        // 원복 write가 지난 tick에서 실패했다면, 새 판정을 내리기 전에 그것부터 재시도한다.
        // 10초 타이머가 그대로 재시도 루프가 된다.
        if let current = run, let outcome = current.finishing {
            await finish(outcome: outcome, failure: current.finishingFailure, at: now)
            return
        }

        guard var state = run else { return }
        await batteryControl.refreshStatus()
        // `cancel()`은 이 `await` 사이에 끼어들 수 있는 별개의 진입점이다 — 재개된 이 tick이
        // 이미 끝난 run을 되살리지 않도록 identity를 다시 확인한다.
        guard run?.id == state.id else { return }
        let status = batteryControl.status
        let reading = await readBattery()
        guard run?.id == state.id else { return }
        lastReading = reading

        // `handleAppLaunch`의 고아 처리를 매 tick으로 반복한다. 데몬이 재시작하거나 정책을
        // 잃으면 `desiredConfiguration?.calibrationActive`가 `true`가 아니게 되는데,
        // `appliedPrimitive`를 그대로 두면 `applyIfChanged`가 "이미 적용됨"으로 오판해 재전송을
        // 건너뛴다 — 그러면 데몬이 캘리브레이션을 믿지 않게 된 순간부터 남은 절차 내내 다시
        // 무장되지 않는다. 앱 시작 시 한 번뿐이던 이 대조를 여기서도 하지 않으면 Fix 1의
        // 실패 모드(방전이 조용히 멈춘 채 진행)를 증폭시킨다. `run = state`가 각 분기에서
        // 이 mutation을 이어받으므로 `run?.id == state.id` 가드와 다투지 않는다.
        if status.desiredConfiguration?.calibrationActive != true {
            state.appliedPrimitive = nil
        }

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
        let id = state.id
        let result = await batteryControl.applyCalibration(primitive: primitive, snapshot: state.snapshot)
        // `cancel()`이 이 write 도중에 끼어들어 다른(또는 없는) run으로 바꿔치기했을 수 있다.
        guard run?.id == id else { return }
        // 실패한 write를 적용된 것으로 기록하면 다음 tick이 재시도하지 않는다 — 전이 write가
        // 조용히 사라지고 절차는 데몬이 아직 이전 단계에 머무는 줄 모른 채 흘러간다.
        guard result != nil else { return }
        state.appliedPrimitive = primitive
        run = state
        saveState()
    }

    private func finish(outcome: CalibrationOutcome, failure: CalibrationFailure?, at now: Date) async {
        guard var state = run else { return }
        sleepAssertion.release()

        // 종료 의도를 먼저 기록한다. 아래 원복 write가 실패해도 이 값은 남아 다음 tick의
        // `evaluate`가 재시도할 수 있다. 같은 의도로 재시도하는 중이면 다시 쓰지 않는다.
        if state.finishing != outcome || state.finishingFailure != failure {
            state.finishing = outcome
            state.finishingFailure = failure
            run = state
            saveState()
        }

        // `.restore`가 이미 적용·확인돼 있다면(성공적인 완주가 `advance(to: .restoring, ...)`
        // 에서 이미 써 둔 경우) 다시 쓰지 않는다 — 전이가 아닌 반복 write는 SMC 트래픽 규칙이
        // 금지하고, 그 write는 이미 검증됐다. 취소·실패 경로에서는 `.restore`가 아직 적용된 적이
        // 없으므로 이 분기를 타지 않고 아래에서 정상적으로 write한다.
        var restoreConfirmed = state.appliedPrimitive == .restore
        if !restoreConfirmed {
            let status = await batteryControl.applyCalibration(primitive: .restore, snapshot: state.snapshot)
            guard run?.id == state.id else { return }
            restoreConfirmed = status != nil
            if restoreConfirmed {
                state.appliedPrimitive = .restore
            }
        }

        guard restoreConfirmed else {
            // 원복 write가 실패했다. `run`을 지우지 않고 `finishing`을 세운 채로 남긴다 — 지우면
            // 데몬은 캘리브레이션을 계속 들고 있는데 앱에는 아무 실행 상태도 없어, reconcile
            // 루프조차 고치지 못하는(오히려 desiredConfiguration에서 그 상태를 되읽어 매분
            // 재확인하는) 궁지가 된다. 다음 tick이 이어서 재시도한다.
            run = state
            saveState()
            return
        }

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
