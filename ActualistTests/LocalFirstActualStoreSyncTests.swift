import Foundation
import GRDB
import Security
import SwiftUI
import Testing
import ZIPFoundation
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func localFirstSyncValueSerializesActualWireValues() async {
        #expect(LocalFirstSyncValue.null.serialized == "0:")
        #expect(LocalFirstSyncValue.int(42).serialized == "N:42")
        #expect(LocalFirstSyncValue.double(12.5).serialized == "N:12.5")
        #expect(LocalFirstSyncValue.string("Coffee").serialized == "S:Coffee")
        #expect(LocalFirstSyncValue.bool(true).serialized == "N:1")
        #expect(LocalFirstSyncValue.bool(false).serialized == "N:0")
    }

    @Test func hybridLogicalClockUsesNodeIDAndIncrementsWhenWallClockDoesNotAdvance() async throws {
        var clock = HybridLogicalClock(
            nodeID: "node1",
            lastTimestamp: "1970-01-01T00:00:01.234Z-0000-node1"
        )

        let first = try clock.next(now: Date(timeIntervalSince1970: 1.0))
        let second = try clock.next(now: Date(timeIntervalSince1970: 1.0))
        let advanced = try clock.next(now: Date(timeIntervalSince1970: 2.0))

        #expect(first == "1970-01-01T00:00:01.234Z-0001-node1")
        #expect(second == "1970-01-01T00:00:01.234Z-0002-node1")
        #expect(advanced == "1970-01-01T00:00:02.000Z-0000-node1")
    }

    @Test func hybridLogicalClockUppercasesHexCounterLikeActualReference() async throws {
        var clock = HybridLogicalClock(
            nodeID: "node1",
            lastTimestamp: "1970-01-01T00:00:01.234Z-0000-node1"
        )
        let now = Date(timeIntervalSince1970: 1.0)

        // Seed counter to 8 so the following two next() calls hit 9 -> A -> B.
        _ = try clock.next(now: now)  // 0001
        _ = try clock.next(now: now)  // 0002
        _ = try clock.next(now: now)  // 0003
        _ = try clock.next(now: now)  // 0004
        _ = try clock.next(now: now)  // 0005
        _ = try clock.next(now: now)  // 0006
        _ = try clock.next(now: now)  // 0007
        _ = try clock.next(now: now)  // 0008
        _ = try clock.next(now: now)  // 0009
        let tenth = try clock.next(now: now)
        let eleventh = try clock.next(now: now)

        // Actual's reference Timestamp.toString uses uppercase hex; peers hash the
        // verbatim string into the merkle trie, so lowercase would corrupt sync.
        #expect(tenth == "1970-01-01T00:00:01.234Z-000A-node1")
        #expect(eleventh == "1970-01-01T00:00:01.234Z-000B-node1")
    }

    @Test func hybridLogicalClockObservedUppercaseTimestampKeepsUppercaseSequence() async throws {
        var clock = HybridLogicalClock(
            nodeID: "node1",
            lastTimestamp: "1970-01-01T00:00:01.234Z-0000-node1"
        )
        clock.observe("1970-01-01T00:00:01.234Z-0009-node1")
        let seeded = try clock.next(now: Date(timeIntervalSince1970: 1.0))
        clock.observe(seeded)
        let next = try clock.next(now: Date(timeIntervalSince1970: 1.0))

        #expect(seeded == "1970-01-01T00:00:01.234Z-000A-node1")
        #expect(next == "1970-01-01T00:00:01.234Z-000B-node1")
    }

    @Test func hybridLogicalClockGeneratesUppercaseCountersThroughLargeSameMillisecondBatch() async throws {
        var clock = HybridLogicalClock(
            nodeID: "node1",
            lastTimestamp: "1970-01-01T00:00:01.234Z-0000-node1"
        )
        let now = Date(timeIntervalSince1970: 1.0)

        var timestamps: [String] = []
        for _ in 0..<20 {
            timestamps.append(try clock.next(now: now))
        }

        // Account creation emits 12 messages in one millisecond; counters 10-11 must be
        // uppercase (000A/000B) to match the Actual reference merkle hash.
        #expect(timestamps[9] == "1970-01-01T00:00:01.234Z-000A-node1")
        #expect(timestamps[10] == "1970-01-01T00:00:01.234Z-000B-node1")
        #expect(timestamps[11] == "1970-01-01T00:00:01.234Z-000C-node1")
        #expect(timestamps[12] == "1970-01-01T00:00:01.234Z-000D-node1")
        #expect(timestamps[18] == "1970-01-01T00:00:01.234Z-0013-node1")
    }

    @Test func hybridLogicalClockThrowsWhenCounterOverflows() async {
        var clock = HybridLogicalClock(
            nodeID: "node1",
            lastTimestamp: "1970-01-01T00:00:01.234Z-ffff-node1"
        )

        #expect(throws: LocalFirstError.hybridLogicalClockOverflow) {
            _ = try clock.next(now: Date(timeIntervalSince1970: 1.0))
        }
    }

    @Test func hybridLogicalClockUsesActualClientIDShape() async {
        let uuid = UUID(uuidString: "A219E7A7-1CC1-8912-ABCD-0123456789AB")!

        #expect(HybridLogicalClock.makeClientID(uuid: uuid) == "abcd0123456789ab")
        #expect(HybridLogicalClock.normalizedNodeID("node-1") == "node1")
    }

    @Test func concurrentLocalMutationsMintDistinctMonotonicTimestampsAfterSuspending() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let mutationCount = 128
        let fixedNow = Date(timeIntervalSince1970: 1_783_404_000)

        let appliedCount = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<mutationCount {
                group.addTask {
                    // Reproduce the suspension that exposed duplicate clock seeds.
                    await Task.yield()
                    let draft = ActualSyncDecodedMessage(
                        timestamp: String(format: "actualist-pending-%08x", index),
                        dataset: "transactions",
                        row: "txn",
                        column: "category",
                        serializedValue: LocalFirstSyncValue.string("category-\(index)").serialized
                    )
                    return try await database.commitLocalSyncMessagesAndEnqueue(
                        [draft],
                        now: fixedNow
                    )
                }
            }

            var total = 0
            for try await count in group {
                total += count
            }
            return total
        }

        let timestamps = try await database.pendingLocalSyncMessages().map(\.message.timestamp)
        #expect(appliedCount == mutationCount)
        #expect(timestamps.count == mutationCount)
        #expect(Set(timestamps).count == mutationCount)
        #expect(timestamps == timestamps.sorted())
        #expect(timestamps.first?.contains("-0000-node1") == true)
        #expect(timestamps.last?.contains("-007F-node1") == true)
    }

    @Test func concurrentStoreMutationsAcrossActorSuspensionAllReachTheOutbox() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let mutationCount = 32

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<mutationCount {
                group.addTask {
                    await Task.yield()
                    _ = try await bundle.store.assignCategoryBudgetAndRefresh(
                        categoryID: "groceries",
                        budgeted: 60_000 + index,
                        budgetID: "group-1",
                        month: "2026-07"
                    ) {}
                }
            }
            try await group.waitForAll()
        }

        let database = try #require(bundle.store.database)
        let pending = try await database.pendingLocalSyncMessages()
        let timestamps = pending.map(\.message.timestamp)
        let expectedMessageCount = mutationCount * 3
        #expect(pending.count == expectedMessageCount)
        #expect(Set(timestamps).count == expectedMessageCount)
        #expect(timestamps == timestamps.sorted())
    }

    @Test func localClockResumesFromPersistedTimestampAcrossDatabaseLifecycles() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let fixedNow = Date(timeIntervalSince1970: 1_783_404_000)
        var database: BudgetDatabase? = try BudgetDatabase(
            databaseURL: fixtureURL,
            localNodeID: "node1"
        )
        let firstDraft = ActualSyncDecodedMessage(
            timestamp: "actualist-pending-00000000",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: LocalFirstSyncValue.string("first").serialized
        )

        _ = try await database?.commitLocalSyncMessagesAndEnqueue([firstDraft], now: fixedNow)
        database = nil

        let reopened = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let secondDraft = ActualSyncDecodedMessage(
            timestamp: "actualist-pending-00000000",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: LocalFirstSyncValue.string("second").serialized
        )
        _ = try await reopened.commitLocalSyncMessagesAndEnqueue([secondDraft], now: fixedNow)

        let timestamps = try await reopened.pendingLocalSyncMessages().map(\.message.timestamp)
        #expect(timestamps.count == 2)
        #expect(timestamps[0].contains("-0000-node1"))
        #expect(timestamps[1].contains("-0001-node1"))
    }

    @Test func remoteTimestampAdvancesLoadedLocalClockWithoutStorageReseed() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL, localNodeID: "node1")
        let remote = ActualSyncDecodedMessage(
            timestamp: "2026-07-25T12:00:00.000Z-000A-remote",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: LocalFirstSyncValue.string("remote").serialized
        )
        _ = try await database.applyRemoteSyncMessages([remote])

        let draft = ActualSyncDecodedMessage(
            timestamp: "actualist-pending-00000000",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: LocalFirstSyncValue.string("local").serialized
        )
        _ = try await database.commitLocalSyncMessagesAndEnqueue(
            [draft],
            now: Date(timeIntervalSince1970: 0)
        )

        let localTimestamp = try #require(
            await database.pendingLocalSyncMessages().first?.message.timestamp
        )
        #expect(localTimestamp == "2026-07-25T12:00:00.000Z-000B-node1")
    }

    @Test func remoteApplyReportsOnlyNewLiveTopLevelTransactions() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let messages = [
            remoteMessage(index: 0, row: "new-top", column: "acct", value: .string("checking")),
            remoteMessage(index: 1, row: "new-top", column: "amount", value: .int(-2_500)),
            remoteMessage(index: 2, row: "txn", column: "amount", value: .int(-13_000)),
            remoteMessage(index: 3, row: "new-child", column: "acct", value: .string("checking")),
            remoteMessage(index: 4, row: "new-child", column: "parent_id", value: .string("new-top")),
            remoteMessage(index: 5, row: "new-deleted", column: "acct", value: .string("checking")),
            remoteMessage(index: 6, row: "new-deleted", column: "tombstone", value: .bool(true)),
            remoteMessage(index: 7, row: "new-split-parent", column: "acct", value: .string("checking")),
            remoteMessage(index: 8, row: "new-split-parent", column: "is_parent", value: .bool(true))
        ]

        let result = try await database.applyRemoteSyncMessagesTrackingInserts(messages)

        #expect(result.appliedMessageCount == messages.count)
        #expect(
            result.insertedTransactionIDsByAccount
                == ["checking": ["new-split-parent", "new-top"]]
        )

        let updateResult = try await database.applyRemoteSyncMessagesTrackingInserts([
            remoteMessage(index: 9, row: "new-top", column: "amount", value: .int(-3_000))
        ])
        #expect(updateResult.insertedTransactionIDsByAccount.isEmpty)
    }

    @Test func backgroundSyncUsesAppliedInsertIDsWithoutSnapshotDiffing() async throws {
        let transport = RecordingSyncTransport()
        try await transport.seedServerMessages([
            remoteMessage(index: 0, row: "background-new", column: "acct", value: .string("checking")),
            remoteMessage(index: 1, row: "background-new", column: "amount", value: .int(-4_200)),
            remoteMessage(index: 2, row: "txn", column: "amount", value: .int(-13_000))
        ])
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in transport }
        )
        try bundle.keychain.saveActualSyncToken("token")

        let results = try await bundle.store.syncAndFindNewTransactions(
            budget: bundle.budget,
            serverURLString: "https://sync.example"
        )

        #expect(results.count == 1)
        #expect(results.first?.account.id == "checking")
        #expect(results.first?.newTransactionIDs == ["background-new"])
    }

    @Test func backgroundRefreshTimeLimitRecordsCleanCompletion() async throws {
        let transport = RecordingSyncTransport(delayNanoseconds: 5_000_000_000)
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in transport }
        )
        try bundle.keychain.saveActualSyncToken("token")
        let state = try makeAppState(for: bundle)
        state.settings.backgroundTransactionRefreshEnabled = true
        state.setupPhase = .ready
        state.selectedBudget = bundle.budget

        let success = await state.performBackgroundTransactionRefresh(
            timeLimit: .milliseconds(10)
        )

        #expect(!success)
        let run = try #require(state.settings.backgroundRefreshDebug.recentRuns.first)
        #expect(run.completionDate != nil)
        #expect(run.succeeded == false)
        #expect(run.message == "Timed out")
    }

    @Test func coldBackgroundRefreshOpensCachedBudgetAndFlushesPendingOutbox() async throws {
        let transport = RecordingSyncTransport()
        let bundle = try await makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("token")

        _ = try await bundle.store.assignCategoryBudgetAndRefresh(
            categoryID: "groceries",
            budgeted: 62_500,
            budgetID: "group-1",
            month: "2026-07"
        ) {}
        let pendingCount = try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1")
        #expect(pendingCount > 0)

        bundle.store.reset()
        let state = try makeAppState(for: bundle)
        state.settings.backgroundTransactionRefreshEnabled = true

        #expect(state.setupPhase == .restoringBudget)
        #expect(!bundle.store.isOpen(budgetID: "group-1"))

        let success = await state.performBackgroundTransactionRefresh()

        #expect(success)
        #expect(bundle.store.isOpen(budgetID: "group-1"))
        #expect(try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1") == 0)
        #expect(await transport.messageCounts().contains(pendingCount))
        let run = try #require(state.settings.backgroundRefreshDebug.recentRuns.first)
        #expect(run.succeeded == true)
        #expect(run.message == "Synced budget; no new transactions")
    }

    @Test func successfulSyncCheckpointSurvivesOfflineCachedBudgetReopen() async throws {
        let transport = RecordingSyncTransport()
        let bundle = try await makeOpenedWritableStoreBundle { _ in transport }
        try bundle.keychain.saveActualSyncToken("token")

        try await bundle.store.refresh(
            budgetID: "group-1",
            serverURLString: "https://sync.example"
        )
        let original = try #require(bundle.store.syncStatus(budgetID: "group-1"))
        let originalLastSyncedAt = try #require(original.lastSyncedAt)
        let requestCount = await transport.messageCounts().count

        bundle.store.reset()
        #expect(try await bundle.store.openCachedBudget(bundle.budget))

        let restored = try #require(bundle.store.syncStatus(budgetID: "group-1"))
        let restoredLastSyncedAt = try #require(restored.lastSyncedAt)
        #expect(abs(restoredLastSyncedAt.timeIntervalSince(originalLastSyncedAt)) < 0.001)
        #expect(restored.lastAppliedMessageCount == original.lastAppliedMessageCount)
        #expect(restored.lastUploadedMessageCount == original.lastUploadedMessageCount)
        #expect(restored.pendingLocalMessageCount == 0)
        #expect(await transport.messageCounts().count == requestCount)
    }

    @Test func localFirstSyncMessageEnvelopeRoundTripsThroughProtobuf() async throws {
        let message = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-node1",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: "S:groceries"
        )

        let envelope = try LocalFirstSyncMessageBuilder.envelope(for: message)
        let decoded = try ActualSync_Message(serializedBytes: envelope.content)

        #expect(envelope.timestamp == message.timestamp)
        #expect(envelope.isEncrypted == false)
        #expect(decoded.dataset == "transactions")
        #expect(decoded.row == "txn")
        #expect(decoded.column == "category")
        #expect(decoded.value == "S:groceries")
    }

    @Test func encryptedDataDecodesActualWireFieldOrder() async throws {
        let iv = Data("123456789012".utf8)
        let authTag = Data("abcdefghijklmnop".utf8)
        let data = Data("ciphertext".utf8)
        var wireData = Data()
        wireData.append(contentsOf: [0x0a, UInt8(iv.count)])
        wireData.append(iv)
        wireData.append(contentsOf: [0x12, UInt8(authTag.count)])
        wireData.append(authTag)
        wireData.append(contentsOf: [0x1a, UInt8(data.count)])
        wireData.append(data)

        let encryptedData = try ActualSync_EncryptedData(serializedBytes: wireData)

        #expect(encryptedData.iv == iv)
        #expect(encryptedData.authTag == authTag)
        #expect(encryptedData.data == data)
    }

    @Test func localFirstSyncMessageEnvelopeCanBeEncrypted() async throws {
        let context = ActualBudgetEncryptionContext(
            keyID: "key-1",
            keyData: try ActualBudgetCrypto.deriveKey(password: "password", salt: "salt")
        )
        let message = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-node1",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: "S:groceries"
        )

        let envelope = try LocalFirstSyncMessageBuilder.envelope(
            for: message,
            encryptionContext: context
        )
        let encryptedData = try ActualSync_EncryptedData(serializedBytes: envelope.content)
        let decrypted = try ActualBudgetCrypto.decrypt(
            ActualEncryptedData(
                data: encryptedData.data,
                iv: encryptedData.iv,
                authTag: encryptedData.authTag
            ),
            keyData: context.keyData
        )
        let decoded = try ActualSync_Message(serializedBytes: decrypted)

        #expect(envelope.timestamp == message.timestamp)
        #expect(envelope.isEncrypted)
        #expect(decoded.dataset == "transactions")
        #expect(decoded.row == "txn")
        #expect(decoded.column == "category")
        #expect(decoded.value == "S:groceries")
    }

    @Test func encryptedBudgetLogsAndAllowsMixedPlaintextEnvelopesByDefault() async throws {
        let database = try BudgetDatabase(databaseURL: makeSQLiteFixture())
        let context = ActualBudgetEncryptionContext(
            keyID: "key-1",
            keyData: try ActualBudgetCrypto.deriveKey(password: "password", salt: "salt")
        )
        let encryptedMessage = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-server",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: LocalFirstSyncValue.string("utilities").serialized
        )
        let plaintextMessage = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0001-server",
            dataset: "transactions",
            row: "txn",
            column: "amount",
            serializedValue: LocalFirstSyncValue.int(-9_999).serialized
        )
        var response = ActualSync_SyncResponse()
        response.messages = [
            try LocalFirstSyncMessageBuilder.envelope(
                for: encryptedMessage,
                encryptionContext: context
            ),
            try LocalFirstSyncMessageBuilder.envelope(for: plaintextMessage)
        ]
        let recorder = PlaintextEnvelopeAuditRecorder()
        let client = SyncClient(plaintextEnvelopeAuditRecorder: recorder.record)
        await client.configure(
            LocalFirstSyncConfiguration(
                fileID: "private-budget-id",
                groupID: nil,
                nodeID: "node",
                encryptionKeyID: context.keyID,
                encryptionContext: context
            )
        )

        let result = try await client.pullAndApply(
            database: database,
            client: FixedResponseSyncTransport(responseData: try response.serializedData()),
            token: "token"
        )

        let transaction = try #require(
            try await database.fetchTransactions(accountID: "checking")
                .first { $0.id == "txn" }
        )
        let events = recorder.events()
        let event = try #require(events.first)
        #expect(result.appliedMessageCount == 2)
        #expect(transaction.category == "utilities")
        #expect(transaction.amount == -9_999)
        #expect(event.budgetIDHash != "private-budget-id")
        #expect(event.budgetIDHash.count == 64)
        #expect(event.plaintextMessageCount == 1)
        #expect(event.totalMessageCount == 2)
        #expect(event.earliestTimestamp == plaintextMessage.timestamp)
        #expect(event.latestTimestamp == plaintextMessage.timestamp)
        #expect(event.hasEncryptionContext)
        #expect(events.count == 1)
    }

    @Test func encryptedBudgetCanRejectMixedPlaintextEnvelopesWithoutApplyingAny() async throws {
        let database = try BudgetDatabase(databaseURL: makeSQLiteFixture())
        let context = ActualBudgetEncryptionContext(
            keyID: "key-1",
            keyData: try ActualBudgetCrypto.deriveKey(password: "password", salt: "salt")
        )
        let encryptedMessage = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-server",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: LocalFirstSyncValue.string("utilities").serialized
        )
        let plaintextMessage = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0001-server",
            dataset: "transactions",
            row: "txn",
            column: "amount",
            serializedValue: LocalFirstSyncValue.int(-9_999).serialized
        )
        var response = ActualSync_SyncResponse()
        response.messages = [
            try LocalFirstSyncMessageBuilder.envelope(
                for: encryptedMessage,
                encryptionContext: context
            ),
            try LocalFirstSyncMessageBuilder.envelope(for: plaintextMessage)
        ]
        let recorder = PlaintextEnvelopeAuditRecorder()
        let client = SyncClient(
            enforcesAuthenticatedEncryptedEnvelopes: true,
            plaintextEnvelopeAuditRecorder: recorder.record
        )
        await client.configure(
            LocalFirstSyncConfiguration(
                fileID: "private-budget-id",
                groupID: nil,
                nodeID: "node",
                encryptionKeyID: context.keyID,
                encryptionContext: context
            )
        )

        await #expect(throws: LocalFirstError.unauthenticatedPlaintextEnvelope) {
            _ = try await client.pullAndApply(
                database: database,
                client: FixedResponseSyncTransport(responseData: try response.serializedData()),
                token: "token"
            )
        }

        let transaction = try #require(
            try await database.fetchTransactions(accountID: "checking")
                .first { $0.id == "txn" }
        )
        #expect(transaction.category == "groceries")
        #expect(transaction.amount == -12_345)
        #expect(recorder.events().count == 1)
    }

    @Test func applyLocalSyncMessagesUpdatesSQLiteAndMessagesTable() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let message = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-node1",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: LocalFirstSyncValue.string("gas").serialized
        )

        let appliedCount = try await database.applyLocalSyncMessages([message])

        let transactions = try await database.fetchTransactions(accountID: "checking")
        let transaction = try #require(transactions.first { $0.id == "txn" })
        #expect(appliedCount == 1)
        #expect(transaction.category == "gas")
        #expect(try await database.latestSyncTimestamp() == message.timestamp)
    }

    @Test func sameCellLocalTimestampCollisionIsReportedAndDoesNotChangeTheValue() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let timestamp = "2026-07-04T12:34:56.789Z-0000-node1"
        let first = ActualSyncDecodedMessage(
            timestamp: timestamp,
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: LocalFirstSyncValue.string("first").serialized
        )
        let colliding = ActualSyncDecodedMessage(
            timestamp: timestamp,
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: LocalFirstSyncValue.string("silently-lost-before-8a").serialized
        )

        _ = try await database.applyLocalSyncMessages([first])
        await #expect(throws: LocalFirstError.localWriteSuperseded) {
            _ = try await database.applyLocalSyncMessages([colliding])
        }

        let transactions = try await database.fetchTransactions(accountID: "checking")
        let transaction = try #require(transactions.first { $0.id == "txn" })
        #expect(transaction.category == "first")
        #expect(try await database.latestSyncTimestamp() == timestamp)
    }

    @Test func midBatchRollbackKeepsDatabaseAndVisibleBudgetStateInSyncAndShowsError() async throws {
        let bundle = try await makeOpenedWritableStoreBundle(
            additionalFixtureSQL: """
                CREATE TRIGGER fail_budget_amount_message
                BEFORE INSERT ON messages_crdt
                WHEN NEW.dataset = 'zero_budgets' AND NEW.column = 'amount'
                BEGIN
                    SELECT RAISE(ABORT, 'forced mid-batch failure');
                END;
                """
        )
        let model = BudgetViewModel()
        await model.load(budgetID: "group-1", repository: bundle.store)
        let initialCategory = try #require(
            model.visibleGroups.flatMap(\.visibleCategories).first { $0.id == "groceries" }
        )
        #expect(initialCategory.budgeted == 50_000)

        model.beginAssignmentEditing(for: initialCategory)
        for digit in [6, 0, 0, 0, 0] {
            model.appendAssignmentDigit(digit)
        }
        let saved = await model.submitAssignment(
            budgetID: "group-1",
            repository: bundle.store
        )

        #expect(!saved)
        #expect(
            model.activeAssignmentErrorMessage
                == LocalFirstError.invalidLocalWrite(
                    "the database transaction was rolled back"
                ).localizedDescription
        )
        #expect(model.assignmentDraft?.submissionState.isSubmitting == false)
        #expect(
            model.visibleGroups.flatMap(\.visibleCategories)
                .first { $0.id == "groceries" }?.budgeted == 50_000
        )

        let reloaded = try await bundle.store.budgetMonth(
            budgetID: "group-1",
            selectedMonth: "2026-07"
        )
        let persistedCategory = try #require(
            reloaded.month.categoryGroups.flatMap(\.categories)
                .first { $0.id == "groceries" }
        )
        #expect(persistedCategory.budgeted == 50_000)
        #expect(try await bundle.store.pendingLocalSyncMessageCount(budgetID: "group-1") == 0)
    }

    @Test func applyLocalSyncMessagesAndEnqueueStoresPendingOutboxMessages() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        // Prime the cached miss before the first write creates the outbox.
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
        let baseTimestamp = try await database.latestSyncTimestamp()
        let message = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-node1",
            dataset: "transactions",
            row: "txn",
            column: "category",
            serializedValue: LocalFirstSyncValue.string("gas").serialized
        )

        let appliedCount = try await database.applyLocalSyncMessagesAndEnqueue([message], baseTimestamp: baseTimestamp)
        let pending = try await database.pendingLocalSyncMessages()
        let transactions = try await database.fetchTransactions(accountID: "checking")
        let transaction = try #require(transactions.first { $0.id == "txn" })

        #expect(appliedCount == 1)
        #expect(transaction.category == "gas")
        #expect(pending.map(\.message) == [message])
        #expect(pending.first?.baseTimestamp == baseTimestamp)
        #expect(try await database.pendingLocalSyncMessageCount() == 1)
    }

    @Test func failedLocalSyncApplyDoesNotLeaveOutboxRows() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let message = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-node1",
            dataset: "transactions",
            row: "txn",
            column: "bogus",
            serializedValue: LocalFirstSyncValue.string("nope").serialized
        )

        await #expect(throws: LocalFirstError.invalidLocalWrite("unknown column transactions.bogus")) {
            _ = try await database.applyLocalSyncMessagesAndEnqueue(
                [message],
                baseTimestamp: try await database.latestSyncTimestamp()
            )
        }
        #expect(try await database.pendingLocalSyncMessageCount() == 0)
    }

    @Test func applyLocalSyncMessagesRejectsUnknownColumns() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let message = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-node1",
            dataset: "transactions",
            row: "txn",
            column: "bogus",
            serializedValue: LocalFirstSyncValue.string("nope").serialized
        )

        await #expect(throws: LocalFirstError.invalidLocalWrite("unknown column transactions.bogus")) {
            _ = try await database.applyLocalSyncMessages([message])
        }
    }

    @Test func deserializeRemoteNumericPayloadsRejectNonFiniteButPreservesHugeDoubles() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)

        let huge = try await database.deserializeSyncValue("N:1e300")
        switch huge {
        case .double(let value):
            #expect(value == 1e300)
        default:
            Issue.record("Expected 1e300 to decode as a Double")
        }

        await #expect(throws: LocalFirstError.invalidDownloadedBudget) {
            _ = try await database.deserializeSyncValue("N:inf")
        }
        await #expect(throws: LocalFirstError.invalidDownloadedBudget) {
            _ = try await database.deserializeSyncValue("N:not-a-number")
        }
    }

    @Test func remoteUnknownDatasetOrColumnAdvancesSyncWithoutMutatingLocalTables() async throws {
        let fixtureURL = try makeSQLiteFixture()
        let database = try BudgetDatabase(databaseURL: fixtureURL)
        let unknownDataset = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:56.789Z-0000-node1",
            dataset: "future_table",
            row: "row-1",
            column: "name",
            serializedValue: LocalFirstSyncValue.string("ignored").serialized
        )
        let unknownColumn = ActualSyncDecodedMessage(
            timestamp: "2026-07-04T12:34:57.789Z-0000-node1",
            dataset: "transactions",
            row: "txn",
            column: "future_column",
            serializedValue: LocalFirstSyncValue.string("ignored").serialized
        )

        let appliedCount = try await database.applyRemoteSyncMessages([unknownColumn, unknownDataset])
        let transactions = try await database.fetchTransactions(accountID: "checking")
        let transaction = try #require(transactions.first { $0.id == "txn" })

        #expect(appliedCount == 2)
        #expect(transaction.category == "groceries")
        #expect(try await database.latestSyncTimestamp() == unknownColumn.timestamp)
    }

    @Test func refreshWithoutOpenBudgetThrowsBudgetNotOpened() async {
        let store = LocalFirstActualStore(
            keychain: KeychainStore(
                service: "com.sporez.actualist.tests",
                account: UUID().uuidString
            )
        )

        await #expect(throws: LocalFirstError.budgetNotOpened) {
            try await store.refresh(budgetID: "missing", serverURLString: "https://example.com")
        }
    }

    @Test func refreshLocalFirstDataIsNoOpWithoutOpenBudget() async {
        let state = makeAppState()
        state.setupPhase = .ready
        state.connectionStatus = .online

        // No budget has been opened, so the guard returns immediately without mutating state.
        await state.refreshLocalFirstData(budgetID: "any")

        #expect(state.connectionStatus == .online)
        #expect(state.localFirstSyncStatus == nil)
    }

    @Test(arguments: ReimportFailureScenario.allCases)
    func reimportFailureLeavesOriginalBudgetOpen(
        scenario: ReimportFailureScenario
    ) async throws {
        let archiveData: Data
        switch scenario {
        case .corruptArchive:
            archiveData = Data("not a zip archive".utf8)
        case .wrongSchema:
            let wrongSchemaURL = FileManager.default.temporaryDirectory
                .appending(path: "ActualistWrongSchema-\(UUID().uuidString).sqlite")
            let queue = try DatabaseQueue(path: wrongSchemaURL.path)
            try await queue.write { db in
                try db.execute(sql: "CREATE TABLE unrelated (id TEXT PRIMARY KEY)")
            }
            archiveData = try makeArchiveData(databaseURL: wrongSchemaURL)
        default:
            archiveData = try makeArchiveData(databaseURL: makeSQLiteFixture())
        }

        let failurePoint: StubConnectionTransport.FailurePoint =
            scenario == .midDownload ? .download : .none
        let injectedCheckpoint: BudgetReimportCheckpoint?
        switch scenario {
        case .midDecrypt:
            injectedCheckpoint = .beforeDecrypt
        case .midExtract:
            injectedCheckpoint = .beforeExtract
        default:
            injectedCheckpoint = nil
        }

        let connectionTransport = StubConnectionTransport(
            failurePoint: failurePoint,
            files: [testRemoteFile()],
            token: "reimport-token",
            downloadData: archiveData
        )
        let syncTransport = RecordingSyncTransport()
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in syncTransport },
            connectionTransportFactory: { _ in connectionTransport },
            reimportFailureCheckpoint: injectedCheckpoint
        )
        try bundle.keychain.saveActualSyncToken("reimport-token")
        let original = try await bundle.store.budgetMonth(
            budgetID: "group-1",
            selectedMonth: "2026-07"
        )

        await #expect(throws: (any Error).self) {
            try await bundle.store.reimportBudget(
                bundle.budget,
                serverURLString: "https://sync.example"
            )
        }

        #expect(bundle.store.isOpen(budgetID: "group-1"))
        let restored = try await bundle.store.budgetMonth(
            budgetID: "group-1",
            selectedMonth: "2026-07"
        )
        #expect(restored.month == original.month)
        #expect(try Data(contentsOf: bundle.fileManager.databaseURL(fileID: "file-1")).count > 0)
        let budgetRoot = bundle.fileManager.applicationSupportURL.appending(path: "Budgets")
        let leftoverNames = try FileManager.default.contentsOfDirectory(atPath: budgetRoot.path)
        #expect(!leftoverNames.contains { $0.contains(".reimport-") })
    }

    @Test func successfulReimportOpensReplacementAndRetainsRecoverableBackup() async throws {
        let replacementURL = try makeSQLiteFixture(
            extraSQL: "INSERT INTO accounts VALUES ('replacement', 'Replacement', 0, 0, 0, 2)"
        )
        let archiveData = try makeArchiveData(databaseURL: replacementURL)
        let connectionTransport = StubConnectionTransport(
            files: [testRemoteFile()],
            token: "reimport-token",
            downloadData: archiveData
        )
        let syncTransport = RecordingSyncTransport()
        let bundle = try await makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in syncTransport },
            connectionTransportFactory: { _ in connectionTransport }
        )
        try bundle.keychain.saveActualSyncToken("reimport-token")

        try await bundle.store.reimportBudget(
            bundle.budget,
            serverURLString: "https://sync.example"
        )

        #expect(bundle.store.isOpen(budgetID: "group-1"))
        let accounts = bundle.store.accountDisplays(budgetID: "group-1").map(\.account.id)
        #expect(accounts.contains("replacement"))
        #expect(try bundle.fileManager.reimportBackupExists(fileID: "file-1"))
    }

    @Test(arguments: [
        ("http://actual.example.com", StubConnectionTransport.FailurePoint.none, false),
        ("https://unreachable.example", .loginMethods, false),
        ("https://wrong-password.example", .login, false),
        ("https://empty.example", .none, true)
    ])
    func failedConnectionValidationPreservesWorkingConnection(
        attemptedURL: String,
        failurePoint: StubConnectionTransport.FailurePoint,
        returnsNoBudgets: Bool
    ) async throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let settingsStore = AppSettingsStore(defaults: defaults)
        let previousSettings = AppSettings(
            localFirstServerURLString: "https://working.example",
            selectedBudgetID: "group-old",
            selectedBudgetName: "Working Budget",
            selectedLocalFirstFileID: "file-old",
            selectedLocalFirstGroupID: "group-old",
            backgroundTransactionRefreshEnabled: true,
            pendingNewTransactionIDsByAccount: ["group-old:checking": ["txn-old"]]
        )
        settingsStore.save(previousSettings)

        let backend = FakeKeychainBackend()
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests",
            account: UUID().uuidString,
            backend: backend
        )
        try keychain.saveActualSyncToken("working-token")
        try keychain.saveLocalFirstEncryptionKey(
            Data("working-key".utf8),
            fileID: "file-old",
            keyID: "key-old"
        )

        let connectionTransport = StubConnectionTransport(
            failurePoint: failurePoint,
            files: returnsNoBudgets ? [] : [
                ActualSyncRemoteFile(
                    fileID: "file-new",
                    groupID: "group-new",
                    name: "New Budget"
                )
            ]
        )
        let store = LocalFirstActualStore(
            keychain: keychain,
            connectionTransportFactory: { _ in connectionTransport }
        )
        let state = AppState(
            settingsStore: settingsStore,
            keychain: keychain,
            localFirstStore: store
        )
        state.setupPhase = .ready
        state.connectionStatus = .online
        let model = SettingsViewModel()
        model.actualPassword = "attempted-password"
        model.serverURLString = attemptedURL

        await model.saveAndTest(using: state)

        #expect(state.settings == previousSettings)
        #expect(settingsStore.load() == previousSettings)
        #expect(keychain.readActualSyncToken() == "working-token")
        #expect(
            keychain.readLocalFirstEncryptionKey(fileID: "file-old", keyID: "key-old")
                == Data("working-key".utf8)
        )
        #expect(state.setupPhase == .ready)
        #expect(state.connectionStatus == .online)
        #expect(model.actualPassword == "attempted-password")
    }

    @Test func syncStatusDefaultsAndEquality() async {
        let base = LocalFirstSyncStatus(fileID: "file", groupID: "group")
        #expect(base.lastSyncedAt == nil)
        #expect(base.lastAppliedMessageCount == 0)
        #expect(base.lastError == nil)
        #expect(base == LocalFirstSyncStatus(fileID: "file", groupID: "group"))
        #expect(base != LocalFirstSyncStatus(fileID: "file", groupID: "other"))
    }

    private func makeAppState() -> AppState {
        let defaultsName = "ActualistTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        return AppState(
            settingsStore: AppSettingsStore(defaults: defaults),
            keychain: KeychainStore(
                service: "com.sporez.actualist.tests",
                account: UUID().uuidString
            )
        )
    }

}
