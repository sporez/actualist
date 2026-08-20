import Foundation
import Testing
@testable import Actualist

@MainActor
extension TransactionEditorViewModelTests {
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

    @Test func allowsCustomPayeeName() {
        let model = TransactionEditorViewModel()
        model.payees = [
            ActualPayee(id: "amazon", name: "Amazon", category: nil, transferAccount: nil),
            ActualPayee(id: "target", name: "Target", category: nil, transferAccount: nil)
        ]

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

        let sections = model.payeeSections

        #expect(sections.map(\.kind) == [.payees, .transfers])
        #expect(sections.first?.options.map(\.title) == ["Corner Store"])
        #expect(sections.last?.options.map(\.title) == ["Ally Checking"])
    }

    @Test func payeeSectionsHideUnresolvedBlankTransferPayees() {
        let model = TransactionEditorViewModel()
        model.payees = [
            ActualPayee(id: "store", name: "Corner Store", category: nil, transferAccount: nil),
            ActualPayee(id: "blank-transfer", name: "", category: nil, transferAccount: "missing-account")
        ]

        let sections = model.payeeSections

        #expect(sections.map(\.kind) == [.payees])
        #expect(sections.first?.options.map(\.title) == ["Corner Store"])
    }

    @Test func sharedPayeePickerMatchesTitlesAliasesAndTransferHeading() {
        let regular = PayeePickerItem(
            id: "coffee",
            title: "Coffee Lab",
            searchAliases: ["Imported Coffee Merchant"]
        )
        let transfer = PayeePickerItem(
            id: "transfer-checking",
            title: "Ally Checking",
            isTransfer: true
        )

        #expect(regular.matches(searchText: "coffee lab"))
        #expect(regular.matches(searchText: "imported"))
        #expect(!regular.matches(searchText: "transfer"))
        #expect(transfer.matches(searchText: "transfer"))
        #expect(transfer.matches(searchText: " ally "))
        #expect(regular.matches(searchText: ""))
    }

    @Test func sharedPayeePickerProjectsSearchOrderingAndCustomSuppression() {
        let items = [
            PayeePickerItem(id: "street", title: "37 Bow Street"),
            PayeePickerItem(id: "coffee", title: "Coffee Lab", searchAliases: ["Imported Coffee"]),
            PayeePickerItem(id: "transfer", title: "Ally Checking", isTransfer: true)
        ]

        let transferSearch = PayeePickerProjection(items: items, searchText: "tr")
        #expect(transferSearch.sections.map(\.id) == ["transfers", "payees"])
        #expect(transferSearch.sections[0].items.map(\.title) == ["Ally Checking"])
        #expect(transferSearch.sections[1].items.map(\.title) == ["37 Bow Street"])

        #expect(!PayeePickerProjection(items: items, searchText: "Coffee Lab").shouldOfferCustomPayee)
        #expect(!PayeePickerProjection(items: items, searchText: "Imported Coffee").shouldOfferCustomPayee)
        #expect(PayeePickerProjection(items: items, searchText: "Local Coffee").shouldOfferCustomPayee)
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
        model.selectCategory(TransactionEditorCategoryOption(id: "groceries", title: "Groceries", amount: nil, valueText: nil))
        model.beginSplitSelection()
        model.toggleSplitCategory(TransactionEditorCategoryOption(id: "household", title: "Household", amount: nil, valueText: nil))
        model.finalizeSplitSelection()
        model.setSplitAmount(rowID: "groceries", value: "500")
        model.setSplitAmount(rowID: "household", value: "734")
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
        model.selectCategory(TransactionEditorCategoryOption(id: "investments", title: "Investments", amount: nil, valueText: nil))
        model.beginSplitSelection()
        model.toggleSplitCategory(TransactionEditorCategoryOption(id: "fees", title: "Fees", amount: nil, valueText: nil))
        model.finalizeSplitSelection()
        model.setSplitAmount(rowID: "investments", value: "617")
        model.setSplitAmount(rowID: "fees", value: "617")

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
        model.clearCategory()
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
        model.selectCategory(TransactionEditorCategoryOption(id: "groceries", title: "Groceries", amount: nil, valueText: nil))
        model.beginSplitSelection()
        model.toggleSplitCategory(TransactionEditorCategoryOption(id: "household", title: "Household", amount: nil, valueText: nil))
        model.finalizeSplitSelection()
        model.setSplitAmount(rowID: "groceries", value: "500")
        model.setSplitAmount(rowID: "household", value: "734")
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
}
