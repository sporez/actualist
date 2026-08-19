import Foundation
import GRDB
import Security
import SwiftUI
import Testing
import ZIPFoundation
@testable import Actualist

@MainActor
struct DemoModeStoreTests {
    /// A demo store backed by a throwaway Application Support directory and a
    /// recording sync transport so tests can assert zero server round-trips.
    private func makeDemoStore(transport: ActualSyncTransport) -> (store: LocalFirstActualStore, fileManager: BudgetFileManager) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ActualistDemo-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fileManager = BudgetFileManager(applicationSupportURL: root)
        let keychain = KeychainStore(
            service: "com.sporez.actualist.tests",
            account: UUID().uuidString
        )
        let store = LocalFirstActualStore(
            keychain: keychain,
            fileManager: fileManager,
            syncTransportFactory: { _ in transport },
            connectionTransportFactory: { _ in StubConnectionTransport() }
        )
        return (store, fileManager)
    }

    private func makeDate(year: Int, month: Int, day: Int) throws -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return try #require(components.date)
    }

    @Test func openDemoBudgetInstallsAndOpensDemoBudget() async throws {
        let transport = RecordingSyncTransport()
        let (store, fileManager) = makeDemoStore(transport: transport)

        try await store.openDemoBudget()

        #expect(store.isDemoBudgetActive)
        #expect(store.isOpen(budgetID: DemoBudget.groupID))
        #expect(store.openedBudgetID == DemoBudget.groupID)
        #expect(fileManager.importedDatabaseExists(fileID: DemoBudget.fileID))

        let accounts = store.accountDisplays(budgetID: DemoBudget.groupID)
        #expect(accounts.count == 4)
        // The bundled artifact's digest matches the committed constants.
        #expect(DemoBudget.bundledArchiveMatchesCommittedDigest())
        // Opening the demo budget never touches a sync transport.
        #expect(await transport.messageCounts().isEmpty)
    }

    @Test func reentryWithStaleVersionReinstalls() async throws {
        let transport = RecordingSyncTransport()
        let (store, fileManager) = makeDemoStore(transport: transport)

        try await store.openDemoBudget()
        // Simulate a stale fixture from an older app build by downgrading the
        // persisted cloudFileID on disk.
        let stale = LocalFirstBudgetMetadata(
            localBudgetID: DemoBudget.fileID,
            cloudFileID: "actualist-demo-budget-v0",
            groupID: DemoBudget.groupID,
            budgetName: DemoBudget.name,
            encryptionKeyID: nil,
            nodeID: DemoBudget.nodeID
        )
        try JSONEncoder.actual.encode(stale).write(to: fileManager.metadataURL(fileID: DemoBudget.fileID))
        store.closeOpenBudget()

        try await store.openDemoBudget()

        #expect(store.isDemoBudgetActive)
        #expect(store.isOpen(budgetID: DemoBudget.groupID))
        let restored = try fileManager.loadMetadata(fileID: DemoBudget.fileID)
        #expect(restored?.cloudFileID == DemoBudget.fileID)
        #expect(await transport.messageCounts().isEmpty)
    }

    @Test func writesApplyLocallyAndOutboxIsDrained() async throws {
        let transport = RecordingSyncTransport()
        let (store, _) = makeDemoStore(transport: transport)

        try await store.openDemoBudget()
        let budgetID = DemoBudget.groupID

        let draft = TransactionDraft(
            accountID: "checking",
            date: try makeDate(year: 2026, month: 8, day: 5),
            amountMinorUnits: -4321,
            payeeID: "grocer",
            payeeName: "Fresh Market",
            categoryID: "groceries",
            notes: "Demo write",
            cleared: false,
            isTransfer: false
        )
        _ = try await store.createTransactionAndRefresh(
            draft,
            budgetID: budgetID,
            didCreate: {}
        )

        // Demo mode drains the outbox immediately; no pending local messages.
        let pending = try await store.pendingLocalSyncMessageCount(budgetID: budgetID)
        #expect(pending == 0)
        #expect(store.syncStatus?.pendingLocalMessageCount == 0)
        // The local write still never reached a server.
        #expect(await transport.messageCounts().isEmpty)
    }

    @Test func refreshPerformsZeroTransportCalls() async throws {
        let transport = RecordingSyncTransport()
        let (store, _) = makeDemoStore(transport: transport)

        try await store.openDemoBudget()
        let budgetID = DemoBudget.groupID

        try await store.refresh(budgetID: budgetID, serverURLString: "")
        #expect(await transport.messageCounts().isEmpty)

        // pullAndReload directly is also transport-free in demo.
        _ = try await store.pullAndReload(budgetID: budgetID, serverURLString: "")
        #expect(await transport.messageCounts().isEmpty)
    }

    @Test func importedBudgetGoneAfterExit() async throws {
        let transport = RecordingSyncTransport()
        let (store, fileManager) = makeDemoStore(transport: transport)

        try await store.openDemoBudget()
        #expect(fileManager.importedDatabaseExists(fileID: DemoBudget.fileID))

        store.closeOpenBudget()
        try store.eraseLocalData()

        #expect(!fileManager.importedDatabaseExists(fileID: DemoBudget.fileID))
        #expect(!store.isDemoBudgetActive)
    }
}
