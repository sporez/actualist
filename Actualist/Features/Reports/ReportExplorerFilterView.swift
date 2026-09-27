import SwiftUI

struct ReportExplorerFilterView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ReportExplorerFilterDraft
    @State private var showsClosedAccounts = false

    let metric: ReportExplorerMetric
    let catalog: ReportExplorerFilterCatalog
    let onApply: (ReportExplorerFilters) -> Void

    init(
        metric: ReportExplorerMetric,
        filters: ReportExplorerFilters,
        catalog: ReportExplorerFilterCatalog,
        onApply: @escaping (ReportExplorerFilters) -> Void
    ) {
        self.metric = metric
        self.catalog = catalog
        self.onApply = onApply
        _draft = State(initialValue: ReportExplorerFilterDraft(filters: filters))
    }

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                if metric.supportsCategoryFilters {
                    categorySection
                }
                if metric == .budgetOverview {
                    Section {
                        Text("Account filters change Spending. Budgeted stays based on the selected categories because budgets are not assigned to accounts.")
                            .font(.footnote)
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }
                }
                Section {
                    Button("Reset Filters") {
                        draft = ReportExplorerFilterDraft(filters: .default)
                    }
                    .accessibilityIdentifier("report-filter-reset")
                }
            }
            .scrollContentBackground(.hidden)
            .background(ActualistTheme.background)
            .navigationTitle("Report Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(draft.filters)
                        dismiss()
                    }
                    .accessibilityIdentifier("report-filter-apply")
                }
            }
        }
        .frame(idealWidth: 560)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .accessibilityIdentifier("report-filter-sheet")
    }

    private var accountSection: some View {
        Section {
            Toggle("Include off-budget accounts", isOn: $draft.filters.includesOffBudget)
                .accessibilityIdentifier("report-filter-off-budget")
            ForEach(openAccounts) { option in
                accountToggle(option)
            }
            if !closedAccounts.isEmpty {
                DisclosureGroup("Closed Accounts", isExpanded: $showsClosedAccounts) {
                    ForEach(closedAccounts) { option in
                        accountToggle(option)
                    }
                }
            }
        } header: {
            filterHeader(
                title: "Accounts",
                selectAll: { draft.selectAllAccounts() },
                clear: { draft.clearAccounts() }
            )
        }
    }

    private var categorySection: some View {
        Section {
            Toggle("Include hidden categories", isOn: $draft.filters.includesHiddenCategories)
                .accessibilityIdentifier("report-filter-hidden-categories")
            Toggle("Include uncategorized", isOn: $draft.filters.includesUncategorized)
                .accessibilityIdentifier("report-filter-uncategorized")
            ForEach(categoryGroups, id: \.name) { group in
                DisclosureGroup(group.name) {
                    ForEach(group.options) { option in
                        categoryToggle(option)
                    }
                }
            }
        } header: {
            filterHeader(
                title: "Categories",
                selectAll: { draft.selectAllCategories() },
                clear: { draft.clearCategories() }
            )
        }
    }

    private var openAccounts: [ReportExplorerAccountFilterOption] {
        catalog.accounts.filter { !$0.isClosed }
    }

    private var closedAccounts: [ReportExplorerAccountFilterOption] {
        catalog.accounts.filter(\.isClosed)
    }

    private var accountIDs: Set<String> {
        Set(catalog.accounts.map(\.id))
    }

    private var categoryIDs: Set<String> {
        Set(catalog.categories(for: metric).map(\.id))
    }

    private var categoryGroups: [(name: String, options: [ReportExplorerCategoryFilterOption])] {
        Dictionary(grouping: catalog.categories(for: metric), by: \.groupName)
            .map { (name: $0.key, options: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func accountToggle(_ option: ReportExplorerAccountFilterOption) -> some View {
        Toggle(isOn: Binding(
            get: { draft.isAccountSelected(option.id) },
            set: { draft.setAccount(option.id, selected: $0, availableIDs: accountIDs) }
        )) {
            HStack {
                Text(option.name)
                if option.isOffBudget {
                    Text("Off budget")
                        .font(.caption)
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
            }
        }
        .accessibilityIdentifier("report-filter-account-\(option.id)")
    }

    private func categoryToggle(_ option: ReportExplorerCategoryFilterOption) -> some View {
        Toggle(isOn: Binding(
            get: { draft.isCategorySelected(option.id) },
            set: { draft.setCategory(option.id, selected: $0, availableIDs: categoryIDs) }
        )) {
            HStack {
                Text(option.name)
                if option.isHidden {
                    Text("Hidden")
                        .font(.caption)
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
            }
        }
        .accessibilityIdentifier("report-filter-category-\(option.id)")
    }

    private func filterHeader(
        title: String,
        selectAll: @escaping () -> Void,
        clear: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button("All", action: selectAll)
            Button("None", action: clear)
        }
        .textCase(nil)
    }
}
