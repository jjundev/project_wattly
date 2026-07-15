import Foundation
import Observation

/// The app-side endpoint for the privileged fan-control helper. It transports only a curve
/// configuration and heartbeats; all SMC writes remain exclusively in the helper process.
@MainActor
@Observable final class FanControlClient {
    private(set) var status = FanControlServiceStatus(
        mode: .unavailable,
        detail: "도우미에 연결되지 않음",
        updatedAt: 0
    )

    func apply(enabled: Bool, curve: FanCurve) async {
        guard let data = try? FanControlCodec.encode(FanControlConfiguration(enabled: enabled, curve: curve)) else {
            updateUnavailable("팬 커브를 인코딩할 수 없음")
            return
        }
        await send { service, reply in service.configure(data, withReply: reply) }
    }

    func heartbeat() async {
        await send { service, reply in service.heartbeat(withReply: reply) }
    }

    func release() async {
        await send { service, reply in service.release(withReply: reply) }
    }

    private func send(_ call: @escaping @Sendable (any FanControlXPCService,
                                                   @escaping (Data?, NSError?) -> Void) -> Void) async {
        switch await Self.request(call) {
        case .success(let value):
            status = value
        case .failure(let failure):
            updateUnavailable(failure.detail)
        }
    }

    /// NSXPC invokes both reply and proxy-error handlers on a private queue. Keep that boundary
    /// nonisolated and resume at most once before returning to this main-actor client.
    private nonisolated static func request(
        _ call: @escaping @Sendable (any FanControlXPCService,
                                     @escaping (Data?, NSError?) -> Void) -> Void
    ) async -> Result<FanControlServiceStatus, XPCRequestFailure> {
        await withCheckedContinuation { continuation in
            let connection = NSXPCConnection(machServiceName: FanControlXPC.machService,
                                             options: .privileged)
            let completion = XPCRequestCompletion(connection: connection, continuation: continuation)
            connection.remoteObjectInterface = NSXPCInterface(with: FanControlXPCService.self)
            connection.resume()

            guard let service = connection.remoteObjectProxyWithErrorHandler({ error in
                completion.finish(.failure(.init(detail: error.localizedDescription)))
            }) as? any FanControlXPCService else {
                completion.finish(.failure(.init(detail: "도우미 연결을 만들 수 없음")))
                return
            }

            call(service) { data, error in
                guard error == nil,
                      let data,
                      let value = try? FanControlCodec.decode(FanControlServiceStatus.self, from: data)
                else {
                    completion.finish(.failure(.init(detail: error?.localizedDescription ?? "도우미 응답 오류")))
                    return
                }
                completion.finish(.success(value))
            }
        }
    }

    private func updateUnavailable(_ detail: String) {
        status = .init(mode: .unavailable,
                       detail: detail,
                       updatedAt: Date().timeIntervalSince1970)
    }
}

/// Thread-safe completion gate for the mutually exclusive XPC reply/error callbacks.
private final class XPCRequestCompletion: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let continuation: CheckedContinuation<Result<FanControlServiceStatus, XPCRequestFailure>, Never>
    private let lock = NSLock()
    private var didFinish = false

    init(connection: NSXPCConnection,
         continuation: CheckedContinuation<Result<FanControlServiceStatus, XPCRequestFailure>, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ result: Result<FanControlServiceStatus, XPCRequestFailure>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()

        connection.invalidate()
        continuation.resume(returning: result)
    }
}

private struct XPCRequestFailure: Error, Sendable {
    let detail: String
}
