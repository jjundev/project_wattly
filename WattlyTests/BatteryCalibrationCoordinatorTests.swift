import Foundation
import Testing
@testable import Wattly

@MainActor
struct BatteryCalibrationCoordinatorTests {
    private final class Fake: @unchecked Sendable {
        var status: BatteryControlServiceStatus
        var reading: CalibrationBatteryReading
        var writes: [BatteryControlConfiguration] = []

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

    private func makeSubject(
        _ fake: Fake,
        defaults: UserDefaults,
        clock: @escaping @Sendable () -> Date
    ) -> BatteryCalibrationCoordinator {
        let client = BatteryControlClient { request in
            if case .configure(let data) = request,
               let decoded = try? BatteryControlCodec.decode(
                   BatteryControlConfigurationRequest.self, from: data) {
                fake.writes.append(decoded.configuration)
                fake.status.desiredConfiguration = decoded.configuration
            }
            return (try? BatteryControlCodec.encode(fake.status), nil)
        }
        return BatteryCalibrationCoordinator(
            batteryControl: client,
            defaults: defaults,
            readBattery: { fake.reading },
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

        let second = makeSubject(fake, defaults: defaults, clock: { Date(timeIntervalSince1970: 30) })
        await second.handleAppLaunch()
        #expect(second.run?.id == runID)
        #expect(second.isRunning)
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
}

struct BatteryCalibrationRateTests {
    @Test func blendedRateFavoursHistoryButFollowsReality() {
        #expect(BatteryCalibration.blendedRate(previous: nil, sample: 0.3) == 0.3)
        let blended = BatteryCalibration.blendedRate(previous: 0.2, sample: 0.4)
        #expect(blended > 0.2 && blended < 0.4)
    }
}
