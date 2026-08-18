import XCTest
@testable import Wattly

@MainActor
final class FanControlClientTests: XCTestCase {

    func testRefreshStatusSuccess() async throws {
        let expectedStatus = FanControlServiceStatus(mode: .controlling, detail: "Mock controlling", updatedAt: 123)
        let client = FanControlClient(requestHandler: { request in
            XCTAssertEqual(request, .status)
            return .success(expectedStatus)
        })
        
        let status = await client.refreshStatus()
        
        XCTAssertEqual(status?.mode, expectedStatus.mode)
        XCTAssertEqual(client.status.mode, expectedStatus.mode)
    }

    func testRefreshStatusFailure() async throws {
        let client = FanControlClient(requestHandler: { request in
            XCTAssertEqual(request, .status)
            return .failure(FanControlClientRequestFailure(detail: "Mock failure"))
        })
        
        let status = await client.refreshStatus()
        
        XCTAssertNil(status)
        XCTAssertEqual(client.status.mode, .unavailable)
        XCTAssertEqual(client.status.detail, "Mock failure")
    }

    actor DataReceiver {
        var data: Data?
        func set(_ data: Data) { self.data = data }
    }

    func testApply() async throws {
        let curve = FanCurve(rpms: Array(repeating: 1500.0, count: 15))
        let expectedStatus = FanControlServiceStatus(mode: .engaging, detail: "Mock engaging", updatedAt: 123)
        let receiver = DataReceiver()
        
        let client = FanControlClient(requestHandler: { request in
            if case .configure(let data) = request {
                await receiver.set(data)
                return .success(expectedStatus)
            }
            XCTFail("Expected configure request")
            return .failure(FanControlClientRequestFailure(detail: ""))
        })
        
        await client.apply(enabled: true, curve: curve)
        
        let configureDataReceived = await receiver.data
        XCTAssertNotNil(configureDataReceived)
        let decoded = try? FanControlCodec.decode(FanControlConfigurationRequest.self, from: configureDataReceived!)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.configuration.enabled, true)
        XCTAssertEqual(client.status.mode, expectedStatus.mode)
    }
}
