import Foundation
import Testing
@testable import Wattly

@Suite struct NativeChargeLimitServiceTests {
    /// 테스트가 바꿔 끼우는 세계. 서비스는 `@Sendable` 클로저로만 읽는다.
    private final class World: @unchecked Sendable {
        var reading: NativeLimitBatteryReading? = .init(percentage: 60, isPluggedIn: true, batteryMilliamps: 4_000)
        var now: TimeInterval = 1_000_000
    }

    private struct Rig {
        let service: NativeChargeLimitService
        let driver: FakeNativeChargeLimitDriver
        let world: World
        let suiteName: String
        // `UserDefaults` isn't `Sendable` on this SDK, so the same instance can't cross into the
        // actor's isolated init and also stay alive here for the test's own reads without Swift 6
        // flagging a data race. A fresh instance per read shares the same suite storage in-process
        // (CFPreferences caches per-domain), so this reads back whatever the actor last wrote.
        var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }
    }

    private func rig(suiteName: String? = nil, driver: FakeNativeChargeLimitDriver? = nil) -> Rig {
        let suiteName = suiteName ?? "native-limit-\(UUID().uuidString)"
        let driver = driver ?? FakeNativeChargeLimitDriver()
        let world = World()
        let service = NativeChargeLimitService(
            driver: driver,
            reader: { world.reading },
            defaults: UserDefaults(suiteName: suiteName)!,
            now: { world.now })
        return Rig(service: service, driver: driver, world: world, suiteName: suiteName)
    }

    private func configure(_ configuration: BatteryControlConfiguration) throws -> BatteryControlClient.BatteryControlClientRequest {
        .configure(try BatteryControlCodec.encode(
            BatteryControlConfigurationRequest(configuration: configuration, generation: 1)))
    }

    @Test func enablingArmsTheNativeLimitAndIsAcceptedByTheExistingPolicy() async throws {
        let r = rig()
        let config = BatteryControlConfiguration(enabled: true, limitPercentage: 80).normalized
        let status = await r.service.process(try configure(config))
        #expect(r.driver.writes == ["set:80"])
        #expect(status.appliedLimitPercentage == 80)
        #expect(status.lastMaintenance?.trigger == .clientConfiguration)
        #expect(status.lastMaintenance?.result == .applied)
        #expect(BatteryControlPolicy.accepted(configuration: config, by: status))
        #expect(r.defaults.bool(forKey: StorageKey.nativeLimitOwned))
    }

    @Test func handleReturnsADecodableStatus() async throws {
        let r = rig()
        let (data, error) = await r.service.handle(.status)
        #expect(error == nil)
        let decoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: try #require(data))
        #expect(decoded.controlBackend == .nativeLimit)
    }

    @Test func aSecondIdenticalConfigureWritesNothingAndReportsVerified() async throws {
        let r = rig()
        let config = BatteryControlConfiguration(enabled: true, limitPercentage: 80)
        _ = await r.service.process(try configure(config))
        let status = await r.service.process(try configure(config))
        #expect(r.driver.writes == ["set:80"])
        #expect(status.lastMaintenance?.result == .verified)
        #expect(BatteryControlPolicy.accepted(configuration: config.normalized, by: status))
    }

    @Test func aStatusTickRearmsAfterSomeoneElseChangedTheLimit() async throws {
        let r = rig()
        _ = await r.service.process(try configure(.init(enabled: true, limitPercentage: 80)))
        r.driver.current = .init(limit: 95, state: .on)   // 시스템 설정에서 바꿨다
        let status = await r.service.process(.status)
        #expect(r.driver.writes == ["set:80", "set:80"])
        #expect(status.appliedLimitPercentage == 80)
        #expect(status.lastMaintenance?.trigger == .startup)
    }

    @Test func offListRequestIsRoundedUpAndReported() async throws {
        let r = rig()
        let status = await r.service.process(try configure(.init(enabled: true, limitPercentage: 70)))
        #expect(r.driver.writes == ["set:80"])
        #expect(status.appliedLimitPercentage == 80)
    }

    @Test func disablingReleasesOnlyWhatThisAppArmed() async throws {
        let owned = rig()
        _ = await owned.service.process(try configure(.init(enabled: true, limitPercentage: 80)))
        let released = await owned.service.process(try configure(.init(enabled: false)))
        #expect(owned.driver.writes == ["set:80", "set:100"])
        #expect(owned.defaults.bool(forKey: StorageKey.nativeLimitOwned) == false)
        #expect(BatteryControlPolicy.accepted(configuration: BatteryControlConfiguration(enabled: false).normalized, by: released))

        let foreignDriver = FakeNativeChargeLimitDriver()
        foreignDriver.current = .init(limit: 90, state: .on)   // 사용자가 시스템 설정에서 직접 건 제한
        let foreign = rig(driver: foreignDriver)
        _ = await foreign.service.process(try configure(.init(enabled: false)))
        #expect(foreignDriver.writes.isEmpty)
        #expect(foreignDriver.current == .init(limit: 90, state: .on))
    }

    @Test func topUpDisablesTemporarilyAndUnpluggingEndsItAndRearms() async throws {
        let r = rig()
        _ = await r.service.process(try configure(.init(enabled: true, limitPercentage: 80)))
        let topUp = await r.service.process(try configure(.init(enabled: true, limitPercentage: 80, topUpActive: true)))
        #expect(r.driver.writes == ["set:80", "tempDisable"])
        #expect(topUp.activity == .topUp)
        #expect(topUp.desiredConfiguration?.topUpActive == true)

        r.world.reading = .init(percentage: 92, isPluggedIn: false, batteryMilliamps: -600)
        let unplugged = await r.service.process(.status)
        #expect(unplugged.desiredConfiguration?.topUpActive == false)
        #expect(unplugged.lastMaintenance?.trigger == .adapterTransition)
        #expect(r.driver.writes == ["set:80", "tempDisable", "set:80"])
    }

    @Test func topUpExpiresTwelveHoursAfterReachingFull() async throws {
        let r = rig()
        _ = await r.service.process(try configure(.init(enabled: true, limitPercentage: 80)))
        _ = await r.service.process(try configure(.init(enabled: true, limitPercentage: 80, topUpActive: true)))

        r.world.reading = .init(percentage: 100, isPluggedIn: true, batteryMilliamps: 0)
        let stamped = await r.service.process(.status)
        #expect(stamped.desiredConfiguration?.topUpActive == true)
        #expect(r.defaults.double(forKey: StorageKey.nativeLimitTopUpReachedFullAt) == 1_000_000)

        r.world.now += BatteryTopUpExpiry.duration - 1
        let stillOn = await r.service.process(.status)
        #expect(stillOn.desiredConfiguration?.topUpActive == true)

        r.world.now += 1
        let expired = await r.service.process(.status)
        #expect(expired.desiredConfiguration?.topUpActive == false)
        #expect(expired.lastMaintenance?.trigger == .topUpExpired)
        #expect(r.driver.writes.last == "set:80")
        #expect(r.defaults.object(forKey: StorageKey.nativeLimitTopUpReachedFullAt) == nil)
    }

    @Test func cancellingTopUpDropsTheClockAndRearms() async throws {
        let r = rig()
        _ = await r.service.process(try configure(.init(enabled: true, limitPercentage: 80, topUpActive: true)))
        r.world.reading = .init(percentage: 100, isPluggedIn: true, batteryMilliamps: 0)
        _ = await r.service.process(.status)
        _ = await r.service.process(try configure(.init(enabled: true, limitPercentage: 80)))
        #expect(r.defaults.object(forKey: StorageKey.nativeLimitTopUpReachedFullAt) == nil)
        #expect(r.driver.current == .init(limit: 80, state: .on))
    }

    @Test func aRelaunchedServiceRemembersThePolicyAndFinishesAnExpiredTopUp() async throws {
        let suiteName = "native-limit-\(UUID().uuidString)"
        let driver = FakeNativeChargeLimitDriver()
        let first = rig(suiteName: suiteName, driver: driver)
        _ = await first.service.process(try configure(.init(enabled: true, limitPercentage: 85, topUpActive: true)))
        first.world.reading = .init(percentage: 100, isPluggedIn: true, batteryMilliamps: 0)
        _ = await first.service.process(.status)

        let second = rig(suiteName: suiteName, driver: driver)   // 앱 재실행
        second.world.reading = .init(percentage: 100, isPluggedIn: true, batteryMilliamps: 0)
        second.world.now = 1_000_000 + BatteryTopUpExpiry.duration
        let status = await second.service.process(.status)
        #expect(status.desiredConfiguration?.limitPercentage == 85)
        #expect(status.desiredConfiguration?.topUpActive == false)
        #expect(driver.current == .init(limit: 85, state: .on))
    }

    @Test func aFailedWriteIsReportedAndNotAccepted() async throws {
        let r = rig()
        r.driver.failWrites = true
        let config = BatteryControlConfiguration(enabled: true, limitPercentage: 80).normalized
        let status = await r.service.process(try configure(config))
        #expect(status.lastMaintenance?.result == .failed)
        #expect(status.detailReason == .init(kind: .applyFailed))
        #expect(BatteryControlPolicy.accepted(configuration: config, by: status) == false)
        #expect(r.defaults.bool(forKey: StorageKey.nativeLimitOwned) == false)
    }

    @Test func unreadableNativeStateWritesNothing() async throws {
        let r = rig()
        r.driver.failReads = true
        let status = await r.service.process(try configure(.init(enabled: true, limitPercentage: 80)))
        #expect(r.driver.writes.isEmpty)
        #expect(status.detailReason == .init(kind: .hardwareReadbackFailed))
    }

    @Test func unreadablePowerSourceWritesNothing() async throws {
        let r = rig()
        r.world.reading = nil
        let status = await r.service.process(try configure(.init(enabled: true, limitPercentage: 80)))
        #expect(r.driver.writes.isEmpty)
        #expect(status.detailReason == .init(kind: .powerSourceUnreadable))
        #expect(status.desiredConfiguration?.enabled == true)
    }

    @Test func anUndecodableConfigureIsAFailedMaintenanceAndKeepsThePreviousPolicy() async throws {
        let r = rig()
        _ = await r.service.process(try configure(.init(enabled: true, limitPercentage: 80)))
        let status = await r.service.process(.configure(Data("not json".utf8)))
        #expect(status.lastMaintenance?.result == .failed)
        #expect(status.desiredConfiguration?.limitPercentage == 80)
    }
}
