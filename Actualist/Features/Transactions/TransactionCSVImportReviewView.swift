import SwiftUI

/// Review surface for the CSV import workflow. Displays already-decided
/// dispositions and calls coordinator intents; amounts come pre-decided from
/// the parsed rows through the shared review formatting helper.
struct TransactionCSVImportReviewView: View {
    @Bindable var coordinator: TransactionCSVImportCoordinator
    let repository: any TransactionCSVImportRepositoryProtocol
    let currency: BudgetCurrency
    let isPrivacyModeEnabled: Bool
    let onCancel: () -> Void

    var body: some View {
        switch coordinator.state {
        case .idle:
            EmptyView()
        case .loading:
            TransactionCommandProgressSheet(
                title: "Reading File",
                message: "Checking the CSV rows against this account…"
            )
        case .reviewing(let review):
            reviewSheet(review)
        case .submitting:
            TransactionCommandProgressSheet(
                title: "Importing",
                message: "The selected rows are being saved together…"
            )
        case .completed(let result):
            TransactionCommandCommittedSheet(
                message: Self.completionMessage(result),
                onDone: onCancel
            )
        case .failed(let message):
            failureSheet(message)
        }
    }

    private func reviewSheet(_ review: TransactionCSVImportReview) -> some View {
        VStack(spacing: 0) {
            ReviewSheetContent {
                ReviewSheetHeader(
                    title: "Import CSV",
                    subtitle: "Review the rows before anything is added to this account."
                )
                .accessibilityIdentifier("transaction-csv-import-review")

                if let summary = coordinator.summary {
                    VStack(spacing: 8) {
                        ReviewSummaryRow(
                            title: "New rows",
                            value: "\(summary.insert)",
                            symbol: "plus.square"
                        )
                        ReviewSummaryRow(
                            title: "Existing rows updated",
                            value: "\(summary.update)",
                            symbol: "pencil.line"
                        )
                        ReviewSummaryRow(
                            title: "Duplicates left unchanged",
                            value: "\(summary.ignored + summary.skipped)",
                            symbol: "checkmark.circle"
                        )
                    }
                    .actualistReviewCard()
                }

                ForEach(review.rows) { row in
                    importRow(row)
                }
            }

            ReviewSheetActions {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("transaction-csv-import-cancel")
                Button(coordinator.submitTitle) {
                    Task { await coordinator.submit(repository: repository) }
                }
                .buttonStyle(.glassProminent)
                .tint(ActualistTheme.accent)
                .disabled(!coordinator.canSubmit)
                .accessibilityIdentifier("transaction-csv-import-confirm")
            }
        }
        .background(ActualistTheme.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func importRow(_ row: TransactionCSVImportReviewRow) -> some View {
        let amount = TransactionCommandReviewFormatting.amountText(
            row.row.amountMinorUnits,
            seed: row.id,
            currency: currency,
            isPrivacyModeEnabled: isPrivacyModeEnabled
        )
        let context = "\(row.row.dateText) · \(amount)"
        if coordinator.isIncluded(row) || coordinator.isToggleable(row) {
            Button {
                coordinator.toggleIncluded(row)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: coordinator.isIncluded(row) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(coordinator.isIncluded(row) ? ActualistTheme.accent : ActualistTheme.secondaryText)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Self.dispositionTitle(row.disposition))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ActualistTheme.primaryText)
                        Text(context)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(ActualistTheme.secondaryText)
                        if let payee = TransactionCommandReviewFormatting.note(
                            row.row.payeeName.isEmpty ? nil : row.row.payeeName,
                            isPrivacyModeEnabled: isPrivacyModeEnabled
                        ) {
                            Text(payee)
                                .font(.caption)
                                .foregroundStyle(ActualistTheme.secondaryText)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .font(.subheadline)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("transaction-csv-import-row-\(row.id)")
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ActualistTheme.secondaryText)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.dispositionTitle(row.disposition))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ActualistTheme.secondaryText)
                    Text(context)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("transaction-csv-import-row-\(row.id)")
        }
    }

    private func failureSheet(_ message: String) -> some View {
        VStack(spacing: 0) {
            ReviewSheetContent {
                ReviewSheetHeader(
                    title: "Couldn't Import",
                    subtitle: message
                )
                .accessibilityIdentifier("transaction-csv-import-failed")
            }
            ReviewSheetActions {
                Button("OK", action: onCancel)
                    .buttonStyle(.glass)
            }
        }
        .background(ActualistTheme.background)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    static func dispositionTitle(_ disposition: TransactionCSVImportDisposition) -> String {
        switch disposition {
        case .insert(let isTransfer):
            return isTransfer ? "New transfer" : "New row"
        case .update:
            return "Update existing row"
        case .ignored:
            return "Duplicate, unchanged"
        case .skippedReconciled:
            return "Matches a reconciled row"
        }
    }

    private static func completionMessage(_ result: TransactionCSVImportApplyResult) -> String {
        var parts: [String] = []
        if result.insertedCount > 0 {
            parts.append("\(result.insertedCount) new row\(result.insertedCount == 1 ? "" : "s") added")
        }
        if result.updatedCount > 0 {
            parts.append("\(result.updatedCount) existing row\(result.updatedCount == 1 ? "" : "s") updated")
        }
        guard !parts.isEmpty else {
            return "Nothing needed to change. Every row in the file was already saved."
        }
        return parts.joined(separator: " and ") + "."
    }
}
