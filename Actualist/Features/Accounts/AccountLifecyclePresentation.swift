import Foundation

struct AccountLifecycleConsequenceRow: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let value: String
}

struct AccountLifecycleChoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

struct AccountLifecycleReviewPresentation: Hashable, Sendable {
    let accountName: String
    let actionTitle: String?
    let canConfirm: Bool
    let isPrivacyProtected: Bool
    let blockerMessages: [String]
    let rows: [AccountLifecycleConsequenceRow]
    let destinationChoices: [AccountLifecycleChoice]
    let selectedDestinationID: String?
    let showsDestinationPicker: Bool
    let categoryChoices: [AccountLifecycleChoice]
    let selectedCategoryID: String?
    let showsCategoryPicker: Bool
}

enum AccountLifecyclePresentation {
    enum MutationSheet: Equatable {
        case rename, reopen, review
    }

    static func mutationSheet(for state: AccountLifecycleState) -> MutationSheet? {
        switch state {
        case .renaming, .submittingRename, .failed(.rename, _):
            .rename
        case .reopening, .submittingReopen, .failed(.reopen, _):
            .reopen
        case .loadingReview, .refreshingReview, .reviewing, .reviewChanged, .submittingReview, .failed(.review, _):
            .review
        case .completed, .idle:
            nil
        }
    }

    static func review(
        _ review: AccountLifecycleReview,
        currency: BudgetCurrency,
        privacyModeEnabled: Bool
    ) -> AccountLifecycleReviewPresentation {
        let accountName = privacyModeEnabled
            ? PrivacyDisplay.name(for: .account, seed: review.account.id)
            : review.account.name
        let balanceText = privacyModeEnabled
            ? PrivacyDisplay.money(
                review.liveBalance,
                seed: "account-lifecycle-balance-\(review.account.id)",
                currency: currency,
                maximumDollars: 15_000
            )
            : currency.formatted(review.liveBalance)
        var rows = [
            AccountLifecycleConsequenceRow(id: "balance", label: "Balance", value: balanceText),
            AccountLifecycleConsequenceRow(
                id: "transactions",
                label: "Transactions",
                value: String(review.liveTransactionCount)
            ),
        ]
        if let destinationID = review.identity.destinationFacts?.account.id,
           let destination = review.eligibleDestinations.first(where: { $0.id == destinationID }) {
            let name = privacyModeEnabled
                ? PrivacyDisplay.name(for: .account, seed: destination.id)
                : destination.name
            rows.append(AccountLifecycleConsequenceRow(
                id: "destination", label: "Transfer to", value: name
            ))
        }
        if let category = review.identity.categoryFacts?.category {
            let name = privacyModeEnabled
                ? PrivacyDisplay.name(for: .category, seed: category.id)
                : category.name
            rows.append(AccountLifecycleConsequenceRow(
                id: "category", label: "Category", value: name
            ))
        }
        if let bankLink = review.bankLink {
            rows.append(AccountLifecycleConsequenceRow(
                id: "bank", label: "Bank connection", value: bankProviderName(bankLink.provider)
            ))
        }
        if !review.activeScheduleReferences.isEmpty {
            rows.append(AccountLifecycleConsequenceRow(
                id: "schedules",
                label: "Active schedules",
                value: review.activeScheduleReferences.map {
                    privacyModeEnabled ? privateScheduleName(seed: $0.id) : $0.name
                }.joined(separator: ", ")
            ))
            let consequence = review.resolvedAction == .deleteEmptyAccount
                ? "Schedules for this account will stop because it will be deleted."
                : "Schedules for this account pause while it is closed and resume if it is reopened."
            rows.append(AccountLifecycleConsequenceRow(
                id: "schedule-posting", label: "Scheduled posting", value: consequence
            ))
        }

        let actionTitle: String?
        switch review.resolvedAction {
        case .some(.deleteEmptyAccount):
            actionTitle = "Delete Account"
        case .some(.closeAtZero):
            actionTitle = "Close Account"
        case .some(.closeWithTransfer):
            actionTitle = "Transfer and Close"
        case .none:
            actionTitle = nil
        }
        let blockerMessages = review.blockers.map {
            blockerMessage($0)
        }
        return AccountLifecycleReviewPresentation(
            accountName: accountName,
            actionTitle: actionTitle,
            canConfirm: !privacyModeEnabled && review.blockers.isEmpty && review.resolvedAction != nil,
            isPrivacyProtected: privacyModeEnabled,
            blockerMessages: blockerMessages,
            rows: rows,
            destinationChoices: review.eligibleDestinations.map {
                AccountLifecycleChoice(id: $0.id, name: $0.name)
            },
            selectedDestinationID: review.identity.destinationFacts?.account.id,
            showsDestinationPicker: review.liveTransactionCount > 0 && review.liveBalance != 0,
            categoryChoices: review.eligibleCategories.map {
                AccountLifecycleChoice(id: $0.id, name: $0.name)
            },
            selectedCategoryID: review.identity.categoryFacts?.category.id,
            showsCategoryPicker: !review.account.offBudget
                && review.identity.destinationFacts?.account.offBudget == true
        )
    }

    private static func bankProviderName(_ provider: AccountLifecycleBankProvider) -> String {
        switch provider {
        case .simpleFIN: "The bank connection will be removed. Undo in History cannot bring it back."
        case .goCardless: "Unlink GoCardless in the Actual web app first"
        case .pluggyAI: "Unlink Pluggy.ai in the Actual web app first"
        case .akahu: "Unlink Akahu in the Actual web app first"
        case .enableBanking: "Unlink Enable Banking in the Actual web app first"
        case .unknown: "Unlink this bank connection in the Actual web app first"
        }
    }

    private static func blockerMessage(_ blocker: AccountLifecycleBlocker) -> String {
        switch blocker {
        case .accountAlreadyClosed:
            return "This account is already closed."
        case .destinationRequired:
            return "Choose an open account for the remaining balance."
        case .destinationIsSource:
            return "Choose a different destination account."
        case .destinationUnavailable:
            return "The destination account is no longer available."
        case .categoryRequired:
            return "Choose an expense category for this transfer."
        case .categoryUnavailable:
            return "The selected category is no longer available."
        case .unsupportedBankProvider:
            return "Actualist cannot remove this bank connection yet."
        case .scheduleInspectionUnavailable:
            return "Schedules for this account could not be checked. Try again."
        }
    }

    private static func privateScheduleName(seed: String) -> String {
        let suffix = Int((PrivacyDisplay.stableHash("schedule-\(seed)") / 17) % 90) + 10
        return "Sample Schedule \(suffix)"
    }
}
