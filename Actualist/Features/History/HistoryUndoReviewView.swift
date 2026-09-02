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

    var body: some View {
        NavigationStack {
            ZStack {
                ActualistTheme.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 10) {
                            Text(review.gestureSummary)
                                .font(ActualistTypography.rowLabel(for: density))
                                .foregroundStyle(ActualistTheme.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if let blockReason = review.blockReason {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .foregroundStyle(ActualistTheme.warning)
                                    Text(blockReason)
                                        .font(ActualistTypography.body(for: density))
                                        .foregroundStyle(ActualistTheme.primaryText)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(14)
                                .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            } else {
                                ForEach(review.entries) { entry in
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
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 14)
                        .padding(.bottom, 18)
                    }
                    .scrollIndicators(.hidden)

                    if review.isUndoable {
                        Button {
                            onConfirm()
                        } label: {
                            Group {
                                if isCommitting {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Text("Undo")
                                        .font(ActualistTypography.control(for: density))
                                        .frame(maxWidth: .infinity)
                                }
                            }
                        }
                        .buttonStyle(.glassProminent)
                        .tint(ActualistTheme.accent)
                        .disabled(isCommitting)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 12)
                        .accessibilityLabel("Confirm undo of \(review.gestureSummary)")
                    }
                }
            }
            .navigationTitle("Undo Action")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cancel")
                    .disabled(isCommitting)
                }
            }
            .interactiveDismissDisabled(isCommitting)
        }
    }
}
