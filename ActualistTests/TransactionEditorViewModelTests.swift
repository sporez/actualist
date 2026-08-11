import Foundation
import Testing
@testable import Actualist

@MainActor
struct TransactionEditorViewModelTests {
    @Test func transactionCategoryPresentationUsesAccountAndTransferBudgetState() {
        func transaction(
            id: String,
            account: String,
            payee: String,
            category: String? = nil
        ) -> ActualTransaction {
            ActualTransaction(
                id: id,
                account: account,
                date: "2026-07-17",
                amount: -7_027,
                payee: payee,
                payeeName: nil,
                importedPayee: nil,
                category: category,
                notes: nil,
                cleared: .bool(true)
            )
        }

        let offBudgetTransaction = transaction(
            id: "tracking-to-checking",
            account: "tracking",
            payee: "transfer-checking"
        )
        let crossBudgetTransfer = transaction(
            id: "checking-to-tracking",
            account: "checking",
            payee: "transfer-tracking"
        )
        let categorizedCrossBudgetTransfer = transaction(
            id: "categorized-checking-to-tracking",
            account: "checking",
            payee: "transfer-tracking",
            category: "investments"
        )
        let sameBudgetTransfer = transaction(
            id: "checking-to-savings",
            account: "checking",
            payee: "transfer-savings"
        )
        let categoryNames = ["investments": "Investments"]
        let transferPayeeIDs: Set<String> = [
            "transfer-checking",
            "transfer-tracking",
            "transfer-savings"
        ]
        let transferAccountIDsByPayeeID = [
            "transfer-checking": "checking",
            "transfer-tracking": "tracking",
            "transfer-savings": "savings"
        ]

        #expect(TransactionCategoryPresentation.names(
            for: offBudgetTransaction,
            categoryNames: categoryNames,
            transferPayeeIDs: transferPayeeIDs,
            transferAccountIDsByPayeeID: transferAccountIDsByPayeeID,
            offBudgetAccountIDs: ["tracking"]
        ) == ["Off budget"])
        #expect(TransactionCategoryPresentation.names(
            for: crossBudgetTransfer,
            categoryNames: categoryNames,
            transferPayeeIDs: transferPayeeIDs,
            transferAccountIDsByPayeeID: transferAccountIDsByPayeeID,
            offBudgetAccountIDs: ["tracking"]
        ) == ["Uncategorized"])
        #expect(TransactionCategoryPresentation.names(
            for: categorizedCrossBudgetTransfer,
            categoryNames: categoryNames,
            transferPayeeIDs: transferPayeeIDs,
            transferAccountIDsByPayeeID: transferAccountIDsByPayeeID,
            offBudgetAccountIDs: ["tracking"]
        ) == ["Investments"])
        #expect(TransactionCategoryPresentation.names(
            for: sameBudgetTransfer,
            categoryNames: categoryNames,
            transferPayeeIDs: transferPayeeIDs,
            transferAccountIDsByPayeeID: transferAccountIDsByPayeeID,
            offBudgetAccountIDs: ["tracking"]
        ) == ["Account Transfer"])
    }

    @Test func formatsTypedDigitsAsCents() {
        let model = TransactionEditorViewModel()

        model.setAmountInput("500")
        #expect(model.amountCents == 500)
        #expect(model.formattedAmount.contains("5.00"))

        model.setAmountInput("50000")
        #expect(model.amountCents == 50000)
        #expect(model.formattedAmount.contains("500.00"))
    }

    @Test func filtersPayeesAndAllowsCustomName() {
        let model = TransactionEditorViewModel()
        model.payees = [
            ActualPayee(id: "amazon", name: "Amazon", category: nil, transferAccount: nil),
            ActualPayee(id: "target", name: "Target", category: nil, transferAccount: nil)
        ]

        #expect(model.filteredPayees(matching: "ama").map(\.name) == ["Amazon"])

        model.useCustomPayee("Local Coffee")
        #expect(model.payeeName == "Local Coffee")
        #expect(model.selectedPayeeID == nil)
    }

    @Test func payeeSectionsKeepTransfersBelowRegularPayeesWithoutSearch() {
        let model = TransactionEditorViewModel()
        model.accounts = [
            ActualAccount(id: "checking", name: "Ally Checking", offbudget: false, closed: false)
        ]
        model.payees = [
            ActualPayee(id: "store", name: "Corner Store", category: nil, transferAccount: nil),
            ActualPayee(id: "transfer-checking", name: "Ally Checking", category: nil, transferAccount: "checking")
        ]

        let sections = model.payeeSections(matching: "")

        #expect(sections.map(\.kind) == [.payees, .transfers])
        #expect(sections.first?.options.map(\.title) == ["Corner Store"])
        #expect(sections.last?.title == "Transfer To/From")
        #expect(sections.last?.options.map(\.title) == ["Ally Checking"])
    }

    @Test func payeeSectionsHideUnresolvedBlankTransferPayees() {
        let model = TransactionEditorViewModel()
        model.payees = [
            ActualPayee(id: "store", name: "Corner Store", category: nil, transferAccount: nil),
            ActualPayee(id: "blank-transfer", name: "", category: nil, transferAccount: "missing-account")
        ]

        let sections = model.payeeSections(matching: "")

        #expect(sections.map(\.kind) == [.payees])
        #expect(sections.first?.options.map(\.title) == ["Corner Store"])
    }

    @Test func payeeSectionsLiftMatchingTransfersDuringSearch() {
        let model = TransactionEditorViewModel()
        model.accounts = [
            ActualAccount(id: "checking", name: "Ally Checking", offbudget: false, closed: false)
        ]
        model.payees = [
            ActualPayee(id: "ally-payee", name: "Ally Auto", category: nil, transferAccount: nil),
            ActualPayee(id: "transfer-checking", name: "Transfer Payee", category: nil, transferAccount: "checking")
        ]

        let sections = model.payeeSections(matching: "ally")

        #expect(sections.map(\.kind) == [.transfers, .payees])
        #expect(sections.first?.options.map(\.title) == ["Ally Checking"])
        #expect(sections.last?.options.map(\.title) == ["Ally Auto"])
    }

    @Test func customPayeeOptionIsHiddenForExactExistingPayeeOrTransferAccountMatch() {
        let model = TransactionEditorViewModel()
        model.accounts = [
            ActualAccount(id: "checking", name: "Ally Checking", offbudget: false, closed: false)
        ]
        model.payees = [
            ActualPayee(id: "store", name: "Corner Store", category: nil, transferAccount: nil),
            ActualPayee(id: "transfer-checking", name: "Transfer Payee", category: nil, transferAccount: "checking")
        ]

        #expect(model.shouldOfferCustomPayee(matching: "Corner Store") == false)
        #expect(model.shouldOfferCustomPayee(matching: "Ally Checking") == false)
        #expect(model.shouldOfferCustomPayee(matching: "Local Coffee") == true)
    }

    @Test func selectedCategoryNameShowsAccountTransferForTransferPayee() {
        let model = TransactionEditorViewModel(
            editing: ActualTransaction(
                id: "transfer",
                account: "checking",
                date: "2026-06-14",
                amount: -1_200,
                payee: "transfer-checking",
                payeeName: nil,
                importedPayee: nil,
                category: nil,
                notes: nil,
                cleared: .bool(false)
            )
        )
        model.payees = [
            ActualPayee(id: "transfer-checking", name: "Ally Checking", category: nil, transferAccount: "checking")
        ]

        #expect(model.selectedCategoryName == "Account Transfer")
    }

    @Test func selectingTransferPayeeClearsCategoryAndMakesCategoryReadOnly() {
        let model = TransactionEditorViewModel()
        model.selectedCategoryID = "groceries"
        model.splitRows = [
            TransactionSplitEditorRow(
                id: "groceries",
                transactionID: nil,
                categoryID: "groceries",
                categoryName: "Groceries",
                amountDigits: "500"
            ),
            TransactionSplitEditorRow(
                id: "household",
                transactionID: nil,
                categoryID: "household",
                categoryName: "Household",
                amountDigits: "734"
            )
        ]
        let transferPayee = ActualPayee(
            id: "transfer-checking",
            name: "Ally Checking",
            category: nil,
            transferAccount: "checking"
        )
        model.payees = [transferPayee]

        model.selectPayee(transferPayee)

        #expect(model.selectedPayeeID == "transfer-checking")
        #expect(model.isCategoryReadOnly)
        #expect(model.selectedCategoryName == "Account Transfer")
        #expect(model.selectedCategoryID == nil)
        #expect(model.splitRows.isEmpty)
    }

    @Test func editingTransferKeepsPayeeNameAfterOptionsLoad() {
        let model = TransactionEditorViewModel(
            editing: ActualTransaction(
                id: "txn-xfer",
                account: "checking",
                date: "2026-07-12",
                amount: -1000,
                payee: "xfer-credit",
                payeeName: "Credit Card",
                importedPayee: nil,
                category: nil,
                notes: nil,
                cleared: .bool(false)
            ),
            payeeName: "Credit Card",
            categoryName: "Account Transfer"
        )
        #expect(model.payeeName == "Credit Card")

        model.apply(
            TransactionEditorOptions(
                accounts: [
                    ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false),
                    ActualAccount(id: "credit", name: "Credit Card", offbudget: false, closed: false)
                ],
                categories: [],
                categoryGroups: [],
                payees: [ActualPayee(id: "xfer-credit", name: "", category: nil, transferAccount: "credit")]
            ),
            loadedMonth: "2026-07"
        )

        #expect(model.payeeName == "Credit Card")
        #expect(model.selectedPayeeName == "Transfer: Credit Card")
        #expect(model.canSave)
    }

    @Test func crossBudgetTransferShowsSelectCategoryNotAccountTransfer() {
        let model = TransactionEditorViewModel()
        model.accounts = [
            ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false),
            ActualAccount(id: "tracking", name: "Tracking", offbudget: true, closed: false),
            ActualAccount(id: "savings", name: "Savings", offbudget: false, closed: false)
        ]
        model.selectedAccountID = "checking"
        let toChecking = ActualPayee(id: "xfer-checking", name: "", category: nil, transferAccount: "checking")
        let toTracking = ActualPayee(id: "xfer-tracking", name: "", category: nil, transferAccount: "tracking")
        let toSavings = ActualPayee(id: "xfer-savings", name: "", category: nil, transferAccount: "savings")
        model.payees = [toChecking, toTracking, toSavings]

        model.selectPayee(toTracking)
        #expect(model.selectedCategoryName == "Select Category")

        model.selectAccount(model.accounts[1])
        model.selectPayee(toChecking)
        #expect(model.selectedCategoryName == "Select Category")

        model.selectAccount(model.accounts[0])
        model.selectPayee(toSavings)
        #expect(model.selectedCategoryName == "Account Transfer")
    }

    @Test func selectingTransferPayeeUsesLinkedAccountNameAndEnablesSave() {
        let model = TransactionEditorViewModel()
        model.accounts = [
            ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false),
            ActualAccount(id: "credit", name: "Credit Card", offbudget: false, closed: false)
        ]
        model.selectedAccountID = "checking"
        model.setAmountInput("1000")
        let toCredit = ActualPayee(id: "xfer-credit", name: "", category: nil, transferAccount: "credit")
        model.payees = [toCredit]

        model.selectPayee(toCredit)

        #expect(model.payeeName == "Credit Card")
        #expect(model.selectedPayeeName == "Transfer: Credit Card")
        #expect(model.canSave)
    }

    @Test func crossBudgetTransferAllowsCategoryButSameBudgetDoesNot() {
        let model = TransactionEditorViewModel()
        model.accounts = [
            ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false),
            ActualAccount(id: "tracking", name: "Tracking", offbudget: true, closed: false),
            ActualAccount(id: "savings", name: "Savings", offbudget: false, closed: false)
        ]
        let toChecking = ActualPayee(id: "xfer-checking", name: "", category: nil, transferAccount: "checking")
        let toTracking = ActualPayee(id: "xfer-tracking", name: "", category: nil, transferAccount: "tracking")
        let toSavings = ActualPayee(id: "xfer-savings", name: "", category: nil, transferAccount: "savings")
        model.payees = [toChecking, toTracking, toSavings]
        model.selectedAccountID = "checking"

        model.selectPayee(toTracking)
        #expect(!model.isCategoryReadOnly)
        model.selectCategory(TransactionEditorCategoryOption(id: "groceries", title: "Groceries", amount: nil, valueText: nil))
        #expect(model.selectedCategoryID == "groceries")

        model.selectAccount(model.accounts[1])
        model.selectPayee(toChecking)
        #expect(!model.isCategoryReadOnly)
        model.selectCategory(TransactionEditorCategoryOption(id: "income", title: "Income", amount: nil, valueText: nil))
        #expect(model.selectedCategoryID == "income")

        model.selectAccount(model.accounts[0])
        model.selectPayee(toSavings)
        #expect(model.isCategoryReadOnly)
        #expect(model.selectedCategoryID == nil)
    }

    @Test func offBudgetToOnBudgetTransferSubmitsSelectedCategoryForPairedRow() async throws {
        let model = TransactionEditorViewModel()
        let checking = ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false)
        let tracking = ActualAccount(id: "tracking", name: "Tracking", offbudget: true, closed: false)
        let toChecking = ActualPayee(id: "xfer-checking", name: "", category: nil, transferAccount: "checking")
        model.accounts = [checking, tracking]
        model.payees = [toChecking]
        model.selectAccount(tracking)
        model.selectPayee(toChecking)
        model.setAmountInput("1000")
        model.selectCategory(
            TransactionEditorCategoryOption(
                id: "income",
                title: "Income",
                amount: nil,
                valueText: nil
            )
        )

        let repository = RecordingTransactionRepository()
        #expect(await model.submit(budgetID: "budget", repository: repository))
        let draft = try await repository.onlyDraft()
        #expect(draft.accountID == "tracking")
        #expect(draft.categoryID == "income")
        #expect(draft.isTransfer)
    }

    @Test func offBudgetAccountDisablesAndDropsCategorySelection() async throws {
        let model = configuredModel()
        let tracking = ActualAccount(
            id: "tracking",
            name: "Target 401K",
            offbudget: true,
            closed: false
        )
        model.accounts = [tracking]
        model.selectedCategoryID = "investments"
        model.splitRows = [
            TransactionSplitEditorRow(
                id: "investments",
                transactionID: nil,
                categoryID: "investments",
                categoryName: "Investments",
                amountDigits: "617"
            ),
            TransactionSplitEditorRow(
                id: "fees",
                transactionID: nil,
                categoryID: "fees",
                categoryName: "Fees",
                amountDigits: "617"
            )
        ]

        model.selectAccount(tracking)

        #expect(model.isCategoryReadOnly)
        #expect(model.selectedCategoryName == "Off budget")
        #expect(model.selectedCategoryID == nil)
        #expect(model.splitRows.isEmpty)

        let repository = RecordingTransactionRepository()
        #expect(await model.submit(budgetID: "budget", repository: repository))
        let draft = try await repository.onlyDraft()
        #expect(draft.accountID == "tracking")
        #expect(draft.categoryID == nil)
        #expect(draft.splits.isEmpty)
    }

    @Test func categoryMutationIsIgnoredForTransferPayees() {
        let model = TransactionEditorViewModel()
        model.payees = [
            ActualPayee(id: "transfer-checking", name: "Ally Checking", category: nil, transferAccount: "checking")
        ]
        model.selectedPayeeID = "transfer-checking"

        model.selectCategory(TransactionEditorCategoryOption(id: "groceries", title: "Groceries", amount: nil, valueText: nil))
        model.beginSplitSelection()
        model.toggleSplitCategory(TransactionEditorCategoryOption(id: "household", title: "Household", amount: nil, valueText: nil))
        model.finalizeSplitSelection()

        #expect(model.selectedCategoryID == nil)
        #expect(model.splitRows.isEmpty)
        #expect(model.selectedCategoryName == "Account Transfer")
    }

    @Test func rulePreviewIsSkippedForTransferPayees() async throws {
        let model = configuredModel()
        model.payees = [
            ActualPayee(id: "transfer-checking", name: "Ally Checking", category: nil, transferAccount: "checking")
        ]
        model.selectedPayeeID = "transfer-checking"
        model.payeeName = "Ally Checking"
        model.selectedCategoryID = nil
        let repository = RecordingTransactionRepository(
            rulePreview: TransactionRulePreview(
                categoryID: "groceries",
                notes: "rule note"
            )
        )

        await model.previewRules(budgetID: "budget", repository: repository)

        #expect(model.selectedCategoryID == nil)
        #expect(model.notes == "  weekly groceries  ")
        #expect(await repository.rulePreviewDraftCount() == 0)
    }

    @Test func transferSubmitDropsCategoryAndSplitsFromDraft() async throws {
        let model = configuredModel()
        model.payees = [
            ActualPayee(id: "transfer-checking", name: "Ally Checking", category: nil, transferAccount: "checking")
        ]
        model.selectedPayeeID = "transfer-checking"
        model.payeeName = "Ally Checking"
        model.selectedCategoryID = "groceries"
        model.splitRows = [
            TransactionSplitEditorRow(
                id: "groceries",
                transactionID: nil,
                categoryID: "groceries",
                categoryName: "Groceries",
                amountDigits: "500"
            ),
            TransactionSplitEditorRow(
                id: "household",
                transactionID: nil,
                categoryID: "household",
                categoryName: "Household",
                amountDigits: "734"
            )
        ]
        let repository = RecordingTransactionRepository()

        #expect(await model.submit(budgetID: "budget", repository: repository))

        let draft = try await repository.onlyDraft()
        #expect(draft.payeeID == "transfer-checking")
        #expect(draft.payeeName == "Ally Checking")
        #expect(draft.categoryID == nil)
        #expect(draft.isTransfer)
        #expect(draft.splits.isEmpty)
    }

    @Test func filtersAndSelectsCategoryBalanceOptions() throws {
        let model = TransactionEditorViewModel()
        model.categoryGroups = [
            TransactionEditorCategoryGroup(
                id: "bills",
                name: "Monthly Bills",
                options: [
                    TransactionEditorCategoryOption(
                        id: "mortgage",
                        title: "Mortgage",
                        amount: 100_00,
                        valueText: "$100.00"
                    )
                ]
            ),
            TransactionEditorCategoryGroup(
                id: "everyday",
                name: "Everyday",
                options: [
                    TransactionEditorCategoryOption(
                        id: "groceries",
                        title: "Groceries",
                        amount: -12_34,
                        valueText: "-$12.34"
                    )
                ]
            )
        ]

        let filteredGroups = model.categorySelectionGroups(matching: "gro")

        #expect(filteredGroups.map(\.id) == ["everyday"])
        #expect(filteredGroups.first?.options.map(\.id) == ["groceries"])

        let option = try #require(filteredGroups.first?.options.first)
        model.selectCategory(option)

        #expect(model.selectedCategoryID == "groceries")
        #expect(model.selectedCategoryName == "Groceries")
    }

    @Test func beginningSplitSelectionSeedsExistingSingleCategory() {
        let model = TransactionEditorViewModel()
        let services = TransactionEditorCategoryOption(
            id: "services",
            title: "Services/Software",
            amount: nil,
            valueText: nil
        )
        let phone = TransactionEditorCategoryOption(
            id: "phone",
            title: "iPhone",
            amount: nil,
            valueText: nil
        )

        model.selectCategory(services)
        model.beginSplitSelection()
        model.toggleSplitCategory(phone)
        model.finalizeSplitSelection()

        #expect(model.selectedCategoryID == nil)
        #expect(model.splitRows.map(\.categoryID) == ["services", "phone"])
        #expect(model.selectedCategoryName == "Services/Software, iPhone")
    }

    @Test func formatsSplitAmountsAndLabelsOverage() {
        let model = TransactionEditorViewModel()
        model.setAmountInput("1000")
        model.toggleSplitCategory(TransactionEditorCategoryOption(id: "services", title: "Services/Software", amount: nil, valueText: nil))
        model.toggleSplitCategory(TransactionEditorCategoryOption(id: "phone", title: "iPhone", amount: nil, valueText: nil))
        model.finalizeSplitSelection()

        model.setSplitAmount(rowID: "services", value: "560")
        model.setSplitAmount(rowID: "phone", value: "500")

        #expect(model.formattedSplitAmount(rowID: "services") == "5.60")
        #expect(model.formattedSplitAmount(rowID: "phone") == "5.00")
        #expect(model.splitRemainingCents == -60)
        #expect(model.splitRemainingStatusText.contains("Over"))
        #expect(model.splitRemainingStatusText.contains("0.60"))
    }

    @Test func buildsSpendDraftForCustomPayee() async throws {
        let model = configuredModel()
        let repository = RecordingTransactionRepository()

        let saved = await model.submit(budgetID: "budget", repository: repository)

        #expect(saved)
        #expect(model.submissionState == .clean)

        let draft = try await repository.onlyDraft()
        #expect(draft.accountID == "checking")
        #expect(draft.amountMinorUnits == -1234)
        #expect(draft.payeeID == nil)
        #expect(draft.payeeName == "Corner Store")
        #expect(draft.categoryID == nil)
        #expect(draft.notes == "weekly groceries")
        #expect(draft.cleared == true)
    }

    @Test func buildsInflowDraftForSelectedPayeeAndCategory() async throws {
        let model = configuredModel()
        model.kind = .inflow
        model.selectedPayeeID = "employer"
        model.payeeName = "Employer"
        model.selectedCategoryID = "income"
        model.notes = "   "
        let repository = RecordingTransactionRepository()

        let saved = await model.submit(budgetID: "budget", repository: repository)

        #expect(saved)

        let draft = try await repository.onlyDraft()
        #expect(draft.amountMinorUnits == 1234)
        #expect(draft.payeeID == "employer")
        #expect(draft.payeeName == "Employer")
        #expect(draft.categoryID == "income")
        #expect(draft.notes == nil)
    }

    @Test func prefilledEditModelMatchesTransaction() {
        let model = TransactionEditorViewModel(
            editing: ActualTransaction(
                id: "txn-1",
                account: "savings",
                date: "2026-06-13",
                amount: 4512,
                payee: "employer",
                payeeName: nil,
                importedPayee: "Imported Employer",
                category: "income",
                notes: "paycheck",
                cleared: .bool(true)
            ),
            payeeName: "Employer",
            categoryName: "Income"
        )

        #expect(model.isEditing)
        #expect(model.title == "Edit Transaction")
        #expect(model.kind == .inflow)
        #expect(model.amountDigits == "4512")
        #expect(model.payeeName == "Employer")
        #expect(model.selectedPayeeID == "employer")
        #expect(model.selectedAccountID == "savings")
        #expect(model.selectedCategoryID == "income")
        #expect(model.selectedCategoryName == "Income")
        #expect(model.notes == "paycheck")
        #expect(model.isCleared)
        #expect(model.saveButtonTitle == "Update")
    }

    @Test func transactionAmountsAreBoundedAndMinimumServerValuesDoNotTrap() {
        let model = TransactionEditorViewModel(
            editing: ActualTransaction(
                id: "txn-min",
                account: "checking",
                date: "2026-07-01",
                amount: Int.min,
                payee: nil,
                payeeName: "Payee",
                importedPayee: nil,
                category: nil,
                notes: nil,
                cleared: .bool(false)
            )
        )

        #expect(model.amountDigits == "9223372036854775808")
        #expect(model.amountCents == 0)

        model.setAmountInput(String(repeating: "9", count: 100))
        #expect(model.amountDigits.count == 16)
        #expect(model.amountCents == 9_999_999_999_999_999)
    }

    @Test func editingSubmitUpdatesExistingTransaction() async throws {
        let model = TransactionEditorViewModel(
            editing: ActualTransaction(
                id: "txn-1",
                account: "checking",
                date: "2026-05-31",
                amount: -1200,
                payee: nil,
                payeeName: "Corner Store",
                importedPayee: nil,
                category: nil,
                notes: nil,
                cleared: .bool(false)
            )
        )
        model.amountDigits = "1299"
        model.date = Self.date("2026-06-14")
        model.notes = "updated"
        let repository = RecordingTransactionRepository()

        let saved = await model.submit(budgetID: "budget", repository: repository)

        #expect(saved)
        #expect(model.submissionState == .clean)
        #expect(await repository.draftCount() == 0)

        let update = try await repository.onlyUpdate()
        #expect(update.transactionID == "txn-1")
        #expect(update.originalAccountID == "checking")
        #expect(update.originalMonth == "2026-05")
        #expect(update.draft.amountMinorUnits == -1299)
        #expect(update.draft.notes == "updated")
    }

    @Test func editingSubmitCanClearExistingCategory() async throws {
        let model = TransactionEditorViewModel(
            editing: ActualTransaction(
                id: "txn-1",
                account: "checking",
                date: "2026-06-14",
                amount: -1200,
                payee: nil,
                payeeName: "Corner Store",
                importedPayee: nil,
                category: "groceries",
                notes: nil,
                cleared: .bool(false)
            ),
            categoryName: "Groceries"
        )
        model.amountDigits = "1200"
        model.clearCategory()
        let repository = RecordingTransactionRepository()

        let saved = await model.submit(budgetID: "budget", repository: repository)

        #expect(saved)
        #expect(model.selectedCategoryName == "Uncategorized")

        let update = try await repository.onlyUpdate()
        #expect(update.draft.categoryID == nil)
    }

    @Test func splitSubmitBlocksMismatchThenAutoDistributesAndBuildsSplitDraft() async throws {
        let model = configuredModel()
        let repository = RecordingTransactionRepository()
        let groceries = TransactionEditorCategoryOption(
            id: "groceries",
            title: "Groceries",
            amount: nil,
            valueText: nil
        )
        let household = TransactionEditorCategoryOption(
            id: "household",
            title: "Household",
            amount: nil,
            valueText: nil
        )

        model.toggleSplitCategory(groceries)
        model.toggleSplitCategory(household)
        model.finalizeSplitSelection()
        model.setSplitAmount(rowID: "groceries", value: "500")
        model.setSplitAmount(rowID: "household", value: "600")

        #expect(await model.submit(budgetID: "budget", repository: repository) == false)
        #expect(model.pendingSplitMismatch == TransactionSplitMismatch(transactionTotal: 1234, splitTotal: 1100))

        model.autoDistributeSplitMismatch()

        #expect(model.splitTotalCents == 1234)
        #expect(await model.submit(budgetID: "budget", repository: repository))

        let draft = try await repository.onlyDraft()
        #expect(draft.categoryID == nil)
        #expect(draft.splits.map(\.categoryID) == ["groceries", "household"])
        #expect(draft.splits.map(\.amountMinorUnits) == [-500, -734])
    }

    @Test func splitUpdateTotalUsesSplitSumAsTransactionAmount() {
        let model = configuredModel()
        model.toggleSplitCategory(TransactionEditorCategoryOption(id: "groceries", title: "Groceries", amount: nil, valueText: nil))
        model.toggleSplitCategory(TransactionEditorCategoryOption(id: "household", title: "Household", amount: nil, valueText: nil))
        model.finalizeSplitSelection()
        model.setSplitAmount(rowID: "groceries", value: "2500")
        model.setSplitAmount(rowID: "household", value: "1250")

        model.updateTotalFromSplits()

        #expect(model.amountCents == 3750)
        #expect(model.splitRemainingCents == 0)
    }

    @Test func splitRowRemovalCollapsesTwoCategoriesToRemainingCategory() {
        let model = configuredModel()
        model.toggleSplitCategory(TransactionEditorCategoryOption(id: "groceries", title: "Groceries", amount: nil, valueText: nil))
        model.toggleSplitCategory(TransactionEditorCategoryOption(id: "household", title: "Household", amount: nil, valueText: nil))
        model.finalizeSplitSelection()

        #expect(model.canRemoveSplitRow)

        model.removeSplit(rowID: "groceries")

        #expect(model.isSplit == false)
        #expect(model.splitRows.isEmpty)
        #expect(model.selectedCategoryID == "household")
        #expect(model.selectedCategoryName == "Household")
    }

    @Test func splitRowRemovalKeepsRemainingSplitWhenMoreThanTwoCategories() {
        let model = configuredModel()
        model.toggleSplitCategory(TransactionEditorCategoryOption(id: "groceries", title: "Groceries", amount: nil, valueText: nil))
        model.toggleSplitCategory(TransactionEditorCategoryOption(id: "household", title: "Household", amount: nil, valueText: nil))

        model.toggleSplitCategory(TransactionEditorCategoryOption(id: "utilities", title: "Utilities", amount: nil, valueText: nil))
        model.finalizeSplitSelection()

        #expect(model.canRemoveSplitRow)

        model.removeSplit(rowID: "utilities")

        #expect(model.splitRows.map(\.categoryID) == ["groceries", "household"])
    }

    @Test func editingExistingSplitPrefillsChildRows() {
        let model = TransactionEditorViewModel(
            editing: ActualTransaction(
                id: "parent",
                account: "checking",
                date: "2026-06-14",
                amount: -5000,
                payee: nil,
                payeeName: "Target",
                importedPayee: nil,
                category: nil,
                notes: nil,
                cleared: .bool(false),
                subtransactions: [
                    ActualTransaction(
                        id: "child-1",
                        account: "checking",
                        date: "2026-06-14",
                        amount: -2500,
                        payee: nil,
                        payeeName: nil,
                        importedPayee: nil,
                        category: "groceries",
                        notes: nil,
                        cleared: .bool(false),
                        isChild: true,
                        parentID: "parent"
                    ),
                    ActualTransaction(
                        id: "child-2",
                        account: "checking",
                        date: "2026-06-14",
                        amount: -2500,
                        payee: nil,
                        payeeName: nil,
                        importedPayee: nil,
                        category: "household",
                        notes: nil,
                        cleared: .bool(false),
                        isChild: true,
                        parentID: "parent"
                    )
                ],
                isParent: true
            )
        )

        #expect(model.isSplit)
        #expect(model.splitRows.map(\.transactionID) == ["child-1", "child-2"])
        #expect(model.splitRows.map(\.amountDigits) == ["2500", "2500"])
    }

    @Test func splitTransactionDecodesParentAndChildren() throws {
        let data = """
        {
          "id": "parent",
          "account": "checking",
          "date": "2026-06-14",
          "amount": -5000,
          "payee_name": "Target",
          "category": null,
          "cleared": true,
          "is_parent": true,
          "subtransactions": [
            {
              "id": "child-1",
              "account": "checking",
              "date": "2026-06-14",
              "amount": -2500,
              "category": "groceries",
              "is_child": true,
              "parent_id": "parent"
            }
          ]
        }
        """.data(using: .utf8)!

        let transaction = try JSONDecoder.actual.decode(ActualTransaction.self, from: data)

        #expect(transaction.isParent)
        #expect(transaction.subtransactions.count == 1)
        #expect(transaction.subtransactions.first?.isChild == true)
        #expect(transaction.subtransactions.first?.parentID == "parent")
    }

    @Test func doesNotSubmitInvalidDrafts() async {
        let repository = RecordingTransactionRepository()
        let missingEverything = TransactionEditorViewModel()
        #expect(await missingEverything.submit(budgetID: "budget", repository: repository) == false)

        let missingAmount = configuredModel()
        missingAmount.amountDigits = ""
        #expect(await missingAmount.submit(budgetID: "budget", repository: repository) == false)

        let missingPayee = configuredModel()
        missingPayee.payeeName = " "
        #expect(await missingPayee.submit(budgetID: "budget", repository: repository) == false)

        let missingAccount = configuredModel()
        missingAccount.selectedAccountID = nil
        #expect(await missingAccount.submit(budgetID: "budget", repository: repository) == false)

        #expect(await repository.draftCount() == 0)
    }

    @Test func successfulSubmitTransitionsThroughRefetching() async {
        let model = configuredModel()
        let repository = RecordingTransactionRepository(pauseAfterDidCreate: true)

        let task = Task {
            await model.submit(budgetID: "budget", repository: repository)
        }

        while await !repository.didCreateFinished() {
            await Task.yield()
        }

        #expect(model.submissionState == .refetching)

        await repository.resumeAfterDidCreate()

        #expect(await task.value == true)
        #expect(model.submissionState == .clean)
    }

    @Test func createFailureLeavesDraftRetryable() async {
        let model = configuredModel()
        let repository = RecordingTransactionRepository(createError: TestError("create failed"))

        let saved = await model.submit(budgetID: "budget", repository: repository)

        #expect(saved == false)
        #expect(model.submissionState == .failed("create failed"))
        #expect(model.errorMessage == "create failed")
        #expect(model.canSave)
    }

    @Test func refreshFailureLeavesDraftRetryable() async {
        let model = configuredModel()
        let repository = RecordingTransactionRepository(refreshError: TestError("refresh failed"))

        let saved = await model.submit(budgetID: "budget", repository: repository)

        #expect(saved == false)
        #expect(model.submissionState == .failed("refresh failed"))
        #expect(model.errorMessage == "refresh failed")
        #expect(model.canSave)
    }

    @Test func duplicateSubmitIsBlockedWhileSubmitting() async {
        let model = configuredModel()
        let repository = RecordingTransactionRepository(pauseBeforeDidCreate: true)

        let firstSubmit = Task {
            await model.submit(budgetID: "budget", repository: repository)
        }

        while await !repository.isPausedBeforeDidCreate() {
            await Task.yield()
        }

        #expect(model.submissionState == .submitting)
        #expect(await model.submit(budgetID: "budget", repository: repository) == false)
        #expect(await repository.draftCount() == 1)

        await repository.resumeBeforeDidCreate()

        #expect(await firstSubmit.value == true)
        #expect(model.submissionState == .clean)
    }

    @Test func rulePreviewAppliesSuggestedCategoryAndNotes() async throws {
        let model = configuredModel()
        model.selectedPayeeID = "target"
        model.payeeName = "Target"
        model.notes = "old note"
        let repository = RecordingTransactionRepository(
            rulePreview: TransactionRulePreview(
                categoryID: "groceries",
                notes: "rule note"
            )
        )

        await model.previewRules(budgetID: "budget", repository: repository)

        #expect(model.selectedCategoryID == "groceries")
        #expect(model.notes == "rule note")

        let draft = try await repository.onlyRulePreviewDraft()
        #expect(draft.accountID == "checking")
        #expect(draft.amountMinorUnits == -1234)
        #expect(draft.payeeID == "target")
        #expect(draft.payeeName == "Target")
        #expect(draft.notes == "old note")
    }

    @Test func unsupportedLocalFirstRulePreviewIsSilent() async {
        let model = configuredModel()
        model.selectedPayeeID = "target"
        model.payeeName = "Target"
        let repository = RecordingTransactionRepository(previewError: LocalFirstError.unsupportedWrite)

        await model.previewRules(budgetID: "budget", repository: repository)

        #expect(model.errorMessage == nil)
        #expect(model.selectedCategoryID == nil)
    }

    private func configuredModel() -> TransactionEditorViewModel {
        let model = TransactionEditorViewModel()
        model.kind = .spend
        model.amountDigits = "1234"
        model.payeeName = "  Corner Store  "
        model.selectedAccountID = "checking"
        model.date = Self.date("2026-06-14")
        model.notes = "  weekly groceries  "
        model.isCleared = true
        return model
    }

    nonisolated static func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: "\(value) 12:00:00")!
    }

}

actor RecordingTransactionRepository: TransactionRepositoryProtocol {
    nonisolated func cachedAccountTransactions(budgetID: String, accountID: String) -> LoadedAccountTransactions? { nil }
    nonisolated func cachedSpendingTransactions(budgetID: String) -> LoadedAccountTransactions? { nil }
    func refreshAccountTransactions(budgetID: String, accountID: String) async throws {}
    func refreshSpendingTransactions(budgetID: String) async throws {}
    func loadOlderTransactions(budgetID: String, accountID: String) async throws {}
    func loadOlderSpendingTransactions(budgetID: String) async throws {}
    func searchAccountTransactions(budgetID: String, accountID: String, query: String, limit: Int, offset: Int) async throws -> LoadedAccountTransactions {
        LoadedAccountTransactions(transactions: [], balance: nil, categoryNames: [:], payeeNames: [:], transferPayeeIDs: [], reachedEnd: true)
    }
    func searchSpendingTransactions(budgetID: String, query: String, limit: Int, offset: Int) async throws -> LoadedAccountTransactions {
        LoadedAccountTransactions(transactions: [], balance: nil, categoryNames: [:], payeeNames: [:], transferPayeeIDs: [], reachedEnd: true)
    }

    private var drafts: [TransactionDraft] = []
    private var updates: [RecordedTransactionUpdate] = []
    private var deletes: [ActualTransaction] = []
    private var rulePreviewDrafts: [TransactionDraft] = []
    private let rulePreview: TransactionRulePreview
    private let previewError: Error?
    private let createError: Error?
    private let refreshError: Error?
    private let pauseBeforeDidCreate: Bool
    private let pauseAfterDidCreate: Bool
    private var didCreateCallbackFinished = false
    private var pausedBeforeDidCreate = false
    private var beforeDidCreateContinuation: CheckedContinuation<Void, Never>?
    private var afterDidCreateContinuation: CheckedContinuation<Void, Never>?

    init(
        rulePreview: TransactionRulePreview = TransactionRulePreview(categoryID: nil, notes: nil),
        previewError: Error? = nil,
        createError: Error? = nil,
        refreshError: Error? = nil,
        pauseBeforeDidCreate: Bool = false,
        pauseAfterDidCreate: Bool = false
    ) {
        self.rulePreview = rulePreview
        self.previewError = previewError
        self.createError = createError
        self.refreshError = refreshError
        self.pauseBeforeDidCreate = pauseBeforeDidCreate
        self.pauseAfterDidCreate = pauseAfterDidCreate
    }

    func editorOptions(budgetID: String, month: String) async throws -> TransactionEditorOptions {
        TransactionEditorOptions(accounts: [], categories: [], categoryGroups: [], payees: [])
    }

    func uncategorizedTransactions(
        budgetID: String,
        month: String
    ) async throws -> LoadedUncategorizedTransactions {
        LoadedUncategorizedTransactions(
            transactions: [],
            accountNames: [:],
            categoryNames: [:],
            payeeNames: [:],
            transferPayeeIDs: [],
            categoryGroups: []
        )
    }

    func previewRules(
        for draft: TransactionDraft,
        budgetID: String
    ) async throws -> TransactionRulePreview {
        rulePreviewDrafts.append(draft)
        if let previewError {
            throw previewError
        }
        return rulePreview
    }

    func createTransactionAndRefresh(
        _ draft: TransactionDraft,
        budgetID: String,
        didCreate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        drafts.append(draft)

        if pauseBeforeDidCreate {
            await withCheckedContinuation { continuation in
                pausedBeforeDidCreate = true
                beforeDidCreateContinuation = continuation
            }
            pausedBeforeDidCreate = false
        }

        if let createError {
            throw createError
        }

        await didCreate()
        didCreateCallbackFinished = true

        if pauseAfterDidCreate {
            await withCheckedContinuation { continuation in
                afterDidCreateContinuation = continuation
            }
        }

        if let refreshError {
            throw refreshError
        }

        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: [draft.accountID],
                months: [draft.month.rawValue],
                transactions: []
            )
        )
    }

    func updateTransactionAndRefresh(
        _ transactionID: String,
        with draft: TransactionDraft,
        budgetID: String,
        originalAccountID: String,
        originalMonth: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        updates.append(
            RecordedTransactionUpdate(
                transactionID: transactionID,
                draft: draft,
                originalAccountID: originalAccountID,
                originalMonth: originalMonth
            )
        )

        if let createError {
            throw createError
        }

        await didUpdate()
        didCreateCallbackFinished = true

        if let refreshError {
            throw refreshError
        }

        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: [originalAccountID, draft.accountID],
                months: [originalMonth, draft.month.rawValue],
                transactions: [transactionID]
            )
        )
    }

    func categorizeTransactionAndRefresh(
        _ transaction: ActualTransaction,
        categoryID: String,
        budgetID: String,
        didUpdate: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        if let createError {
            throw createError
        }

        await didUpdate()

        if let refreshError {
            throw refreshError
        }

        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: [transaction.account],
                months: transaction.date.actualYearMonth.map { [$0] } ?? [],
                transactions: transaction.id.map { [$0] } ?? []
            )
        )
    }

    func deleteTransactionAndRefresh(
        _ transaction: ActualTransaction,
        budgetID: String,
        didDelete: @escaping () async -> Void
    ) async throws -> TransactionMutationResult {
        deletes.append(transaction)

        if let createError {
            throw createError
        }

        await didDelete()
        didCreateCallbackFinished = true

        if let refreshError {
            throw refreshError
        }

        return TransactionMutationResult(
            ok: true,
            changed: ChangedResources(
                accounts: [transaction.account],
                months: transaction.date.actualYearMonth.map { [$0] } ?? [],
                transactions: transaction.id.map { [$0] } ?? []
            )
        )
    }

    func onlyDraft() throws -> TransactionDraft {
        try #require(drafts.first)
    }

    func onlyUpdate() throws -> RecordedTransactionUpdate {
        try #require(updates.first)
    }

    func onlyDelete() throws -> ActualTransaction {
        try #require(deletes.first)
    }

    func onlyRulePreviewDraft() throws -> TransactionDraft {
        try #require(rulePreviewDrafts.first)
    }

    func rulePreviewDraftCount() -> Int {
        rulePreviewDrafts.count
    }

    func draftCount() -> Int {
        drafts.count
    }

    func didCreateFinished() -> Bool {
        didCreateCallbackFinished
    }

    func isPausedBeforeDidCreate() -> Bool {
        pausedBeforeDidCreate
    }

    func resumeBeforeDidCreate() {
        beforeDidCreateContinuation?.resume()
        beforeDidCreateContinuation = nil
    }

    func resumeAfterDidCreate() {
        afterDidCreateContinuation?.resume()
        afterDidCreateContinuation = nil
    }
}

struct RecordedTransactionUpdate: Sendable {
    let transactionID: String
    let draft: TransactionDraft
    let originalAccountID: String
    let originalMonth: String
}

struct TestError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
