import SwiftUI

struct TransactionScheduleConversionReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: TransactionScheduleConversionCoordinator
    let repository: any TransactionScheduleConversionRepositoryProtocol
    let onCommitted: @MainActor (TransactionScheduleConversionOutcome) -> Void

    var body: some View {
        NavigationStack {
            Group {
                switch coordinator.state {
                case .idle:
                    ContentUnavailableView("Transaction", systemImage: "calendar.badge.plus")
                case .loading:
                    ProgressView("Preparing Conversion Review")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .review(let review): reviewContent(review)
                case .submitting:
                    progressContent
                case .committed(let receipt): committed(receipt)
                case .failed(let message): failure(message)
                }
            }
            .background(ActualistTheme.background)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { close() }
                        .labelStyle(.iconOnly)
                        .disabled(coordinator.state.isSubmitting)
                        .accessibilityIdentifier("transaction-schedule-conversion-close")
                }
            }
        }
        .frame(idealWidth: 540)
        .presentationDetents([.large])
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationBackground(ActualistTheme.background)
        .interactiveDismissDisabled(coordinator.state.isSubmitting)
        .accessibilityIdentifier("transaction-schedule-conversion-review")
    }

    private func reviewContent(_ review: TransactionScheduleConversionReviewContent) -> some View {
        ReviewSheetContent {
            ReviewSheetHeader(
                title: "Convert Future Transaction",
                subtitle: "Review the schedule that will replace this transaction."
            )
            VStack(spacing: 10) {
                ReviewSummaryRow(title: "Date", value: review.dateText, symbol: "calendar")
                ReviewSummaryRow(title: "Amount", value: review.amountText, symbol: "dollarsign.circle")
                ReviewSummaryRow(title: "Account", value: review.accountText, symbol: "building.columns")
                ReviewSummaryRow(title: "Payee", value: review.payeeText, symbol: "person.crop.circle")
                ReviewSummaryRow(title: "Category", value: review.categoryText, symbol: "tag")
                ReviewSummaryRow(title: "Transaction", value: review.transactionTypeText, symbol: "arrow.left.arrow.right")
            }
            .actualistReviewCard(padding: 12)
            Label(
                "Saving creates a one-time schedule marked for automatic posting and removes the original transaction.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.subheadline)
            .foregroundStyle(ActualistTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
            .actualistReviewCard(padding: 12)
            Text("After a successful sync, this phone posts the schedule when it is due. If that sync does not finish, the schedule stays unposted.")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            ReviewSheetActions {
                Button("Cancel", role: .cancel) { close() }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("transaction-schedule-conversion-cancel")
                Button("Convert Transaction", systemImage: "calendar.badge.plus") {
                    coordinator.confirm(repository: repository, onCommitted: onCommitted)
                }
                .buttonStyle(.glassProminent)
                .tint(ActualistTheme.accent)
                .disabled(coordinator.state.isBusy)
                .accessibilityIdentifier("transaction-schedule-conversion-confirm")
            }
        }
    }

    private var progressContent: some View {
        ReviewSheetContent {
            ReviewSheetHeader(title: "Creating Schedule")
            Label(
                "The original transaction and its schedule are being saved together.",
                systemImage: "arrow.triangle.2.circlepath"
            )
            .font(.subheadline)
            .foregroundStyle(ActualistTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .actualistReviewCard()
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func committed(_ receipt: ScheduleConversionReceipt) -> some View {
        ReviewSheetContent {
            ReviewSheetHeader(title: "Schedule Created")
            Label(
                receipt.refreshPending
                    ? "The schedule was saved. The transaction and schedule views still need to refresh."
                    : "The schedule was saved and the original transaction was removed.",
                systemImage: receipt.refreshPending ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
            )
            .font(.subheadline)
            .foregroundStyle(receipt.refreshPending ? ActualistTheme.warning : ActualistTheme.positive)
            .fixedSize(horizontal: false, vertical: true)
            .actualistReviewCard()
            Text("Closing this review will not create another schedule.")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            ReviewSheetActions {
                Button("Done") { coordinator.finishCommitted(); dismiss() }
                    .buttonStyle(.glassProminent)
                    .tint(ActualistTheme.accent)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        ReviewSheetContent {
            ReviewSheetHeader(title: "Transaction Not Converted")
            Label(message, systemImage: "xmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(ActualistTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
                .actualistReviewCard()
            Text("No schedule was created. Review the latest transaction before trying again.")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            ReviewSheetActions {
                Button("Close") { close() }
                    .buttonStyle(.glassProminent)
                    .tint(ActualistTheme.accent)
            }
        }
    }

    private var navigationTitle: String {
        switch coordinator.state {
        case .idle, .loading, .review: "Convert Transaction"
        case .submitting: "Creating Schedule"
        case .committed: "Schedule Created"
        case .failed: "Conversion Unavailable"
        }
    }

    private func close() {
        guard !coordinator.state.isSubmitting else { return }
        _ = coordinator.cancel()
        dismiss()
    }
}
