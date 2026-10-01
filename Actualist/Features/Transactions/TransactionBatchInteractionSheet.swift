import SwiftUI

struct TransactionBatchInteractionSheet: View {
    @Bindable var presentation: TransactionBatchPresentation
    let isPrivacyModeEnabled: Bool
    let feedSnapshot: @MainActor () -> TransactionBatchFeedSnapshot?
    let repository: any TransactionBatchRepositoryProtocol
    let onCommitted: @MainActor (TransactionBatchOutcome) -> Void

    var body: some View {
        Group {
            switch presentation.sheetContent {
            case .categoryPicker:
                if let categoryPicker = presentation.categoryPicker {
                    TransactionBatchCategoryPickerView(
                        workflow: categoryPicker,
                        onSelect: { categoryID in
                            presentation.selectCategory(
                                categoryID,
                                feedSnapshot: feedSnapshot(),
                                repository: repository
                            )
                        },
                        onCancel: { presentation.cancelSheet() }
                    )
                }
            case .review:
                reviewContent
            case nil:
                EmptyView()
            }
        }
        .interactiveDismissDisabled(presentation.preventsSheetDismissal)
    }

    @ViewBuilder
    private var reviewContent: some View {
        switch presentation.selection.state {
        case .preparing:
            progressContent(title: "Preparing Review", message: "Checking the selected transaction rows…")
        case .reviewing(let review):
            TransactionBatchReviewSheet(
                review: review,
                isPrivacyModeEnabled: isPrivacyModeEnabled,
                onCancel: { presentation.cancelSheet() },
                onConfirm: {
                    presentation.confirm(
                        repository: repository,
                        currentFeedSnapshot: feedSnapshot,
                        onCommitted: onCommitted
                    )
                }
            )
        case .submitting:
            progressContent(title: "Saving Changes", message: "The selected changes are being saved together…")
        case .committed(let outcome):
            committedContent(outcome)
        case .inactive, .selecting, .failed:
            EmptyView()
        }
    }

    private func progressContent(title: String, message: String) -> some View {
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

    private func committedContent(_ outcome: TransactionBatchOutcome) -> some View {
        VStack(spacing: 0) {
            ReviewSheetContent {
                ReviewSheetHeader(title: "Changes Saved")
                Text(completionMessage(outcome))
                    .font(.subheadline)
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .actualistReviewCard()
            }
            ReviewSheetActions {
                Button(action: { presentation.finishCommittedResult() }) {
                    Text("Done")
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.glassProminent)
                .tint(ActualistTheme.accent)
            }
        }
        .background(ActualistTheme.background)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func completionMessage(_ outcome: TransactionBatchOutcome) -> String {
        guard outcome.sessionCurrent else {
            return "Changes were saved, but this budget is no longer open. Reopen it to see the updated transactions."
        }
        if outcome.refreshPending {
            return "Changes were saved. The transaction list is refreshing. You can undo them together in Budget → History."
        }
        return "The selected changes were saved together. You can undo them together in Budget → History."
    }
}
