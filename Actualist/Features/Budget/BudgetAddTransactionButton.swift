import SwiftUI

struct BudgetAddTransactionButton: View {
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: isExpanded ? 8 : 0) {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                Text("Transaction")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .opacity(isExpanded ? 1 : 0)
                    .fixedSize()
                    .frame(width: isExpanded ? nil : 0, alignment: .leading)
                    .clipped()
                    .accessibilityHidden(!isExpanded)
            }
            .clipped()
        }
        .buttonStyle(.glass)
        .buttonBorderShape(isExpanded ? .capsule : .circle)
        .controlSize(.large)
        .accessibilityLabel("Add Transaction")
    }
}
