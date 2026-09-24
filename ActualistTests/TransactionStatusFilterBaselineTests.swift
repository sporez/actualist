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
        let uncleared = try await database.fetchTransactionPage(statusFilter: .uncleared)
        let cleared = try await database.fetchTransactionPage(statusFilter: .cleared)

        #expect(transaction.cleared?.boolValue == false)
        #expect(!transaction.reconciled)
        #expect(semantics.status == .uncleared)
        #expect(uncleared.transactions.map(\.id) == ["legacy-no-status"])
        #expect(cleared.transactions.isEmpty)
    }

    @Test func filteredPagesApplyExclusiveStatusesBeforePagination() async throws {
        let database = try TransactionStatusFilterTestSupport.database()

        let all = try await database.fetchTransactionPage(accountID: "checking")
        let uncleared = try await database.fetchTransactionPage(
            accountID: "checking", statusFilter: .uncleared
        )
        let cleared = try await database.fetchTransactionPage(
            accountID: "checking", statusFilter: .cleared
        )
        let reconciled = try await database.fetchTransactionPage(
            accountID: "checking", statusFilter: .reconciled
        )

        #expect(all.transactions.contains { $0.id == "status-reconciled" })
        #expect(uncleared.transactions.compactMap(\.id).filter { $0.hasPrefix("status-") } == [
            "status-neither", "status-null",
        ])
        #expect(cleared.transactions.compactMap(\.id).filter { $0.hasPrefix("status-") } == [
            "status-cleared",
        ])
        #expect(reconciled.transactions.compactMap(\.id).filter { $0.hasPrefix("status-") } == [
            "status-reconciled", "status-reconciled-uncleared",
        ])
        #expect(!cleared.transactions.contains { $0.id == "status-reconciled" })
        #expect(uncleared.transactions.first?.id != "other-account-row")

        let flatChildSearch = try await database.fetchTransactionPage(
            accountID: "checking", matching: "mixed uncategorized search needle", statusFilter: .uncleared
        )
        #expect(flatChildSearch.transactions.map(\.id) == ["mixed-uncategorized-child"])
        #expect(flatChildSearch.transactions.first?.subtransactions.isEmpty == true)
    }

    @Test func uncategorizedStatusSelectionUsesEligibleSplitChildrenAndExistingExclusions() async throws {
        let database = try TransactionStatusFilterTestSupport.database()

        let grouped = try await database.fetchTransactionPage(
            accountID: "checking", statusFilter: .uncategorized
        )
        let spending = try await database.fetchTransactionPage(statusFilter: .uncategorized)
        let search = try await database.fetchTransactionPage(
            accountID: "checking", matching: "mixed uncategorized search needle", statusFilter: .uncategorized
        )

        #expect(grouped.transactions.compactMap(\.id) == [
            "mapped-empty-target", "mixed-parent",
            "ordinary-uncategorized", "offbudget-destination-transfer",
        ])
        #expect(spending.transactions.contains { $0.id == "unknown-source-account" })
        #expect(grouped.transactions.first { $0.id == "mixed-parent" }?.subtransactions.map(\.id) == [
            "mixed-uncategorized-child", "mixed-categorized-child",
        ])
        #expect(search.transactions.map(\.id) == ["mixed-uncategorized-child"])
        #expect(!grouped.transactions.contains { $0.id == "mapped-null-target" || $0.id == "unknown-source-account" })
        #expect(!grouped.transactions.contains { $0.id == "offbudget-source" || $0.id == "onbudget-transfer" })
        #expect(!grouped.transactions.contains { $0.id == "mixed-tombstoned-child" || $0.id == "dead-parent" })
        #expect(!grouped.transactions.contains {
            $0.id == "categorized-only-parent" || $0.id == "dead-only-parent"
        })
    }

    @Test func groupedStatusFiltersSelectRootStatusBeforeLimitAndUnlimitedAssembly() async throws {
        let database = try TransactionStatusFilterTestSupport.database()

        let unclearedPage = try await database.fetchTransactionPage(
            accountID: "checking", limit: 1, statusFilter: .uncleared
        )
        let unclearedRemainder = try await database.fetchTransactionPage(
            accountID: "checking", limit: 500, offset: unclearedPage.nextOffset, statusFilter: .uncleared
        )
        let unclearedAll = try await database.fetchTransactionPage(
            accountID: "checking", statusFilter: .uncleared
        )
        let clearedPage = try await database.fetchTransactionPage(
            accountID: "checking", limit: 1, statusFilter: .cleared
        )
        let clearedRemainder = try await database.fetchTransactionPage(
            accountID: "checking", limit: 500, offset: clearedPage.nextOffset, statusFilter: .cleared
        )
        let clearedAll = try await database.fetchTransactionPage(
            accountID: "checking", statusFilter: .cleared
        )

        #expect(unclearedRemainder.reachedEnd)
        #expect(clearedRemainder.reachedEnd)
        #expect((unclearedPage.transactions + unclearedRemainder.transactions).map(\.id) == unclearedAll.transactions.map(\.id))
        #expect((clearedPage.transactions + clearedRemainder.transactions).map(\.id) == clearedAll.transactions.map(\.id))
        #expect(!unclearedAll.transactions.contains { $0.id == "mixed-parent" })
        let clearedParent = try #require(clearedAll.transactions.first { $0.id == "mixed-parent" })
        #expect(clearedParent.subtransactions.map(\.id) == [
            "mixed-uncategorized-child", "mixed-categorized-child",
        ])
        #expect(clearedAll.nextOffset == clearedAll.transactions.count)
        #expect(unclearedAll.nextOffset == unclearedAll.transactions.count)

        let groupedChildSearch = try await database.fetchTransactionPage(
            accountID: "checking",
            matching: "mixed uncategorized search needle",
            splits: .grouped,
            statusFilter: .uncleared
        )
        #expect(groupedChildSearch.transactions.map(\.id) == ["mixed-parent"])
    }

    @Test func searchFilterPagesAndOffsetsCountOnlyMatchingRowsNotAttachedContext() async throws {
        let database = try TransactionStatusFilterTestSupport.database()

        let first = try await database.fetchTransactionPage(
            accountID: "checking", matching: "status-search-needle", limit: 50,
            statusFilter: .uncleared
        )
        let second = try await database.fetchTransactionPage(
            accountID: "checking", matching: "status-search-needle", limit: 50,
            offset: first.nextOffset, statusFilter: .uncleared
        )
        let parentMatch = try await database.fetchTransactionPage(
            accountID: "checking", matching: "split parent", limit: 1, statusFilter: .cleared
        )

        #expect(first.transactions.map(\.id) == (0..<50).map { String(format: "search-match-%03d", $0) })
        #expect(first.nextOffset == 50)
        #expect(!first.reachedEnd)
        #expect(second.transactions.map(\.id) == (50..<53).map { String(format: "search-match-%03d", $0) })
        #expect(second.nextOffset == 53)
        #expect(second.reachedEnd)
        #expect(parentMatch.transactions.map(\.id) == ["mixed-parent"])
        #expect(parentMatch.transactions.first?.subtransactions.count == 2)
        #expect(parentMatch.nextOffset == 1)
    }
}
