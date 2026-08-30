import GRDB
import Testing
@testable import Actualist

/// The SimpleFIN surface may display links created by other Actual providers,
/// but every unlink entry point must leave those providers' metadata intact.
extension LocalFirstActualStoreTests {
    @Test func goCardlessLinkCannotBeUnlinkedBySimpleFINPath() async throws {
        try await expectProtectedProviderMetadata(syncSource: "goCardless")
    }

    @Test func plaidLinkCannotBeUnlinkedBySimpleFINPath() async throws {
        try await expectProtectedProviderMetadata(syncSource: "plaid")
    }

    @Test func unknownProviderLinkCannotBeUnlinkedBySimpleFINPath() async throws {
        try await expectProtectedProviderMetadata(syncSource: "futureProvider")
    }

    private func expectProtectedProviderMetadata(syncSource: String) async throws {
        let bundle = try await makeBankSyncStore(transport: StubSimpleFINTransport())
        let databaseURL = try bundle.fileManager.databaseURL(fileID: "file-1")
        let queue = try DatabaseQueue(path: databaseURL.path)
        try await queue.write { db in
            try db.execute(
                sql: """
                    UPDATE accounts
                    SET account_id = 'other-remote',
                        account_sync_source = ?,
                        bank = 'other-bank',
                        balance_current = 101,
                        balance_available = 202,
                        balance_limit = 303,
                        bank_sync_status = 'provider-owned'
                    WHERE id = 'savings'
                    """,
                arguments: [syncSource]
            )
        }

        await #expect(
            throws: LocalFirstActualStore.BankSyncStoreError.notSimpleFINLinked
        ) {
            try await bundle.store.unlinkBankAccount("savings", budgetID: "group-1")
        }

        let storedRow: Row? = try await queue.read { db in
            return try Row.fetchOne(
                db,
                sql: """
                    SELECT account_id, account_sync_source, bank,
                           balance_current, balance_available, balance_limit,
                           bank_sync_status
                    FROM accounts WHERE id = 'savings'
                    """
            )
        }
        let row = try #require(storedRow)
        #expect(row["account_id"] as String? == "other-remote")
        #expect(row["account_sync_source"] as String? == syncSource)
        #expect(row["bank"] as String? == "other-bank")
        #expect(row["balance_current"] as Int? == 101)
        #expect(row["balance_available"] as Int? == 202)
        #expect(row["balance_limit"] as Int? == 303)
        #expect(row["bank_sync_status"] as String? == "provider-owned")

        let messages = try storedCRDTMessages(at: databaseURL)
        #expect(!messages.contains {
            $0.dataset == "accounts" && $0.row == "savings" && $0.serializedValue == "0:"
        })

        // Defense in depth: even bypassing the store preflight cannot produce
        // unlink CRDT messages for another provider.
        let database = try #require(bundle.store.database)
        await #expect(throws: LocalFirstError.self) {
            var builder = LocalFirstSyncMessageBuilder()
            _ = try await database.makeBankSyncUnlinkMessages(
                accountID: "savings",
                builder: &builder
            )
        }
    }

    @MainActor
    @Test func viewModelRefusesNonSimpleFINUnlinkIntent() async throws {
        let transport = StubSimpleFINTransport(remoteAccounts: [])
        let bundle = try await makeBankSyncStore(transport: transport)
        let queue = try DatabaseQueue(
            path: bundle.fileManager.databaseURL(fileID: "file-1").path
        )
        try await queue.write { db in
            try db.execute(
                sql: """
                    UPDATE accounts
                    SET account_id = 'gocardless-remote',
                        account_sync_source = 'goCardless',
                        bank = 'gocardless-bank'
                    WHERE id = 'savings'
                    """
            )
        }
        let model = BankSyncViewModel(
            store: bundle.store,
            budgetID: "group-1",
            currency: .usd
        )
        await model.load()
        let line = try #require(model.accountLines.first { $0.id == "savings" })
        #expect(line.isLinked)
        #expect(!line.isSyncable)
        #expect(model.linkedAccountDisplayName(for: line) == "Savings")

        model.selectAccount("savings")
        await model.unlinkSelected()

        #expect(model.phase == .failed("Only SimpleFIN-linked accounts can sync here."))
        let source = try await queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT account_sync_source FROM accounts WHERE id = 'savings'"
            )
        }
        #expect(source == "goCardless")
    }
}
