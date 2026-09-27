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
    let blockerMessages: [String]
    let rows: [AccountLifecycleConsequenceRow]
}

enum AccountLifecyclePresentation {
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
            rows.append(AccountLifecycleConsequenceRow(
                id: "category", label: "Category", value: category.name
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
                value: review.activeScheduleReferences.map(\.name).joined(separator: ", ")
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
        let blockerMessages = review.blockers.map(blockerMessage)
        return AccountLifecycleReviewPresentation(
            accountName: accountName,
            title: title,
            actionTitle: actionTitle,
            canConfirm: !privacyModeEnabled && review.blockers.isEmpty && review.resolvedAction != nil,
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

    private static func blockerMessage(_ blocker: AccountLifecycleBlocker) -> String {
        switch blocker {
        case .accountAlreadyClosed:
            "This account is already closed."
        case .destinationRequired:
            "Choose an open account for the remaining balance."
        case .destinationIsSource:
            "Choose a different destination account."
        case .destinationUnavailable:
            "The destination account is no longer available."
        case .categoryRequired:
            "Choose an expense category for this transfer."
        case .categoryUnavailable:
            "The selected category is no longer available."
        case .unsupportedBankProvider:
            "This bank connection cannot be removed safely yet."
        case .activeSchedules(let schedules):
            "Active schedules still use this account: \(schedules.map(\.name).joined(separator: ", "))."
        case .scheduleInspectionUnavailable:
            "Active schedules could not be checked."
        }
    }
}
