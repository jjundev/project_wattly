import Foundation
import Testing
@testable import Wattly

struct FanControlProtocolTests {
    @Test func configurationRoundTrips() throws {
        let input = FanControlConfiguration(enabled: true,
                                            curve: FanCurve(rpms: [800,900,1000,1200,1500,1900,2400,3000,3600,4200,4800,5500,6200,6800,7400]))
        #expect(try FanControlCodec.decode(FanControlConfiguration.self,
                                           from: FanControlCodec.encode(input)) == input)
    }

    @Test func stateChangingRequestsCarryGeneration() throws {
        let configuration = FanControlConfiguration(enabled: false,
                                                     curve: FanCurve(rpms: [800,900,1000,1200,1500,1900,2400,3000,3600,4200,4800,5500,6200,6800,7400]))
        let configure = FanControlConfigurationRequest(configuration: configuration, generation: 41)
        let release = FanControlReleaseRequest(generation: 42)

        #expect(try FanControlCodec.decode(FanControlConfigurationRequest.self,
                                           from: FanControlCodec.encode(configure)) == configure)
        #expect(try FanControlCodec.decode(FanControlReleaseRequest.self,
                                           from: FanControlCodec.encode(release)) == release)
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
