import SwiftUI

/// Nested review inside the History sheet: shows current → proposed per
/// category and always requires confirmation (Q7). A blocked undo shows the
/// refusal reason and no confirm control; it writes nothing.
struct HistoryUndoReviewView: View {
    @Environment(\.actualistDensity) private var density

    let review: HistoryUndoReviewPresentation
    let isCommitting: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                ReviewSheetHeader(title: "Undo Action", subtitle: review.gestureSummary)
                    .padding(.bottom, 4)

                if let blockReason = review.blockReason {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(ActualistTheme.warning)
                        Text(blockReason)
                            .font(ActualistTypography.body(for: density))
                            .foregroundStyle(ActualistTheme.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .actualistReviewCard()
                } else {
                    ForEach(review.entries) { entry in
                        entryRow(entry)
                            .actualistReviewCard()
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .reviewSheetBottomBar {
            ReviewSheetSecondaryButton {
                onCancel()
            }
            .disabled(isCommitting)

            if review.isUndoable {
                ReviewSheetPrimaryButton {
                    onConfirm()
                } label: {
                    if isCommitting {
                        ProgressView()
                    } else {
                        Text("Undo")
                    }
                }
                .disabled(isCommitting)
                .accessibilityLabel("Confirm undo of \(review.gestureSummary)")
            }
        }
        .reviewSheetPresentation(detents: [.medium], appState: appState)
        .interactiveDismissDisabled(isCommitting)
    }

    private func entryRow(_ entry: HistoryUndoReviewPresentation.Entry) -> some View {
        HStack(spacing: 12) {
            Text(entry.name)
                .font(ActualistTypography.rowTitle(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .lineLimit(2)

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Text(entry.currentText)
                    .foregroundStyle(ActualistTheme.secondaryText)
                Text("→")
                    .foregroundStyle(ActualistTheme.secondaryText)
                Text(entry.proposedText)
                    .foregroundStyle(ActualistTheme.primaryText)
            }
            .font(ActualistTypography.rowValue(for: density))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }
}
