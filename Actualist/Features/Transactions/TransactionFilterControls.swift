import SwiftUI

struct TransactionStatusFilterMenu: View {
    let selection: TransactionStatusFilter
    var showsTitle = false
    let onSelect: (TransactionStatusFilter) -> Void

    var body: some View {
        Menu {
            ForEach(TransactionStatusFilter.allCases, id: \.self) { filter in
                Button {
                    onSelect(filter)
                } label: {
                    if selection == filter {
                        Label(filter.title, systemImage: "checkmark")
                    } else {
                        Text(filter.title)
                    }
                }
                .accessibilityAddTraits(selection == filter ? .isSelected : [])
            }
        } label: {
            if showsTitle {
                Label("Filter Transactions", systemImage: "line.3.horizontal.decrease")
            } else {
                Image(systemName: "line.3.horizontal.decrease")
            }
        }
        .accessibilityLabel("Filter Transactions")
    }
}

struct TransactionStatusFilterIndicator: View {
    let selection: TransactionStatusFilter
    let onClear: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            Button(action: onClear) {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text("Filtered: \(selection.title)")
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            .buttonStyle(.glass)
            .tint(ActualistTheme.accent)
            .accessibilityLabel("Clear \(selection.title) Filter")
            Spacer(minLength: 0)
        }
    }
}

extension TransactionStatusFilter {
    var title: String {
        switch self {
        case .all: "All"
        case .uncategorized: "Uncategorized"
        case .uncleared: "Uncleared"
        case .cleared: "Cleared"
        case .reconciled: "Reconciled"
        }
    }

    var emptyMessage: String {
        switch self {
        case .all: "No transactions yet"
        case .uncategorized: "No uncategorized transactions"
        case .uncleared: "No uncleared transactions"
        case .cleared: "No cleared transactions"
        case .reconciled: "No reconciled transactions"
        }
    }

    var loadingMessage: String {
        switch self {
        case .all: "Loading transactions"
        case .uncategorized: "Loading uncategorized transactions"
        case .uncleared: "Loading uncleared transactions"
        case .cleared: "Loading cleared transactions"
        case .reconciled: "Loading reconciled transactions"
        }
    }

    var searchingMessage: String {
        self == .all ? "Searching transactions" : "Searching \(title.lowercased()) transactions"
    }
}
