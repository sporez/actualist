import AppIntents
import Foundation
import Testing
@testable import Actualist

@MainActor
struct ShortcutCatalogCoverageTests {
    private let fixtures = LocalFirstActualStoreTests()

    private func makeSession(
        extraSQL: String = "",
        defaultAccountID: String? = nil
    ) async throws -> (session: ShortcutsBudgetSession, appState: AppState, bundle: LocalFirstActualStoreTests.OpenedWritableStoreBundle) {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle(additionalFixtureSQL: extraSQL)
        let appState = try fixtures.makeAppState(for: bundle)
        if let defaultAccountID {
            appState.settings.defaultAccountIDByBudgetID["group-1"] = defaultAccountID
        }
        return (ShortcutsBudgetSession(appState: appState), appState, bundle)
    }

    @Test func sessionReadsCoverLookupsCachesAndMissingEntities() async throws {
        let (session, appState, _) = try await makeSession(
            extraSQL: "INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent) VALUES ('uncat', 'checking', 20260704, -500, NULL, 0, NULL, 0);"
        )

        #expect(try await session.category(id: "groceries", month: "2026-07").id == "groceries")
        await #expect(throws: ShortcutsError.categoryNotFound) {
            _ = try await session.category(id: "missing")
        }
        #expect(try await session.payee(id: "coffee").name == "Coffee Shop")
        await #expect(throws: ShortcutsError.payeeNotFound) {
            _ = try await session.payee(id: "missing")
        }
        await #expect(throws: ShortcutsError.accountNotFound) {
            _ = try await session.account(id: "closed", includeClosed: false)
        }
        #expect(try await session.transferPayee(forAccountID: "savings").isTransfer)
        await #expect(throws: ShortcutsError.transferDestinationMissing) {
            _ = try await session.transferPayee(forAccountID: "missing")
        }

        _ = try await session.uncategorizedCount()
        #expect(try await session.uncategorizedCount() == 1)
        _ = try await session.reportsDashboard()
        _ = try await session.reportsDashboard()
        _ = try await session.transactions(search: "   ")
        _ = try await session.transactions(accountID: "checking", search: "coffee")
        _ = try await session.transactions(search: "coffee")
        _ = try await session.transactions()

        let current = ReportCalendar.monthID(for: Date(), calendar: ReportCalendar.gregorianLocal)
        _ = ShortcutsBudgetSession.reportRange(for: current)
        _ = ShortcutsBudgetSession.reportRange(for: "2020-01")
        _ = ShortcutsBudgetSession.reportRange(for: "not-a-month")

        try session.enqueueRoute(.tab(.accounts))
        #expect(appState.selectedTab == .accounts)
        try session.enqueueRoute(.account(id: "checking"))
        #expect(appState.selectedTab == .accounts)
        try session.enqueueRoute(.category(id: "groceries", month: "2026-07"))
        #expect(appState.selectedTab == .budget)
        try session.enqueueRoute(.uncategorized(month: "2026-07"))
        try session.enqueueRoute(.newTransaction(ShortcutEditorPrefill(payeeName: "Cafe")))
        #expect(appState.routeCoordinator.pendingRoute != nil)

        #expect(ShortcutEntityMatching.name("Checking", matches: "  "))
        #expect(!ShortcutEntityMatching.name("Checking", matches: "zzz"))
        let namedMonths = try await session.months(matching: ReportCalendar.shortMonthTitle("2026-07"))
        #expect(namedMonths.contains { $0.id == "2026-07" })
        #expect(try await session.months(matching: "zzzz").isEmpty)

        let otherMonth = try await session.loadedMonth(preferred: "2026-06")
        #expect(otherMonth.selectedMonth == "2026-06")
    }

    @Test func reconstructsBudgetFromSelectedAndListedBudgets() async throws {
        let (session, appState, bundle) = try await makeSession()
        appState.selectedBudget = bundle.budget
        bundle.store.reset()
        #expect(try await session.prepare().budgetID == "group-1")

        let (listedSession, listedState, listedBundle) = try await makeSession()
        listedState.budgets = [listedBundle.budget]
        listedBundle.store.reset()
        #expect(try await listedSession.prepare().budgetID == "group-1")
    }

    @Test func missingLocalFileIDFailsWithoutGuessingABudget() async throws {
        let defaults = try #require(UserDefaults(suiteName: "ActualistTests.\(UUID().uuidString)"))
        let settingsStore = AppSettingsStore(defaults: defaults)
        settingsStore.save(AppSettings(selectedBudgetID: "group-missing"))
        let appState = AppState(settingsStore: settingsStore)
        let session = ShortcutsBudgetSession(appState: appState)
        await #expect(throws: ShortcutsError.noBudgetSelected) {
            try await session.prepare()
        }
    }

    @Test func fetchTransactionReturnsParentChildrenAndMisses() async throws {
        let (session, _, bundle) = try await makeSession(
            extraSQL: """
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent)
                VALUES ('split-parent', 'checking', 20260710, -5000, NULL, 0, NULL, 1);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent)
                VALUES ('split-a', 'checking', 20260710, -2000, 'groceries', 0, 'split-parent', 0);
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent)
                VALUES ('split-b', 'checking', 20260710, -3000, 'utilities', 0, 'split-parent', 0);
            """
        )
        let parent = try #require(try await bundle.store.fetchTransaction(budgetID: "group-1", id: "split-parent"))
        #expect(parent.isParent)
        #expect(parent.subtransactions.count == 2)
        let child = try #require(try await bundle.store.fetchTransaction(budgetID: "group-1", id: "split-a"))
        #expect(child.isChild)
        #expect(child.parentID == "split-parent")
        #expect(try await bundle.store.fetchTransaction(budgetID: "group-1", id: "missing") == nil)
        #expect(try await bundle.store.fetchTransaction(budgetID: "group-1", id: "   ") == nil)
        await #expect(throws: ShortcutsError.transactionNotFound) {
            _ = try await session.actualTransaction(id: " ")
        }
    }

    @Test func entitiesExposeDisplayPropertiesAndQueries() async throws {
        let (session, _, _) = try await makeSession()
        let accounts = try await session.accounts(includeClosed: false)
        #expect(!accounts.isEmpty)
        #expect(String(describing: accounts[0].displayRepresentation.title).isEmpty == false)

        let categories = try await session.categories(includeHidden: false)
        #expect(!categories.isEmpty)
        #expect(String(describing: categories[0].displayRepresentation.title).isEmpty == false)

        let payees = try await session.payees(includeTransfers: false)
        #expect(payees.map(\.id) == ["coffee"])
        #expect(String(describing: payees[0].displayRepresentation.title).isEmpty == false)

        let months = try await session.months()
        #expect(!months.isEmpty)
        #expect(String(describing: months[0].displayRepresentation.title).isEmpty == false)

        let summary = try await session.budgetSummary()
        #expect(String(describing: summary.displayRepresentation.title).isEmpty == false)

        let alerts = try await session.budgetAlerts()
        for alert in alerts {
            _ = alert.displayRepresentation
        }

        let recent = try await session.transactions()
        #expect(TransactionEntity.make(from: ActualTransaction(
            id: nil,
            account: "checking",
            date: "2026-07-03",
            amount: -100,
            payee: nil,
            payeeName: nil,
            importedPayee: nil,
            category: nil,
            notes: nil,
            cleared: nil
        ), maps: TransactionNameMaps(
            accountNames: [:],
            categoryNames: [:],
            payeeNames: [:],
            transferPayeeIDs: []
        )) == nil)
        if let first = recent.first {
            _ = first.displayRepresentation
        }
        let mapped = TransactionEntity.make(
            from: ActualTransaction(
                id: "mapped",
                account: "checking",
                date: "2026-07-03",
                amount: -100,
                payee: "coffee",
                payeeName: nil,
                importedPayee: nil,
                category: "groceries",
                notes: nil,
                cleared: nil
            ),
            maps: TransactionNameMaps(
                accountNames: ["checking": "Checking"],
                categoryNames: ["groceries": "Groceries"],
                payeeNames: ["coffee": "Coffee Shop"],
                transferPayeeIDs: ["xfer"]
            )
        )
        #expect(mapped?.payee == "Coffee Shop")
        #expect(mapped?.isTransfer == false)
        let undated = TransactionEntity(
            id: "undated",
            amount: nil,
            date: nil,
            payee: "Unknown payee",
            account: "checking",
            category: nil,
            notes: nil,
            cleared: false,
            isTransfer: false
        )
        #expect(String(describing: undated.displayRepresentation.title).contains("Unknown date"))
    }

    @Test func transactionCommandCoversTransfersImportAndRejectedUpdates() async throws {
        let (session, _, _) = try await makeSession(defaultAccountID: "checking")

        await #expect(throws: ShortcutsError.amountInvalid) {
            _ = try await ShortcutTransactionCommand.log(
                .init(amountMinorUnits: 0, direction: .spend, accountID: "checking", payeeName: "Zero"),
                session: session
            )
        }
        let offBudget = try await ShortcutTransactionCommand.log(
            .init(
                amountMinorUnits: 300,
                direction: .spend,
                accountID: "tracking",
                payeeName: "Broker",
                categoryID: "groceries"
            ),
            session: session
        )
        #expect(offBudget.category == nil)

        await #expect(throws: ShortcutsError.transferDestinationMissing) {
            _ = try await ShortcutTransactionCommand.transfer(
                fromAccountID: "checking",
                toAccountID: "checking",
                amountMinorUnits: 100,
                date: nil,
                notes: nil,
                session: session
            )
        }

        let importedTransfer = try await ShortcutTransactionCommand.importFromText(
            "transfer 25 from Checking to Savings",
            session: session
        )
        #expect(importedTransfer.isTransfer)
        let importedCategory = try await ShortcutTransactionCommand.importFromText(
            "12.50 coffee Groceries Checking",
            session: session
        )
        #expect(importedCategory.category == "Groceries")
        await #expect(throws: ShortcutsError.accountNotFound) {
            _ = try await ShortcutTransactionCommand.importFromText(
                "transfer 10 from Missing to Savings",
                session: session
            )
        }
        await #expect(throws: ShortcutsError.categoryNotFound) {
            _ = try await ShortcutTransactionCommand.importFromText(
                "5.00 snack NotACategory Checking",
                session: session
            )
        }

        #expect(throws: ShortcutsError.accountNotFound) {
            _ = try ShortcutTransactionCommand.uniqueMatch(
                in: [AccountEntity(id: "a", name: "A", balance: nil, offBudget: false, closed: false)],
                named: \.name,
                query: "   ",
                notFound: .accountNotFound
            )
        }
        #expect(throws: ShortcutsError.accountNotFound) {
            _ = try ShortcutTransactionCommand.uniqueMatch(
                in: [AccountEntity(id: "a", name: "A", balance: nil, offBudget: false, closed: false)],
                named: \.name,
                query: "zzz",
                notFound: .accountNotFound
            )
        }
        #expect(throws: ShortcutsError.ambiguousMatch) {
            _ = try ShortcutTransactionCommand.uniqueMatch(
                in: [
                    AccountEntity(id: "a", name: "Checking", balance: nil, offBudget: false, closed: false),
                    AccountEntity(id: "b", name: "checking", balance: nil, offBudget: false, closed: false)
                ],
                named: \.name,
                query: "Checking",
                notFound: .accountNotFound
            )
        }
        #expect(ShortcutTransactionCommand.resolvedPayeeName(id: "x", name: nil) == "Payee")
        #expect(ShortcutTransactionCommand.resolvedPayeeName(id: nil, name: nil) == "Unknown")
        #expect(ShortcutTransactionCommand.trimmed("  ") == nil)

        let created = try await ShortcutTransactionCommand.log(
            .init(amountMinorUnits: 400, direction: .spend, accountID: "checking", payeeName: "Shop"),
            session: session
        )
        let inflow = try await ShortcutTransactionCommand.update(
            .init(transactionID: created.id, amountMinorUnits: 600, direction: .inflow),
            session: session
        )
        #expect(inflow.amount?.amount == Decimal(6))
        await #expect(throws: ShortcutsError.amountInvalid) {
            _ = try await ShortcutTransactionCommand.update(
                .init(transactionID: created.id, amountMinorUnits: 0),
                session: session
            )
        }
        await #expect(throws: ShortcutsError.transactionNotFound) {
            _ = try await ShortcutTransactionCommand.update(
                .init(transactionID: "missing", notes: "x"),
                session: session
            )
        }

        let (closedSession, _, _) = try await makeSession(
            extraSQL: "INSERT INTO accounts VALUES ('closed', 'Old Card', 0, 1, 0, 9);"
        )
        let closedTarget = try await ShortcutTransactionCommand.log(
            .init(amountMinorUnits: 200, direction: .spend, accountID: "checking", payeeName: "Move"),
            session: closedSession
        )
        await #expect(throws: ShortcutsError.accountClosed) {
            _ = try await ShortcutTransactionCommand.update(
                .init(transactionID: closedTarget.id, accountID: "closed"),
                session: closedSession
            )
        }
    }

    @Test func transferUpdatesRefuseStructuralChanges() async throws {
        let (session, _, _) = try await makeSession()
        let transfer = try await ShortcutTransactionCommand.transfer(
            fromAccountID: "checking",
            toAccountID: "savings",
            amountMinorUnits: 1_000,
            date: Date(),
            notes: "move",
            session: session
        )
        await #expect(throws: ShortcutsError.unsupportedTransfer) {
            _ = try await ShortcutTransactionCommand.update(
                .init(transactionID: transfer.id, payeeName: "Not A Transfer"),
                session: session
            )
        }
        await #expect(throws: ShortcutsError.unsupportedTransfer) {
            _ = try await ShortcutTransactionCommand.update(
                .init(transactionID: transfer.id, categoryID: "groceries"),
                session: session
            )
        }
        await #expect(throws: ShortcutsError.unsupportedTransfer) {
            _ = try await ShortcutTransactionCommand.update(
                .init(transactionID: transfer.id, payeeID: "coffee"),
                session: session
            )
        }
        let noted = try await ShortcutTransactionCommand.update(
            .init(transactionID: transfer.id, notes: "still a transfer"),
            session: session
        )
        #expect(noted.isTransfer)
        #expect(noted.notes == "still a transfer")
    }

    @Test func splitParentWithoutTwoChildrenFailsInsteadOfRewriting() async throws {
        let (session, _, _) = try await makeSession(
            extraSQL: """
            INSERT INTO transactions (id, acct, date, amount, category, tombstone, parent_id, is_parent)
                VALUES ('broken-parent', 'checking', 20260711, -1000, NULL, 0, NULL, 1);
            """
        )
        await #expect(throws: ShortcutsError.unsupportedSplit) {
            _ = try await ShortcutTransactionCommand.update(
                .init(transactionID: "broken-parent", notes: "nope"),
                session: session
            )
        }
        await #expect(throws: ShortcutsError.unsupportedSplit) {
            _ = try await ShortcutTransactionCommand.update(
                .init(transactionID: "broken-parent", direction: .inflow),
                session: session
            )
        }
        await #expect(throws: ShortcutsError.unsupportedSplit) {
            _ = try await ShortcutTransactionCommand.categorize(
                transactionID: "broken-parent",
                categoryID: "groceries",
                session: session
            )
        }
    }

    @Test func budgetCommandsCoverRemainingModesAndZeroMove() async throws {
        let (session, _, _) = try await makeSession()
        await #expect(throws: ShortcutsError.amountInvalid) {
            _ = try await ShortcutBudgetCommand.move(
                fromCategoryID: "groceries",
                toCategoryID: nil,
                amountMinorUnits: 0,
                month: "2026-07",
                session: session
            )
        }
        let summary = try await ShortcutBudgetCommand.applyTemplate(
            mode: .overwrite,
            categoryID: "groceries",
            month: "2026-07",
            session: session
        )
        #expect(summary.month == "2026-07")
        await #expect(throws: ShortcutsError.templateUnsupported) {
            _ = try await ShortcutBudgetCommand.applyTemplate(
                mode: .overwrite,
                categoryID: nil,
                month: "2026-07",
                session: session
            )
        }
        let carryoverOff = try await ShortcutBudgetCommand.setCarryover(
            categoryID: "utilities",
            enabled: false,
            startMonth: "2026-07",
            session: session
        )
        #expect(!carryoverOff.carryover)

        let before = try await session.category(id: "groceries", month: "2026-07")
        let beforeBudgeted = try ShortcutMoney.minorUnits(from: before.budgeted!)
        async let first = ShortcutBudgetCommand.add(
            categoryID: "groceries",
            amountMinorUnits: 1_000,
            month: "2026-07",
            session: session
        )
        async let second = ShortcutBudgetCommand.add(
            categoryID: "groceries",
            amountMinorUnits: 1_000,
            month: "2026-07",
            session: session
        )
        _ = try await (first, second)
        let after = try await session.category(id: "groceries", month: "2026-07")
        #expect(try ShortcutMoney.minorUnits(from: after.budgeted!) == beforeBudgeted + 2_000)
    }

    @Test func clearedCachesReloadInsteadOfServingStaleEmptyState() async throws {
        let (session, _, bundle) = try await makeSession()
        _ = try await session.prepare()
        bundle.store.loadedBudgetMonthsByBudget.removeAll()
        bundle.store.monthsByBudget.removeAll()
        let reloaded = try await session.loadedMonth()
        #expect(!reloaded.selectedMonth.isEmpty)
        bundle.store.loadedBudgetMonthsByBudget.removeAll()
        let preferred = try await session.loadedMonth(preferred: "2026-07")
        #expect(preferred.selectedMonth == "2026-07")

        bundle.store.accountsByBudget.removeAll()
        #expect(!(try await session.accounts(includeClosed: false)).isEmpty)
        bundle.store.payeesByBudget.removeAll()
        #expect(!(try await session.payees(includeTransfers: false)).isEmpty)
        bundle.store.uncategorizedTransactionsByKey.removeAll()
        _ = try await session.uncategorizedCount(month: "2026-07")

        bundle.store.accountsByBudget["group-1"] = [
            AccountDisplay(
                account: ActualAccount(id: "closed-only", name: "Closed", offbudget: false, closed: true),
                balance: 0
            )
        ]
        var noneIntent = GetAccountsIntent()
        noneIntent.session = session
        noneIntent.includeClosed = false
        _ = try await noneIntent.perform()

        bundle.store.accountsByBudget["group-1"] = [
            AccountDisplay(
                account: ActualAccount(id: "solo", name: "Solo", offbudget: false, closed: false),
                balance: 100
            )
        ]
        var oneIntent = GetAccountsIntent()
        oneIntent.session = session
        oneIntent.includeClosed = false
        _ = try await oneIntent.perform()

        bundle.store.accountsByBudget["group-1"] = [
            AccountDisplay(
                account: ActualAccount(id: "ghost", name: "Ghost", offbudget: false, closed: false),
                balance: nil
            )
        ]
        var balance = GetAccountBalanceIntent()
        balance.session = session
        balance.account = AccountEntity(
            id: "ghost",
            name: "Ghost",
            balance: nil,
            offBudget: false,
            closed: false
        )
        _ = try await balance.perform()

        var openNew = OpenNewTransactionIntent()
        openNew.session = session
        openNew.direction = .spend
        _ = try await openNew.perform()
    }

    @Test func applyShortcutPrefillAcceptsCategoryNameOnly() {
        let model = TransactionEditorViewModel()
        model.applyShortcutPrefill(
            ShortcutEditorPrefill(
                payeeName: "   ",
                categoryName: "Dining",
                direction: .inflow
            )
        )
        #expect(model.kind == .inflow)
        #expect(model.payeeName.isEmpty)
        #expect(model.selectedCategoryID == nil)
        #expect(model.selectedCategoryName.contains("Dining"))
    }
}
