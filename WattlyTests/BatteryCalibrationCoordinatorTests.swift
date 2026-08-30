import Foundation
import Testing
@testable import Wattly

@MainActor
struct BatteryCalibrationCoordinatorTests {
    private final class Fake: @unchecked Sendable {
        var status: BatteryControlServiceStatus
        var reading: CalibrationBatteryReading
        var writes: [BatteryControlConfiguration] = []
        /// 켜면 이후 `.configure` 요청이 XPC 오류로 실패한다 — 원복/전이 write가 거부되는
        /// 상황(Fix 1/4)을 흉내내는 용도다.
        var rejectWrites = false

        init() {
            status = BatteryControlServiceStatus(
                mode: .charging, currentPercentage: 50, isPowerAdapterConnected: true,
                detail: "", updatedAt: 0,
                isHardwareSupported: true, isDischargeHardwareSupported: true,
                capabilities: [.calibrationV1])
            reading = CalibrationBatteryReading(
                isCharging: true, adapterWatts: 68, chargingCurrentMilliamps: 2500,
                maxCapacityMilliampHours: 6208, designCapacityMilliampHours: 6249,
                cycleCount: 112)
        }
    }

    /// 재진입/취소 경쟁 테스트가 `readBattery`의 정지 지점을 직접 통제할 수 있게 해 준다.
    /// `armed`일 때만 실제로 suspend하므로, 통제되지 않은 tick(예: `start()`)은 그대로
    /// 지나간다.
    private actor Gate {
        private var armed = false
        private var isWaiting = false
        private var continuation: CheckedContinuation<Void, Never>?

        func arm() { armed = true }

        func waitIfArmed() async {
            guard armed else { return }
            armed = false
            isWaiting = true
            await withCheckedContinuation { continuation = $0 }
            isWaiting = false
        }

        /// suspend된 tick이 실제로 continuation에서 멈출 때까지 폴링한다 — 단일
        /// `Task.yield()`에 기대는 것보다 신뢰할 수 있다.
        func waitUntilBlocked() async {
            while !isWaiting {
                await Task.yield()
            }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func makeSubject(
        _ fake: Fake,
        defaults: UserDefaults,
        clock: @escaping @Sendable () -> Date,
        readBattery: (@Sendable () async -> CalibrationBatteryReading)? = nil
    ) -> BatteryCalibrationCoordinator {
        let client = BatteryControlClient { request in
            if case .configure(let data) = request {
                if fake.rejectWrites {
                    return (nil, NSError(domain: "test", code: 1))
                }
                if let decoded = try? BatteryControlCodec.decode(
                    BatteryControlConfigurationRequest.self, from: data) {
                    fake.writes.append(decoded.configuration)
                    fake.status.desiredConfiguration = decoded.configuration
                }
            }
            return (try? BatteryControlCodec.encode(fake.status), nil)
        }
        return BatteryCalibrationCoordinator(
            batteryControl: client,
            defaults: defaults,
            readBattery: readBattery ?? { fake.reading },
            sleepAssertion: SleepAssertion(create: { _ in 1 }, release: { _ in }),
            notifyPause: { _ in },
            notifyFinished: { _ in },
            clock: clock,
            startsTimer: false)
    }

    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func startEntersTheFirstChargeStepAndRecordsTheBaseline() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.start")
        let subject = makeSubject(fake, defaults: defaults, clock: { Date(timeIntervalSince1970: 0) })

        await subject.start()

        #expect(subject.isRunning)
        #expect(subject.run?.step == .chargeToFull)
        #expect(subject.run?.beginMaxCapacityMilliampHours == 6208)
        #expect(subject.run?.beginCycleCount == 112)
        #expect(fake.writes.last?.calibrationActive == true)
        #expect(fake.writes.last?.topUpActive == true)
        // 절차 중에는 자동 방전을 세워 둔다 — 같은 CHIE를 다투면 방전이 되돌려진다.
        #expect(fake.writes.last?.autoDischargeEnabled == false)
    }

    @Test func aRepeatedTickDoesNotRewriteTheSamePrimitive() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.norewrite")
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 0)
        let subject = makeSubject(fake, defaults: defaults, clock: { now })
        await subject.start()
        let afterStart = fake.writes.count

        now = now.addingTimeInterval(10)
        await subject.evaluate(at: now)
        now = now.addingTimeInterval(10)
        await subject.evaluate(at: now)

        // 전이가 아닌 반복 write는 SMC 트래픽 규칙이 금지한다.
        #expect(fake.writes.count == afterStart)
    }

    @Test func fullSettledForAMinuteAdvancesIntoDischarge() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.full")
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 0)
        let subject = makeSubject(fake, defaults: defaults, clock: { now })
        await subject.start()

        fake.status.currentPercentage = 100
        fake.reading.isCharging = false
        for _ in 0..<7 {
            now = now.addingTimeInterval(10)
            await subject.evaluate(at: now)
        }

        #expect(subject.run?.step == .dischargeToFloor)
        #expect(fake.writes.last?.topUpActive == false)
        #expect(fake.writes.last?.calibrationActive == true)
    }

    @Test func adapterLossDuringChargePausesWithoutWriting() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.adapter")
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 0)
        let subject = makeSubject(fake, defaults: defaults, clock: { now })
        await subject.start()
        let afterStart = fake.writes.count

        fake.reading.adapterWatts = 0
        fake.status.isPowerAdapterConnected = false
        now = now.addingTimeInterval(10)
        await subject.evaluate(at: now)

        #expect(subject.run?.pause == .needsAdapter)
        #expect(fake.writes.count == afterStart)
        #expect(subject.isRunning)
    }

    /// CHIE 강제 방전 중에는 `isPowerAdapterConnected`가 거짓말을 하지만 `AdapterDetails.Watts`는
    /// 여전히 참을 보고한다(개발기에서 3회 재현). `adapterLossDuringChargePausesWithoutWriting`은
    /// 둘 다 꺼서 `reading.isAdapterPresent` 항을 빼먹은 구현도 통과시키므로, 이 항이 실제로
    /// 지키는 조합을 별도로 고정한다.
    @Test func adapterWattsAloneKeepsTheProcedureRunningDuringForcedDischarge() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.adapter-watts-only")
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 0)
        let subject = makeSubject(fake, defaults: defaults, clock: { now })
        await subject.start()

        fake.reading.adapterWatts = 68
        fake.status.isPowerAdapterConnected = false
        now = now.addingTimeInterval(10)
        await subject.evaluate(at: now)

        #expect(subject.run?.pause == nil)
        #expect(subject.isRunning)
    }

    @Test func aLongGapBetweenTicksIsTreatedAsSleepNotAsAStall() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.sleep")
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 0)
        let subject = makeSubject(fake, defaults: defaults, clock: { now })
        await subject.start()
        // 방전 단계로 강제 진입
        fake.status.currentPercentage = 100
        fake.reading.isCharging = false
        for _ in 0..<7 { now = now.addingTimeInterval(10); await subject.evaluate(at: now) }
        #expect(subject.run?.step == .dischargeToFloor)

        // 뚜껑을 20분 덮었다: SoC 무변화 + tick 공백. 정체로 오인하면 60%에서 절차가 끝난다.
        fake.status.currentPercentage = 60
        now = now.addingTimeInterval(1200)
        await subject.evaluate(at: now)

        #expect(subject.run?.pause == .systemSleep)
        #expect(subject.run?.timers.socUnchangedSeconds == 0)
        #expect(subject.run?.step == .dischargeToFloor)
    }

    @Test func cancelRestoresTheSnapshotAndRecordsHistory() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.cancel")
        defaults.set(true, forKey: StorageKey.batteryLimitEnabled)
        defaults.set(85, forKey: StorageKey.batteryLimitPercentage)
        defaults.set(true, forKey: StorageKey.batteryAutoDischargeEnabled)
        let subject = makeSubject(fake, defaults: defaults, clock: { Date(timeIntervalSince1970: 0) })
        await subject.start()

        await subject.cancel()

        #expect(subject.isRunning == false)
        #expect(fake.writes.last?.calibrationActive == false)
        #expect(fake.writes.last?.limitPercentage == 85)
        #expect(fake.writes.last?.autoDischargeEnabled == true)   // 원값 복원
        #expect(subject.history.first?.outcome == .cancelled)
    }

    @Test func stateAndHistorySurviveARelaunch() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.persist")
        let first = makeSubject(fake, defaults: defaults, clock: { Date(timeIntervalSince1970: 0) })
        await first.start()
        let runID = first.run?.id
        #expect(first.run?.appliedPrimitive == .chargeToFull)

        let second = makeSubject(fake, defaults: defaults, clock: { Date(timeIntervalSince1970: 30) })
        await second.handleAppLaunch()
        #expect(second.run?.id == runID)
        #expect(second.isRunning)
        // 데몬이 여전히 캘리브레이션을 들고 있으므로(같은 fake를 공유) 재무장 분기(Fix 3)를
        // 타지 않아야 하고, 저장된 appliedPrimitive가 그대로 살아남아야 한다.
        #expect(second.run?.appliedPrimitive == .chargeToFull)
    }

    @Test func aDaemonThatForgotCalibrationIsReArmedOnLaunch() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.forgot")
        let first = makeSubject(fake, defaults: defaults, clock: { Date(timeIntervalSince1970: 0) })
        await first.start()
        #expect(first.run?.appliedPrimitive == .chargeToFull)

        // 데몬이 재시작해 캘리브레이션을 잊었다: desiredConfiguration이 더는 그것을 들고
        // 있지 않다. appliedPrimitive만 믿으면 다음 tick이 write를 건너뛰어 절차가 idle
        // 데몬을 향해 맹목적으로 흘러간다.
        fake.status.desiredConfiguration = BatteryControlConfiguration(
            enabled: false, calibrationActive: false)
        let writesBeforeRelaunch = fake.writes.count

        let second = makeSubject(fake, defaults: defaults, clock: { Date(timeIntervalSince1970: 30) })
        await second.handleAppLaunch()

        #expect(second.isRunning)
        #expect(fake.writes.count > writesBeforeRelaunch)
        #expect(fake.writes.last?.calibrationActive == true)
        #expect(second.run?.appliedPrimitive == .chargeToFull)
    }

    @Test func launchWithNoRunStillPopulatesLastReadingForTheCooldownGate() async {
        let fake = Fake()
        fake.reading.cycleCount = 200
        let defaults = freshDefaults("calibration.launch-no-run")
        let subject = makeSubject(fake, defaults: defaults, clock: { Date(timeIntervalSince1970: 0) })

        await subject.handleAppLaunch()

        // `lastReading`이 채워지지 않았다면 `cycleCount`가 nil로 남아 90일/40사이클의
        // "또는" 중 사이클 쪽 탈출이 영영 발동하지 못한다.
        #expect(subject.lastReading.cycleCount == 200)
    }

    @Test func anOrphanedDaemonCalibrationIsReleasedOnLaunch() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.orphan")
        // 저장된 실행 상태는 없는데 데몬만 캘리브레이션을 들고 있다 — 무기한 충전 억제가
        // 남는 유일한 경로다.
        fake.status.desiredConfiguration = BatteryControlConfiguration(
            enabled: true, calibrationActive: true, calibrationTargetPercentage: 20)
        let subject = makeSubject(fake, defaults: defaults, clock: { Date(timeIntervalSince1970: 0) })

        await subject.handleAppLaunch()

        #expect(subject.isRunning == false)
        #expect(fake.writes.last?.calibrationActive == false)
    }

    @Test func historyKeepsAtMostFiveEntries() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.history")
        let subject = makeSubject(fake, defaults: defaults, clock: { Date(timeIntervalSince1970: 0) })
        for _ in 0..<7 {
            await subject.start()
            await subject.cancel()
        }
        #expect(subject.history.count == BatteryCalibrationCoordinator.maxHistoryCount)
    }

    // MARK: - Fix 1: 실패한 원복 write는 재시도된다

    @Test func aFailedRestoreWriteIsRetriedInsteadOfStrandingTheDaemon() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.finish-retry")
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 0)
        let subject = makeSubject(fake, defaults: defaults, clock: { now })
        await subject.start()

        fake.rejectWrites = true
        now = now.addingTimeInterval(10)
        await subject.cancel()

        // 원복 write가 거부됐다 — run을 지우면 데몬은 캘리브레이션을 영원히 들고 있는데
        // 앱은 그것을 고칠 실행 상태가 없어진다.
        #expect(subject.isRunning)
        #expect(subject.run?.finishing == .cancelled)
        #expect(subject.history.isEmpty)

        fake.rejectWrites = false
        now = now.addingTimeInterval(10)
        await subject.evaluate(at: now)

        // 다음 tick(10초 타이머와 같은 간격)이 재시도해 마무리한다.
        #expect(subject.isRunning == false)
        #expect(subject.history.count == 1)
        #expect(subject.history.first?.outcome == .cancelled)
    }

    // MARK: - Fix 2: `evaluate`는 재진입하지 않고, 도중 취소는 되살아나지 않는다

    @Test func evaluateReArmsWhenTheDaemonForgetsCalibrationMidRun() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.forgot-midrun")
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 0)
        let subject = makeSubject(fake, defaults: defaults, clock: { now })
        await subject.start()
        #expect(subject.run?.appliedPrimitive == .chargeToFull)

        // 데몬이 재시작해 캘리브레이션을 잊었다 — 이번엔 앱 재시작이 아니라 같은 실행이
        // 도는 중 다음 tick에서다. `handleAppLaunch`만 이 대조를 하면, 열 시간짜리 절차
        // 안에서는 이런 순간이 재무장 없이 그대로 흘러가 Fix 1의 실패 모드를 증폭시킨다.
        fake.status.desiredConfiguration = BatteryControlConfiguration(
            enabled: false, calibrationActive: false)
        let writesBefore = fake.writes.count

        now = now.addingTimeInterval(10)
        await subject.evaluate(at: now)

        // 아직 전이 문턱 아래라 단계는 그대로지만, 현재 primitive가 "이미 적용됨"으로
        // 건너뛰어지지 않고 다시 나가야 한다.
        #expect(subject.run?.step == .chargeToFull)
        #expect(fake.writes.count > writesBefore)
        #expect(fake.writes.last?.calibrationActive == true)
        #expect(subject.run?.appliedPrimitive == .chargeToFull)
    }

    @Test func cancellingASuspendedTickLeavesExactlyOneHistoryEntry() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.cancel-race")
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 0)
        let gate = Gate()
        let subject = makeSubject(fake, defaults: defaults, clock: { now }, readBattery: {
            await gate.waitIfArmed()
            return fake.reading
        })
        await subject.start()

        await gate.arm()
        now = now.addingTimeInterval(10)
        let task = Task { await subject.evaluate(at: now) }
        await gate.waitUntilBlocked()

        // tick이 `readBattery()` 안에서 정지된 동안 취소한다.
        await subject.cancel()

        #expect(subject.isRunning == false)
        #expect(subject.history.count == 1)
        #expect(subject.history.first?.outcome == .cancelled)

        // 정지됐던 tick을 재개시킨다 — 취소된 run을 되살리면 안 된다.
        await gate.release()
        await task.value

        #expect(subject.isRunning == false)
        #expect(subject.history.count == 1)
    }

    @Test func overlappingEvaluateCallsProduceOnlyOneDaemonWrite() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.overlap")
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 0)
        let gate = Gate()
        let subject = makeSubject(fake, defaults: defaults, clock: { now }, readBattery: {
            await gate.waitIfArmed()
            return fake.reading
        })
        await subject.start()

        fake.status.currentPercentage = 100
        fake.reading.isCharging = false
        for _ in 0..<5 {
            now = now.addingTimeInterval(10)
            await subject.evaluate(at: now)
        }
        // 아직 전이 문턱(fullHoldSeconds >= 60) 아래다.
        #expect(subject.run?.step == .chargeToFull)

        await gate.arm()
        now = now.addingTimeInterval(10)
        let writesBefore = fake.writes.count
        let task = Task { await subject.evaluate(at: now) }
        await gate.waitUntilBlocked()

        // 겹쳐 부른 두 번째 호출은 아무 일도 하지 않고 즉시 반환해야 한다.
        await subject.evaluate(at: now)
        #expect(fake.writes.count == writesBefore)

        await gate.release()
        await task.value

        #expect(subject.run?.step == .dischargeToFloor)
        #expect(fake.writes.count == writesBefore + 1)
    }

    // MARK: - Fix 4: 실패한 write는 적용된 것으로 기록되지 않는다

    @Test func aFailedPrimitiveWriteIsNotRecordedAsApplied() async {
        let fake = Fake()
        let defaults = freshDefaults("calibration.write-fail")
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 0)
        let subject = makeSubject(fake, defaults: defaults, clock: { now })
        await subject.start()

        fake.status.currentPercentage = 100
        fake.reading.isCharging = false
        fake.rejectWrites = true
        for _ in 0..<6 {
            now = now.addingTimeInterval(10)
            await subject.evaluate(at: now)
        }

        // 순수 판정은 write 성패와 무관하게 단계를 전이시킨다 — 문제는 그 write가 적용된
        // 것으로 잘못 기록되는 것이다.
        #expect(subject.run?.step == .dischargeToFloor)
        #expect(subject.run?.appliedPrimitive == .chargeToFull)

        fake.rejectWrites = false
        now = now.addingTimeInterval(10)
        await subject.evaluate(at: now)

        #expect(subject.run?.appliedPrimitive == .dischargeToFloor)
    }
}

struct BatteryCalibrationRateTests {
    @Test func blendedRateFavoursHistoryButFollowsReality() {
        #expect(BatteryCalibration.blendedRate(previous: nil, sample: 0.3) == 0.3)
        let blended = BatteryCalibration.blendedRate(previous: 0.2, sample: 0.4)
        #expect(blended > 0.2 && blended < 0.4)
    }
}
