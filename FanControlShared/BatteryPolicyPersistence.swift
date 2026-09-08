import Darwin
import Foundation

public struct PersistedBatteryPolicy: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var ownerUID: UInt32
    public var configuration: BatteryControlConfiguration
    public var updatedAt: TimeInterval
    /// Top Up이 100%에 도달한 벽시계 시각. 도달 전에는 `nil`.
    ///
    /// **`configuration` 안이 아니라 여기 있는 이유가 핵심이다.** 설정 구조체는 앱이 60초마다
    /// 되밀어 주는 값이고, `BatteryControlPolicy.shouldReapply`는 `topUpActive`와 수동 방전
    /// 필드만 헬퍼 쪽 값으로 보존한다. 앱이 모르는 필드를 설정에 넣으면 다음 reconcile이 앱의
    /// 사본(=nil)으로 덮어써서 만료 시계가 조용히 사라진다.
    ///
    /// Optional이라 합성 Codable이 `decodeIfPresent`를 쓰고, 따라서 이 필드를 모르는 구버전
    /// 헬퍼가 쓴 파일도 그대로 읽힌다. `schemaVersion`을 올려서는 안 되는 이유는
    /// `BatteryPolicyFileStore.load()`가 정확한 일치를 요구하기 때문이다.
    public var topUpReachedFullAt: TimeInterval?
    /// Wattly가 시스템 `SleepDisabled`를 켠 벽시계 시각. **소유 마커 겸 12시간 만료 시계**다.
    /// 우리가 켜지 않았으면(사용자가 직접 `pmset disablesleep 1`을 했더라도) `nil`.
    /// 플래그를 켜기 **전에** 저장한다 — 그 사이에 데몬이 죽어도 재시작이 마커만 보고 정리한다.
    /// `topUpReachedFullAt`과 같은 이유로 `configuration` 안이 아니라 여기 있다.
    public var sleepInhibitedAt: TimeInterval?

    public init(
        ownerUID: UInt32,
        configuration: BatteryControlConfiguration,
        updatedAt: TimeInterval,
        topUpReachedFullAt: TimeInterval? = nil,
        sleepInhibitedAt: TimeInterval? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.ownerUID = ownerUID
        self.configuration = configuration.normalized
        self.updatedAt = updatedAt
        self.topUpReachedFullAt = topUpReachedFullAt
        self.sleepInhibitedAt = sleepInhibitedAt
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
    /// `sleepInhibitedAt` 마커만, `Codable` 전체 디코딩 없이 읽는다. `load()`가
    /// `unreadablePayload`·`unsupportedSchema`·`rollbackFailed`로 던지는 바로 그 순간에도
    /// 마커는 여전히 필요하다 — 그 값이 재부팅을 넘어 남는 `SleepDisabled`의 유일한 정리
    /// 단서이기 때문이다. 기본 구현은 `nil`(메모리 기반 저장소는 원시 바이트가 없다);
    /// `BatteryPolicyFileStore`만 실제로 읽는다.
    func loadSleepInhibitedAtLenient() -> TimeInterval?
}

extension BatteryPolicyStoring {
    public func loadSleepInhibitedAtLenient() -> TimeInterval? { nil }
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
            updatedAt: policy.updatedAt,
            topUpReachedFullAt: policy.topUpReachedFullAt,
            sleepInhibitedAt: policy.sleepInhibitedAt
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
        try synchronizeDirectory(directory.deletingLastPathComponent())
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

    /// 순수 읽기, 부수효과 없음 — `load()`의 `.previous` 롤백 rename은 여기서 하지 않는다.
    /// 그 rename은 `load()`만의 몫이다: 저 함수가 이미 호출돼 실패했을 시점에는 캐노니컬
    /// 파일이 놓일 자리에 이미 올바른 내용이 있거나(롤백 성공 후 디코드만 실패), 애초에
    /// `.previous`가 없었거나(디코드 실패) 둘 중 하나다. 원시 JSON에서 `sleepInhibitedAt`
    /// 키 하나만 뽑아내므로, 현재 바이너리가 `schemaVersion`을 이해하지 못해도(다운그레이드
    /// 등) 값이 나온다. 파일이 없거나, 못 읽거나, JSON이 아니거나, 키가 없으면 `nil`.
    public func loadSleepInhibitedAtLenient() -> TimeInterval? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["sleepInhibitedAt"] as? TimeInterval
    }

    public func remove() throws {
        let directory = fileURL.deletingLastPathComponent()
        let policyURLs = [
            fileURL,
            directory.appendingPathComponent(".battery-control.previous"),
            directory.appendingPathComponent(".battery-control.stale")
        ]
        let existingURLs = policyURLs.filter { fileManager.fileExists(atPath: $0.path) }
        guard !existingURLs.isEmpty else { return }
        for url in existingURLs {
            try fileManager.removeItem(at: url)
        }
        try synchronizeDirectory(directory)
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
        let staleURL = directory.appendingPathComponent(".battery-control.stale")
        try? fileManager.removeItem(at: staleURL)
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
        guard hadPrevious else { return }
        guard rename(previousURL.path, staleURL.path) == 0 else {
            let finalizationErrno = errno
            guard rename(previousURL.path, fileURL.path) == 0 else {
                throw BatteryPolicyStoreError.rollbackFailed(errno: errno)
            }
            try synchronizeDirectory(directory)
            throw BatteryPolicyStoreError.fileOperation(errno: finalizationErrno)
        }
        do {
            try synchronizeDirectory(directory)
        } catch {
            guard rename(staleURL.path, fileURL.path) == 0 else {
                throw BatteryPolicyStoreError.rollbackFailed(errno: errno)
            }
            try synchronizeDirectory(directory)
            throw error
        }
        try? fileManager.removeItem(at: staleURL)
    }
}
