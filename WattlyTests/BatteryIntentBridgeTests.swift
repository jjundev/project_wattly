import Testing
import Foundation
@testable import Wattly

private actor ConfigReceiver {
    var config: BatteryControlConfigurationRequest?
    func set(_ config: BatteryControlConfigurationRequest?) {
        self.config = config
    }
}

private struct MockBatteryMetricProvider: MetricProvider {
    let kind: ProviderKind = .battery
    let reading: ProviderReading

    func read(at instant: ContinuousClock.Instant) async -> ProviderReading {
        reading
    }
}

@Suite struct BatteryIntentBridgeTests {
    // MARK: - fetchLimitConfig Tests

    @Test func fetchLimitConfigReadsFromUserDefaults() async throws {
        let suiteName = "BatteryIntentBridgeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: StorageKey.batteryLimitEnabled)
        defaults.set(85, forKey: StorageKey.batteryLimitPercentage)
        defaults.set(true, forKey: StorageKey.batterySailingEnabled)
        defaults.set(4, forKey: StorageKey.batterySailingDelta)
        defaults.set(true, forKey: StorageKey.batteryHeatProtectionEnabled)

        let bridge = BatteryIntentBridge(userDefaults: defaults, clientProvider: {
            BatteryControlClient(requestHandler: { req in
                let status = BatteryControlServiceStatus(
                    mode: .charging,
                    currentPercentage: 70,
                    isPowerAdapterConnected: true,
                    detail: "정상",
                    updatedAt: 100,
                    desiredConfiguration: BatteryControlConfiguration(
                        enabled: true, limitPercentage: 85, lowerHysteresisDelta: 4, heatProtectionEnabled: true, topUpActive: false
                    )
                )
                let data = try? BatteryControlCodec.encode(status)
                return (data, nil)
            })
        })

        let config = try await bridge.fetchLimitConfig()
        #expect(config.isEnabled == true)
        #expect(config.limitPercentage == 85)
        #expect(config.isSailingEnabled == true)
        #expect(config.sailingDelta == 4)
        #expect(config.isHeatProtectionEnabled == true)
        #expect(config.isTopUpActive == false)
    }

    @Test func fetchLimitConfigFallsBackToDefaultsWhenEmpty() async throws {
        let suiteName = "BatteryIntentBridgeTestsEmpty-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let bridge = BatteryIntentBridge(userDefaults: defaults, clientProvider: {
            BatteryControlClient(requestHandler: { req in
                let status = BatteryControlServiceStatus(
                    mode: .charging,
                    currentPercentage: 70,
                    isPowerAdapterConnected: true,
                    detail: "정상",
                    updatedAt: 100,
                    activity: .topUp
                )
                let data = try? BatteryControlCodec.encode(status)
                return (data, nil)
            })
        })

        let config = try await bridge.fetchLimitConfig()
        #expect(config.isEnabled == Defaults.batteryLimitEnabled)
        #expect(config.limitPercentage == Defaults.batteryLimitPercentage)
        #expect(config.isSailingEnabled == Defaults.batterySailingEnabled)
        #expect(config.sailingDelta == Defaults.batterySailingDelta)
        #expect(config.isHeatProtectionEnabled == Defaults.batteryHeatProtectionEnabled)
        #expect(config.isTopUpActive == true)
    }

    // MARK: - fetchBatteryState Tests

    @Test func fetchBatteryStateFromProviderAndClient() async throws {
        let suiteName = "BatteryIntentBridgeTestsState-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let sample = BatterySample(
            netW: -18.5,
            milliamps: 1500,
            volts: 12.0,
            charging: true,
            externalConnected: true,
            remainingWh: 60.0,
            maxWh: 80.0,
            timeRemainingMinutes: 45,
            efficiencyPercent: 96.4,
            temperatureCelsius: 31.0
        )
        let mockProvider = MockBatteryMetricProvider(reading: .value(.battery(sample)))

        let bridge = BatteryIntentBridge(userDefaults: defaults, clientProvider: {
            BatteryControlClient(requestHandler: { _ in
                let status = BatteryControlServiceStatus(
                    mode: .charging,
                    currentPercentage: 75,
                    isPowerAdapterConnected: true,
                    detail: "충전 중",
                    updatedAt: 100,
                    batteryTemperatureCelsius: 31.0
                )
                let data = try? BatteryControlCodec.encode(status)
                return (data, nil)
            })
        }, batteryProvider: mockProvider)

        let state = try await bridge.fetchBatteryState()
        #expect(state.percentage == 75)
        #expect(state.isCharging == true)
        #expect(state.isPowerAdapterConnected == true)
        #expect(state.temperatureCelsius == 31.0)
        #expect(state.netWatts == -18.5)
        #expect(state.timeRemainingMinutes == 45)
        #expect(state.healthPercentage == 96)
    }

    @Test func fetchBatteryStateCalculatesPercentageWhenClientStatusHasZero() async throws {
        let suiteName = "BatteryIntentBridgeTestsZeroPerc-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let sample = BatterySample(
            netW: 5.0,
            milliamps: 400,
            volts: 11.5,
            charging: false,
            externalConnected: false,
            remainingWh: 40.0,
            maxWh: 80.0,
            timeRemainingMinutes: 300,
            efficiencyPercent: 99.0,
            temperatureCelsius: 28.0
        )
        let mockProvider = MockBatteryMetricProvider(reading: .value(.battery(sample)))

        let bridge = BatteryIntentBridge(userDefaults: defaults, clientProvider: {
            BatteryControlClient(requestHandler: { _ in
                let status = BatteryControlServiceStatus(
                    mode: .charging,
                    currentPercentage: 0,
                    isPowerAdapterConnected: false,
                    detail: "방전 중",
                    updatedAt: 100
                )
                let data = try? BatteryControlCodec.encode(status)
                return (data, nil)
            })
        }, batteryProvider: mockProvider)

        let state = try await bridge.fetchBatteryState()
        #expect(state.percentage == 50)
        #expect(state.isCharging == false)
        #expect(state.isPowerAdapterConnected == false)
        #expect(state.temperatureCelsius == 28.0)
        #expect(state.netWatts == 5.0)
        #expect(state.timeRemainingMinutes == 300)
        #expect(state.healthPercentage == 99)
    }

    // MARK: - applyLimit Tests

    @Test func applyLimitPersistsDefaultsAndInvokesClient() async throws {
        let suiteName = "BatteryIntentBridgeTestsApply-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(false, forKey: StorageKey.batteryLimitEnabled)
        defaults.set(80, forKey: StorageKey.batteryLimitPercentage)

        let receiver = ConfigReceiver()
        let bridge = BatteryIntentBridge(userDefaults: defaults, clientProvider: {
            BatteryControlClient(requestHandler: { req in
                if case .configure(let data) = req {
                    let decoded = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
                    Task { await receiver.set(decoded) }
                }
                let status = BatteryControlServiceStatus(
                    mode: .charging,
                    currentPercentage: 70,
                    isPowerAdapterConnected: true,
                    detail: "정상",
                    updatedAt: 100,
                    isHardwareSupported: true
                )
                let data = try? BatteryControlCodec.encode(status)
                return (data, nil)
            })
        })

        let status = try await bridge.applyLimit(enabled: true, limitPercentage: 90)
        #expect(status.isHardwareSupported == true)
        #expect(defaults.bool(forKey: StorageKey.batteryLimitEnabled) == true)
        #expect(defaults.integer(forKey: StorageKey.batteryLimitPercentage) == 90)

        let requested = await receiver.config
        #expect(requested?.configuration.limitPercentage == 90)
        #expect(requested?.configuration.enabled == true)
    }

    /// Regression for the missing-argument bug: `applyLimit` must thread the user's auto-discharge
    /// opt-in and manual-discharge target through to the client, not silently reset them to
    /// `apply`'s defaults (`false` / `80`).
    @Test func applyLimitCarriesAutoDischargeAndManualDischargeTarget() async throws {
        let suiteName = "BatteryIntentBridgeTestsAutoDischarge-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(false, forKey: StorageKey.batteryLimitEnabled)
        defaults.set(80, forKey: StorageKey.batteryLimitPercentage)
        defaults.set(true, forKey: StorageKey.batteryAutoDischargeEnabled)
        defaults.set(70, forKey: StorageKey.batteryManualDischargeTarget)

        let receiver = ConfigReceiver()
        let bridge = BatteryIntentBridge(userDefaults: defaults, clientProvider: {
            BatteryControlClient(requestHandler: { req in
                if case .configure(let data) = req {
                    let decoded = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
                    Task { await receiver.set(decoded) }
                }
                let status = BatteryControlServiceStatus(
                    mode: .charging,
                    currentPercentage: 70,
                    isPowerAdapterConnected: true,
                    detail: "정상",
                    updatedAt: 100,
                    isHardwareSupported: true
                )
                let data = try? BatteryControlCodec.encode(status)
                return (data, nil)
            })
        })

        _ = try await bridge.applyLimit(enabled: true, limitPercentage: 90)

        let requested = await receiver.config
        #expect(requested?.configuration.autoDischargeEnabled == true)
        #expect(requested?.configuration.manualDischargeTarget == 70)
    }

    @Test func applyLimitThrowsWhenHardwareUnsupported() async {
        let suiteName = "BatteryIntentBridgeTestsUnsupported-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let bridge = BatteryIntentBridge(userDefaults: defaults, clientProvider: {
            BatteryControlClient(requestHandler: { _ in
                let status = BatteryControlServiceStatus(
                    mode: .unsupported,
                    currentPercentage: 70,
                    isPowerAdapterConnected: true,
                    detail: "하드웨어 미지원",
                    updatedAt: 100,
                    isHardwareSupported: false
                )
                let data = try? BatteryControlCodec.encode(status)
                return (data, nil)
            })
        })

        await #expect(throws: BatteryIntentError.hardwareUnsupported) {
            try await bridge.applyLimit(enabled: true, limitPercentage: 80)
        }
    }

    @Test func applyFailsWhenHelperUnavailable() async {
        let suiteName = "BatteryIntentBridgeTestsFail-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let bridge = BatteryIntentBridge(userDefaults: defaults, clientProvider: {
            BatteryControlClient(requestHandler: { _ in
                (nil, NSError(domain: "Wattly", code: 1, userInfo: [NSLocalizedDescriptionKey: "Helper not installed"]))
            })
        })

        await #expect(throws: BatteryIntentError.helperNotInstalled) {
            try await bridge.applyLimit(enabled: true, limitPercentage: 80)
        }
    }

    // MARK: - applySailing Tests

    @Test func applySailingPersistsDefaultsAndInvokesClient() async throws {
        let suiteName = "BatteryIntentBridgeTestsSailing-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: StorageKey.batteryLimitEnabled)
        defaults.set(80, forKey: StorageKey.batteryLimitPercentage)

        let receiver = ConfigReceiver()
        let bridge = BatteryIntentBridge(userDefaults: defaults, clientProvider: {
            BatteryControlClient(requestHandler: { req in
                if case .configure(let data) = req {
                    let decoded = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
                    Task { await receiver.set(decoded) }
                }
                let status = BatteryControlServiceStatus(
                    mode: .inhibited,
                    currentPercentage: 80,
                    isPowerAdapterConnected: true,
                    detail: "Sailing 구동 중",
                    updatedAt: 100,
                    isHardwareSupported: true
                )
                let data = try? BatteryControlCodec.encode(status)
                return (data, nil)
            })
        })

        let status = try await bridge.applySailing(enabled: true, delta: 6)
        #expect(status.mode == .inhibited)
        #expect(defaults.bool(forKey: StorageKey.batterySailingEnabled) == true)
        #expect(defaults.integer(forKey: StorageKey.batterySailingDelta) == 6)

        let requested = await receiver.config
        #expect(requested?.configuration.lowerHysteresisDelta == 6)
    }

    @Test func applySailingDisabledUsesDefaultDelta2() async throws {
        let suiteName = "BatteryIntentBridgeTestsSailingOff-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: StorageKey.batterySailingEnabled)
        defaults.set(5, forKey: StorageKey.batterySailingDelta)

        let receiver = ConfigReceiver()
        let bridge = BatteryIntentBridge(userDefaults: defaults, clientProvider: {
            BatteryControlClient(requestHandler: { req in
                if case .configure(let data) = req {
                    let decoded = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
                    Task { await receiver.set(decoded) }
                }
                let status = BatteryControlServiceStatus(
                    mode: .inhibited,
                    currentPercentage: 80,
                    isPowerAdapterConnected: true,
                    detail: "OK",
                    updatedAt: 100,
                    isHardwareSupported: true
                )
                let data = try? BatteryControlCodec.encode(status)
                return (data, nil)
            })
        })

        let _ = try await bridge.applySailing(enabled: false, delta: nil)
        #expect(defaults.bool(forKey: StorageKey.batterySailingEnabled) == false)
        #expect(defaults.integer(forKey: StorageKey.batterySailingDelta) == 5)

        let requested = await receiver.config
        #expect(requested?.configuration.lowerHysteresisDelta == 2)
    }

    // MARK: - applyTopUp Tests

    @Test func applyTopUpStartAndCancel() async throws {
        let suiteName = "BatteryIntentBridgeTestsTopUp-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(80, forKey: StorageKey.batteryLimitPercentage)

        let receiver = ConfigReceiver()
        let bridge = BatteryIntentBridge(userDefaults: defaults, clientProvider: {
            BatteryControlClient(requestHandler: { req in
                if case .configure(let data) = req {
                    let decoded = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
                    Task { await receiver.set(decoded) }
                }
                let status = BatteryControlServiceStatus(
                    mode: .charging,
                    currentPercentage: 80,
                    isPowerAdapterConnected: true,
                    detail: "Top-Up",
                    updatedAt: 100,
                    isHardwareSupported: true
                )
                let data = try? BatteryControlCodec.encode(status)
                return (data, nil)
            })
        })

        // Start TopUp
        let startStatus = try await bridge.applyTopUp(start: true)
        #expect(startStatus.isHardwareSupported == true)
        var requested = await receiver.config
        #expect(requested?.configuration.topUpActive == true)

        // Cancel TopUp
        let cancelStatus = try await bridge.applyTopUp(start: false)
        #expect(cancelStatus.isHardwareSupported == true)
        requested = await receiver.config
        #expect(requested?.configuration.topUpActive == false)
    }

    // MARK: - applyHeatProtection Tests

    @Test func applyHeatProtectionPersistsDefaultsAndInvokesClient() async throws {
        let suiteName = "BatteryIntentBridgeTestsHeat-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(false, forKey: StorageKey.batteryHeatProtectionEnabled)
        defaults.set(35, forKey: StorageKey.batteryHeatProtectionThreshold)

        let receiver = ConfigReceiver()
        let bridge = BatteryIntentBridge(userDefaults: defaults, clientProvider: {
            BatteryControlClient(requestHandler: { req in
                if case .configure(let data) = req {
                    let decoded = try? BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
                    Task { await receiver.set(decoded) }
                }
                let status = BatteryControlServiceStatus(
                    mode: .charging,
                    currentPercentage: 70,
                    isPowerAdapterConnected: true,
                    detail: "발열 보호 활성화",
                    updatedAt: 100,
                    isHardwareSupported: true
                )
                let data = try? BatteryControlCodec.encode(status)
                return (data, nil)
            })
        })

        let status = try await bridge.applyHeatProtection(enabled: true, thresholdCelsius: 40)
        #expect(status.isHardwareSupported == true)
        #expect(defaults.bool(forKey: StorageKey.batteryHeatProtectionEnabled) == true)
        #expect(defaults.integer(forKey: StorageKey.batteryHeatProtectionThreshold) == 40)

        let requested = await receiver.config
        #expect(requested?.configuration.heatProtectionEnabled == true)
        #expect(requested?.configuration.heatProtectionThresholdCelsius == 40)
    }
}
