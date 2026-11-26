import Foundation
import GRDB
@testable import Actualist

/// Shared Enable Banking test fixtures: a stub of the server's routes, the
/// recorded server responses of the `EnableBankingServer` fixture decoded by
/// the production client, and an account linked the way the Actual web app
/// links one.
@MainActor
enum EnableBankingTestSupport {
    /// Thread-safe stub of the server's Enable Banking routes, keyed by the
    /// remote account ID. An unlisted account answers like a server without
    /// the routes.
    actor StubTransport: EnableBankingServerTransport {
        struct Request: Equatable {
            let accountID: String
            let startDate: String
            let aspspName: String?
        }

        private var answers: [String: Result<SimpleFINAccountDownload?, ActualAPIError>]
        private var support: Result<SimpleFINServerSupport, ActualAPIError>
        private(set) var requests: [Request] = []
        private(set) var statusRequests = 0
        private var gate: TestLatch?
        nonisolated let entered = TestLatch()

        init(
            _ answers: [String: Result<SimpleFINAccountDownload?, ActualAPIError>] = [:],
            support: Result<SimpleFINServerSupport, ActualAPIError> = .success(.configured)
        ) {
            self.answers = answers
            self.support = support
        }

        func setAnswer(_ answer: Result<SimpleFINAccountDownload?, ActualAPIError>, for accountID: String) {
            answers[accountID] = answer
        }

        func setGate(_ gate: TestLatch?) {
            self.gate = gate
        }

        func status(token: String) async throws -> SimpleFINServerSupport {
            statusRequests += 1
            return try support.get()
        }

        func transactions(
            token: String,
            accountID: String,
            startDate: String,
            aspspName: String?
        ) async throws -> SimpleFINAccountDownload? {
            requests.append(Request(accountID: accountID, startDate: startDate, aspspName: aspspName))
            if let gate {
                entered.trip()
                await gate.wait()
            }
            return try (answers[accountID] ?? .success(nil)).get()
        }
    }

    /// The server's response to one fixture scenario, decoded by the production client.
    static func download(_ scenarioID: String) throws -> SimpleFINAccountDownload {
        let scenario = try EnableBankingServerFixture.load().scenario(scenarioID)
        return try ActualServerEnableBankingClient.decodeTransactionsResponse(from: Data(scenario.bodyText.utf8))
    }

    static func makeStore(
        support: LocalFirstActualStoreTests,
        simpleFIN: LocalFirstActualStoreTests.StubSimpleFINTransport = .init(),
        enableBanking: StubTransport,
        additionalFixtureSQL: String = ""
    ) async throws -> LocalFirstActualStoreTests.OpenedWritableStoreBundle {
        let bundle = try await support.makeBankSyncStore(transport: simpleFIN, additionalFixtureSQL: additionalFixtureSQL)
        bundle.store.seams.enableBankingTransportFactory = { _ in enableBanking }
        return bundle
    }

    /// Links an account the way the Actual web app's `linkEnableBankingAccount` leaves it.
    static func link(
        _ store: LocalFirstActualStore,
        accountID: String,
        remoteAccountID: String,
        bankName: String?,
        status: String? = nil
    ) async throws {
        let database = try store.requireDatabase(for: "group-1")
        let queue = await database.queue
        try await queue.write { db in
            let bankID = "bank-\(accountID)"
            try db.execute(sql: "INSERT INTO banks (id, bank_id, name) VALUES (?, ?, ?)",
                           arguments: [bankID, remoteAccountID, bankName])
            try db.execute(
                sql: "UPDATE accounts SET account_id = ?, account_sync_source = 'enableBanking', bank = ? WHERE id = ?",
                arguments: [remoteAccountID, bankID, accountID]
            )
            if let status {
                if try !SQLiteSchema.columns(of: "accounts", in: db).contains("bank_sync_status") {
                    try db.execute(sql: "ALTER TABLE accounts ADD COLUMN bank_sync_status TEXT")
                }
                try db.execute(sql: "UPDATE accounts SET bank_sync_status = ? WHERE id = ?", arguments: [status, accountID])
            }
        }
    }

    static func storedStatus(_ store: LocalFirstActualStore, accountID: String) async throws -> String? {
        let database = try store.requireDatabase(for: "group-1")
        return try await BankSyncLinkSQL.bankSyncLinkedAccounts(in: database)
            .first { $0.id == accountID }?.bankSyncStatus
    }
}
