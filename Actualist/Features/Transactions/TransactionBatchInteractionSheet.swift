import SwiftUI

struct TransactionBatchInteractionSheet: View {
    @Bindable var presentation: TransactionBatchPresentation
    let isPrivacyModeEnabled: Bool
    let feedContext: @MainActor () -> TransactionSelectionContext?
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
                                feedContext: feedContext(),
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
                        currentFeedContext: feedContext,
                        onCommitted: onCommitted
                    )
                }
            )
        case .submitting:
            progressContent(title: "Saving Changes", message: "The selected changes are being saved together…")
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
}
