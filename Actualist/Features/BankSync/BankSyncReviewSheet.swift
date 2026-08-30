import SwiftUI

/// Review sheet shown after a successful download, before any write
/// (Decision Log: review, then apply). Confirm applies every reviewed plan;
/// cancel writes nothing.
struct BankSyncReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: BankSyncViewModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(viewModel.reviewLines) { line in
                        BankSyncReviewRow(line: line)
                    }
                } footer: {
                    Text("Nothing is saved until you confirm.")
                        .font(.caption)
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                .settingsSectionChrome()
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .foregroundStyle(ActualistTheme.primaryText)
            .tint(ActualistTheme.accent)
            .navigationTitle("Review Bank Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancelReview()
                        dismiss()
                    }
                    .disabled(viewModel.phase == .applying)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm") {
                        Task {
                            await viewModel.confirmReview()
                            dismiss()
                        }
                    }
                    .disabled(viewModel.phase == .applying)
                }
            }
            .interactiveDismissDisabled(viewModel.phase == .applying)
        }
    }
}

private struct BankSyncReviewRow: View {
    let line: BankSyncViewModel.ReviewLine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(line.accountName)
                .font(.body.weight(.semibold))
                .foregroundStyle(ActualistTheme.primaryText)

            HStack(spacing: 12) {
                if line.addedCount > 0 {
                    Label("\(line.addedCount) added", systemImage: "plus.circle")
                        .foregroundStyle(ActualistTheme.positive)
                }
                if line.updatedCount > 0 {
                    Label("\(line.updatedCount) matched", systemImage: "arrow.triangle.merge")
                        .foregroundStyle(ActualistTheme.accent)
                }
                if line.unchangedCount > 0 {
                    Label("\(line.unchangedCount) unchanged", systemImage: "checkmark.circle")
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                if line.problemCount > 0 {
                    Label("\(line.problemCount) problems", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(ActualistTheme.warning)
                }
            }
            .font(.caption)
            .labelStyle(.titleAndIcon)

            if let opening = line.openingBalanceText {
                Text("Opening balance: \(opening)")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
        }
        .padding(.vertical, 2)
    }
}
