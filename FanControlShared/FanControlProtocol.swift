import Foundation

struct FanControlConfiguration: Codable, Equatable, Sendable {
    var enabled: Bool
    var curve: FanCurve
}

/// Every state-changing app request carries a client-issued generation. The helper ignores a
/// request that arrives after a newer request, which prevents a delayed enable from undoing a
/// later disable when the two calls use separate XPC connections.
struct FanControlConfigurationRequest: Codable, Equatable, Sendable {
    var configuration: FanControlConfiguration
    var generation: UInt64
}

struct FanControlReleaseRequest: Codable, Equatable, Sendable {
    var generation: UInt64
}

enum FanControlServiceMode: String, Codable, Equatable, Sendable {
    case unavailable, automatic, engaging, controlling, failed
}

struct FanControlServiceStatus: Codable, Equatable, Sendable {
    var mode: FanControlServiceMode
    var detail: String
    var updatedAt: TimeInterval
}

enum FanControlCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }
}

@objc(FanControlXPCService)
protocol FanControlXPCService {
    func configure(_ data: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func heartbeat(withReply reply: @escaping (Data?, NSError?) -> Void)
    func release(_ data: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func status(withReply reply: @escaping (Data?, NSError?) -> Void)
}

enum FanControlXPC {
    static let machService = "dev.jjundev.WattlyFanDaemon"
    static let daemonPath = "/Library/PrivilegedHelperTools/dev.jjundev.WattlyFanDaemon"
}
