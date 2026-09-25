import Foundation
import GRDB
import Testing
@testable import Actualist

/// Regression coverage for the narrow Actual-parity bank-sync fixes.
/// All provider responses and databases are synthetic; no network is used.
@MainActor
struct BankSyncCorrectnessInvestigationTests {
    private let support = LocalFirstActualStoreTests()

    private actor OfflineSync: ActualSyncTransport {
        func sync(data: Data, token: String) async throws -> Data {
            throw ActualAPIError.transport(.notConnectedToInternet)
        }
    }

    private actor Provider: SimpleFINServerTransport {
        let response: SimpleFINTransactionsResponse
        let pause: Bool
        let configured: SimpleFINServerSupport
        let operationalFailure: Bool
        var waiting: CheckedContinuation<Void, Never>?
        var observer: CheckedContinuation<Void, Never>?
        var entered = false

        init(response: SimpleFINTransactionsResponse, pause: Bool = false,
             configured: SimpleFINServerSupport = .configured, operationalFailure: Bool = false) {
            self.response = response
            self.pause = pause
            self.configured = configured
            self.operationalFailure = operationalFailure
        }

        func simpleFINStatus(token: String) async throws -> SimpleFINServerSupport { configured }
        func simpleFINAccounts(token: String) async throws -> [SimpleFINRemoteAccount]? { [] }
        func simpleFINTransactions(token: String, accountIDs: [String],
                                   startDates: [String]) async throws -> SimpleFINTransactionsResponse? {
            if pause && !entered {
                await withCheckedContinuation { continuation in
                    waiting = continuation
                    entered = true
                    observer?.resume()
                    observer = nil
                }
            }
            if operationalFailure { throw ActualAPIError.transport(.timedOut) }
            return response
        }
        func waitUntilRequested() async {
            if entered { return }
            await withCheckedContinuation { observer = $0 }
        }
        func release() { waiting?.resume(); waiting = nil }
    }

    private func response(error: String? = nil, rows: Bool = false) -> SimpleFINTransactionsResponse {
        let transaction = SimpleFINRemoteTransaction(id: "synthetic-download",
            dateUnixSeconds: 1_783_080_000, amount: "-1.00", currency: "USD",
            payeeName: "Coffee Shop", notes: nil, booked: true, accountID: "old-link")
        return SimpleFINTransactionsResponse(downloads: ["old-link": .init(
            transactions: rows ? [transaction] : [], startingBalance: nil,
            errorType: error, errorCode: error)], errorType: nil, errorCode: nil)
    }

    private func fixture(_ provider: Provider) async throws -> LocalFirstActualStoreTests.OpenedWritableStoreBundle {
        let bundle = try await support.makeOpenedWritableStoreBundle(
            syncTransportFactory: { _ in OfflineSync() },
            simpleFINTransportFactory: { _ in provider },
            pendingLocalMessageFlushRetryDelays: [],
            additionalFixtureSQL: LocalFirstActualStoreTests.bankSyncColumnsSQL)
        bundle.store.openedServerURLString = "https://sync.example"
        try bundle.keychain.saveActualSyncToken("synthetic-token")
        let queue = try queue(bundle)
        try await queue.write { db in
            try db.execute(sql: """
                UPDATE accounts SET account_id = 'old-link', account_sync_source = 'simpleFin',
                last_sync = '1600000000000', bank_sync_status = 'ok' WHERE id = 'savings'
                """)
        }
        return bundle
    }

    private func queue(_ bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle) throws -> DatabaseQueue {
        try DatabaseQueue(path: bundle.fileManager.databaseURL(fileID: "file-1").path)
    }

    private struct Snapshot: Equatable {
        let lastSync: String?
        let status: String?
        let balance: Int?
        let messages: Int
        let outbox: Int
        let transactions: Int
    }

    private func snapshot(_ bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle) throws -> Snapshot {
        try queue(bundle).read { db in
            let hasOutbox = try db.tableExists("actualist_outbox")
            return Snapshot(
                lastSync: try String.fetchOne(db, sql: "SELECT last_sync FROM accounts WHERE id = 'savings'"),
                status: try String.fetchOne(db, sql: "SELECT bank_sync_status FROM accounts WHERE id = 'savings'"),
                balance: try Int.fetchOne(db, sql: "SELECT balance_current FROM accounts WHERE id = 'savings'"),
                messages: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages_crdt") ?? 0,
                outbox: hasOutbox ? (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM actualist_outbox") ?? 0) : 0,
                transactions: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") ?? 0)
        }
    }

    @Test func emptyCompletedDownloadAdvancesTimestampOnlyOnApply() async throws {
        let bundle = try await fixture(Provider(response: response()))
        let before = try snapshot(bundle)
        let plan = try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        #expect(try snapshot(bundle) == before)
        #expect(plan.inserts.isEmpty && plan.updates.isEmpty)
        _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        let after = try snapshot(bundle)
        #expect(after.lastSync != before.lastSync)
        #expect(after.status == "ok")
        #expect(after.balance == nil)
        #expect(after.messages == before.messages + 3)
        #expect(after.outbox == before.outbox + 3)
    }

    @Test func warningPayloadAndErrorOnlyPreserveTimestampLikeActual() async throws {
        for rows in [false, true] {
            let bundle = try await fixture(Provider(response: response(error: "ACCOUNT_NEEDS_ATTENTION", rows: rows)))
            let plan = try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
            #expect(plan.durableStatus == .attentionRequired)
            #expect(plan.inserts.isEmpty)
            _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
            let after = try snapshot(bundle)
            #expect(after.lastSync == "1600000000000")
            #expect(after.status == "attention-required")
            #expect(after.outbox == 1)
        }
    }

    @Test func incompleteAccountMustNotMasqueradeAsEmptySuccess() async throws {
        let decoded = try ActualServerSimpleFINClient.decodeTransactionsResponse(
            from: Data(#"{"status":"ok","data":{"old-link":{}}}"#.utf8))
        let bundle = try await fixture(Provider(response: decoded))
        let plan = try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        // Desired invariant: absent transactions.all is not proof of completion.
        #expect(plan.durableStatus != .ok || !plan.problems.isEmpty)
    }

    @Test(arguments: [false, true], ["unchanged", "unlink", "relink", "remote-link", "closed", "deleted"])
    func inFlightResultMustMatchPersistedLink(failure: Bool, mutation: String) async throws {
        let provider = Provider(response: response(error: failure ? "TIMED_OUT" : nil, rows: !failure), pause: true)
        let bundle = try await fixture(provider)
        let task = Task { try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1") }
        await provider.waitUntilRequested()
        if mutation == "unlink" {
            try await bundle.store.unlinkBankAccount("savings", budgetID: "group-1")
        } else if mutation == "relink" {
            let remote = SimpleFINRemoteAccount(accountID: "new-link", name: "Synthetic", balance: nil,
                currency: "USD", institution: nil, orgName: nil, orgDomain: "bank.example", orgID: nil)
            try await bundle.store.linkBankAccount("savings", to: remote, budgetID: "group-1")
        } else if mutation != "unchanged" {
            let database = try #require(bundle.store.database)
            let column = mutation == "remote-link" ? "account_id" : (mutation == "closed" ? "closed" : "tombstone")
            let value = mutation == "remote-link" ? "S:new-link" : "N:1"
            _ = try await database.applyRemoteSyncMessages([ActualSyncDecodedMessage(
                timestamp: "2026-09-01T00:00:00.000Z-0000-1234567890abcdef",
                dataset: "accounts", row: "savings", column: column, serializedValue: value)])
        }
        let before = try snapshot(bundle)
        await provider.release()
        do {
            let plan = try await task.value
            _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        } catch {
            if mutation == "unchanged" { throw error }
        }
        let after = try snapshot(bundle)
        if mutation == "unchanged" {
            #expect(after.messages > before.messages)
            #expect(after.status == (failure ? "timed-out" : "ok"))
            #expect(failure ? after.lastSync == before.lastSync : after.lastSync != before.lastSync)
        } else {
            // Rejected results must have no durable effects.
            #expect(after == before)
        }
    }

    @Test(arguments: [false, true])
    func staleThrownFailureCannotOverwriteRemoteRelink(close: Bool) async throws {
        let provider = Provider(response: response(), pause: true, operationalFailure: true)
        let bundle = try await fixture(provider)
        let task = Task { try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1") }
        await provider.waitUntilRequested()
        if close {
            bundle.store.closeOpenBudget()
        } else {
            let database = try #require(bundle.store.database)
            _ = try await database.applyRemoteSyncMessages([ActualSyncDecodedMessage(
                timestamp: "2026-09-01T00:00:00.000Z-0000-1234567890abcdef",
                dataset: "accounts", row: "savings", column: "account_id", serializedValue: "S:new-link")])
        }
        let before = try snapshot(bundle)
        await provider.release()
        await #expect(throws: ActualAPIError.self) { try await task.value }
        #expect(try snapshot(bundle) == before)
    }

    @Test(arguments: ["unchanged", "storage", "provider", "closed-handle"])
    func commitBoundaryValidatesCapturedIdentity(mutation: String) async throws {
        let bundle = try await fixture(Provider(response: response()))
        let plan = try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        let database = try #require(bundle.store.database)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.makeBankSyncCompletionMessages(
            accountID: "savings",
            lastSyncEpochMilliseconds: nil,
            status: .failed,
            balanceDisposition: .preserve,
            builder: &builder
        )
        if mutation == "storage" {
            try await queue(bundle).write { db in
                try db.execute(sql: "UPDATE actualist_budget_identity SET storage_id = 'replacement'")
            }
        } else if mutation == "provider" {
            try await queue(bundle).write { db in
                try db.execute(sql: "UPDATE accounts SET account_sync_source = 'other' WHERE id = 'savings'")
            }
        } else if mutation == "closed-handle" {
            bundle.store.closeOpenBudget()
        }
        let before = try snapshot(bundle)
        if mutation == "unchanged" {
            _ = try await database.commitBankSyncMessages(messages, expectedLink: plan.link)
            #expect(try snapshot(bundle).status == "failed")
        } else {
            await #expect(throws: LocalFirstError.self) {
                try await database.commitBankSyncMessages(messages, expectedLink: plan.link)
            }
            #expect(try snapshot(bundle) == before)
        }
    }

    @Test func olderDownloadCannotReplaceNewerRun() async throws {
        let provider = Provider(response: response(rows: true), pause: true)
        let bundle = try await fixture(provider)
        let older = Task { try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1") }
        await provider.waitUntilRequested()
        let newer = try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        _ = try await bundle.store.applyBankSyncPlan(newer, budgetID: "group-1")
        let before = try snapshot(bundle)
        await provider.release()
        await #expect(throws: LocalFirstActualStore.BankSyncStoreError.staleGeneration) { try await older.value }
        #expect(try snapshot(bundle) == before)
    }

    @Test func duplicateAccountRequestsProduceOnePlan() async throws {
        let bundle = try await fixture(Provider(response: response()))
        let plans = try await bundle.store.downloadBankSyncPlans(accountIDs: ["savings", "savings"], budgetID: "group-1")
        #expect(plans.count == 1)
    }

    @Test func missingLocalSyncTokenDoesNotWriteSharedStatus() async throws {
        let bundle = try await fixture(Provider(response: response()))
        try bundle.keychain.removeActualSyncToken()
        let before = try snapshot(bundle)
        await #expect(throws: LocalFirstError.missingSyncToken) {
            try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        }
        #expect(try snapshot(bundle) == before)
    }

    @Test func thrownOperationalFailureRecordsStatusWithoutChangingTimestamp() async throws {
        let bundle = try await fixture(Provider(response: response(), operationalFailure: true))
        let before = try snapshot(bundle)
        await #expect(throws: ActualAPIError.self) {
            try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        }
        let after = try snapshot(bundle)
        #expect(after.lastSync == before.lastSync)
        #expect(after.status == "timed-out")
        #expect(after.messages == before.messages + 1)
        #expect(after.outbox == before.outbox + 1)
    }

    @Test func missingDeviceKeyRefusesUnsupportedServerWithoutSharedWrites() async throws {
        let provider = Provider(response: .init(downloads: [:], errorType: nil, errorCode: nil), configured: .unsupported)
        let bundle = try await fixture(provider)
        #expect(try !bundle.store.hasBankSyncDeviceKey())
        let before = try snapshot(bundle)
        await #expect(throws: LocalFirstActualStore.BankSyncStoreError.notConfigured) {
            try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        }
        #expect(try snapshot(bundle) == before)
    }

    @Test func rollbackRemovesTransactionsStatusCRDTAndOutboxTogether() async throws {
        let bundle = try await fixture(Provider(response: response(rows: true)))
        let plan = try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        try await queue(bundle).write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_stamp BEFORE UPDATE OF bank_sync_status ON accounts
                BEGIN SELECT RAISE(ABORT, 'synthetic rollback'); END
                """)
        }
        let before = try snapshot(bundle)
        await #expect(throws: LocalFirstError.self) {
            try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        }
        #expect(try snapshot(bundle) == before)
    }

    @Test func completedPlanCannotBeAppliedTwice() async throws {
        let bundle = try await fixture(Provider(response: response(rows: true)))
        let plan = try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        _ = try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        let before = try snapshot(bundle)
        await #expect(throws: LocalFirstActualStore.BankSyncStoreError.staleGeneration) {
            try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        }
        #expect(try snapshot(bundle) == before)
    }

    @Test func completedReviewThenUnlinkIsAlreadyRejected() async throws {
        let bundle = try await fixture(Provider(response: response(rows: true)))
        let plan = try await bundle.store.downloadBankSyncPlan(accountID: "savings", budgetID: "group-1")
        try await bundle.store.unlinkBankAccount("savings", budgetID: "group-1")
        let before = try snapshot(bundle)
        await #expect(throws: LocalFirstActualStore.BankSyncStoreError.staleGeneration) {
            try await bundle.store.applyBankSyncPlan(plan, budgetID: "group-1")
        }
        #expect(try snapshot(bundle) == before)
    }

    @Test func directBridgeWarningMustSurviveNormalization() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InvestigationWarningProtocol.self]
        let client = SimpleFINBridgeClient(baseURL: URL(string: "https://bridge.example/user")!,
            username: "synthetic", password: "synthetic", session: URLSession(configuration: configuration))
        let result = try await client.transactions(accountIDs: ["old-link"], startDates: ["2026-01-01"])
        let download = try #require(result.downloads["old-link"])
        #expect(download.errorCode == "ACCOUNT_NEEDS_ATTENTION")
    }
}

private final class InvestigationWarningProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = #"{"errors":["Connection to Synthetic Bank may need attention"],"errlist":[{"code":"ACCOUNT_NEEDS_ATTENTION","msg":"Needs attention","account_id":"old-link"}],"accounts":[{"id":"old-link","currency":"USD","org":{"name":"Synthetic Bank"},"transactions":[] }]}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
