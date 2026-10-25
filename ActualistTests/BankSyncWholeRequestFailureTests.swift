import Foundation
import Testing
@testable import Actualist

/// A whole-request `/simplefin/transactions` failure is one cause for the
/// run, classified from the server's code. The server's `reason` text is
/// untrusted and never decoded, stored or shown.
struct BankSyncWholeRequestFailureTests {
    @Test func codesClassifyIntoPlainCauses() {
        #expect(BankSyncWholeRequestFailure.classify(errorCode: nil) == nil)
        #expect(BankSyncWholeRequestFailure.classify(errorCode: "SERVER_DOWN") == .serverDown)
        #expect(BankSyncWholeRequestFailure.classify(errorCode: "server_down") == .serverDown)
        for code in ["INVALID_ACCESS_TOKEN", "UNAUTHORIZED", "INVALID_CREDENTIALS"] {
            #expect(BankSyncWholeRequestFailure.classify(errorCode: code) == .accessRejected)
        }
        #expect(BankSyncWholeRequestFailure.classify(errorCode: "TIMED_OUT") == .timedOut)
        #expect(BankSyncWholeRequestFailure.classify(errorCode: "RATE_LIMIT_EXCEEDED") == .rateLimited)
        #expect(BankSyncWholeRequestFailure.classify(errorCode: "SOMETHING_NEW") == .other)
    }

    @Test func everyCauseHasItsOwnPlainSummary() {
        #expect(BankSyncWholeRequestFailure.serverDown.summary
            == "Bank Sync could not run. Your Actual server could not reach SimpleFIN. Try again later.")
        #expect(BankSyncWholeRequestFailure.accessRejected.summary
            == "Bank Sync could not run. SimpleFIN no longer accepts the saved access. Set up SimpleFIN again, then relink your accounts.")
        #expect(BankSyncWholeRequestFailure.timedOut.summary
            == "Bank Sync could not run. SimpleFIN took too long to answer. Try again later.")
        #expect(BankSyncWholeRequestFailure.rateLimited.summary
            == "Bank Sync could not run. SimpleFIN is limiting requests. Try again later.")
        #expect(BankSyncWholeRequestFailure.other.summary
            == "Bank Sync failed on your Actual server. Try again later.")
        #expect(Set(BankSyncWholeRequestFailure.allCases.map(\.summary)).count
            == BankSyncWholeRequestFailure.allCases.count)
    }

    @Test func transportClassifiesWholeRequestErrorAndDropsServerReason() throws {
        let body = """
        {"status": "ok", "data": {"error_type": "SERVER_DOWN", "error_code": "SERVER_DOWN",
         "reason": "synthetic-reason-qq7 from 10.0.0.9"}}
        """
        let response = try ActualServerSimpleFINClient.decodeTransactionsResponse(from: Data(body.utf8))
        #expect(response.wholeRequestFailure == .serverDown)
        #expect(!String(describing: response).contains("synthetic-reason-qq7"))

        let flat = try ActualServerSimpleFINClient.decodeTransactionsResponse(
            from: Data(#"{"error_type": "SimplefinError", "error_code": "INVALID_ACCESS_TOKEN"}"#.utf8)
        )
        #expect(flat.wholeRequestFailure == .accessRejected)

        let perAccountOnly = try ActualServerSimpleFINClient.decodeTransactionsResponse(
            from: Data(#"{"errors": {"acct_1": [{"error_type": "SimplefinError", "error_code": "TIMED_OUT"}]}}"#.utf8)
        )
        #expect(perAccountOnly.wholeRequestFailure == nil)
    }

    @Test func accountStatusTextIsNeutralOnlyForAGenericFailureDuringAWholeRequestFailure() {
        #expect(BankSyncCopy.statusText(durableStatus: "failed") == "Failed")
        #expect(BankSyncCopy.statusText(durableStatus: "failed", lastRunFailure: .serverDown) == "Not synced")
        #expect(BankSyncCopy.statusText(durableStatus: "reauth-required", lastRunFailure: .accessRejected)
            == "Reconnect required")
        #expect(BankSyncCopy.statusText(durableStatus: "ok", lastRunFailure: .serverDown) == nil)
    }
}

extension LocalFirstActualStoreTests {
    private func wholeRequestTransport(code: String) -> StubSimpleFINTransport {
        StubSimpleFINTransport(
            remoteAccounts: [remoteAccount()],
            response: SimpleFINTransactionsResponse(downloads: [:], errorType: code, errorCode: code)
        )
    }

    private func linkedStore(_ transport: StubSimpleFINTransport) async throws -> OpenedWritableStoreBundle {
        let bundle = try await makeBankSyncStore(transport: transport)
        try await bundle.store.linkBankAccount("savings", to: remoteAccount(), budgetID: "group-1")
        return bundle
    }

    @Test func planningReportsOneWholeRequestFailureAndKeepsDurableStatus() async throws {
        let bundle = try await linkedStore(wholeRequestTransport(code: "SERVER_DOWN"))
        let plans = try await bundle.store.downloadBankSyncPlans(accountIDs: ["savings"], budgetID: "group-1")
        let plan = try #require(plans.first)
        #expect(plan.wholeRequestFailure == .serverDown)
        // The synced vocabulary is unchanged: the same status as before.
        #expect(plan.durableStatus == .failed)

        let token = try await linkedStore(wholeRequestTransport(code: "INVALID_ACCESS_TOKEN"))
        let tokenPlan = try #require(
            try await token.store.downloadBankSyncPlans(accountIDs: ["savings"], budgetID: "group-1").first
        )
        #expect(tokenPlan.wholeRequestFailure == .accessRejected)
        #expect(tokenPlan.durableStatus == .reauthRequired)
    }

    @Test func perAccountErrorIsNotAWholeRequestFailure() async throws {
        let transport = StubSimpleFINTransport(
            remoteAccounts: [remoteAccount()],
            response: SimpleFINTransactionsResponse(
                downloads: ["sfin-1": SimpleFINAccountDownload(
                    transactions: [], startingBalance: nil, errorType: "TIMED_OUT", errorCode: "TIMED_OUT"
                )],
                errorType: nil,
                errorCode: nil
            )
        )
        let bundle = try await linkedStore(transport)
        let plan = try #require(
            try await bundle.store.downloadBankSyncPlans(accountIDs: ["savings"], budgetID: "group-1").first
        )
        #expect(plan.wholeRequestFailure == nil)
        #expect(plan.durableStatus == .timedOut)
    }

    @MainActor
    @Test func syncAllSaysOnceWhyTheRunCouldNotRun() async throws {
        for (code, failure, rowText) in [
            ("SERVER_DOWN", BankSyncWholeRequestFailure.serverDown, "Not synced"),
            ("INVALID_ACCESS_TOKEN", .accessRejected, "Reconnect required"),
            ("BRAND_NEW_CODE", .other, "Not synced")
        ] {
            let bundle = try await linkedStore(wholeRequestTransport(code: code))
            let model = BankSyncViewModel(store: bundle.store, budgetID: "group-1", currency: .usd)
            await model.load()
            await model.syncAll()

            #expect(model.resultLines.isEmpty)
            #expect(model.lastRun?.summary == failure.summary)
            #expect(model.lastRun?.failure == failure)
            #expect(model.phase == .ready)
            #expect(model.accountLines.first { $0.id == "savings" }?.statusText == rowText)

            // The cause survives a later visit to the screen.
            let reopened = BankSyncViewModel(store: bundle.store, budgetID: "group-1", currency: .usd)
            await reopened.load()
            #expect(reopened.lastRun?.failure == failure)
            #expect(reopened.accountLines.first { $0.id == "savings" }?.statusText == rowText)
        }
    }

    @MainActor
    @Test func perAccountFailureKeepsItsOwnResultLine() async throws {
        let transport = StubSimpleFINTransport(
            remoteAccounts: [remoteAccount()],
            response: SimpleFINTransactionsResponse(
                downloads: ["sfin-1": SimpleFINAccountDownload(
                    transactions: [], startingBalance: nil, errorType: "TIMED_OUT", errorCode: "TIMED_OUT"
                )],
                errorType: nil,
                errorCode: nil
            )
        )
        let bundle = try await linkedStore(transport)
        let model = BankSyncViewModel(store: bundle.store, budgetID: "group-1", currency: .usd)
        await model.load()
        await model.syncAll()
        #expect(model.lastRun?.failure == nil)
        #expect(model.resultLines.first?.statusText == "Skipped · Timed out")
    }

    @Test func backgroundRunRecordsTheSameCause() async throws {
        let bundle = try await linkedStore(wholeRequestTransport(code: "SERVER_DOWN"))
        let result = try await bundle.store.backgroundBankSyncApply(budgetID: "group-1")
        #expect(result.insertedTransactionIDsByAccount.values.allSatisfy { $0.isEmpty })
        let run = try #require(try await bundle.store.bankSyncLastRun(budgetID: "group-1"))
        #expect(run.trigger == .background)
        #expect(run.failure == .serverDown)
        #expect(run.summary == BankSyncWholeRequestFailure.serverDown.summary)
    }

    @Test func diagnosticSnapshotHoldsStatusTimeAndCauseWithoutNamesOrIDs() async throws {
        let bundle = try await linkedStore(wholeRequestTransport(code: "SERVER_DOWN"))
        _ = try await bundle.store.backgroundBankSyncApply(budgetID: "group-1")
        let snapshot = try #require(await bundle.store.bankSyncDiagnosticSnapshot())
        #expect(snapshot.accounts.count == 1)
        #expect(snapshot.accounts.first?.status == "failed")
        #expect(snapshot.lastRun?.failure == .serverDown)
        let text = String(describing: snapshot)
        for forbidden in ["savings", "Savings", "sfin-1", "Chase", "chase.example"] {
            #expect(!text.contains(forbidden))
        }
    }
}
