import SwiftUI

struct ReportExplorerFilterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var draft: ReportExplorerFilterDraft
    @State private var showsClosedAccounts = false

    let metric: ReportExplorerMetric
    let defaults: ReportExplorerFilters
    let catalog: ReportExplorerFilterCatalog
    let onApply: (ReportExplorerFilters) -> Void

    init(
        metric: ReportExplorerMetric,
        filters: ReportExplorerFilters,
        defaults: ReportExplorerFilters,
        catalog: ReportExplorerFilterCatalog,
        onApply: @escaping (ReportExplorerFilters) -> Void
    ) {
        self.metric = metric
        self.defaults = defaults
        self.catalog = catalog
        self.onApply = onApply
        _draft = State(initialValue: ReportExplorerFilterDraft(
            filters: filters,
            defaults: defaults,
            accounts: catalog.accounts,
            categories: catalog.categories(for: metric)
        ))
    }

    var body: some View {
        NavigationStack {
            ReviewSheetContent {
                ReviewSheetHeader(
                    title: "Filter This Report",
                    subtitle: metric.supportsCategoryFilters
                        ? "Choose accounts and categories to include."
                        : "Choose accounts to include."
                )
                Button("Reset Filters", systemImage: "arrow.counterclockwise") {
                    draft.reset()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .tint(ActualistTheme.accent)
                .accessibilityIdentifier("report-filter-reset")
                accountSection
                if metric.supportsCategoryFilters {
                    categorySection
                }
                if metric == .budgetOverview {
                    Text("Account filters change Spending. Budgeted stays based on the selected categories because budgets are not assigned to accounts.")
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .actualistReviewCard(padding: 12)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .reviewSheetBottomBar {
                Button(role: .cancel) { dismiss() } label: {
                    Text("Cancel")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 32)
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("report-filter-cancel")

                Button { applyDraft() } label: {
                    Text("Apply")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.glassProminent)
                .tint(ActualistTheme.accent)
                .accessibilityIdentifier("report-filter-apply")
            }
        }
        .frame(idealWidth: 560)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationBackground(ActualistTheme.background)
        .accessibilityIdentifier("report-filter-sheet")
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            filterHeader(
                title: "Accounts",
                symbol: "building.2",
                selectAll: { draft.selectAllAccounts() },
                clear: { draft.clearAccounts() }
            )

            Toggle("Include off-budget accounts", isOn: Binding(
                get: { draft.filters.includesOffBudget },
                set: { draft.setIncludesOffBudget($0) }
            ))
                .accessibilityIdentifier("report-filter-off-budget")
            ForEach(openAccounts) { option in
                accountToggle(option)
            }
            if !closedAccounts.isEmpty {
                DisclosureGroup("Closed Accounts", isExpanded: $showsClosedAccounts) {
                    disclosedRows {
                        ForEach(closedAccounts) { option in
                            accountToggle(option)
                        }
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ActualistTheme.primaryText)
            }
        }
        .actualistReviewCard(padding: 14)
    }

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            filterHeader(
                title: "Categories",
                symbol: "square.grid.2x2",
                selectAll: { draft.selectAllCategories() },
                clear: { draft.clearCategories() }
            )

            Toggle("Include hidden categories", isOn: Binding(
                get: { draft.filters.includesHiddenCategories },
                set: { draft.setIncludesHiddenCategories($0) }
            ))
                .accessibilityIdentifier("report-filter-hidden-categories")
            Toggle("Include uncategorized", isOn: $draft.filters.includesUncategorized)
                .accessibilityIdentifier("report-filter-uncategorized")
            if metric.supportsTransferFilter {
                Toggle("Include transfers", isOn: Binding(
                    get: { draft.includesTransfers },
                    set: { draft.setIncludesTransfers($0) }
                ))
                .accessibilityIdentifier("report-filter-transfers")
            }

            ForEach(categoryGroups, id: \.name) { group in
                DisclosureGroup(group.name) {
                    disclosedRows {
                        ForEach(group.options) { option in
                            categoryToggle(option)
                        }
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ActualistTheme.primaryText)
            }
        }
        .actualistReviewCard(padding: 14)
    }

    private var openAccounts: [ReportExplorerAccountFilterOption] {
        catalog.accounts.filter { !$0.isClosed }
    }

    private var closedAccounts: [ReportExplorerAccountFilterOption] {
        catalog.accounts.filter(\.isClosed)
    }

    private var categoryGroups: [(name: String, options: [ReportExplorerCategoryFilterOption])] {
        Dictionary(grouping: catalog.categories(for: metric), by: \.groupName)
            .map { (name: $0.key, options: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Matches the open-account rows' spacing so switches never touch.
    private func disclosedRows(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(.top, 8)
    }

    private func accountToggle(_ option: ReportExplorerAccountFilterOption) -> some View {
        Toggle(isOn: Binding(
            get: { draft.isAccountIncluded(option.id) },
            set: { draft.setAccount(option.id, included: $0) }
        )) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(option.name)
                    .fixedSize(horizontal: false, vertical: true)
                if option.isOffBudget {
                    Text("Off budget")
                        .font(.caption)
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.subheadline)
        .accessibilityIdentifier("report-filter-account-\(option.id)")
    }

    private func categoryToggle(_ option: ReportExplorerCategoryFilterOption) -> some View {
        Toggle(isOn: Binding(
            get: { draft.isCategoryIncluded(option.id) },
            set: { draft.setCategory(option.id, included: $0) }
        )) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(option.name)
                    .fixedSize(horizontal: false, vertical: true)
                if option.isHidden {
                    Text("Hidden")
                        .font(.caption)
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.subheadline)
        .accessibilityIdentifier("report-filter-category-\(option.id)")
    }

    private func filterHeader(
        title: String,
        symbol: String,
        selectAll: @escaping () -> Void,
        clear: @escaping () -> Void
    ) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return layout {
            Label(title, systemImage: symbol)
                .font(.headline.weight(.semibold))
                .foregroundStyle(ActualistTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 8)
            }
            HStack(spacing: 16) {
                Button("All", action: selectAll)
                Button("None", action: clear)
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(ActualistTheme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func applyDraft() {
        onApply(draft.filters)
        dismiss()
    }
}
