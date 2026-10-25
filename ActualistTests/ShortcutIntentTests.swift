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
        try await makeSessionAndAppState().session
    }

    private func makeSessionAndAppState() async throws -> (session: ShortcutsBudgetSession, appState: AppState) {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        return (ShortcutsBudgetSession(appState: appState), appState)
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

    /// Siri sends "transaction" to Wallet and Apple Cash, so the logging
    /// phrase must avoid payment words.
    @Test func extractedLoggingPhraseAvoidsWalletWords() throws {
        let url = try #require(
            Bundle.main.url(
                forResource: "extract",
                withExtension: "actionsdata",
                subdirectory: "Metadata.appintents"
            )
        )
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let shortcuts = try #require(payload?["autoShortcuts"] as? [[String: Any]])
        let log = try #require(shortcuts.first { $0["actionIdentifier"] as? String == "LogTransactionIntent" })
        let phrases = try #require(log["phraseTemplates"] as? [[String: Any]]).compactMap { $0["key"] as? String }
        #expect(phrases == ["Log an expense in ${applicationName}"])
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

        // The schema search intent has no shortcut category; its own test pins it.
        #expect(Set(actions.keys).subtracting(["SearchSpendingIntent"]) == Set(expected.keys))
        for (identifier, category) in expected {
            let action = try #require(actions[identifier] as? [String: Any])
            let metadata = try #require(action["descriptionMetadata"] as? [String: Any])
            let categoryName = try #require(metadata["categoryName"] as? [String: Any])
            let title = try #require(categoryName["title"] as? [String: Any])
            #expect(title["key"] as? String == category)
        }
    }

    /// The system enforces the policy from the build-time metadata, not the
    /// static property, so pin the extracted values: only the tab opens and the
    /// add-only actions skip the system unlock (the app gates the latter on
    /// Allow Logging While Locked).
    @Test func extractedIntentMetadataPinsWhichActionsRunWhileLocked() throws {
        let url = try #require(
            Bundle.main.url(
                forResource: "extract",
                withExtension: "actionsdata",
                subdirectory: "Metadata.appintents"
            )
        )
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let actions = try #require(payload?["actions"] as? [String: Any])
        // App Intents encodes `.alwaysAllowed` as 0 and `.requiresAuthentication` as 1.
        let alwaysAllowed: Set<String> = [
            "OpenBudgetIntent",
            "OpenAccountsIntent",
            "OpenSpendingIntent",
            "OpenReportsIntent",
            "LogTransactionIntent",
            "LogTransferIntent",
            "ImportTransactionFromTextIntent"
        ]
        #expect(alwaysAllowed.isSubset(of: Set(actions.keys)))
        for (identifier, value) in actions where identifier != "SearchSpendingIntent" {
            let action = try #require(value as? [String: Any])
            let policy = action["authenticationPolicy"] as? Int
            #expect(policy == (alwaysAllowed.contains(identifier) ? 0 : 1), "\(identifier)")
        }
        // A shown dialog stalls a locked automation, so the add-only actions
        // must not provide one (`outputFlags` bit 4 is ProvidesDialog).
        for identifier in ["LogTransactionIntent", "LogTransferIntent", "ImportTransactionFromTextIntent"] {
            let action = try #require(actions[identifier] as? [String: Any])
            let flags = try #require(action["outputFlags"] as? Int)
            #expect(flags & 4 == 0, "\(identifier)")
        }
    }

    /// Siri AI finds the search intent only through its registered schema. A
    /// schema intent needs at least local-device authentication (2) and the
    /// app foregrounded before it routes.
    @Test func extractedMetadataRegistersTheSearchInAppSchema() throws {
        let url = try #require(
            Bundle.main.url(
                forResource: "extract",
                withExtension: "actionsdata",
                subdirectory: "Metadata.appintents"
            )
        )
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let actions = try #require(payload?["actions"] as? [String: Any])
        let action = try #require(actions["SearchSpendingIntent"] as? [String: Any])
        let schemas = try #require(action["assistantDefinedSchemas"] as? [[String: Any]])
        #expect(schemas.contains { $0["domain"] as? String == "system" && $0["name"] as? String == "SystemSearchInAppIntent" })
        #expect(action["authenticationPolicy"] as? Int == 2)
        #expect(action["openAppWhenRun"] as? Bool == true)
    }

    @Test func openIntentsOpenTheAppBeforeRunning() {
        let expected = IntentModes.foreground(.immediate)
        #expect(OpenBudgetIntent.supportedModes == expected)
        #expect(OpenAccountsIntent.supportedModes == expected)
        #expect(OpenSpendingIntent.supportedModes == expected)
        #expect(OpenReportsIntent.supportedModes == expected)
        #expect(OpenAccountIntent.supportedModes == expected)
        #expect(OpenCategoryIntent.supportedModes == expected)
        #expect(OpenUncategorizedIntent.supportedModes == expected)
        #expect(OpenNewTransactionIntent.supportedModes == expected)
    }

    @Test func searchSpendingIntentOpensSpendingWithTheTrimmedQuery() async throws {
        guard #available(iOS 27.0, *) else { return }
        let (session, appState) = try await makeSessionAndAppState()
        #expect(SearchSpendingIntent.searchScopes == [.general])
        #expect(SearchSpendingIntent.supportedModes == .foreground(.immediate))

        var intent = SearchSpendingIntent()
        intent.criteria = StringSearchCriteria(term: "  Costco ")
        intent.session = session
        _ = try await intent.perform()
        #expect(appState.routeCoordinator.pendingRoute == .spendingSearch(query: "Costco"))
        #expect(appState.selectedTab == .spending)

        intent.criteria = StringSearchCriteria(term: " ")
        _ = try await intent.perform()
        #expect(appState.routeCoordinator.pendingRoute == .tab(.spending))
    }

    @Test func addOnlyIntentsRunInBackgroundAndCanContinueInForeground() {
        let expected: IntentModes = [.background, .foreground(.dynamic)]
        #expect(LogTransactionIntent.supportedModes == expected)
        #expect(LogTransferIntent.supportedModes == expected)
        #expect(ImportTransactionFromTextIntent.supportedModes == expected)
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
        let (session, appState) = try await makeSessionAndAppState()
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
        let loggedByIntent = try await log.perform().value
        #expect(loggedByIntent?.payee == "Intent Cafe")
        #expect(loggedByIntent?.notes == "note")
        #expect(loggedByIntent?.cleared == false)
        #expect(loggedByIntent?.isTransfer == false)
        #expect(loggedByIntent?.amount.map { abs($0.amount) } == Decimal(string: "3.5"))

        let transfer = LogTransferIntent()
        transfer.session = session
        transfer.fromAccount = account("checking")
        transfer.toAccount = account("savings")
        transfer.amount = amount("4.00")
        let transferred = try await transfer.perform().value
        #expect(transferred?.isTransfer == true)
        #expect(transferred?.amount.map { abs($0.amount) } == 4)

        let update = UpdateTransactionIntent()
        update.session = session
        update.transaction = transaction
        update.notes = "updated from intent"
        let updated = try await update.perform().value
        #expect(updated?.id == logged.id)
        #expect(updated?.notes == "updated from intent")

        let categorize = CategorizeTransactionIntent()
        categorize.session = session
        categorize.transaction = transaction
        categorize.category = category("utilities")
        let categorized = try await categorize.perform().value
        #expect(categorized?.id == logged.id)
        #expect(categorized?.category != nil)
        #expect(categorized?.category != logged.category)

        let cleared = SetTransactionClearedIntent()
        cleared.session = session
        cleared.transaction = transaction
        cleared.cleared = true
        let clearedResult = try await cleared.perform().value
        #expect(clearedResult?.id == logged.id)
        #expect(clearedResult?.cleared == true)

        let getOne = GetTransactionIntent()
        getOne.session = session
        getOne.transaction = transaction
        let fetched = try await getOne.perform().value
        #expect(fetched?.id == logged.id)
        #expect(fetched?.cleared == true)

        let delete = DeleteTransactionIntent()
        delete.session = session
        delete.transaction = transaction
        let deleted = try await delete.perform().value
        #expect(deleted?.id == logged.id)
        await #expect(throws: (any Error).self) {
            _ = try await getOne.perform()
        }

        let importText = ImportTransactionFromTextIntent()
        importText.session = session
        importText.text = "1.25 coffee Groceries Checking"
        let imported = try await importText.perform().value
        #expect(imported?.amount.map { abs($0.amount) } == Decimal(string: "1.25"))
        #expect(imported?.isTransfer == false)

        let assign = AssignCategoryBudgetIntent()
        assign.session = session
        assign.category = category()
        assign.amount = amount("20.00")
        assign.month = month()
        let assigned = try await assign.perform().value
        #expect(assigned?.id == "groceries")
        #expect(assigned?.budgeted?.amount == 20)

        let add = AddToCategoryBudgetIntent()
        add.session = session
        add.category = category()
        add.amount = amount("5.00")
        add.month = month()
        let added = try await add.perform().value
        #expect(added?.id == "groceries")
        #expect(added?.budgeted?.amount == 25)

        let move = MoveMoneyIntent()
        move.session = session
        move.fromCategory = category()
        move.amount = amount("1.00")
        move.month = month()
        let moved = try await move.perform().value
        #expect(moved?.id == "groceries")
        #expect(moved?.budgeted?.amount == 24)

        let template = ApplyBudgetTemplateIntent()
        template.session = session
        template.mode = .fillEmpty
        template.category = category()
        template.month = month()
        let templated = try await template.perform().value
        #expect(templated?.month == "2026-07")

        let carryover = SetCategoryCarryoverIntent()
        carryover.session = session
        carryover.category = category("utilities")
        carryover.enabled = true
        carryover.startMonth = month()
        let carried = try await carryover.perform().value
        #expect(carried?.id == "utilities")
        #expect(carried?.carryover == true)

        let createPayee = CreatePayeeIntent()
        createPayee.session = session
        createPayee.name = "Intent Payee"
        let payee = try await createPayee.perform().value
        #expect(payee?.name == "Intent Payee")

        let createAccount = CreateAccountIntent()
        createAccount.session = session
        createAccount.name = "Intent Cash"
        createAccount.offBudget = true
        let newAccount = try await createAccount.perform().value
        #expect(newAccount?.name == "Intent Cash")
        #expect(newAccount?.offBudget == true)

        let openBudget = OpenBudgetIntent()
        openBudget.session = session
        _ = try await openBudget.perform()
        #expect(appState.routeCoordinator.pendingRoute == .tab(.budget))
        #expect(appState.selectedTab == .budget)
        let openAccounts = OpenAccountsIntent()
        openAccounts.session = session
        _ = try await openAccounts.perform()
        #expect(appState.routeCoordinator.pendingRoute == .tab(.accounts))
        #expect(appState.selectedTab == .accounts)
        let openSpending = OpenSpendingIntent()
        openSpending.session = session
        _ = try await openSpending.perform()
        #expect(appState.routeCoordinator.pendingRoute == .tab(.spending))
        #expect(appState.selectedTab == .spending)
        let openReports = OpenReportsIntent()
        openReports.session = session
        _ = try await openReports.perform()
        #expect(appState.routeCoordinator.pendingRoute == .tab(.reports))
        #expect(appState.selectedTab == .reports)

        let openAccount = OpenAccountIntent()
        openAccount.session = session
        openAccount.account = account()
        _ = try await openAccount.perform()
        #expect(appState.routeCoordinator.pendingRoute == .account(id: "checking"))
        #expect(appState.selectedTab == .accounts)

        let openCategory = OpenCategoryIntent()
        openCategory.session = session
        openCategory.category = category()
        openCategory.month = month()
        _ = try await openCategory.perform()
        #expect(appState.routeCoordinator.pendingRoute == .category(id: "groceries", month: "2026-07"))
        #expect(appState.selectedTab == .budget)

        let openUncategorized = OpenUncategorizedIntent()
        openUncategorized.session = session
        openUncategorized.month = month()
        _ = try await openUncategorized.perform()
        #expect(appState.routeCoordinator.pendingRoute == .uncategorized(month: "2026-07"))

        let openNew = OpenNewTransactionIntent()
        openNew.session = session
        openNew.account = account()
        openNew.amount = amount("9.99")
        openNew.payeeName = "Prefill"
        openNew.category = category()
        openNew.notes = "from shortcut"
        openNew.direction = .inflow
        _ = try await openNew.perform()
        #expect(appState.routeCoordinator.pendingRoute == .newTransaction(ShortcutEditorPrefill(
            accountID: "checking",
            amountMinorUnits: 999,
            payeeName: "Prefill",
            categoryID: "groceries",
            categoryName: "groceries",
            notes: "from shortcut",
            direction: .inflow
        )))
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
        let none = try await noneIntent.perform().value
        #expect(none?.isEmpty == true)

        bundle.store.accountsByBudget["group-1"] = [
            AccountDisplay(
                account: ActualAccount(id: "solo", name: "Solo", offbudget: false, closed: false),
                balance: 100
            )
        ]
        let oneIntent = GetAccountsIntent()
        oneIntent.session = session
        oneIntent.includeClosed = false
        let one = try await oneIntent.perform().value
        #expect(one?.map(\.id) == ["solo"])

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
        let ghostBalance = try await balance.perform().value
        #expect(ghostBalance?.amount == 0)

        let openNew = OpenNewTransactionIntent()
        openNew.session = session
        openNew.direction = .spend
        _ = try await openNew.perform()
        #expect(appState.routeCoordinator.pendingRoute == .newTransaction(ShortcutEditorPrefill(direction: .spend)))
    }

    @Test func addOnlyIntentsAskForUnlockOnlyWhenLockedWithTheSettingOff() async throws {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        let unlocked = ShortcutsBudgetSession(appState: appState, isDeviceLocked: { false })
        let locked = ShortcutsBudgetSession(appState: appState, isDeviceLocked: { true })

        #expect(!appState.settings.shortcutsLockedLoggingEnabled)
        #expect(try !unlocked.needsUnlockToLog())
        #expect(try locked.needsUnlockToLog())
        appState.settings.shortcutsLockedLoggingEnabled = true
        #expect(try !locked.needsUnlockToLog())
        #expect(try !unlocked.needsUnlockToLog())

        appState.updateShortcutsEnabled(false)
        #expect(throws: ShortcutsError.shortcutsDisabled) { _ = try locked.needsUnlockToLog() }
    }

    @Test func lockedRunWithTheSettingOnLogsWithoutAskingToUnlock() async throws {
        let bundle = try await fixtures.makeOpenedWritableStoreBundle()
        let appState = try fixtures.makeAppState(for: bundle)
        appState.settings.shortcutsLockedLoggingEnabled = true
        let session = ShortcutsBudgetSession(appState: appState, isDeviceLocked: { true })
        let log = LogTransactionIntent()
        log.session = session
        log.amount = amount("2.75")
        log.account = account()
        log.direction = .spend
        log.payeeName = "Locked Cafe"
        log.cleared = false
        let transfer = LogTransferIntent()
        transfer.session = session
        transfer.fromAccount = account("checking")
        transfer.toAccount = account("savings")
        transfer.amount = amount("6.00")
        let importText = ImportTransactionFromTextIntent()
        importText.session = session
        importText.text = "1.40 bakery Groceries Checking"

        let logged = try await log.perform().value
        #expect(logged?.payee == "Locked Cafe")
        #expect(logged?.amount.map { abs($0.amount) } == Decimal(string: "2.75"))
        let transferred = try await transfer.perform().value
        #expect(transferred?.isTransfer == true)
        #expect(transferred?.amount.map { abs($0.amount) } == 6)
        let imported = try await importText.perform().value
        #expect(imported?.amount.map { abs($0.amount) } == Decimal(string: "1.4"))
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
