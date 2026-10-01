import SwiftUI

struct TransactionSelectionBar: ToolbarContent {
    let selectedCount: Int
    let canAct: Bool
    let onDone: () -> Void
    let onClear: () -> Void
    let onCategorize: () -> Void
    let onDelete: () -> Void
    var onDuplicate: (() -> Void)? = nil
    var onMerge: (() -> Void)? = nil

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Done", action: onDone)
                .accessibilityIdentifier("transaction-selection-done")
        }

        ToolbarItem(placement: .principal) {
            Text("\(selectedCount) selected")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier("transaction-selection-count")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Clear Transactions", systemImage: "checkmark.circle", action: onClear)
                Button("Categorize Transactions…", systemImage: "tag", action: onCategorize)
                if let onDuplicate {
                    Button("Duplicate Transactions…", systemImage: "plus.square.on.square", action: onDuplicate)
                        .accessibilityIdentifier("transaction-selection-duplicate")
                }
                if let onMerge, selectedCount == 2 {
                    Button("Merge Transactions…", systemImage: "arrow.triangle.merge", action: onMerge)
                        .accessibilityIdentifier("transaction-selection-merge")
                }
                Button("Delete Transactions…", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("Selected Transaction Actions")
            .accessibilityIdentifier("transaction-selection-actions")
            .disabled(!canAct)
        }
    }
}
