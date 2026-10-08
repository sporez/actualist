import SwiftUI

/// One-line reminder shown on pre-commit reviews whose result lands in History.
struct TransactionHistoryUndoHint: View {
    var body: some View {
        Text("You can undo this in Budget → History.")
            .font(.footnote)
            .foregroundStyle(ActualistTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("transaction-history-undo-hint")
    }
}
