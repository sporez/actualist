import SwiftUI

/// Inline outcomes; expansion is presentation-only.
struct BankSyncResultRow: View {
    let line: BankSyncViewModel.ResultLine
    @State private var showsMatchDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(line.accountName)
                .font(.body.weight(.semibold))
                .foregroundStyle(ActualistTheme.primaryText)

            VStack(alignment: .leading, spacing: 4) {
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
                          ? "Changes saved for 1 match"
                          : "Changes saved for \(line.matchLines.count) matches")
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
