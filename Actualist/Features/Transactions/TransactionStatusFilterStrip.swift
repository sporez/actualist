import SwiftUI

struct TransactionStatusFilterStrip: View {
    @Environment(\.actualistDensity) private var density
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let selection: TransactionStatusFilter
    let onSelect: (TransactionStatusFilter) -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(TransactionStatusFilter.allCases, id: \.self) { filter in
                            filterButton(filter)
                                .id(filter)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Transaction filters")
                .onChange(of: selection) { _, value in
                    withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(value, anchor: .center) }
                }
                .onChange(of: dynamicTypeSize) { _, _ in
                    proxy.scrollTo(selection, anchor: .center)
                }
                .onChange(of: geometry.size.width) { _, _ in
                    proxy.scrollTo(selection, anchor: .center)
                }
            }
        }
        .frame(height: 44)
    }

    @ViewBuilder
    private func filterButton(_ filter: TransactionStatusFilter) -> some View {
        let button = Button { onSelect(filter) } label: {
            Text(filter.title)
                .font(ActualistTypography.control(for: density))
                .lineLimit(1)
                .fixedSize()
                .frame(minHeight: 44)
                .padding(.horizontal, 14)
        }
        if selection == filter {
            button.buttonStyle(.glassProminent)
                .tint(ActualistTheme.accent)
                .accessibilityAddTraits(.isSelected)
                .accessibilityLabel(filter.title)
        } else {
            button.buttonStyle(.glass)
                .accessibilityLabel(filter.title)
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
