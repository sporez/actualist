import Foundation
import Testing
@testable import Actualist

struct AccountLifecycleModelsTests {
    @Test func renameInputTrimsSubmittedNameButPinsExactCurrentName() throws {
        let command = try AccountRenameCommand(
            accountID: " checking ",
            expectedCurrentName: " Checking ",
            newName: "  Daily Spending  "
        ).normalized()

        #expect(command.accountID == "checking")
        #expect(command.expectedCurrentName == " Checking ")
        #expect(command.newName == "Daily Spending")
    }

    @Test func renameDraftRejectsBlankAndExactDuplicateButAllowsCaseVariant() {
        let account = lifecycleAccount(id: "checking", name: "Checking")
        let existing = [account, lifecycleAccount(id: "savings", name: "Savings", closed: true)]
        let identity = AccountLifecycleIdentity(budgetID: "budget", accountID: account.id)

        var draft = AccountRenameDraft(
            identity: identity,
            account: account,
            existingAccounts: existing,
            name: "   ",
            validationMessage: nil
        )
        #expect(draft.validationError == .blankName)

        draft.name = " Savings "
        #expect(draft.validationError == .duplicateName("Savings"))

        draft.name = "savings"
        #expect(draft.validationError == nil)
        #expect(draft.command?.newName == "savings")
    }

    @Test func eligibilityExcludesClosedAccountsAndDistinguishesMissingIDs() {
        let open = lifecycleAccount(id: "open", name: "Open")
        let closed = lifecycleAccount(id: "closed", name: "Closed", closed: true)
        let snapshot = AccountEligibilitySnapshot(accounts: [open, closed])

        #expect(snapshot.eligiblePostingAccounts == [open])
        #expect(snapshot.postingEligibility(accountID: "open") == .eligible(open))
        #expect(snapshot.postingEligibility(accountID: "closed") == .closed(closed))
        #expect(snapshot.postingEligibility(accountID: "missing") == .missing(accountID: "missing"))
    }

    @Test func reviewPresentationHidesFinancialIdentityAndRemoteBankValues() throws {
        let account = lifecycleAccount(id: "checking", name: "Checking")
        let category = AccountLifecycleCategory(
            id: "medical-category",
            name: "Confidential Medical",
            isHidden: false
        )
        let schedule = AccountScheduleReference(
            id: "private-schedule",
            name: "Private Therapy Schedule"
        )
        let review = AccountLifecycleReview(
            identity: AccountLifecycleReviewIdentity(
                budgetID: "budget",
                accountID: account.id,
                action: .close(destinationAccountID: nil, categoryID: category.id),
                sourceFacts: AccountLifecycleSourceFacts(
                    account: account,
                    liveBalance: -12_345,
                    liveTransactionCount: 1,
                    liveFamilyCount: 1,
                    pairedTransferCount: 0
                ),
                destinationFacts: nil,
                categoryFacts: AccountLifecycleCategoryFacts(category: category),
                transactionGraphDigest: "digest",
                scheduleDigest: "schedule",
                bankLinkIdentity: AccountLifecycleBankLinkIdentity(
                    remoteAccountID: "remote-secret",
                    syncSource: "simpleFin",
                    bankRowID: "bank-secret"
                )
            ),
            account: account,
            liveBalance: -12_345,
            liveTransactionCount: 1,
            liveFamilyCount: 1,
            pairedTransferCount: 0,
            bankLink: AccountLifecycleBankLink(
                provider: .simpleFIN,
                identity: AccountLifecycleBankLinkIdentity(
                    remoteAccountID: "remote-secret",
                    syncSource: "simpleFin",
                    bankRowID: "bank-secret"
                )
            ),
            activeScheduleReferences: [schedule],
            eligibleDestinations: [],
            eligibleCategories: [category],
            resolvedAction: .closeAtZero,
            blockers: [.activeSchedules([schedule])]
        )

        let presentation = AccountLifecyclePresentation.review(
            review,
            currency: .usd,
            privacyModeEnabled: true
        )
        let unprotectedPresentation = AccountLifecyclePresentation.review(
            review,
            currency: .usd,
            privacyModeEnabled: false
        )
        let joinedCopy = ([presentation.accountName] + presentation.rows.map(\.value)).joined(separator: " ")
        let unprotectedCopy = (
            [unprotectedPresentation.accountName]
                + unprotectedPresentation.rows.map(\.value)
                + unprotectedPresentation.blockerMessages
        ).joined(separator: " ")

        #expect(presentation.accountName != account.name)
        #expect(presentation.rows.first?.value != BudgetCurrency.usd.formatted(-12_345))
        #expect(!joinedCopy.contains("remote-secret"))
        #expect(!joinedCopy.contains("bank-secret"))
        #expect(!joinedCopy.contains(category.name))
        #expect(!joinedCopy.contains(schedule.name))
        #expect(!presentation.blockerMessages.joined().contains(schedule.name))
        #expect(presentation.isPrivacyProtected)
        #expect(!presentation.canConfirm)
        #expect(unprotectedCopy.contains(category.name))
        #expect(unprotectedCopy.contains(schedule.name))
        #expect(!unprotectedPresentation.isPrivacyProtected)
    }

    private func lifecycleAccount(
        id: String,
        name: String,
        closed: Bool = false
    ) -> AccountLifecycleAccount {
        AccountLifecycleAccount(
            id: id,
            name: name,
            offBudget: false,
            isClosed: closed,
            accountGroupID: "group"
        )
    }
}
