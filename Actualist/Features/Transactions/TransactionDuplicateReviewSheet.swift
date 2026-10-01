import SwiftUI

struct TransactionDuplicateCommandSheet: View {
    @Bindable var coordinator: TransactionDuplicateCoordinator
    let currency: BudgetCurrency
    let isPrivacyModeEnabled: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void
    let onDone: () -> Void

    var body: some View {
        switch coordinator.state {
        case .preparing:
            TransactionCommandProgressSheet(
                title: "Preparing Review",
                message: "Checking the selected transaction rows…"
            )
        case .reviewing(let review):
            TransactionDuplicateReviewSheet(
                review: review,
                currency: currency,
                isPrivacyModeEnabled: isPrivacyModeEnabled,
                onCancel: onCancel,
                onConfirm: onConfirm
            )
        case .submitting:
            TransactionCommandProgressSheet(
                title: "Saving Changes",
                message: "The selected copies are being saved together…"
            )
        case .committed(let outcome):
            TransactionCommandCommittedSheet(
                message: Self.completionMessage(outcome),
                onDone: onDone
            )
        case .idle, .failed:
            EmptyView()
        }
    }

    private static func completionMessage(_ outcome: TransactionDuplicateOutcome) -> String {
        guard outcome.sessionCurrent else {
            return "Copies were saved, but this budget is no longer open. Reopen it to see the new transactions."
        }
        if outcome.refreshPending {
            return "Copies were saved. The transaction list is refreshing. You can undo them together in Budget → History."
        }
        return "The selected transactions were duplicated. You can undo them together in Budget → History."
    }
}

struct TransactionDuplicateReviewSheet: View {
    @Environment(\.locale) private var locale

    let review: TransactionDuplicateReview
    let currency: BudgetCurrency
    let isPrivacyModeEnabled: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        let display = TransactionDuplicateReviewDisplay(
            review: review,
            currency: currency,
            locale: locale,
            isPrivacyModeEnabled: isPrivacyModeEnabled
        )
        VStack(spacing: 0) {
            ReviewSheetContent {
                ReviewSheetHeader(title: display.title, subtitle: display.subtitle)
                    .accessibilityIdentifier("transaction-duplicate-review")

                VStack(spacing: 8) {
                    ReviewSummaryRow(
                        title: "Selected transactions",
                        value: display.selectedCountText,
                        symbol: "checkmark.circle"
                    )
                    ReviewSummaryRow(
                        title: "Copies",
                        value: display.copyCountText,
                        symbol: "plus.square.on.square"
                    )
                }
                .actualistReviewCard()

                if let familyMessage = display.familyDeduplicationMessage {
                    Text(familyMessage)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(ActualistTheme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .actualistReviewCard()
                        .accessibilityIdentifier("transaction-duplicate-family-deduplication")
                }

                if let unavailable = display.unavailableMessage {
                    Text(unavailable)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(ActualistTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .actualistReviewCard()
                }

                ForEach(display.groups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ActualistTheme.primaryText)
                        ForEach(group.rows) { row in
                            duplicateRow(row)
                        }
                    }
                    .actualistReviewCard()
                }
            }

            ReviewSheetActions {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.glass)
                Button(display.confirmationTitle, action: onConfirm)
                    .buttonStyle(.glassProminent)
                    .tint(ActualistTheme.accent)
                    .disabled(!display.canSubmit)
                    .accessibilityIdentifier("transaction-duplicate-confirm")
            }
        }
        .background(ActualistTheme.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func duplicateRow(_ row: TransactionDuplicateReviewDisplay.Row) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.role)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ActualistTheme.primaryText)
            Text(row.context)
                .font(.caption)
                .foregroundStyle(ActualistTheme.secondaryText)
            Text(row.amount)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(ActualistTheme.primaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transaction-duplicate-row-\(row.id)")
    }
}
