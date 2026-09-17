import Testing
@testable import Wattly

/// macOS 27에서 AppleSmartBattery 최상위 키가 사라진 뒤의 배터리 사실 디코딩·우선순위.
/// 바이트 벡터는 2026-09-17 Mac17,2 / macOS 27.0 실측값이다.
struct BatteryFactsTests {

    // MARK: fromSMC — B0RM/B0NC/B0DC/B0CT/B0AT/B0AC (전부 리틀엔디안)

    private static let liveSMC: [String: (type: String, bytes: [UInt8])] = [
        "B0RM": ("ui16", [0xb8, 0x10]),   // 4280 mAh
        "B0NC": ("ui16", [0x6f, 0x18]),   // 6255 mAh
        "B0DC": ("ui16", [0x69, 0x18]),   // 6249 mAh
        "B0CT": ("ui16", [0x89, 0x00]),   // 137 cycles
        "B0AT": ("ui16", [0xfb, 0x0b]),   // 3067 centi-°C
        "B0AC": ("si16", [0x29, 0x10]),   // +4137 mA (charging)
    ]

    @Test func smcDecodesEveryLiveKey() {
        let facts = BatteryFactsSource.fromSMC { Self.liveSMC[$0] }
        #expect(facts.remainingMilliampHours == 4280)
        #expect(facts.maxMilliampHours == 6255)
        #expect(facts.designMilliampHours == 6249)
        #expect(facts.cycleCount == 137)
        #expect(facts.temperatureCelsius == 30.67)
        #expect(facts.currentMilliamps == 4137)
    }

    @Test func smcNegativeCurrentIsSignExtended() {
        let facts = BatteryFactsSource.fromSMC { key in
            key == "B0AC" ? ("si16", [0x12, 0xf8]) : nil     // −2030 mA (discharging)
        }
        #expect(facts.currentMilliamps == -2030)
    }

    @Test func smcMissingKeysStayNil() {
        let facts = BatteryFactsSource.fromSMC { _ in nil }
        #expect(facts == BatteryFacts())
    }

    @Test func smcRejectsZeroCapacityAndOutOfRangeTemperature() {
        let facts = BatteryFactsSource.fromSMC { key in
            switch key {
            case "B0NC": return ("ui16", [0x00, 0x00])   // 0 mAh → 무효
            case "B0AT": return ("ui16", [0x28, 0x23])   // 9000 centi-°C = 90 °C → 범위 밖
            default: return nil
            }
        }
        #expect(facts.maxMilliampHours == nil)
        #expect(facts.temperatureCelsius == nil)
    }

    // MARK: fromRegistry — 레거시 최상위 키 우선, BatteryData 서브딕셔너리 폴백

    @Test func registryLegacyTopLevelKeysWinOverBatteryData() {
        let facts = BatteryFactsSource.fromRegistry(
            topLevel: ["AppleRawCurrentCapacity": 6175, "AppleRawMaxCapacity": 6238,
                       "DesignCapacity": 6249, "CycleCount": 112, "Temperature": 3072],
            batteryData: ["RemainingCapacity": 1, "NominalChargeCapacity": 2, "DesignCapacity": 3])
        #expect(facts.remainingMilliampHours == 6175)
        #expect(facts.maxMilliampHours == 6238)
        #expect(facts.designMilliampHours == 6249)
        #expect(facts.cycleCount == 112)
        #expect(facts.temperatureCelsius == 30.72)
        #expect(facts.currentMilliamps == nil)   // 레지스트리는 전류를 주지 않는다
    }

    @Test func registryFallsBackToBatteryDataOnMacOS27() {
        // macOS 27 실측: 최상위에는 CycleCount만 남고 mAh는 BatteryData로 옮겨갔다.
        let facts = BatteryFactsSource.fromRegistry(
            topLevel: ["CycleCount": 137],
            batteryData: ["RemainingCapacity": 4280, "NominalChargeCapacity": 6255,
                          "FullChargeCapacity": 6103, "DesignCapacity": 6249])
        #expect(facts.remainingMilliampHours == 4280)
        #expect(facts.maxMilliampHours == 6255)      // Nominal, FullChargeCapacity가 아니다
        #expect(facts.designMilliampHours == 6249)
        #expect(facts.cycleCount == 137)
        #expect(facts.temperatureCelsius == nil)
    }

    @Test func registryRejectsNonPositiveAndOutOfRange() {
        let facts = BatteryFactsSource.fromRegistry(
            topLevel: ["AppleRawMaxCapacity": 0, "Temperature": -100],
            batteryData: ["DesignCapacity": -5])
        #expect(facts == BatteryFacts())
    }

    @Test func registryZeroTopLevelKeyFallsThroughToBatteryData() {
        // 최상위 키가 존재하지만 0이면 "없는 것"과 같다 — BatteryData가 대신 채운다.
        let facts = BatteryFactsSource.fromRegistry(
            topLevel: ["AppleRawMaxCapacity": 0, "DesignCapacity": -1],
            batteryData: ["NominalChargeCapacity": 6255, "DesignCapacity": 6249])
        #expect(facts.maxMilliampHours == 6255)
        #expect(facts.designMilliampHours == 6249)
    }

    // MARK: fromSMC — smcTemperatureCelsius single-key helper

    @Test func smcTemperatureReadsOnlyB0AT() {
        var asked: [String] = []
        let c = BatteryFactsSource.smcTemperatureCelsius { key in asked.append(key); return key == "B0AT" ? ("ui16", [0xfb, 0x0b]) : nil }
        #expect(c == 30.67)
        #expect(asked == ["B0AT"])
    }

    // MARK: merged — 필드별 primary ?? fallback

    @Test func mergedFillsOnlyTheHolesFromFallback() {
        var primary = BatteryFacts()
        primary.cycleCount = 112
        primary.temperatureCelsius = 30.72
        var fallback = BatteryFacts()
        fallback.remainingMilliampHours = 4280
        fallback.maxMilliampHours = 6255
        fallback.cycleCount = 137            // primary가 있으니 무시
        fallback.temperatureCelsius = 30.67  // primary가 있으니 무시
        fallback.currentMilliamps = 4137

        let merged = BatteryFactsSource.merged(primary: primary, fallback: fallback)
        #expect(merged.remainingMilliampHours == 4280)
        #expect(merged.maxMilliampHours == 6255)
        #expect(merged.designMilliampHours == nil)
        #expect(merged.cycleCount == 112)
        #expect(merged.temperatureCelsius == 30.72)
        #expect(merged.currentMilliamps == 4137)
    }

    @Test func mergedDoesNotEvaluateFallbackWhenPrimaryIsComplete() {
        let primary = BatteryFacts(remainingMilliampHours: 1, maxMilliampHours: 2, designMilliampHours: 3,
                                   cycleCount: 4, temperatureCelsius: 5, currentMilliamps: 6)
        var evaluated = false
        let merged = BatteryFactsSource.merged(primary: primary, fallback: { evaluated = true; return BatteryFacts() }())
        #expect(merged == primary)
        #expect(evaluated == false)
    }
}
