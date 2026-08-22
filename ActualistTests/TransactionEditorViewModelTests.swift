import Foundation
import Testing
@testable import Actualist

@MainActor
struct TransactionEditorViewModelTests {
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
        model.selectCategory(TransactionEditorCategoryOption(id: "income", title: "Income", amount: nil, valueText: nil))
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

    @Test func applyShortcutPrefillSetsPayeeCategoryAndAmount() {
        let model = TransactionEditorViewModel()
        model.applyShortcutPrefill(
            ShortcutEditorPrefill(
                accountID: "checking",
                amountMinorUnits: 1_250,
                payeeID: "coffee",
                payeeName: "Coffee Shop",
                categoryID: "groceries",
                categoryName: "Groceries",
                notes: "Latte",
                direction: .spend
            )
        )

        #expect(model.kind == .spend)
        #expect(model.amountDigits == "1250")
        #expect(model.selectedAccountID == "checking")
        #expect(model.selectedPayeeID == "coffee")
        #expect(model.payeeName == "Coffee Shop")
        #expect(model.selectedCategoryID == "groceries")
        #expect(model.selectedCategoryName == "Groceries")
        #expect(model.notes == "Latte")
    }

    @Test func applyShortcutPrefillResolvesCategoryNameWhenOptionsLoad() {
        let model = TransactionEditorViewModel()
        model.applyShortcutPrefill(ShortcutEditorPrefill(categoryName: "Dining"))
        #expect(model.selectedCategoryID == nil)
        #expect(model.selectedCategoryName == "Dining")

        model.apply(
            TransactionEditorOptions(
                accounts: [],
                categories: [
                    ActualCategory(id: "dining", name: "Dining", isIncome: false, hidden: false, groupID: "group")
                ],
                categoryGroups: [],
                payees: []
            ),
            loadedMonth: "2026-07"
        )
        #expect(model.selectedCategoryID == "dining")
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

    @Test func delayedRulePreviewDoesNotReplaceActiveSplitSelection() async {
        let model = configuredModel()
        model.selectedPayeeID = "target"
        model.payeeName = "Target"
        model.selectCategory(
            TransactionEditorCategoryOption(
                id: "groceries",
                title: "Groceries",
                amount: nil,
                valueText: nil
            )
        )
        let repository = RecordingTransactionRepository(
            rulePreview: TransactionRulePreview(categoryID: "household", notes: "rule note"),
            pausedRulePreviewPayeeNames: ["Target"]
        )

        let preview = Task {
            await model.previewRules(budgetID: "budget", repository: repository)
        }
        while await !repository.isRulePreviewPaused(payeeName: "Target") {
            await Task.yield()
        }
        model.beginSplitSelection()
        await repository.resumeRulePreview(payeeName: "Target")
        await preview.value

        #expect(model.isSelectingSplit)
        #expect(model.selectedCategoryID == "groceries")
        #expect(model.notes == "  weekly groceries  ")
    }

    @Test func delayedRulePreviewDoesNotApplyAfterBudgetChanges() async {
        let model = configuredModel()
        model.selectedPayeeID = "target"
        model.payeeName = "Target"
        let repository = RecordingTransactionRepository(
            rulePreview: TransactionRulePreview(categoryID: "groceries", notes: "rule note"),
            pausedRulePreviewPayeeNames: ["Target"]
        )
        var currentBudgetID = "budget"

        let preview = Task {
            await model.previewRules(
                budgetID: "budget",
                repository: repository,
                currentBudgetID: { currentBudgetID }
            )
        }
        while await !repository.isRulePreviewPaused(payeeName: "Target") {
            await Task.yield()
        }
        currentBudgetID = "other"
        await repository.resumeRulePreview(payeeName: "Target")
        await preview.value

        #expect(model.selectedCategoryID == nil)
        #expect(model.notes == "  weekly groceries  ")
    }

    @Test func rulePreviewFeedsEnteredPayeeNameAsImportedPayeeForManualEntry() async throws {
        // Manually-added transactions have no real imported payee, but the rules
        // Actual creates when categorizing an imported transaction match on
        // `imported_payee`. The preview draft must feed the entered payee name as
        // the imported-payee text so those rules fire; the saved draft keeps nil.
        let model = TransactionEditorViewModel()
        model.kind = .spend
        model.amountDigits = "4999"
        model.selectedAccountID = "checking"
        model.payeeName = "1Password"
        model.selectedPayeeID = nil
        model.date = Self.date("2026-08-12")
        let repository = RecordingTransactionRepository(
            rulePreview: TransactionRulePreview(categoryID: "subscriptions", notes: nil)
        )

        await model.previewRules(budgetID: "budget", repository: repository)

        let previewDraft = try await repository.onlyRulePreviewDraft()
        #expect(previewDraft.payeeName == "1Password")
        #expect(previewDraft.importedPayee == "1Password")

        // The submitted transaction must not record a fake imported payee.
        #expect(await model.submit(budgetID: "budget", repository: repository))
        let savedDraft = try await repository.onlyDraft()
        #expect(savedDraft.importedPayee == nil)
    }

    @Test func rulePreviewKeepsRealImportedPayeeWhenEditingImportedTransaction() async throws {
        let model = TransactionEditorViewModel(
            editing: ActualTransaction(
                id: "txn-imp",
                account: "checking",
                date: "2026-08-12",
                amount: -4999,
                payee: "onepass",
                payeeName: "1Password",
                importedPayee: "1PASSWORD*SUBSCRIPTION",
                category: nil,
                notes: nil,
                cleared: .bool(false)
            )
        )
        model.amountDigits = "4999"
        let repository = RecordingTransactionRepository(
            rulePreview: TransactionRulePreview(categoryID: "subscriptions", notes: nil)
        )

        await model.previewRules(budgetID: "budget", repository: repository)

        let previewDraft = try await repository.onlyRulePreviewDraft()
        #expect(previewDraft.importedPayee == "1PASSWORD*SUBSCRIPTION")
    }

    @Test func applyRespectsPreferredAccountOrder() {
        let model = TransactionEditorViewModel()
        let accounts = [
            ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false),
            ActualAccount(id: "savings", name: "Savings", offbudget: false, closed: false),
            ActualAccount(id: "credit", name: "Credit Card", offbudget: false, closed: false)
        ]

        model.apply(
            TransactionEditorOptions(accounts: accounts, categories: [], categoryGroups: [], payees: []),
            loadedMonth: "2026-09",
            preferredAccountIDs: ["savings", "credit", "checking"]
        )

        #expect(model.accounts.map(\.id) == ["savings", "credit", "checking"])
    }

    @Test func applyPreservesOriginalOrderWhenNoPreference() {
        let model = TransactionEditorViewModel()
        let accounts = [
            ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false),
            ActualAccount(id: "savings", name: "Savings", offbudget: false, closed: false)
        ]

        model.apply(
            TransactionEditorOptions(accounts: accounts, categories: [], categoryGroups: [], payees: []),
            loadedMonth: "2026-09"
        )

        #expect(model.accounts.map(\.id) == ["checking", "savings"])
    }

    @Test func applyAppendsUnknownPreferredIDsAtEnd() {
        let model = TransactionEditorViewModel()
        let accounts = [
            ActualAccount(id: "checking", name: "Checking", offbudget: false, closed: false),
            ActualAccount(id: "savings", name: "Savings", offbudget: false, closed: false)
        ]

        model.apply(
            TransactionEditorOptions(accounts: accounts, categories: [], categoryGroups: [], payees: []),
            loadedMonth: "2026-09",
            preferredAccountIDs: ["savings", "deleted-account"]
        )

        #expect(model.accounts.map(\.id) == ["savings", "checking"])
    }
}
