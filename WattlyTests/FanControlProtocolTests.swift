import Foundation
import Testing
@testable import Wattly

struct FanControlProtocolTests {
    @Test func configurationRoundTrips() throws {
        let input = FanControlConfiguration(enabled: true,
                                            curve: FanCurve(rpms: [1200, 2500, 4500, 6000]))
        #expect(try FanControlCodec.decode(FanControlConfiguration.self,
                                           from: FanControlCodec.encode(input)) == input)
    }

    @Test func malformedConfigurationIsRejected() {
        #expect(throws: (any Error).self) {
            try FanControlCodec.decode(FanControlConfiguration.self, from: Data("{}".utf8))
        }
    }

    @Test func controllingStatusRoundTrips() throws {
        let input = FanControlServiceStatus(mode: .controlling, detail: "CPU 70°C", updatedAt: 100)
        #expect(try FanControlCodec.decode(FanControlServiceStatus.self,
                                          from: FanControlCodec.encode(input)) == input)
    }
}
