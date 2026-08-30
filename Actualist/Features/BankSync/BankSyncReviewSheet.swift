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
                    Text("Matched transactions keep their amount and date. The details below list every other transaction field Confirm will change. Unchanged transactions are not modified; skipped accounts only save their bank status.")
                        .font(.caption)
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                .settingsSectionChrome()

                Section {
                    ForEach(viewModel.reviewLines) { line in
                        BankSyncReviewRow(line: line)
                    }
                } footer: {
                    Text(viewModel.reviewHasProblems
                         ? "Nothing can be saved because some bank transactions could not be read. Cancel and retry."
                         : "Nothing is saved until you confirm.")
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
                    .disabled(!viewModel.canConfirmReview)
                }
            }
            .interactiveDismissDisabled(viewModel.phase == .applying)
        }
    }
}

private struct BankSyncReviewRow: View {
    let line: BankSyncViewModel.ReviewLine
    @State private var showsMatchDetails = true

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
                if let statusText = line.statusText {
                    Label(statusText, systemImage: "exclamationmark.circle")
                        .foregroundStyle(ActualistTheme.danger)
                }
            }
            .font(.caption)
            .labelStyle(.titleAndIcon)

            if let problemSummary = line.problemSummary {
                Text(problemSummary)
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.warning)
            }

            if let opening = line.openingBalanceText {
                Text("Opening balance: \(opening)")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }

            if !line.matchLines.isEmpty {
                DisclosureGroup(isExpanded: $showsMatchDetails) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(line.matchLines.enumerated()), id: \.element.id) { index, match in
                            if index > 0 {
                                Divider()
                                    .overlay(ActualistTheme.separator)
                            }
                            BankSyncMatchReviewRow(match: match)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text(line.matchLines.count == 1
                         ? "Exact changes for 1 match"
                         : "Exact changes for \(line.matchLines.count) matches")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ActualistTheme.primaryText)
                }
                .tint(ActualistTheme.accent)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct BankSyncMatchReviewRow: View {
    let match: BankSyncViewModel.ReviewMatchLine

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(match.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ActualistTheme.primaryText)
                    Text(match.dateText)
                        .font(.caption2)
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                Spacer(minLength: 8)
                Text(match.amountText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(ActualistTheme.primaryText)
            }

            ForEach(Array(match.changes.enumerated()), id: \.offset) { _, change in
                Text(change)
                    .font(.caption2)
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
