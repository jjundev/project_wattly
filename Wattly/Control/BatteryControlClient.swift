import Foundation
import Observation
import AppKit

@MainActor
@Observable public final class BatteryControlClient {
    public enum BatteryControlClientRequest: Sendable, Equatable {
        case configure(Data)
        case status
    }

    public typealias RequestHandler = @Sendable (BatteryControlClientRequest) async -> (Data?, NSError?)

    private let requestHandler: RequestHandler
    public private(set) var status = BatteryControlServiceStatus(
        mode: .unavailable,
        currentPercentage: 0,
        isPowerAdapterConnected: false,
        detail: "도우미에 연결되지 않음",
        updatedAt: 0
    )
    public private(set) var isInstallingHelper = false
    private var commandGeneration = UInt64(Date().timeIntervalSince1970 * 1_000_000)

    public init(requestHandler: RequestHandler? = nil) {
        self.requestHandler = requestHandler ?? { req in
            switch req {
            case .configure(let data):
                return await Self.sendXPC { svc, reply in svc.configureBattery(data, withReply: reply) }
            case .status:
                return await Self.sendXPC { svc, reply in svc.batteryStatus(withReply: reply) }
            }
        }
    }

    public func apply(enabled: Bool, limitPercentage: Int) async {
        commandGeneration &+= 1
        let config = BatteryControlConfiguration(enabled: enabled, limitPercentage: limitPercentage)
        let request = BatteryControlConfigurationRequest(configuration: config, generation: commandGeneration)
        guard let data = try? BatteryControlCodec.encode(request) else { return }

        let (replyData, _) = await requestHandler(.configure(data))
        if let replyData, let decoded = try? BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: replyData) {
            self.status = decoded
        }
    }

    public func refreshStatus() async {
        let (replyData, _) = await requestHandler(.status)
        if let replyData, let decoded = try? BatteryControlCodec.decode(BatteryControlServiceStatus.self, from: replyData) {
            self.status = decoded
        }
    }

    public func installHelper() async throws {
        isInstallingHelper = true
        defer { isInstallingHelper = false }
        try await FanHelperInstaller.install()
        await refreshStatus()
    }

    private static func sendXPC(_ block: @escaping (FanControlXPCService, @escaping (Data?, NSError?) -> Void) -> Void) async -> (Data?, NSError?) {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: FanControlXPC.machService, options: .privileged)
            let completion = XPCRequestCompletion(connection: connection, continuation: continuation)
            connection.remoteObjectInterface = NSXPCInterface(with: FanControlXPCService.self)
            connection.resume()
            guard let service = connection.remoteObjectProxyWithErrorHandler({ error in
                completion.finish(data: nil, error: error as NSError)
            }) as? any FanControlXPCService else {
                completion.finish(data: nil, error: NSError(domain: "Wattly", code: 1, userInfo: [NSLocalizedDescriptionKey: "도우미 연결을 만들 수 없음"]))
                return
            }
            block(service) { data, error in
                completion.finish(data: data, error: error)
            }
        }
    }
}

/// Thread-safe completion gate for the mutually exclusive XPC reply/error callbacks.
private final class XPCRequestCompletion: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let continuation: CheckedContinuation<(Data?, NSError?), Never>
    private let lock = NSLock()
    private var didFinish = false

    init(connection: NSXPCConnection,
         continuation: CheckedContinuation<(Data?, NSError?), Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(data: Data?, error: NSError?) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()

        connection.invalidate()
        continuation.resume(returning: (data, error))
    }
}
