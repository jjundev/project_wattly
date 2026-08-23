import Darwin
import Foundation
import Testing
@testable import Wattly

@Suite struct BatteryPolicyPersistenceTests {
    private struct InjectedDirectorySyncError: Error {}

    private final class SynchronizationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var callCount = 0
        private let failureCall: Int
        private let beforeFailure: @Sendable () -> Void

        init(
            failureCall: Int,
            beforeFailure: @escaping @Sendable () -> Void = {}
        ) {
            self.failureCall = failureCall
            self.beforeFailure = beforeFailure
        }

        func synchronize(_: URL) throws {
            let currentCall = lock.withLock {
                callCount += 1
                return callCount
            }
            guard currentCall == failureCall else { return }
            beforeFailure()
            throw InjectedDirectorySyncError()
        }
    }

    private func temporaryStore(
        synchronizeDirectory: (@Sendable (URL) throws -> Void)? = nil
    ) throws -> (directory: URL, store: BatteryPolicyFileStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wattly-policy-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("battery-control-v1.json")
        let store: BatteryPolicyFileStore
        if let synchronizeDirectory {
            store = BatteryPolicyFileStore(
                fileURL: fileURL,
                synchronizeDirectory: synchronizeDirectory
            )
        } else {
            store = BatteryPolicyFileStore(fileURL: fileURL)
        }
        return (
            directory,
            store
        )
    }

    @Test func roundTripNormalizesConfigurationAndKeepsOwner() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save(.init(
            ownerUID: 501,
            configuration: .init(
                enabled: true,
                limitPercentage: 110,
                lowerHysteresisDelta: 20
            ),
            updatedAt: 10
        ))

        let loaded = try #require(try store.load())
        #expect(loaded.schemaVersion == 1)
        #expect(loaded.ownerUID == 501)
        #expect(loaded.configuration.limitPercentage == 100)
        #expect(loaded.configuration.lowerHysteresisDelta == 10)
    }

    @Test func savedFileIsOwnerReadWriteOnly() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save(.init(ownerUID: 501, configuration: .init(), updatedAt: 10))

        let attributes = try FileManager.default.attributesOfItem(
            atPath: store.fileURL.path
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func savedDirectoryIsOwnerWritableAndWorldReadable() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save(.init(ownerUID: 501, configuration: .init(), updatedAt: 10))

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o755)
    }

    @Test func firstDirectoryCreationRequiresParentDirectorySync() throws {
        let (directory, initialStore) = try temporaryStore(synchronizeDirectory: { _ in })
        defer { try? FileManager.default.removeItem(at: directory) }
        let parentDirectory = directory.deletingLastPathComponent()
        let store = BatteryPolicyFileStore(
            fileURL: initialStore.fileURL,
            synchronizeDirectory: { synchronizedDirectory in
                if synchronizedDirectory == parentDirectory {
                    throw InjectedDirectorySyncError()
                }
            }
        )

        #expect(throws: InjectedDirectorySyncError.self) {
            try store.save(.init(ownerUID: 501, configuration: .init(), updatedAt: 10))
        }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func secondSaveAtomicallyReplacesTheFirstPayload() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save(.init(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 80),
            updatedAt: 1
        ))
        try store.save(.init(
            ownerUID: 501,
            configuration: .init(enabled: false, limitPercentage: 100),
            updatedAt: 2
        ))

        let loaded = try #require(try store.load())
        #expect(loaded.updatedAt == 2)
        #expect(loaded.configuration.enabled == false)
        #expect(try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).count == 1)
    }

    @Test func corruptPayloadThrowsInsteadOfPretendingThereIsNoPolicy() throws {
        let (directory, store) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: store.fileURL)

        #expect(throws: BatteryPolicyStoreError.self) {
            _ = try store.load()
        }
    }

    @Test func unsupportedSchemaIsReportedExplicitly() throws {
        let (directory, store) = try temporaryStore(synchronizeDirectory: { _ in })
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var policy = PersistedBatteryPolicy(ownerUID: 501, configuration: .init(), updatedAt: 10)
        policy.schemaVersion = 99
        try JSONEncoder().encode(policy).write(to: store.fileURL)

        #expect(throws: BatteryPolicyStoreError.unsupportedSchema(99)) {
            _ = try store.load()
        }
    }

    @Test func removeDeletesThePolicyAndIsIdempotent() throws {
        let (directory, store) = try temporaryStore(synchronizeDirectory: { _ in })
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.save(.init(ownerUID: 501, configuration: .init(), updatedAt: 10))

        try store.remove()
        #expect(try store.load() == nil)
        try store.remove()
    }

    @Test func removeClearsCanonicalAndRecoveryArtifactsDurably() throws {
        let (directory, store) = try temporaryStore(synchronizeDirectory: { _ in })
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousURL = directory.appendingPathComponent(".battery-control.previous")
        let staleURL = directory.appendingPathComponent(".battery-control.stale")
        for url in [store.fileURL, previousURL, staleURL] {
            try Data("policy".utf8).write(to: url)
        }

        try store.remove()

        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: previousURL.path))
        #expect(!FileManager.default.fileExists(atPath: staleURL.path))
        #expect(try store.load() == nil)
    }

    @Test func postRenameSyncFailureRestoresThePriorCanonicalFile() throws {
        let (directory, initialStore) = try temporaryStore(synchronizeDirectory: { _ in })
        defer { try? FileManager.default.removeItem(at: directory) }
        try initialStore.save(.init(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 80),
            updatedAt: 1
        ))
        let probe = SynchronizationProbe(failureCall: 3)
        let failingStore = BatteryPolicyFileStore(
            fileURL: initialStore.fileURL,
            synchronizeDirectory: probe.synchronize
        )

        #expect(throws: InjectedDirectorySyncError.self) {
            try failingStore.save(.init(
                ownerUID: 501,
                configuration: .init(enabled: true, limitPercentage: 90),
                updatedAt: 2
            ))
        }
        let recovered = try #require(try initialStore.load())
        #expect(recovered.configuration.limitPercentage == 80)
        #expect(recovered.updatedAt == 1)
    }

    @Test func finalizationSyncFailureRestoresThePriorCanonicalFile() throws {
        let (directory, initialStore) = try temporaryStore(synchronizeDirectory: { _ in })
        defer { try? FileManager.default.removeItem(at: directory) }
        try initialStore.save(.init(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 80),
            updatedAt: 1
        ))
        let probe = SynchronizationProbe(failureCall: 4)
        let failingStore = BatteryPolicyFileStore(
            fileURL: initialStore.fileURL,
            synchronizeDirectory: probe.synchronize
        )

        #expect(throws: InjectedDirectorySyncError.self) {
            try failingStore.save(.init(
                ownerUID: 501,
                configuration: .init(enabled: true, limitPercentage: 90),
                updatedAt: 2
            ))
        }
        let recovered = try #require(try initialStore.load())
        #expect(recovered.configuration.limitPercentage == 80)
        #expect(recovered.updatedAt == 1)
    }

    @Test func postRenameSyncFailureWithoutPriorFileRemovesCanonicalFile() throws {
        let (directory, initialStore) = try temporaryStore(synchronizeDirectory: { _ in })
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let probe = SynchronizationProbe(failureCall: 2)
        let failingStore = BatteryPolicyFileStore(
            fileURL: initialStore.fileURL,
            synchronizeDirectory: probe.synchronize
        )

        #expect(throws: InjectedDirectorySyncError.self) {
            try failingStore.save(.init(
                ownerUID: 501,
                configuration: .init(enabled: true, limitPercentage: 90),
                updatedAt: 2
            ))
        }
        #expect(!FileManager.default.fileExists(atPath: initialStore.fileURL.path))
    }

    @Test func loadRecoversPreviousFileBeforeReadingCanonicalFile() throws {
        let (directory, store) = try temporaryStore(synchronizeDirectory: { _ in })
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousURL = directory.appendingPathComponent(".battery-control.previous")
        try JSONEncoder().encode(PersistedBatteryPolicy(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 80),
            updatedAt: 1
        )).write(to: previousURL)
        try JSONEncoder().encode(PersistedBatteryPolicy(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 90),
            updatedAt: 2
        )).write(to: store.fileURL)

        let recovered = try #require(try store.load())
        #expect(recovered.configuration.limitPercentage == 80)
        #expect(recovered.updatedAt == 1)
        #expect(!FileManager.default.fileExists(atPath: previousURL.path))
    }

    @Test func loadIgnoresFinalizedStaleBackup() throws {
        let (directory, store) = try temporaryStore(synchronizeDirectory: { _ in })
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staleURL = directory.appendingPathComponent(".battery-control.stale")
        try JSONEncoder().encode(PersistedBatteryPolicy(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 80),
            updatedAt: 1
        )).write(to: staleURL)
        try JSONEncoder().encode(PersistedBatteryPolicy(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 90),
            updatedAt: 2
        )).write(to: store.fileURL)

        let loaded = try #require(try store.load())
        #expect(loaded.configuration.limitPercentage == 90)
        #expect(loaded.updatedAt == 2)
    }

    @Test func rollbackFailureIsReportedSeparately() throws {
        let (directory, initialStore) = try temporaryStore(synchronizeDirectory: { _ in })
        defer { try? FileManager.default.removeItem(at: directory) }
        try initialStore.save(.init(
            ownerUID: 501,
            configuration: .init(enabled: true, limitPercentage: 80),
            updatedAt: 1
        ))
        let previousURL = directory.appendingPathComponent(".battery-control.previous")
        let probe = SynchronizationProbe(failureCall: 3) {
            try? FileManager.default.removeItem(at: previousURL)
        }
        let failingStore = BatteryPolicyFileStore(
            fileURL: initialStore.fileURL,
            synchronizeDirectory: probe.synchronize
        )

        #expect(throws: BatteryPolicyStoreError.rollbackFailed(errno: ENOENT)) {
            try failingStore.save(.init(
                ownerUID: 501,
                configuration: .init(enabled: true, limitPercentage: 90),
                updatedAt: 2
            ))
        }
    }

    @Test func defaultURLIsTheRootOwnedApplicationSupportPath() {
        #expect(BatteryPolicyFileStore.defaultURL.path
                == "/Library/Application Support/Wattly/battery-control-v1.json")
    }
}
