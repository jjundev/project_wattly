import Darwin
import Foundation

public struct PersistedBatteryPolicy: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var ownerUID: UInt32
    public var configuration: BatteryControlConfiguration
    public var updatedAt: TimeInterval

    public init(
        ownerUID: UInt32,
        configuration: BatteryControlConfiguration,
        updatedAt: TimeInterval
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.ownerUID = ownerUID
        self.configuration = configuration.normalized
        self.updatedAt = updatedAt
    }
}

public enum BatteryPolicyStoreError: Error, Equatable {
    case unsupportedSchema(Int)
    case unreadablePayload
    case fileOperation(errno: Int32)
    case rollbackFailed(errno: Int32)
}

public protocol BatteryPolicyStoring: Sendable {
    func load() throws -> PersistedBatteryPolicy?
    func save(_ policy: PersistedBatteryPolicy) throws
    func remove() throws
}

public final class BatteryPolicyFileStore: BatteryPolicyStoring, @unchecked Sendable {
    public static let defaultURL = URL(
        fileURLWithPath: "/Library/Application Support/Wattly",
        isDirectory: true
    ).appendingPathComponent("battery-control-v1.json")

    public let fileURL: URL
    private let fileManager: FileManager
    private let synchronizeDirectory: @Sendable (URL) throws -> Void

    public convenience init(
        fileURL: URL = BatteryPolicyFileStore.defaultURL,
        fileManager: FileManager = .default
    ) {
        self.init(
            fileURL: fileURL,
            fileManager: fileManager,
            synchronizeDirectory: BatteryPolicyFileStore.fsyncDirectory
        )
    }

    public init(
        fileURL: URL,
        fileManager: FileManager = .default,
        synchronizeDirectory: @escaping @Sendable (URL) throws -> Void
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.synchronizeDirectory = synchronizeDirectory
    }

    public func load() throws -> PersistedBatteryPolicy? {
        let directory = fileURL.deletingLastPathComponent()
        let previousURL = directory.appendingPathComponent(".battery-control.previous")
        if fileManager.fileExists(atPath: previousURL.path) {
            guard rename(previousURL.path, fileURL.path) == 0 else {
                throw BatteryPolicyStoreError.rollbackFailed(errno: errno)
            }
            try synchronizeDirectory(directory)
        }
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let policy = try JSONDecoder().decode(
                PersistedBatteryPolicy.self,
                from: Data(contentsOf: fileURL)
            )
            guard policy.schemaVersion == PersistedBatteryPolicy.currentSchemaVersion else {
                throw BatteryPolicyStoreError.unsupportedSchema(policy.schemaVersion)
            }
            return policy
        } catch let error as BatteryPolicyStoreError {
            throw error
        } catch {
            throw BatteryPolicyStoreError.unreadablePayload
        }
    }

    public func save(_ policy: PersistedBatteryPolicy) throws {
        let normalized = PersistedBatteryPolicy(
            ownerUID: policy.ownerUID,
            configuration: policy.configuration,
            updatedAt: policy.updatedAt
        )
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        guard chmod(directory.path, 0o755) == 0 else {
            throw BatteryPolicyStoreError.fileOperation(errno: errno)
        }
        try synchronizeDirectory(directory)

        let temporaryURL = directory.appendingPathComponent(
            ".battery-control-\(UUID().uuidString).tmp"
        )
        let data = try JSONEncoder().encode(normalized)
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw BatteryPolicyStoreError.fileOperation(errno: errno)
        }

        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard chmod(temporaryURL.path, 0o600) == 0 else {
                throw BatteryPolicyStoreError.fileOperation(errno: errno)
            }
            try replaceDurably(
                temporaryURL: temporaryURL,
                directory: directory
            )
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    public func remove() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
        try synchronizeDirectory(fileURL.deletingLastPathComponent())
    }

    private static func fsyncDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw BatteryPolicyStoreError.fileOperation(errno: errno)
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw BatteryPolicyStoreError.fileOperation(errno: errno)
        }
    }

    private func replaceDurably(
        temporaryURL: URL,
        directory: URL
    ) throws {
        let previousURL = directory.appendingPathComponent(".battery-control.previous")
        try? fileManager.removeItem(at: previousURL)
        let hadPrevious = fileManager.fileExists(atPath: fileURL.path)
        if hadPrevious {
            guard link(fileURL.path, previousURL.path) == 0 else {
                throw BatteryPolicyStoreError.fileOperation(errno: errno)
            }
            try synchronizeDirectory(directory)
        }
        guard rename(temporaryURL.path, fileURL.path) == 0 else {
            try? fileManager.removeItem(at: previousURL)
            throw BatteryPolicyStoreError.fileOperation(errno: errno)
        }
        do {
            try synchronizeDirectory(directory)
        } catch {
            if hadPrevious {
                guard rename(previousURL.path, fileURL.path) == 0 else {
                    throw BatteryPolicyStoreError.rollbackFailed(errno: errno)
                }
            } else {
                try fileManager.removeItem(at: fileURL)
            }
            try synchronizeDirectory(directory)
            throw error
        }
        try? fileManager.removeItem(at: previousURL)
    }
}
