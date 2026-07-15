import Foundation

struct FanControlConfiguration: Codable, Equatable, Sendable {
    var enabled: Bool
    var curve: FanCurve
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
    func release(withReply reply: @escaping (Data?, NSError?) -> Void)
    func status(withReply reply: @escaping (Data?, NSError?) -> Void)
}

enum FanControlXPC {
    static let machService = "dev.jjundev.WattlyFanDaemon"
    static let daemonPath = "/Library/PrivilegedHelperTools/dev.jjundev.WattlyFanDaemon"
}
