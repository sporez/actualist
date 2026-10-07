import CryptoKit
import Foundation
import Testing
@testable import Actualist

private enum ScheduleInteropConfiguration {
    static let controlOriginEnvironment = "SCHEDULE_INTEROP_CONTROL_ORIGIN"
    static let runIDEnvironment = "SCHEDULE_INTEROP_RUN_ID"
    static let actualRevisionEnvironment = "SCHEDULE_INTEROP_ACTUAL_REVISION"
    static let freezeIDEnvironment = "SCHEDULE_INTEROP_FREEZE_ID"
    static let actualRevision = "59fe126f637d858c061e1eeedbef5436c8f2225a"
    static let freezeID = "schedule-interop-manual-v1"

    static var isConfigured: Bool {
        value(controlOriginEnvironment) != nil
    }

    /// xcodebuild strips `TEST_RUNNER_` for the test host. Discovery-time
    /// traits do not see that host environment, so the test body checks both
    /// names after it has actually started.
    static func value(_ name: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let direct = environment[name], !direct.isEmpty {
            return direct
        }
        if let prefixed = environment["TEST_RUNNER_\(name)"], !prefixed.isEmpty {
            return prefixed
        }
        return nil
    }
}

@MainActor
@Suite("Local-first schedule interoperability")
struct LocalFirstActualStoreScheduleInteropTests {
    private let support = LocalFirstActualStoreTests()

    @Test
    func realSyncFirstSwiftPostExportsActualMessages() async throws {
        // A discovery-time `.enabled(if:)` never saw the runner environment, so
        // the test was omitted and xcodebuild exited 0 without posting a result.
        // `Skip` is not available in this Testing module. Return only when the
        // running test host also lacks the environment, so a normal unit run
        // stays green. The interop runner still fails if no result is posted.
        guard ScheduleInteropConfiguration.isConfigured else {
            let names = ProcessInfo.processInfo.environment.keys
                .filter { $0.contains("SCHEDULE_INTEROP") || $0.hasPrefix("TEST_RUNNER_") }
                .sorted()
            print("schedule-interop-unconfigured keys=\(names.joined(separator: ","))")
            return
        }
        let configuration = try configuration()
        let control = ScheduleInteropControlClient(
            origin: configuration.controlOrigin,
            runID: configuration.runID
        )
        let handshake = try await control.handshake()
        try handshake.validate(against: configuration)

        let fixtureDayID = Self.today()
        guard handshake.occurrenceDayID == fixtureDayID else {
            throw InteropError.handshakeMismatch
        }
        let bundle = try await support.makeOpenedWritableStoreBundle(
            syncTransportFactory: {
                ActualServerSyncClient(baseURL: $0, firstConnectionRetryDelays: [])
            },
            connectionTransportFactory: {
                ActualServerSyncClient(baseURL: $0, firstConnectionRetryDelays: [])
            },
            pendingLocalMessageFlushRetryDelays: [.zero]
        )
        let store = bundle.store
        store.closeOpenBudget()

        let handoff = try await control.fixtureHandoff()
        try handoff.validate(against: configuration, handshake: handshake)
        let fixtureArchive = try await control.fixtureArchive()
        let archiveHash = Self.sha256(fixtureArchive)
        guard archiveHash == handoff.fixtureArchiveSHA256 else {
            throw InteropError.handshakeMismatch
        }

        let metadata = LocalFirstBudgetMetadata(
            localBudgetID: handoff.fileID,
            cloudFileID: handoff.fileID,
            groupID: handoff.groupID,
            budgetName: handoff.budgetName,
            encryptionKeyID: nil,
            nodeID: "swift-\(configuration.runID)"
        )
        let stagingURL = try bundle.fileManager.prepareDownloadStaging(fileID: handoff.fileID)
        try fixtureArchive.write(to: stagingURL, options: .atomic)
        _ = try await bundle.fileManager.importBudgetZip(
            at: stagingURL,
            remoteFile: ActualSyncRemoteFile(
                fileID: handoff.fileID,
                groupID: handoff.groupID,
                name: handoff.budgetName
            ),
            metadata: metadata
        )
        let budget = ActualBudget(
            budgetID: handoff.fileID,
            cloudFileId: handoff.fileID,
            groupId: handoff.groupID,
            name: handoff.budgetName,
            state: nil
        )
        guard try await store.openCachedBudget(budget) else {
            throw InteropError.handshakeMismatch
        }
        store.openedServerURLString = handoff.serverOrigin.absoluteString
        try bundle.keychain.saveActualSyncToken(handoff.syncToken)

        // This explicit production sync proves that the handoff identity can
        // exchange with the server. postSchedule performs its own mandatory
        // pullAndReload again before it re-reads status and writes.
        try await store.refresh(
            budgetID: handoff.groupID,
            serverURLString: handoff.serverOrigin.absoluteString
        )
        let review = try await store.schedulePostingReview(
            budgetID: handoff.groupID,
            scheduleID: handshake.scheduleID
        )
        let receipt = try await store.postSchedule(review: review, date: .scheduled)

        // Await only the production flush task created by postSchedule. This is
        // not scheduler polling and does not replace the store's normal path.
        let productionFlush = store.syncLane.scheduledFlushTask
        await productionFlush?.value
        #expect(try await store.pendingLocalSyncMessageCount(budgetID: handoff.groupID) == 0)

        let database = try #require(store.database)
        let transaction = try #require(try await database.fetchTransaction(id: receipt.transactionID))
        #expect(transaction.schedule == handshake.scheduleID)
        #expect(transaction.amount == -10_000)
        #expect(receipt.refreshPending == false)
        #expect(receipt.occurrenceDayID == fixtureDayID)
        #expect(receipt.postedDayID == fixtureDayID)

        try await control.recordSwiftResult(
            ScheduleInteropSwiftResult(
                schemaVersion: 1,
                runID: configuration.runID,
                fixtureArchiveSHA256: archiveHash,
                scheduleID: receipt.scheduleID,
                transactionID: receipt.transactionID,
                occurrenceDayID: receipt.occurrenceDayID,
                postedDayID: receipt.postedDayID,
                appliedMessageCount: receipt.appliedMessageCount
            )
        )
    }

    private func configuration() throws -> Configuration {
        let runID = try Self.required(ScheduleInteropConfiguration.runIDEnvironment)
        let actualRevision = try Self.required(ScheduleInteropConfiguration.actualRevisionEnvironment)
        let freezeID = try Self.required(ScheduleInteropConfiguration.freezeIDEnvironment)
        guard actualRevision == ScheduleInteropConfiguration.actualRevision else {
            throw InteropError.sourceMismatch("unexpected Actual revision")
        }
        guard freezeID == ScheduleInteropConfiguration.freezeID else {
            throw InteropError.sourceMismatch("unexpected source freeze")
        }
        let originValue = try Self.required(ScheduleInteropConfiguration.controlOriginEnvironment)
        let origin = try Self.loopbackOrigin(originValue)
        return Configuration(
            controlOrigin: origin,
            runID: try Self.safeIdentifier(runID, field: "run ID"),
            actualRevision: actualRevision,
            freezeID: freezeID
        )
    }

    private static func required(_ key: String) throws -> String {
        guard let value = ScheduleInteropConfiguration.value(key) else {
            throw InteropError.missingConfiguration(key)
        }
        return value
    }

    private static func safeIdentifier(_ value: String, field: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard !value.isEmpty,
              value.count <= 128,
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw InteropError.invalidConfiguration(field)
        }
        return value
    }

    nonisolated static func loopbackOrigin(_ value: String) throws -> URL {
        guard let components = URLComponents(string: value),
              components.scheme == "http",
              components.host == "127.0.0.1",
              components.port != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let url = components.url else {
            throw InteropError.invalidConfiguration("loopback origin")
        }
        return url
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func today() -> String { TestLocalDay.today() }

    struct Configuration {
        let controlOrigin: URL
        let runID: String
        let actualRevision: String
        let freezeID: String
    }
}
