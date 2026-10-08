import SwiftUI

struct TransactionBatchReviewSheet: View {
    @Environment(\.locale) private var locale

    let review: TransactionBatchReview
    let isPrivacyModeEnabled: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        let display = TransactionBatchReviewDisplay(
            review: review,
            locale: locale,
            isPrivacyModeEnabled: isPrivacyModeEnabled
        )
        ReviewSheetContent {
            ReviewSheetHeader(
                title: display.title,
                subtitle: "These are the exact transactions and stored changes that will be saved together."
            )

            VStack(spacing: 8) {
                ReviewSummaryRow(
                    title: "Selected transactions",
                    value: display.selectedCountText,
                    symbol: "checkmark.circle"
                )
                ReviewSummaryRow(
                    title: "Rows changing",
                    value: display.changedCountText,
                    symbol: "arrow.left.arrow.right"
                )
                if let skipped = display.skippedCountText {
                    ReviewSummaryRow(
                        title: "Skipped",
                        value: skipped,
                        symbol: "minus.circle",
                        valueColor: ActualistTheme.secondaryText
                    )
                }
                if let blocked = display.blockedCountText {
                    ReviewSummaryRow(
                        title: "Blocked",
                        value: blocked,
                        symbol: "exclamationmark.circle",
                        valueColor: ActualistTheme.danger
                    )
                }
            }
            .actualistReviewCard()

            if let warning = display.authorizationMessage {
                Label(warning, systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ActualistTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .actualistReviewCard()
            }

            TransactionHistoryUndoHint()

            LazyVStack(spacing: 10) {
                ForEach(display.rows) { row in
                    transactionCard(row)
                }
            }
        }
        .reviewSheetBottomBar {
            ReviewSheetSecondaryButton(action: onCancel)

            ReviewSheetPrimaryButton(tint: confirmTint, action: onConfirm) {
                Text(display.confirmationTitle)
            }
            .disabled(!display.canSubmit)
        }
        .background(ActualistTheme.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func transactionCard(_ row: TransactionBatchReviewDisplay.Row) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let member = row.member {
                memberHeader(member, status: row.status, tone: row.tone)
                effectList(member.effects)
            } else {
                unavailableHeader(status: row.status, tone: row.tone)
            }

            if let explanation = row.explanation {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(toneColor(row.tone))
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(row.linkedMembers) { member in
                VStack(alignment: .leading, spacing: 8) {
                    memberHeader(member, status: member.relation, tone: .warning)
                    effectList(member.effects)
                }
                .padding(.top, 10)
                .overlay(alignment: .top) { ActualistTheme.separator.frame(height: 1) }
            }
        }
        .actualistReviewCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transaction-batch-review-row-\(row.id)")
    }

    private func unavailableHeader(
        status: String,
        tone: TransactionBatchReviewDisplay.Tone
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label("Transaction unavailable", systemImage: "questionmark.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ActualistTheme.primaryText)
            Spacer(minLength: 8)
            Text(status)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(toneColor(tone))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func memberHeader(
        _ member: TransactionBatchReviewDisplay.Member,
        status: String?,
        tone: TransactionBatchReviewDisplay.Tone
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                memberIdentity(member)
                Spacer(minLength: 8)
                amountAndStatus(member.amount, status: status, tone: tone, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 8) {
                memberIdentity(member)
                amountAndStatus(member.amount, status: status, tone: tone, alignment: .leading)
            }
        }
    }

    private func memberIdentity(_ member: TransactionBatchReviewDisplay.Member) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(member.payee)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ActualistTheme.primaryText)
            Text(member.context)
                .font(.caption)
                .foregroundStyle(ActualistTheme.secondaryText)
            if let note = member.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .lineLimit(2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func amountAndStatus(
        _ amount: String,
        status: String?,
        tone: TransactionBatchReviewDisplay.Tone,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(amount)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(ActualistTheme.primaryText)
            if let status {
                Text(status)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(toneColor(tone))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func effectList(_ effects: [TransactionBatchReviewDisplay.Effect]) -> some View {
        if effects.isEmpty {
            Text("No stored values will change.")
                .font(.caption)
                .foregroundStyle(ActualistTheme.secondaryText)
        } else {
            VStack(spacing: 6) {
                ForEach(effects) { effect in
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(effect.title)
                            Spacer(minLength: 8)
                            Text("\(effect.before) → \(effect.after)")
                                .multilineTextAlignment(.trailing)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(effect.title)
                            Text("\(effect.before) → \(effect.after)")
                                .foregroundStyle(ActualistTheme.primaryText)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Delete removes real transactions, so its confirm reads as destructive;
    /// the other batch intents stay accent-tinted.
    private var confirmTint: Color {
        review.intent == .delete ? ActualistTheme.danger : ActualistTheme.accent
    }

    private func toneColor(_ tone: TransactionBatchReviewDisplay.Tone) -> Color {
        switch tone {
        case .normal: ActualistTheme.primaryText
        case .positive: ActualistTheme.accent
        case .warning: ActualistTheme.warning
        case .danger: ActualistTheme.danger
        case .secondary: ActualistTheme.secondaryText
        }
    }
}
