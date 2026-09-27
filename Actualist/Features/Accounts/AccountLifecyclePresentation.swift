import Foundation

struct AccountLifecycleConsequenceRow: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let value: String
}

struct AccountLifecycleReviewPresentation: Hashable, Sendable {
    let accountName: String
    let title: String
    let actionTitle: String?
    let canConfirm: Bool
    let isPrivacyProtected: Bool
    let blockerMessages: [String]
    let rows: [AccountLifecycleConsequenceRow]
}

enum AccountLifecyclePresentation {
    enum MutationSheet: Equatable {
        case rename, reopen, savedRefreshPending
    }

    static func mutationSheet(for state: AccountLifecycleState) -> MutationSheet? {
        switch state {
        case .renaming, .submittingRename, .failed(.rename, _):
            .rename
        case .reopening, .submittingReopen, .failed(.reopen, _):
            .reopen
        case .completed(let outcome):
            outcome.refreshPending ? .savedRefreshPending : nil
        case .idle, .loadingReview, .reviewing, .failed(.review, _):
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
        }

        let actionTitle: String?
        let title: String
        switch review.resolvedAction {
        case .some(.deleteEmptyAccount):
            title = "Delete Empty Account"
            actionTitle = "Delete Account"
        case .some(.closeAtZero):
            title = "Close Account"
            actionTitle = "Close Account"
        case .some(.closeWithTransfer):
            title = "Transfer Balance and Close"
            actionTitle = "Transfer and Close"
        case .none:
            title = "Review Account"
            actionTitle = nil
        }
        let blockerMessages = review.blockers.map {
            blockerMessage($0, privacyModeEnabled: privacyModeEnabled)
        }
        return AccountLifecycleReviewPresentation(
            accountName: accountName,
            title: title,
            actionTitle: actionTitle,
            canConfirm: !privacyModeEnabled && review.blockers.isEmpty && review.resolvedAction != nil,
            isPrivacyProtected: privacyModeEnabled,
            blockerMessages: blockerMessages,
            rows: rows
        )
    }

    private static func bankProviderName(_ provider: AccountLifecycleBankProvider) -> String {
        switch provider {
        case .simpleFIN: "SimpleFIN connection will be removed"
        case .goCardless: "GoCardless connection will be removed"
        case .pluggyAI: "Pluggy.ai connection will be removed"
        case .akahu: "Akahu connection will be removed"
        case .enableBanking: "Enable Banking connection will be removed"
        case .unknown: "Unsupported connection"
        }
    }

    private static func blockerMessage(
        _ blocker: AccountLifecycleBlocker,
        privacyModeEnabled: Bool
    ) -> String {
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
            return "This bank connection cannot be removed safely yet."
        case .activeSchedules(let schedules):
            let names = schedules.map {
                privacyModeEnabled ? privateScheduleName(seed: $0.id) : $0.name
            }
            return "Active schedules still use this account: \(names.joined(separator: ", "))."
        case .scheduleInspectionUnavailable:
            return "Active schedules could not be checked."
        }
    }

    private static func privateScheduleName(seed: String) -> String {
        let suffix = Int((PrivacyDisplay.stableHash("schedule-\(seed)") / 17) % 90) + 10
        return "Sample Schedule \(suffix)"
    }
}
