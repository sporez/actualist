import AppIntents
import Foundation
import Testing
@testable import Actualist

@MainActor
// AppIntent's @Dependency wrapper uses the shared AppDependencyManager. Keep
// every direct `perform()` test in this serialized suite so test sessions
// cannot cross between independently opened fixture budgets.
@Suite(.serialized)
struct ShortcutIntentTests {
    private let fixtures = LocalFirstActualStoreTests()

    private func makeSession() async throws -> ShortcutsBudgetSession {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        return ShortcutsBudgetSession(appState: appState)
    }

    private func account(_ id: String = "checking") -> AccountEntity {
        AccountEntity(id: id, name: id, balance: nil, offBudget: id == "tracking", closed: false)
    }

    private func category(_ id: String = "groceries") -> CategoryEntity {
        CategoryEntity(
            id: id,
            name: id,
            group: "Everyday",
            available: nil,
            budgeted: nil,
            spent: nil,
            carryover: false,
            isIncome: false,
            isHidden: false
        )
    }

    private func month(_ id: String = "2026-07") -> BudgetMonthEntity {
        BudgetMonthEntity.make(monthID: id)
    }

    private func amount(_ value: String) -> IntentCurrencyAmount {
        IntentCurrencyAmount(amount: Decimal(string: value)!, currencyCode: ShortcutMoney.currencyCode)
    }

    @Test func providerDonatesTheStaticPhraseSet() {
        #expect(ActualistShortcutsProvider.appShortcuts.count == 6)
    }

    @Test func extractedIntentMetadataUsesShortcutCategories() throws {
        let url = try #require(
            Bundle.main.url(
                forResource: "extract",
                withExtension: "actionsdata",
                subdirectory: "Metadata.appintents"
            )
        )
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let actions = try #require(payload?["actions"] as? [String: Any])
        let expected: [String: String] = [
            "GetAccountsIntent": "Accounts",
            "GetAccountIntent": "Accounts",
            "GetAccountBalanceIntent": "Accounts",
            "GetAccountTransactionsIntent": "Accounts",
            "CreateAccountIntent": "Accounts",
            "OpenAccountsIntent": "Accounts",
            "OpenAccountIntent": "Accounts",
            "GetCategoriesIntent": "Budget",
            "GetCategoryIntent": "Budget",
            "GetCategoryBalanceIntent": "Budget",
            "GetReadyToAssignIntent": "Budget",
            "GetBudgetSummaryIntent": "Budget",
            "GetOverspentCategoriesIntent": "Budget",
            "GetUncategorizedTransactionsIntent": "Budget",
            "GetUncategorizedCountIntent": "Budget",
            "GetBudgetAlertsIntent": "Budget",
            "AssignCategoryBudgetIntent": "Budget",
            "AddToCategoryBudgetIntent": "Budget",
            "MoveMoneyIntent": "Budget",
            "ApplyBudgetTemplateIntent": "Budget",
            "SetCategoryCarryoverIntent": "Budget",
            "OpenBudgetIntent": "Budget",
            "OpenCategoryIntent": "Budget",
            "OpenUncategorizedIntent": "Budget",
            "GetPayeesIntent": "Transactions",
            "CreatePayeeIntent": "Transactions",
            "GetTransactionsIntent": "Transactions",
            "GetTransactionIntent": "Transactions",
            "LogTransactionIntent": "Transactions",
            "LogTransferIntent": "Transactions",
            "UpdateTransactionIntent": "Transactions",
            "CategorizeTransactionIntent": "Transactions",
            "SetTransactionClearedIntent": "Transactions",
            "DeleteTransactionIntent": "Transactions",
            "ImportTransactionFromTextIntent": "Transactions",
            "OpenNewTransactionIntent": "Transactions",
            "OpenSpendingIntent": "Transactions",
            "GetNetWorthIntent": "Reports",
            "GetCashFlowIntent": "Reports",
            "GetBudgetOverviewIntent": "Reports",
            "OpenReportsIntent": "Reports"
        ]

        #expect(Set(actions.keys) == Set(expected.keys))
        for (identifier, category) in expected {
            let action = try #require(actions[identifier] as? [String: Any])
            let metadata = try #require(action["descriptionMetadata"] as? [String: Any])
            let categoryName = try #require(metadata["categoryName"] as? [String: Any])
            let title = try #require(categoryName["title"] as? [String: Any])
            #expect(title["key"] as? String == category)
        }
    }

    @Test func openIntentsUseDynamicForegroundMode() {
        let expected = IntentModes.foreground(.dynamic)
        #expect(OpenBudgetIntent.supportedModes == expected)
        #expect(OpenAccountsIntent.supportedModes == expected)
        #expect(OpenSpendingIntent.supportedModes == expected)
        #expect(OpenReportsIntent.supportedModes == expected)
        #expect(OpenAccountIntent.supportedModes == expected)
        #expect(OpenCategoryIntent.supportedModes == expected)
        #expect(OpenUncategorizedIntent.supportedModes == expected)
        #expect(OpenNewTransactionIntent.supportedModes == expected)
    }

    @Test func intentEnumsMapToDomainCommands() {
        #expect(ShortcutTransactionDirectionAppEnum.spend.commandDirection == .spend)
        #expect(ShortcutTransactionDirectionAppEnum.inflow.commandDirection == .inflow)
        #expect(ShortcutTemplateMode.fillEmpty.storeMode == .fillEmpty)
        #expect(ShortcutTemplateMode.overwrite.storeMode == .overwrite)
    }

    @Test func readIntentsReturnValuesForTheSelectedBudget() async throws {
        let session = try await makeSession()

        let accounts = GetAccountsIntent()
        accounts.session = session
        accounts.includeClosed = false
        _ = try await accounts.perform()

        let accountIntent = GetAccountIntent()
        accountIntent.session = session
        accountIntent.account = account()
        _ = try await accountIntent.perform()

        let balance = GetAccountBalanceIntent()
        balance.session = session
        balance.account = account()
        _ = try await balance.perform()

        let accountTxns = GetAccountTransactionsIntent()
        accountTxns.session = session
        accountTxns.account = account()
        accountTxns.limit = 10
        _ = try await accountTxns.perform()

        let categories = GetCategoriesIntent()
        categories.session = session
        categories.includeHidden = false
        categories.month = month()
        _ = try await categories.perform()

        let getCategory = GetCategoryIntent()
        getCategory.session = session
        getCategory.category = category()
        getCategory.month = month()
        _ = try await getCategory.perform()

        for metric in [CategoryBalanceMetric.available, .budgeted, .spent] {
            let metricIntent = GetCategoryBalanceIntent()
            metricIntent.session = session
            metricIntent.category = category()
            metricIntent.metric = metric
            metricIntent.month = month()
            _ = try await metricIntent.perform()
        }

        let payees = GetPayeesIntent()
        payees.session = session
        payees.includeTransfers = true
        _ = try await payees.perform()

        let ready = GetReadyToAssignIntent()
        ready.session = session
        ready.month = month()
        _ = try await ready.perform()

        let summary = GetBudgetSummaryIntent()
        summary.session = session
        summary.month = month()
        _ = try await summary.perform()

        let overspent = GetOverspentCategoriesIntent()
        overspent.session = session
        overspent.month = month()
        _ = try await overspent.perform()

        let uncategorized = GetUncategorizedTransactionsIntent()
        uncategorized.session = session
        uncategorized.month = month()
        uncategorized.limit = 10
        _ = try await uncategorized.perform()

        let count = GetUncategorizedCountIntent()
        count.session = session
        count.month = month()
        _ = try await count.perform()

        let alerts = GetBudgetAlertsIntent()
        alerts.session = session
        alerts.month = month()
        _ = try await alerts.perform()

        let transactions = GetTransactionsIntent()
        transactions.session = session
        transactions.account = account()
        transactions.search = "coffee"
        transactions.limit = 10
        _ = try await transactions.perform()

        let netWorth = GetNetWorthIntent()
        netWorth.session = session
        netWorth.month = month()
        _ = try await netWorth.perform()

        let cashFlow = GetCashFlowIntent()
        cashFlow.session = session
        cashFlow.month = month()
        _ = try await cashFlow.perform()

        let overview = GetBudgetOverviewIntent()
        overview.session = session
        overview.month = month()
        _ = try await overview.perform()

        let accountQuery = AccountEntityQuery()
        accountQuery.session = session
        #expect(!(try await accountQuery.suggestedEntities()).isEmpty)
        #expect(!(try await accountQuery.entities(for: ["checking"])).isEmpty)
        #expect(try await accountQuery.entities(matching: "check").map(\.id) == ["checking"])

        let categoryQuery = CategoryEntityQuery()
        categoryQuery.session = session
        #expect(!(try await categoryQuery.suggestedEntities()).isEmpty)
        #expect(!(try await categoryQuery.entities(for: ["groceries"])).isEmpty)
        #expect(try await categoryQuery.entities(matching: "groc").map(\.id) == ["groceries"])

        let payeeQuery = PayeeEntityQuery()
        payeeQuery.session = session
        #expect(try await payeeQuery.suggestedEntities().map(\.id) == ["coffee"])
        #expect(!(try await payeeQuery.entities(for: ["coffee"])).isEmpty)
        #expect(try await payeeQuery.entities(matching: "coffee").map(\.id) == ["coffee"])

        let monthQuery = BudgetMonthEntityQuery()
        monthQuery.session = session
        #expect(!(try await monthQuery.suggestedEntities()).isEmpty)
        #expect(!(try await monthQuery.entities(for: ["2026-07"])).isEmpty)
        #expect(try await monthQuery.entities(matching: "2026-07").map(\.id) == ["2026-07"])
        #expect(await monthQuery.defaultResult()?.id != nil)

        let summaryQuery = BudgetSummaryEntityQuery()
        summaryQuery.session = session
        #expect(try await summaryQuery.suggestedEntities().count == 1)
        #expect(!(try await summaryQuery.entities(for: ["2026-07"])).isEmpty)
        #expect(await summaryQuery.defaultResult()?.month != nil)

        let alertQuery = BudgetAlertEntityQuery()
        alertQuery.session = session
        let suggestedAlerts = try await alertQuery.suggestedEntities()
        _ = try await alertQuery.entities(for: suggestedAlerts.map(\.id))
        _ = try await alertQuery.entities(for: [])

        let transactionQuery = TransactionEntityQuery()
        transactionQuery.session = session
        let recent = try await transactionQuery.suggestedEntities()
        #expect(!recent.isEmpty)
        #expect(!(try await transactionQuery.entities(for: recent.prefix(1).map(\.id))).isEmpty)
        #expect(!(try await transactionQuery.entities(matching: "123")).isEmpty)
    }

    @Test func writeAndOpenIntentsExercisePerformPaths() async throws {
        let session = try await makeSession()
        let logged = try await ShortcutTransactionCommand.log(
            .init(amountMinorUnits: 250, direction: .spend, accountID: "checking", payeeName: "Intent Shop"),
            session: session
        )
        let transaction = TransactionEntity(
            id: logged.id,
            amount: logged.amount,
            date: logged.date,
            payee: logged.payee,
            account: logged.account,
            category: logged.category,
            notes: logged.notes,
            cleared: logged.cleared,
            isTransfer: logged.isTransfer
        )

        let log = LogTransactionIntent()
        log.session = session
        log.amount = amount("3.50")
        log.account = account()
        log.direction = .spend
        log.payeeName = "Intent Cafe"
        log.category = category()
        log.notes = "note"
        log.cleared = false
        _ = try await log.perform()

        let transfer = LogTransferIntent()
        transfer.session = session
        transfer.fromAccount = account("checking")
        transfer.toAccount = account("savings")
        transfer.amount = amount("4.00")
        _ = try await transfer.perform()

        let update = UpdateTransactionIntent()
        update.session = session
        update.transaction = transaction
        update.notes = "updated from intent"
        _ = try await update.perform()

        let categorize = CategorizeTransactionIntent()
        categorize.session = session
        categorize.transaction = transaction
        categorize.category = category("utilities")
        _ = try await categorize.perform()

        let cleared = SetTransactionClearedIntent()
        cleared.session = session
        cleared.transaction = transaction
        cleared.cleared = true
        _ = try await cleared.perform()

        let getOne = GetTransactionIntent()
        getOne.session = session
        getOne.transaction = transaction
        _ = try await getOne.perform()

        let delete = DeleteTransactionIntent()
        delete.session = session
        delete.transaction = transaction
        _ = try await delete.perform()

        let importText = ImportTransactionFromTextIntent()
        importText.session = session
        importText.text = "1.25 coffee Groceries Checking"
        _ = try await importText.perform()

        let assign = AssignCategoryBudgetIntent()
        assign.session = session
        assign.category = category()
        assign.amount = amount("20.00")
        assign.month = month()
        _ = try await assign.perform()

        let add = AddToCategoryBudgetIntent()
        add.session = session
        add.category = category()
        add.amount = amount("5.00")
        add.month = month()
        _ = try await add.perform()

        let move = MoveMoneyIntent()
        move.session = session
        move.fromCategory = category()
        move.amount = amount("1.00")
        move.month = month()
        _ = try await move.perform()

        let template = ApplyBudgetTemplateIntent()
        template.session = session
        template.mode = .fillEmpty
        template.category = category()
        template.month = month()
        _ = try await template.perform()

        let carryover = SetCategoryCarryoverIntent()
        carryover.session = session
        carryover.category = category("utilities")
        carryover.enabled = true
        carryover.startMonth = month()
        _ = try await carryover.perform()

        let createPayee = CreatePayeeIntent()
        createPayee.session = session
        createPayee.name = "Intent Payee"
        _ = try await createPayee.perform()

        let createAccount = CreateAccountIntent()
        createAccount.session = session
        createAccount.name = "Intent Cash"
        createAccount.offBudget = true
        _ = try await createAccount.perform()

        let openBudget = OpenBudgetIntent()
        openBudget.session = session
        _ = try await openBudget.perform()
        let openAccounts = OpenAccountsIntent()
        openAccounts.session = session
        _ = try await openAccounts.perform()
        let openSpending = OpenSpendingIntent()
        openSpending.session = session
        _ = try await openSpending.perform()
        let openReports = OpenReportsIntent()
        openReports.session = session
        _ = try await openReports.perform()

        let openAccount = OpenAccountIntent()
        openAccount.session = session
        openAccount.account = account()
        _ = try await openAccount.perform()

        let openCategory = OpenCategoryIntent()
        openCategory.session = session
        openCategory.category = category()
        openCategory.month = month()
        _ = try await openCategory.perform()

        let openUncategorized = OpenUncategorizedIntent()
        openUncategorized.session = session
        openUncategorized.month = month()
        _ = try await openUncategorized.perform()

        let openNew = OpenNewTransactionIntent()
        openNew.session = session
        openNew.account = account()
        openNew.amount = amount("9.99")
        openNew.payeeName = "Prefill"
        openNew.category = category()
        openNew.notes = "from shortcut"
        openNew.direction = .inflow
        _ = try await openNew.perform()
    }

    @Test func intentResponseEdgeCasesUseTheOwningTestSession() async throws {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        let session = ShortcutsBudgetSession(appState: appState)

        bundle.store.accountsByBudget["group-1"] = [
            AccountDisplay(
                account: ActualAccount(id: "closed-only", name: "Closed", offbudget: false, closed: true),
                balance: 0
            )
        ]
        let noneIntent = GetAccountsIntent()
        noneIntent.session = session
        noneIntent.includeClosed = false
        _ = try await noneIntent.perform()

        bundle.store.accountsByBudget["group-1"] = [
            AccountDisplay(
                account: ActualAccount(id: "solo", name: "Solo", offbudget: false, closed: false),
                balance: 100
            )
        ]
        let oneIntent = GetAccountsIntent()
        oneIntent.session = session
        oneIntent.includeClosed = false
        _ = try await oneIntent.perform()

        bundle.store.accountsByBudget["group-1"] = [
            AccountDisplay(
                account: ActualAccount(id: "ghost", name: "Ghost", offbudget: false, closed: false),
                balance: nil
            )
        ]
        let balance = GetAccountBalanceIntent()
        balance.session = session
        balance.account = AccountEntity(
            id: "ghost",
            name: "Ghost",
            balance: nil,
            offBudget: false,
            closed: false
        )
        _ = try await balance.perform()

        let openNew = OpenNewTransactionIntent()
        openNew.session = session
        openNew.direction = .spend
        _ = try await openNew.perform()
    }

    @Test func disabledShortcutsRefuseIntentPerform() async throws {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        appState.updateShortcutsEnabled(false)
        let session = ShortcutsBudgetSession(appState: appState)

        let accounts = GetAccountsIntent()
        accounts.session = session
        await #expect(throws: ShortcutsError.shortcutsDisabled) {
            _ = try await accounts.perform()
        }
        let open = OpenBudgetIntent()
        open.session = session
        await #expect(throws: ShortcutsError.shortcutsDisabled) {
            _ = try await open.perform()
        }
    }
}
