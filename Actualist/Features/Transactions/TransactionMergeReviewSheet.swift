import SwiftUI

struct TransactionMergeCommandSheet: View {
    @Bindable var coordinator: TransactionMergeCoordinator
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
        case .reviewing(let reviewed):
            TransactionMergeReviewSheet(
                review: reviewed.review,
                currency: currency,
                isPrivacyModeEnabled: isPrivacyModeEnabled,
                onCancel: onCancel,
                onConfirm: onConfirm
            )
        case .submitting:
            TransactionCommandProgressSheet(
                title: "Saving Changes",
                message: "The selected transactions are being merged…"
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

    private static func completionMessage(_ outcome: TransactionMergeOutcome) -> String {
        guard outcome.sessionCurrent else {
            return "The merge was saved, but this budget is no longer open. Reopen it to see the updated transactions."
        }
        if outcome.refreshPending {
            return "The merge was saved. The transaction list is refreshing. You can undo it in Budget → History."
        }
        return "The selected transactions were merged. You can undo them together in Budget → History."
    }
}

struct TransactionMergeReviewSheet: View {
    @Environment(\.locale) private var locale

    let review: TransactionMergeReview
    let currency: BudgetCurrency
    let isPrivacyModeEnabled: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        let display = TransactionMergeReviewDisplay(
            review: review,
            locale: locale,
            currency: currency,
            isPrivacyModeEnabled: isPrivacyModeEnabled
        )
        ReviewSheetContent {
            ReviewSheetHeader(title: display.title, subtitle: display.subtitle)
                .accessibilityIdentifier("transaction-merge-review")

            VStack(spacing: 8) {
                ReviewSummaryRow(
                    title: "Selected transactions",
                    value: display.inputCountText,
                    symbol: "checkmark.circle"
                )
                if let kept = display.keptLabel {
                    ReviewSummaryRow(
                        title: "Kept",
                        value: kept,
                        symbol: "checkmark.circle",
                        valueColor: ActualistTheme.accent
                    )
                }
                if let dropped = display.droppedLabel {
                    ReviewSummaryRow(
                        title: "Dropped",
                        value: dropped,
                        symbol: "minus.circle",
                        valueColor: ActualistTheme.secondaryText
                    )
                }
            }
            .actualistReviewCard()

            if let blocked = display.blockedMessage {
                Label(blocked, systemImage: "exclamationmark.circle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ActualistTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .actualistReviewCard()
                    .accessibilityIdentifier("transaction-merge-blocked-reason")
            }

            if let warning = display.authorizationMessage {
                Label(warning, systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ActualistTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .actualistReviewCard()
                    .accessibilityIdentifier("transaction-merge-reconciled-warning")
            }

            ForEach(display.inputs) { input in
                inputCard(input, effects: input.isKept ? display.keptEffects : [])
            }
        }
        .reviewSheetBottomBar {
            Button(role: .cancel, action: onCancel) {
                Text("Cancel")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 32)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.glass)

            Button(action: onConfirm) {
                Text(display.confirmationTitle)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent)
            .tint(ActualistTheme.accent)
            .disabled(!display.canSubmit)
            .accessibilityIdentifier("transaction-merge-confirm")
        }
        .background(ActualistTheme.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func inputCard(
        _ input: TransactionMergeReviewDisplay.Input,
        effects: [TransactionMergeReviewDisplay.Effect]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(input.positionLabel)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    outcomeLabel(input.outcomeLabel, isKept: input.isKept)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(input.positionLabel)
                        .font(.subheadline.weight(.semibold))
                    outcomeLabel(input.outcomeLabel, isKept: input.isKept)
                }
            }
            .foregroundStyle(ActualistTheme.primaryText)

            if let role = input.role, let context = input.context, let amount = input.amount {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        mergeIdentity(role: role, context: context)
                        Spacer(minLength: 8)
                        mergeAmount(amount)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        mergeIdentity(role: role, context: context)
                        mergeAmount(amount)
                    }
                }
                if let note = input.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .lineLimit(2)
                }
            }

            Text(input.detail)
                .font(.caption)
                .foregroundStyle(ActualistTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if !effects.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(effects) { effect in
                        Text("\(effect.title): \(effect.value)")
                            .font(.caption)
                            .foregroundStyle(ActualistTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .actualistReviewCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transaction-merge-input-\(input.position)-\(input.id)")
    }

    private func mergeIdentity(role: String, context: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(role)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ActualistTheme.secondaryText)
            Text(context)
                .font(.caption)
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func mergeAmount(_ amount: String) -> some View {
        Text(amount)
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(ActualistTheme.primaryText)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func outcomeLabel(_ label: String?, isKept: Bool) -> some View {
        if let label {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isKept ? ActualistTheme.accent : ActualistTheme.secondaryText)
                .accessibilityIdentifier(isKept ? "transaction-merge-kept" : "transaction-merge-dropped")
        }
    }
}

struct TransactionCommandProgressSheet: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            ReviewSheetHeader(title: title)
            ProgressView(message)
                .frame(maxWidth: .infinity)
                .actualistReviewCard()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(ActualistTheme.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct TransactionCommandCommittedSheet: View {
    let message: String
    let onDone: () -> Void

    var body: some View {
        ReviewSheetContent {
            ReviewSheetHeader(title: "Changes Saved")
            Text(message)
                .font(.subheadline)
                .foregroundStyle(ActualistTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .actualistReviewCard()
        }
        .reviewSheetBottomBar {
            Button(action: onDone) {
                Text("Done")
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent)
            .tint(ActualistTheme.accent)
        }
        .background(ActualistTheme.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
