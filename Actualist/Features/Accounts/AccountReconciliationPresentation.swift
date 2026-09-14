import Foundation

enum AccountReconciliationCopy {
    static let balancePrompt = "Enter the current balance of your bank account that you want to reconcile with:"
    static let lastBankBalance = "Last Balance from Bank"
    static let useLastSyncedTotal = "Use last synced total"
    static let reconcile = "Reconcile"
}

enum AccountReconciliationAction: Hashable, Sendable {
    case refresh
    case createAdjustment
    case lockTransactions
    case exit
}

enum AccountReconciliationDifferenceTone: Hashable, Sendable {
    case balanced
    case remaining
    case unavailable
}

enum AccountReconciliationPrimaryAction: Hashable, Sendable {
    case createAdjustment
    case lockTransactions
}

struct AccountReconciliationTargetPresentation: Hashable, Sendable {
    let accountName: String
    let amountText: String
    let clearedBalanceText: String
    let lastSyncedBalanceText: String?
    let lastReconciledText: String
    let validationMessage: String?
    let canContinue: Bool
    let isPrivacyProtected: Bool
}

struct AccountReconciliationPanelPresentation: Hashable, Sendable {
    let targetText: String
    let clearedBalanceText: String
    let differenceText: String
    let differenceTone: AccountReconciliationDifferenceTone
    let primaryAction: AccountReconciliationPrimaryAction?
    let submittingAction: AccountReconciliationAction?
    let errorMessage: String?
    let isPrivacyProtected: Bool
}

enum AccountReconciliationPresentation {
    static func target(
        entry: AccountReconciliationTargetEntry,
        currency: BudgetCurrency,
        privacyModeEnabled: Bool,
        locale: Locale = .current
    ) -> AccountReconciliationTargetPresentation {
        let parsedTarget = try? entry.input.minorUnits(currency: currency, locale: locale).get()
        let target = parsedTarget ?? entry.snapshot.clearedBalance
        let enteredAmountText: String
        if let parsedTarget {
            enteredAmountText = currency.formatted(parsedTarget)
        } else if entry.input.text.isEmpty {
            enteredAmountText = currency.formatted(0)
        } else {
            enteredAmountText = entry.input.text
        }
        return AccountReconciliationTargetPresentation(
            accountName: privacyModeEnabled
                ? PrivacyDisplay.name(for: .account, seed: entry.identity.accountID)
                : entry.snapshot.accountName,
            amountText: privacyModeEnabled
                ? amountText(
                    target,
                    seed: "reconciliation-target-entry-\(entry.identity.accountID)",
                    currency: currency,
                    privacyModeEnabled: true
                )
                : enteredAmountText,
            clearedBalanceText: amountText(
                entry.snapshot.clearedBalance,
                seed: "reconciliation-cleared-entry-\(entry.identity.accountID)",
                currency: currency,
                privacyModeEnabled: privacyModeEnabled
            ),
            lastSyncedBalanceText: entry.snapshot.lastSyncedBalance.map {
                amountText(
                    $0,
                    seed: "reconciliation-synced-entry-\(entry.identity.accountID)",
                    currency: currency,
                    privacyModeEnabled: privacyModeEnabled
                )
            },
            lastReconciledText: lastReconciledText(
                entry.snapshot.lastReconciledAt,
                privacyModeEnabled: privacyModeEnabled
            ),
            validationMessage: privacyModeEnabled
                ? "Turn off Sample Values to reconcile with your real balance."
                : entry.validationMessage,
            canContinue: !privacyModeEnabled && parsedTarget != nil,
            isPrivacyProtected: privacyModeEnabled
        )
    }

    static func panel(
        session: AccountReconciliationSession,
        submittingAction: AccountReconciliationAction?,
        errorMessage: String?,
        currency: BudgetCurrency,
        privacyModeEnabled: Bool
    ) -> AccountReconciliationPanelPresentation {
        let calculation = AccountReconciliationCalculation(
            targetBalance: session.targetBalance,
            clearedBalance: session.snapshot.clearedBalance
        )
        let amounts = panelAmounts(
            session: session,
            difference: calculation.difference,
            currency: currency,
            privacyModeEnabled: privacyModeEnabled
        )
        let primaryAction: AccountReconciliationPrimaryAction?
        let tone: AccountReconciliationDifferenceTone
        switch calculation.difference {
        case .some(0):
            primaryAction = .lockTransactions
            tone = .balanced
        case .some:
            primaryAction = .createAdjustment
            tone = .remaining
        case nil:
            primaryAction = nil
            tone = .unavailable
        }
        return AccountReconciliationPanelPresentation(
            targetText: currency.formatted(amounts.target),
            clearedBalanceText: currency.formatted(amounts.cleared),
            differenceText: amounts.difference.map(currency.formatted) ?? "Unavailable",
            differenceTone: tone,
            primaryAction: primaryAction,
            submittingAction: submittingAction,
            errorMessage: errorMessage,
            isPrivacyProtected: privacyModeEnabled
        )
    }

    private static func panelAmounts(
        session: AccountReconciliationSession,
        difference: Int?,
        currency: BudgetCurrency,
        privacyModeEnabled: Bool
    ) -> (target: Int, cleared: Int, difference: Int?) {
        guard privacyModeEnabled else {
            return (session.targetBalance, session.snapshot.clearedBalance, difference)
        }
        let cleared = PrivacyDisplay.amount(
            session.snapshot.clearedBalance,
            seed: "reconciliation-panel-cleared-\(session.identity.accountID)",
            currency: currency,
            maximumDollars: 1_200
        )
        guard let difference else { return (cleared, cleared, nil) }
        guard difference != 0 else { return (cleared, cleared, 0) }
        let privateDifference = PrivacyDisplay.amount(
            difference,
            seed: "reconciliation-panel-difference-\(session.identity.accountID)",
            currency: currency,
            maximumDollars: 250
        )
        return (cleared + privateDifference, cleared, privateDifference)
    }

    private static func amountText(
        _ amount: Int,
        seed: String,
        currency: BudgetCurrency,
        privacyModeEnabled: Bool
    ) -> String {
        guard privacyModeEnabled else { return currency.formatted(amount) }
        return PrivacyDisplay.money(
            amount,
            seed: seed,
            currency: currency,
            maximumDollars: 1_200
        )
    }

    private static func lastReconciledText(
        _ date: Date?,
        privacyModeEnabled: Bool
    ) -> String {
        guard !privacyModeEnabled else { return "Hidden while Sample Values is on" }
        guard let date else { return "Not yet reconciled" }
        return "Reconciled \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
