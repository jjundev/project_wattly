import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryControlBackendTests {
    private func status(backend: BatteryControlBackend?) -> BatteryControlServiceStatus {
        BatteryControlServiceStatus(
            mode: .charging,
            currentPercentage: 70,
            isPowerAdapterConnected: true,
            detail: "테스트",
            updatedAt: 1,
            controlBackend: backend)
    }

    @Test func payloadFromHelperThatNeverHeardOfBackendsDecodesAsNil() throws {
        let data = try BatteryControlCodec.encode(status(backend: nil))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["controlBackend"] == nil)
        let decoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: data)
        #expect(decoded.controlBackend == nil)
    }

    @Test func nativeLimitRoundTrips() throws {
        let data = try BatteryControlCodec.encode(status(backend: .nativeLimit))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["controlBackend"] as? String == "native-limit")
        let decoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: data)
        #expect(decoded.controlBackend == .nativeLimit)
    }

    @Test func unknownBackendTokenDoesNotFailTheWholeStatus() throws {
        let data = try BatteryControlCodec.encode(status(backend: .smc))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["controlBackend"] = "quantum"
        let mutated = try JSONSerialization.data(withJSONObject: object)
        let decoded = try BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: mutated)
        #expect(decoded.controlBackend == .unrecognized)
        #expect(decoded.currentPercentage == 70)
    }
}
