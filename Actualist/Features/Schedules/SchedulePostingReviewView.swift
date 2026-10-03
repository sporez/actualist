import SwiftUI

struct SchedulePostingReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var coordinator: SchedulePostingCoordinator
    let postingRepository: any SchedulePostingRepositoryProtocol

    var body: some View {
        Group {
            switch coordinator.state {
            case .idle:
                ContentUnavailableView("Schedule", systemImage: "calendar")
            case .loading:
                ProgressView("Preparing Post Review")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .review(let review):
                reviewContent(review)
            case .syncing:
                progressContent(
                    title: "Syncing before post",
                    message: "Actualist is syncing this budget before it posts the transaction.",
                    symbol: "arrow.triangle.2.circlepath"
                )
            case .submitting:
                progressContent(
                    title: "Posting transaction",
                    message: "The transaction is being saved to this budget. Keep this review open until it finishes.",
                    symbol: "square.and.arrow.down"
                )
            case .committed(let receipt):
                committed(receipt, refreshPending: false)
            case .committedRefreshPending(let receipt):
                committed(receipt, refreshPending: true)
            case .failed(let message):
                failure(message)
            }
        }
        .background(ActualistTheme.background)
        .frame(idealWidth: 540)
        .presentationDetents([.large])
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationBackground(ActualistTheme.background)
        .interactiveDismissDisabled(coordinator.state.isSubmitting)
    }

    private func reviewContent(_ review: SchedulePostingReviewContent) -> some View {
        ReviewSheetContent {
            ReviewSheetHeader(
                title: "Post Scheduled Transaction",
                subtitle: review.title
            )
            VStack(spacing: 10) {
                ReviewSummaryRow(title: "Amount", value: review.amountText, symbol: "dollarsign.circle")
                ReviewSummaryRow(title: "Account", value: review.accountText, symbol: "building.columns")
                ReviewSummaryRow(title: "Payee", value: review.payeeText, symbol: "person.crop.circle")
                ReviewSummaryRow(title: "Current status", value: review.statusText, symbol: "clock")
                ReviewSummaryRow(title: "Scheduled date", value: review.scheduledDateText, symbol: "calendar")
            }
            .actualistReviewCard(padding: 12)

            VStack(alignment: .leading, spacing: 8) {
                Text("Transaction date")
                    .font(.headline.weight(.bold))
                Picker("Transaction date", selection: selectedDateBinding) {
                    Text("Scheduled date · \(review.scheduledDateText)")
                        .tag(SchedulePostingDate.scheduled)
                    Text("Post today · \(review.todayDateText)")
                        .tag(SchedulePostingDate.today(dayID: review.todayDayID))
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("schedule-post-date-choice")
            }
            .actualistReviewCard(padding: 12)

            if let reason = review.unavailableReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(ActualistTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .actualistReviewCard(padding: 12)
                    .accessibilityIdentifier("schedule-post-unavailable-reason")
            }
            Text("Actualist syncs this budget before posting. A saved transaction stays saved even if the schedule view needs to refresh.")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("schedule-post-review")
        .reviewSheetBottomBar {
            Button(role: .cancel) {
                close()
            } label: {
                Text("Cancel")
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 32)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("schedule-post-cancel")
            Button {
                coordinator.confirm(postingRepository: postingRepository)
            } label: {
                Label("Post Transaction", systemImage: "arrow.up.circle")
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent)
            .tint(ActualistTheme.accent)
            .disabled(!review.canSubmit || coordinator.state.isBusy)
            .accessibilityIdentifier("schedule-post-confirm")
        }
    }

    private var selectedDateBinding: Binding<SchedulePostingDate> {
        Binding(
            get: {
                guard case .review(let review) = coordinator.state else { return .scheduled }
                return review.selectedDate
            },
            set: coordinator.selectDate
        )
    }

    private func progressContent(title: String, message: String, symbol: String) -> some View {
        ReviewSheetContent {
            ReviewSheetHeader(title: title)
            Label(message, systemImage: symbol)
                .font(.subheadline)
                .foregroundStyle(ActualistTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .actualistReviewCard()
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
        .reviewSheetBottomBar {
            Button(role: .cancel) {
                if coordinator.state.isSubmitting { return }
                _ = coordinator.cancel()
                dismiss()
            } label: {
                Text(coordinator.state.isSubmitting ? "Saving…" : "Cancel Sync")
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glass)
            .disabled(coordinator.state.isSubmitting)
        }
    }

    private func committed(_ receipt: SchedulePostingReceipt, refreshPending: Bool) -> some View {
        ReviewSheetContent {
            ReviewSheetHeader(title: "Transaction Posted")
            Label(
                refreshPending
                    ? "The transaction was saved. The schedule view still needs to refresh."
                    : "The transaction was saved to this budget.",
                systemImage: refreshPending ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill"
            )
            .font(.subheadline)
            .foregroundStyle(refreshPending ? ActualistTheme.warning : ActualistTheme.positive)
            .fixedSize(horizontal: false, vertical: true)
            .actualistReviewCard()
            ReviewSummaryRow(title: "Schedule occurrence", value: SchedulePresentation.dateLabel(receipt.occurrenceDayID), symbol: "calendar.badge.clock")
            ReviewSummaryRow(title: "Transaction date", value: SchedulePresentation.dateLabel(receipt.postedDayID), symbol: "calendar")
            Text("Closing this message will not post the transaction again.")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .reviewSheetBottomBar {
            Button {
                coordinator.finishCommitted()
                dismiss()
            } label: {
                Text("Done")
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent)
            .tint(ActualistTheme.accent)
        }
    }

    private func failure(_ message: String) -> some View {
        ReviewSheetContent {
            ReviewSheetHeader(title: "Transaction Not Posted")
            Label(message, systemImage: "xmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(ActualistTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
                .actualistReviewCard()
            Text("No transaction was posted. Review the latest schedule before trying again.")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .reviewSheetBottomBar {
            Button {
                close()
            } label: {
                Text("Close")
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent)
            .tint(ActualistTheme.accent)
        }
    }

    private func close() {
        guard !coordinator.state.isSubmitting else { return }
        _ = coordinator.cancel()
        dismiss()
    }
}
