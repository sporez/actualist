import Foundation
import Testing
@testable import Actualist

extension LocalFirstActualStoreTests {
    @Test func localCommitPersistsPendingMarkerAtomically() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let database = try #require(bundle.store.database)
        var builder = LocalFirstSyncMessageBuilder()
        let messages = try await database.makeBankSyncCompletionMessages(
            accountID: "checking",
            lastSyncEpochMilliseconds: nil,
            status: .failed,
            balanceDisposition: .preserve,
            builder: &builder
        )

        _ = try await database.commitLocalSyncMessagesAndEnqueue(
            messages,
            pendingNewTransactions: .init(
                transactionIDsByAccount: ["checking": ["new-1"]],
                source: .bankSync,
                notificationID: "opaque-1"
            )
        )

        #expect(try await database.pendingNewTransactionIDsByAccount() == ["checking": ["new-1"]])
        #expect(try await database.pendingNewTransactionDelivery()?.notificationID == "opaque-1")
    }

    @Test func failedLocalCommitRollsBackPendingMarker() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let database = try #require(bundle.store.database)
        let invalid = ActualSyncDecodedMessage(
            timestamp: "actualist-pending-test",
            dataset: "missing_dataset",
            row: "new-1",
            column: "amount",
            serializedValue: "N:1"
        )

        await #expect(throws: LocalFirstError.self) {
            try await database.commitLocalSyncMessagesAndEnqueue(
                [invalid],
                pendingNewTransactions: .init(
                    transactionIDsByAccount: ["checking": ["new-1"]],
                    source: .bankSync,
                    notificationID: "opaque-1"
                )
            )
        }
        #expect(try await database.pendingNewTransactionIDsByAccount().isEmpty)
    }

    @Test func pendingMarkersSurviveDatabaseReopen() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let url = try bundle.fileManager.databaseURL(fileID: "file-1")
        let database = try #require(bundle.store.database)
        try await database.recordPendingNewTransactions(.init(
            transactionIDsByAccount: ["checking": ["new-1"]],
            source: .remoteSync,
            notificationID: "opaque-1"
        ))
        bundle.store.closeOpenBudget()

        let reopened = try BudgetDatabase(databaseURL: url, localNodeID: "reopened")
        #expect(try await reopened.pendingNewTransactionIDsByAccount() == ["checking": ["new-1"]])
        #expect(try await reopened.pendingNewTransactionDelivery()?.notificationID == "opaque-1")
    }

    @Test func reviewPersistsAndSuppressesDeliveryWithoutResurrection() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let database = try #require(bundle.store.database)
        let commit = BudgetDatabase.PendingNewTransactionCommit(
            transactionIDsByAccount: ["checking": ["new-1"]],
            source: .bankSync,
            notificationID: "opaque-1"
        )
        try await database.recordPendingNewTransactions(commit)
        #expect(try await database.migrateLegacyAndReviewPendingNewTransactions(
            [:], transactionIDs: ["new-1"], accountID: "checking"
        ) == 1)
        try await database.recordPendingNewTransactions(commit)

        #expect(try await database.pendingNewTransactionIDsByAccount().isEmpty)
        #expect(try await database.pendingNewTransactionDelivery() == nil)
    }

    @Test func notificationAcknowledgementDoesNotReviewMarker() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let database = try #require(bundle.store.database)
        try await database.recordPendingNewTransactions(.init(
            transactionIDsByAccount: ["checking": ["new-1"]],
            source: .bankSync,
            notificationID: "opaque-1"
        ))
        let delivery = try #require(try await database.pendingNewTransactionDelivery())
        try await database.acknowledgePendingNewTransactionDelivery(delivery.transactionIDs)

        #expect(try await database.pendingNewTransactionDelivery() == nil)
        #expect(try await database.pendingNewTransactionIDsByAccount() == ["checking": ["new-1"]])
    }

    @Test func legacyProjectionMigratesAcknowledgedAndReconcilesExactly() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let projection = try await bundle.store.reconcilePendingNewTransactionProjection(
            budgetID: "group-1",
            legacyStorage: [
                "group-1|checking": ["legacy-1"],
                "other|checking": ["other-1"]
            ]
        )

        #expect(projection["group-1|checking"] == ["legacy-1"])
        #expect(projection["other|checking"] == ["other-1"])
        #expect(try await bundle.store.pendingNewTransactionDelivery(budgetID: "group-1") == nil)

        _ = try await bundle.store.reviewPendingNewTransactions(
            budgetID: "group-1",
            accountID: "checking",
            transactionIDs: ["legacy-1"],
            projection: projection
        )
        let reconciled = try await bundle.store.reconcilePendingNewTransactionProjection(
            budgetID: "group-1",
            legacyStorage: projection
        )
        #expect(reconciled["group-1|checking"] == nil)
        #expect(reconciled["other|checking"] == ["other-1"])
    }

    @Test func reviewBeforePreparationMigratesAndReviewsLegacyMarkerAtomically() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let legacy = ["group-1|checking": ["legacy-1"]]

        let reviewed = try await bundle.store.reviewPendingNewTransactions(
            budgetID: "group-1",
            accountID: "checking",
            transactionIDs: ["legacy-1"],
            projection: legacy
        )
        let reconciled = try await bundle.store.reconcilePendingNewTransactionProjection(
            budgetID: "group-1",
            legacyStorage: legacy
        )

        #expect(reviewed.clearedCount == 1)
        #expect(reviewed.projection["group-1|checking"] == nil)
        #expect(reconciled["group-1|checking"] == nil)
    }

    @Test func reviewMarksOnlyCapturedIDsAndPreservesNewArrival() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let database = try #require(bundle.store.database)
        try await database.recordPendingNewTransactions(.init(
            transactionIDsByAccount: ["checking": ["visible-before-disappear"]],
            source: .bankSync,
            notificationID: "opaque-1"
        ))
        let capturedIDs = Set(["visible-before-disappear"])
        try await database.recordPendingNewTransactions(.init(
            transactionIDsByAccount: ["checking": ["arrived-after-disappear"]],
            source: .bankSync,
            notificationID: "opaque-2"
        ))

        let reviewed = try await bundle.store.reviewPendingNewTransactions(
            budgetID: "group-1",
            accountID: "checking",
            transactionIDs: capturedIDs,
            projection: ["group-1|checking": Array(capturedIDs)]
        )

        #expect(reviewed.clearedCount == 1)
        #expect(reviewed.projection["group-1|checking"] == ["arrived-after-disappear"])
        #expect(try await database.pendingNewTransactionDelivery()?.transactionIDs == ["arrived-after-disappear"])
    }

    @Test func staleBudgetIdentityRefusesProjection() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        await #expect(throws: LocalFirstError.budgetNotOpened) {
            try await bundle.store.reconcilePendingNewTransactionProjection(
                budgetID: "other-budget",
                legacyStorage: ["other-budget|checking": ["wrong"]]
            )
        }
    }

    @Test func preparationDoesNotRestoreSettingsAfterSessionIdentityChanges() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let database = try #require(bundle.store.database)
        try await database.recordPendingNewTransactions(.init(
            transactionIDsByAccount: ["checking": ["new-1"]],
            source: .bankSync,
            notificationID: "opaque-1"
        ))
        let delay = ManualTestDelay()
        let state = try makeAppState(
            for: bundle,
            notificationAuthorizationRequester: {
                try await delay.sleep(for: .seconds(1))
                return true
            }
        )
        state.settings.backgroundTransactionRefreshEnabled = true
        let preparation = Task { await state.prepareBackgroundTransactionNotifications() }
        _ = try await delay.waitUntilSleeping()
        state.settings.selectedBudgetID = "replacement-budget"
        state.settings.localFirstServerURLString = "https://replacement.example"
        state.settings.backgroundTransactionRefreshEnabled = false
        delay.resume()
        await preparation.value

        #expect(state.settings.selectedBudgetID == "replacement-budget")
        #expect(state.settings.localFirstServerURLString == "https://replacement.example")
        #expect(!state.settings.backgroundTransactionRefreshEnabled)
        #expect(state.settings.pendingNewTransactionIDsByAccount.isEmpty)
    }

    @Test func preparationMergesMarkersAcrossUnrelatedSettingsAndLogChanges() async throws {
        let bundle = try await makeOpenedWritableStoreBundle()
        let database = try #require(bundle.store.database)
        try await database.recordPendingNewTransactions(.init(
            transactionIDsByAccount: ["checking": ["new-1"]],
            source: .bankSync,
            notificationID: "opaque-1"
        ))
        let delay = ManualTestDelay()
        let state = try makeAppState(
            for: bundle,
            notificationAuthorizationRequester: {
                try await delay.sleep(for: .seconds(1))
                return true
            }
        )
        state.settings.backgroundTransactionRefreshEnabled = true
        let preparation = Task { await state.prepareBackgroundTransactionNotifications() }
        _ = try await delay.waitUntilSleeping()
        state.settings.theme = .actualPurpleLight
        state.settings.localFirstSyncDebug.totalEventCount = 7
        delay.resume()
        await preparation.value

        #expect(state.settings.theme == .actualPurpleLight)
        #expect(state.settings.localFirstSyncDebug.totalEventCount == 7)
        #expect(state.settings.pendingNewTransactionIDsByAccount["group-1|checking"] == ["new-1"])
    }
}
