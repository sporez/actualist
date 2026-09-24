import Testing
@testable import Actualist

struct TransactionStatusFilterBaselineTests {
    @Test func currentReadsProjectExclusiveStatusesAndNullAsUncleared() async throws {
        let database = try TransactionStatusFilterTestSupport.database()

        let accountRows = try await database.fetchTransactions(accountID: "checking")
        let statusRows = accountRows.filter { $0.id?.hasPrefix("status-") == true }
        let semantics = Dictionary(uniqueKeysWithValues: statusRows.compactMap { transaction in
            transaction.id.map {
                ($0, TransactionRowSemantics.project(transaction, lookup: TransactionRowLookup()).status)
            }
        })

        #expect(Set(statusRows.compactMap(\.id)) == [
            "status-neither", "status-cleared", "status-reconciled",
            "status-reconciled-uncleared", "status-null",
        ])
        #expect(semantics["status-neither"] == .uncleared)
        #expect(semantics["status-cleared"] == .cleared)
        #expect(semantics["status-reconciled"] == .reconciled)
        #expect(semantics["status-reconciled-uncleared"] == .reconciled)
        #expect(semantics["status-null"] == .uncleared)

        let spendingRows = try await database.fetchTransactions()
        #expect(spendingRows.contains { $0.id == "other-account-row" })
        #expect(!accountRows.contains { $0.id == "other-account-row" })
    }

    @Test func existingUncategorizedReadPreservesMappedSplitTransferAndTombstoneSemantics() async throws {
        let database = try TransactionStatusFilterTestSupport.database()

        let grouped = try await database.fetchTransactions(accountID: "checking")
        let mixedParent = try #require(grouped.first { $0.id == "mixed-parent" })
        #expect(mixedParent.subtransactions.map(\.id) == [
            "mixed-uncategorized-child", "mixed-categorized-child",
        ])
        #expect(mixedParent.cleared?.boolValue == true)
        #expect(!mixedParent.reconciled)
        #expect(mixedParent.subtransactions[0].cleared?.boolValue == false)
        #expect(mixedParent.subtransactions[0].reconciled == false)
        #expect(mixedParent.subtransactions[1].cleared?.boolValue == true)
        #expect(mixedParent.subtransactions[1].reconciled)

        let reviewRows = try await database.fetchUncategorizedTransactions()
        #expect(reviewRows.compactMap(\.id) == [
            "mapped-empty-target",
            "unknown-source-account",
            "mixed-uncategorized-child",
            "ordinary-uncategorized",
            "offbudget-destination-transfer",
        ])
        #expect(!reviewRows.contains { $0.id == "mapped-null-target" })
        #expect(!reviewRows.contains { $0.id == "offbudget-source" })
        #expect(!reviewRows.contains { $0.id == "onbudget-transfer" })
        #expect(!reviewRows.contains { $0.id == "mixed-parent" || $0.id == "mixed-categorized-child" })
        #expect(!reviewRows.contains { $0.id == "mixed-tombstoned-child" })
        #expect(!reviewRows.contains { $0.id == "dead-parent" || $0.id == "orphan-of-dead-parent" })
        #expect(!reviewRows.contains { $0.id == "uncategorized-tombstone" })
    }

    @Test func existingSearchPagesInterleavedMatchesBeforeApplyingOffsets() async throws {
        let database = try TransactionStatusFilterTestSupport.database()

        let first = try await database.fetchTransactionPage(
            accountID: "checking",
            matching: "status-search-needle",
            limit: 50
        )
        let second = try await database.fetchTransactionPage(
            accountID: "checking",
            matching: "status-search-needle",
            limit: 50,
            offset: 50
        )
        let allAccounts = try await database.fetchTransactionPage(
            matching: "status-search-needle",
            limit: 60
        )

        #expect(first.transactions.compactMap(\.id) == (0..<50).map { String(format: "search-match-%03d", $0) })
        #expect(!first.reachedEnd)
        #expect(second.transactions.compactMap(\.id) == (50..<53).map { String(format: "search-match-%03d", $0) })
        #expect(second.reachedEnd)
        #expect(allAccounts.transactions.map(\.id) == (0..<53).map { String(format: "search-match-%03d", $0) })
        #expect(allAccounts.reachedEnd)
        #expect((first.transactions + second.transactions).count == 53)
    }

    @Test func missingStatusColumnsReadAsUncleared() async throws {
        let database = try TransactionStatusFilterTestSupport.legacyDatabaseWithoutStatusColumns()

        let rows = try await database.fetchTransactions(accountID: "checking")
        let transaction = try #require(rows.first { $0.id == "legacy-no-status" })
        let semantics = TransactionRowSemantics.project(transaction, lookup: TransactionRowLookup())

        #expect(transaction.cleared?.boolValue == false)
        #expect(!transaction.reconciled)
        #expect(semantics.status == .uncleared)
    }
}
