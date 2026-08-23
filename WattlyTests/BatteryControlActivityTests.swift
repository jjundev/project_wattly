import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryControlActivityTests {
    @Test func roundTripsEveryKnownToken() throws {
        for activity in BatteryControlActivity.allCases where activity != .unrecognized {
            let data = try BatteryControlCodec.encode(activity)
            let decoded = try BatteryControlCodec.decode(BatteryControlActivity.self, from: data)
            #expect(decoded == activity)
        }
    }

    @Test func unknownAndMalformedTokensBecomeUnrecognized() throws {
        let future = try BatteryControlCodec.decode(
            BatteryControlActivity.self,
            from: Data("\"futureActivity\"".utf8))
        let malformed = try BatteryControlCodec.decode(
            BatteryControlActivity.self,
            from: Data("42".utf8))

        #expect(future == .unrecognized)
        #expect(malformed == .unrecognized)
    }

    @Test func existingReasonsInferOnlyVerifiedBaseActivities() {
        #expect(BatteryControlActivity.inferred(from: .init(kind: .limitDisabled)) == .inactive)
        #expect(BatteryControlActivity.inferred(
            from: .init(kind: .chargingToTarget, limitPercentage: 80)) == .chargingToLimit)
        #expect(BatteryControlActivity.inferred(
            from: .init(kind: .inhibitedAtLimit, limitPercentage: 80)) == .holdingAtLimit)
        #expect(BatteryControlActivity.inferred(from: .init(kind: .onBatteryPower)) == .onBatteryPower)

        #expect(BatteryControlActivity.inferred(from: .init(kind: .initializing)) == nil)
        #expect(BatteryControlActivity.inferred(from: .init(kind: .applyFailed)) == nil)
        #expect(BatteryControlActivity.inferred(from: .init(kind: .releaseFailed)) == nil)
        #expect(BatteryControlActivity.inferred(from: nil) == nil)
    }

    @Test func explicitKnownActivityWinsAndUnrecognizedFallsBack() {
        let reason = BatteryControlStatusReason(kind: .chargingToTarget, limitPercentage: 80)

        #expect(BatteryControlActivity.resolved(explicit: .heatProtection, reason: reason)
                == .heatProtection)
        #expect(BatteryControlActivity.resolved(explicit: .unrecognized, reason: reason)
                == .chargingToLimit)
        #expect(BatteryControlActivity.resolved(explicit: nil, reason: reason)
                == .chargingToLimit)
    }

    @Test func sailingReasonInfersSailingActivity() {
        let reason = BatteryControlStatusReason(kind: .sailing, limitPercentage: 80, resumePercentage: 75)
        #expect(BatteryControlActivity.inferred(from: reason) == .sailing)
        #expect(BatteryControlActivity.resolved(explicit: nil, reason: reason) == .sailing)
    }
}
