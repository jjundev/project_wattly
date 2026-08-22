import Foundation
import Testing
@testable import Wattly

private actor RequestReceiver {
    var request: BatteryControlClient.BatteryControlClientRequest?
    func set(_ request: BatteryControlClient.BatteryControlClientRequest) {
        self.request = request
    }
}

struct BatteryControlClientTests {
    @MainActor @Test func clientAppliesConfigurationAndUpdatesStatus() async throws {
        let expectedStatus = BatteryControlServiceStatus(
            mode: .inhibited,
            currentPercentage: 85,
            isPowerAdapterConnected: true,
            detail: "85% 바이패스 구동 중",
            updatedAt: 1.0
        )
        let receiver = RequestReceiver()
        let client = BatteryControlClient { request in
            await receiver.set(request)
            switch request {
            case .configure:
                let data = try? BatteryControlCodec.encode(expectedStatus)
                return (data, nil)
            case .status:
                let data = try? BatteryControlCodec.encode(expectedStatus)
                return (data, nil)
            }
        }

        await client.apply(enabled: true, limitPercentage: 85)
        #expect(client.status.mode == .inhibited)
        #expect(client.status.currentPercentage == 85)
        #expect(client.status.isPowerAdapterConnected == true)

        let receivedRequest = await receiver.request
        if case .configure(let data) = receivedRequest {
            let req = try BatteryControlCodec.decode(BatteryControlConfigurationRequest.self, from: data)
            #expect(req.configuration.enabled == true)
            #expect(req.configuration.limitPercentage == 85)
        } else {
            Issue.record("Expected configure request")
        }
    }

    @MainActor @Test func clientInitialStateIsUnavailable() {
        let client = BatteryControlClient()
        #expect(client.status.mode == .unavailable)
        #expect(client.isInstallingHelper == false)
    }

    @MainActor @Test func clientRefreshesStatus() async {
        let expectedStatus = BatteryControlServiceStatus(
            mode: .charging,
            currentPercentage: 70,
            isPowerAdapterConnected: true,
            detail: "목표치(80%)까지 충전 중",
            updatedAt: 2.0
        )
        let client = BatteryControlClient { request in
            switch request {
            case .configure:
                return (nil, nil)
            case .status:
                let data = try? BatteryControlCodec.encode(expectedStatus)
                return (data, nil)
            }
        }

        await client.refreshStatus()
        #expect(client.status.mode == .charging)
        #expect(client.status.currentPercentage == 70)
        #expect(client.status.detail == "목표치(80%)까지 충전 중")
    }

    @MainActor @Test func clientHandlesErrorGracefully() async {
        let client = BatteryControlClient { _ in
            (nil, NSError(domain: "WattlyTest", code: -1, userInfo: nil))
        }

        await client.apply(enabled: true, limitPercentage: 80)
        #expect(client.status.mode == .unavailable)
    }
}
