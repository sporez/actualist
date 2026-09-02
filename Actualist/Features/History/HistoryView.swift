import SwiftUI

/// History sheet (Q16/Q17): the last 25 money-flow gestures, presented from
/// the Budget trailing ellipsis menu at medium/large detents so the budget
/// stays visible behind the sheet after an undo. Layout only — loading, undo
/// state, and errors live in `HistoryViewModel`.
struct HistoryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density
    @State private var viewModel = HistoryViewModel()
    @State private var selectedDetent: PresentationDetent = .medium

    var body: some View {
        NavigationStack {
            ZStack {
                ActualistTheme.background.ignoresSafeArea()

                content
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
            .task { await viewModel.load(using: appState) }
            .sheet(item: reviewBinding) { review in
                HistoryUndoReviewView(
                    review: review,
                    isCommitting: viewModel.committingActionID == review.actionID,
                    onConfirm: {
                        Task { await viewModel.confirmUndo(using: appState) }
                    },
                    onCancel: {
                        viewModel.cancelUndo()
                    }
                )
                .environment(appState)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .appSwitcherPrivacyProtected()
            }
            .alert(
                "Couldn't Undo",
                isPresented: undoFailureBinding,
                actions: {
                    Button("OK", role: .cancel) {
                        viewModel.dismissUndoFailure()
                    }
                },
                message: {
                    Text(viewModel.undoFailureMessage ?? "")
                }
            )
        }
        .presentationDetents([.medium, .large], selection: $selectedDetent)
        .presentationDragIndicator(.visible)
    }

    private var reviewBinding: Binding<HistoryUndoReviewPresentation?> {
        Binding(
            get: { viewModel.activeReview },
            set: { isPresented in
                if isPresented == nil {
                    viewModel.cancelUndo()
                }
            }
        )
    }

    private var undoFailureBinding: Binding<Bool> {
        Binding(
            get: { viewModel.undoFailureMessage != nil },
            set: { isPresented in
                if !isPresented {
                    viewModel.dismissUndoFailure()
                }
            }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            messageRow(
                title: "History Unavailable",
                detail: message,
                systemImage: "exclamationmark.triangle"
            )
        case .loaded:
            if viewModel.rows.isEmpty {
                emptyState
            } else {
                rowList
            }
        }
    }

    private var emptyState: some View {
        messageRow(
            title: "No Actions Yet",
            detail: "Assignments, moves, template applies, and transactions you make on this device appear here.",
            systemImage: "clock"
        )
    }

    private func messageRow(title: String, detail: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(ActualistTheme.secondaryText)
            Text(title)
                .font(ActualistTypography.sectionTitle(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
            Text(detail)
                .font(ActualistTypography.rowLabel(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rowList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(viewModel.rows) { row in
                    HistoryRowView(
                        row: row,
                        showsProgress: viewModel.isPreparingUndoForRowID == row.id,
                        onUndo: {
                            Task { await viewModel.beginUndo(row, using: appState) }
                        }
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await viewModel.refresh(using: appState)
        }
    }
}

private struct HistoryRowView: View {
    @Environment(\.actualistDensity) private var density

    let row: HistoryRowModel
    let showsProgress: Bool
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ActualistTheme.secondaryText)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(row.isUndone ? ActualistTheme.secondaryText : ActualistTheme.primaryText)
                    .lineLimit(3)
                Text(row.detail)
                    .font(ActualistTypography.rowLabel(for: density))
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .lineLimit(3)
            }

            Spacer(minLength: 8)

            if let amountText = row.amountText {
                Text(amountText)
                    .font(ActualistTypography.rowValue(for: density))
                    .foregroundStyle(amountColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            if row.canUndo {
                Group {
                    if showsProgress {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Undo", action: onUndo)
                            .font(ActualistTypography.control(for: density))
                            .foregroundStyle(ActualistTheme.accent)
                    }
                }
                .frame(minWidth: 46, alignment: .trailing)
                .accessibilityLabel("Undo \(row.title)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch row.visual {
        case .assign:
            "banknote"
        case .move:
            "arrow.left.arrow.right"
        case .template:
            "sparkles"
        case .createTransaction:
            "plus"
        case .editTransaction:
            "pencil"
        case .deleteTransaction:
            "trash"
        case .categorize:
            "tag"
        }
    }

    private var amountColor: Color {
        switch row.amountTone {
        case .positive:
            ActualistTheme.positive
        case .negative:
            ActualistTheme.danger
        case .neutral:
            ActualistTheme.secondaryText
        }
    }
}
