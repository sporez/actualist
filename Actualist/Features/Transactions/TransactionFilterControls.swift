import SwiftUI

struct TransactionStatusFilterMenu: View {
    let selection: TransactionStatusFilter
    var showsTitle = false
    var onMoreFilters: (() -> Void)?
    var onSavedFilters: (() -> Void)?
    let onSelect: (TransactionStatusFilter) -> Void

    var body: some View {
        Menu {
            TransactionStatusFilterOptions(
                filters: TransactionStatusFilter.allCases,
                selection: selection,
                onSelect: onSelect
            )
            if let onMoreFilters {
                Divider()
                Button("More Filters…", systemImage: "slider.horizontal.3", action: onMoreFilters)
                    .accessibilityIdentifier("transaction-more-filters")
            }
            if let onSavedFilters {
                Button("Saved Filters…", systemImage: "bookmark", action: onSavedFilters)
                    .accessibilityIdentifier("transaction-saved-filters")
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

private struct TransactionStatusFilterOptions: View {
    let filters: [TransactionStatusFilter]
    let selection: TransactionStatusFilter
    let onSelect: (TransactionStatusFilter) -> Void

    var body: some View {
        ForEach(filters, id: \.self) { filter in
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
    }
}

struct TransactionStatusFilterIndicator: View {
    let selection: TransactionStatusFilter
    let onSelect: (TransactionStatusFilter) -> Void

    var body: some View {
        TransactionFilterIndicatorRow(
            clearAccessibilityLabel: "Clear \(selection.title) Filter",
            clearAccessibilityIdentifier: "transaction-filter-clear-status",
            onClear: { onSelect(.all) }
        ) {
            Menu {
                TransactionStatusFilterOptions(
                    filters: TransactionStatusFilter.allCases.filter { $0 != .all },
                    selection: selection,
                    onSelect: onSelect
                )
            } label: {
                TransactionFilterIndicatorLabel(
                    systemImage: "line.3.horizontal.decrease",
                    title: "Filtered: \(selection.title)"
                )
            }
            .menuStyle(.button)
            .accessibilityLabel("Filtered: \(selection.title)")
            .accessibilityHint("Shows other filters")
            .accessibilityIdentifier("transaction-filter-status")
        }
    }
}

struct TransactionStructuredFilterIndicator: View {
    let conditionCount: Int
    let onEdit: () -> Void
    let onClear: () -> Void

    private var conditionSummary: String {
        "\(conditionCount) \(conditionCount == 1 ? "condition" : "conditions")"
    }

    var body: some View {
        TransactionFilterIndicatorRow(
            clearAccessibilityLabel: "Clear More Filters, \(conditionSummary)",
            clearAccessibilityIdentifier: "transaction-filter-clear-structured",
            onClear: onClear
        ) {
            Button(action: onEdit) {
                TransactionFilterIndicatorLabel(
                    systemImage: "slider.horizontal.3",
                    title: "More Filters: \(conditionCount)"
                )
            }
            .accessibilityLabel("More Filters, \(conditionSummary)")
            .accessibilityHint("Edits the filter conditions")
            .accessibilityIdentifier("transaction-filter-edit-structured")
        }
    }
}

/// An active-filter pill beside its own round clear button. The two stay
/// separate glass buttons, never one nested inside the other.
private struct TransactionFilterIndicatorRow<Pill: View>: View {
    let clearAccessibilityLabel: String
    let clearAccessibilityIdentifier: String
    let onClear: () -> Void
    @ViewBuilder let pill: Pill

    @ScaledMetric(relativeTo: .subheadline) private var clearGlyphSize: CGFloat = 20

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            pill
                .buttonStyle(.glass)
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .frame(width: clearGlyphSize, height: clearGlyphSize)
                    .padding(7)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(clearAccessibilityLabel)
            .accessibilityIdentifier(clearAccessibilityIdentifier)
            Spacer(minLength: 0)
        }
    }
}

private struct TransactionFilterIndicatorLabel: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(title)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.bold))
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(ActualistTheme.primaryText)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

struct TransactionActiveFilterSections: View {
    let status: TransactionStatusFilter
    let structuredConditionCount: Int
    let onSelectStatus: (TransactionStatusFilter) -> Void
    let onEditStructured: () -> Void
    let onClearStructured: () -> Void

    var body: some View {
        Group {
            if status != .all {
                Section {
                    TransactionStatusFilterIndicator(selection: status, onSelect: onSelectStatus)
                        .plainListRow()
                }
            }
            if structuredConditionCount > 0 {
                Section {
                    TransactionStructuredFilterIndicator(
                        conditionCount: structuredConditionCount,
                        onEdit: onEditStructured,
                        onClear: onClearStructured
                    )
                    .plainListRow()
                }
            }
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
