import Testing
@testable import Actualist

@Suite("Transaction schedule conversion presentation")
struct TransactionScheduleConversionPresentationTests {
    @Test func entryPointIsAvailableOnlyForStrictlyFutureRootTransactions() {
        let lookup = TransactionRowLookup(
            payeeNames: ["market": "Fresh Market"],
            categoryNames: ["groceries": "Groceries"]
        )

        let future = entry(
            for: transaction(id: "future", date: "2026-09-30", payee: "market"),
            lookup: lookup
        )
        #expect(future?.transactionID == "future")
        #expect(future?.names.account == "Everyday Checking")
        #expect(future?.names.payee == "Fresh Market")
        #expect(future?.names.category == "Groceries")
        #expect(entry(for: transaction(id: "today", date: "2026-09-29"), lookup: lookup) == nil)
        #expect(entry(for: transaction(id: "past", date: "2026-09-28"), lookup: lookup) == nil)
        #expect(entry(for: transaction(id: nil, date: "2026-09-30"), lookup: lookup) == nil)
        #expect(entry(for: transaction(id: "invalid", date: "not-a-date"), lookup: lookup) == nil)
        #expect(entry(for: transaction(id: "child", date: "2026-09-30", isChild: true), lookup: lookup) == nil)
    }

    @Test func entryPointExcludesReconciledAndTransferFamilies() {
        let transferLookup = TransactionRowLookup(transferPayeeIDs: ["transfer"])
        #expect(entry(
            for: transaction(id: "transfer", date: "2026-09-30", payee: "transfer"),
            lookup: transferLookup
        ) == nil)
        #expect(entry(
            for: transaction(id: "reconciled", date: "2026-09-30", reconciled: true),
            lookup: .init()
        ) == nil)

        let reconciledChild = transaction(
            id: "child", date: "2026-09-30", reconciled: true, isChild: true
        )
        let parent = transaction(
            id: "parent", date: "2026-09-30", subtransactions: [reconciledChild], isParent: true
        )
        #expect(entry(for: parent, lookup: .init()) == nil)
    }

    @Test func entryPointRequiresScheduleAuthoringSupport() {
        let lookup = TransactionRowLookup()
        let future = transaction(id: "future", date: "2026-09-30")

        // A budget whose schema cannot accept schedules offers no entry.
        #expect(entry(for: future, lookup: lookup, supportsAuthoring: false) == nil)
        #expect(entry(for: future, lookup: lookup, supportsAuthoring: true)?.transactionID == "future")
    }

    private func entry(
        for transaction: ActualTransaction,
        lookup: TransactionRowLookup,
        supportsAuthoring: Bool = true
    ) -> TransactionScheduleConversionEntryPoint? {
        TransactionScheduleConversionEntryPoint.project(
            transaction: transaction,
            lookup: lookup,
            asOfDayID: "2026-09-29",
            accountName: "Everyday Checking",
            supportsAuthoring: supportsAuthoring
        )
    }

    private func transaction(
        id: String?,
        date: String,
        payee: String? = nil,
        reconciled: Bool = false,
        subtransactions: [ActualTransaction] = [],
        isParent: Bool = false,
        isChild: Bool = false
    ) -> ActualTransaction {
        ActualTransaction(
            id: id,
            account: "checking",
            date: date,
            amount: -100,
            payee: payee,
            payeeName: nil,
            importedPayee: nil,
            category: "groceries",
            notes: nil,
            cleared: nil,
            reconciled: reconciled,
            subtransactions: subtransactions,
            isParent: isParent,
            isChild: isChild
        )
    }
}
