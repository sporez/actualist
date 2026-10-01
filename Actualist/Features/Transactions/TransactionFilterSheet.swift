import SwiftUI

struct TransactionFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var workflow: TransactionFilterWorkflow
    let budgetID: String
    let repository: any TransactionRepositoryProtocol
    let availableAccounts: [ActualAccount]

    var body: some View {
        NavigationStack {
            ReviewSheetContent {
                ReviewSheetHeader(
                    title: "More Filters",
                    subtitle: "Refine this transaction feed."
                )
                joinCard
                dateCard
                ForEach(TransactionFilterField.allCases, id: \.self) { field in
                    fieldCard(field)
                }
                preservedConditionsCard
                loadStateCard
                if let message = workflow.validationMessage {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.danger)
                        .actualistReviewCard(padding: 12)
                }
            }
            .accessibilityIdentifier("transaction-filter-review-scroll")
            .navigationTitle("Transaction Filters")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaBar(edge: .bottom, spacing: 0) {
                ReviewSheetActions {
                    Button("Clear") {
                        if workflow.clearAndApply() { dismiss() }
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("transaction-filter-clear")

                    Button(role: .cancel) { dismiss() } label: {
                        Text("Cancel").frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("transaction-filter-cancel")

                    Button {
                        if workflow.apply() { dismiss() }
                    } label: {
                        Text("Apply").frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(ActualistTheme.accent)
                    .accessibilityIdentifier("transaction-filter-apply")
                }
            }
        }
        .frame(idealWidth: 560)
        .presentationSizing(.page.fitted(horizontal: true, vertical: false))
        .presentationBackground(ActualistTheme.background)
        .accessibilityIdentifier("transaction-filter-sheet")
        .task {
            await workflow.loadOptions(
                budgetID: budgetID,
                repository: repository,
                availableAccounts: availableAccounts
            ).value
        }
        .onDisappear { workflow.cancelLoading() }
    }

    private var joinCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            compactHeading("Match conditions", symbol: "line.3.horizontal.decrease")
            Picker("Match conditions", selection: $workflow.conditionsJoin) {
                Text("All (AND)").tag(TransactionQueryJoin.and)
                Text("Any (OR)").tag(TransactionQueryJoin.or)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("transaction-filter-join")
            Text("Status and search filters still apply.")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .actualistReviewCard()
    }

    private var dateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $workflow.includesDate) {
                compactHeading("Date", symbol: "calendar")
            }
            .accessibilityIdentifier("transaction-filter-date-enabled")
            if workflow.includesDate {
                Picker("Date condition", selection: $workflow.dateOperation) {
                    Text("Is").tag(TransactionQueryDateOperation.isOn)
                    Text("Is approximately").tag(TransactionQueryDateOperation.isApproximately)
                    Text("Is after").tag(TransactionQueryDateOperation.isAfter)
                    Text("Is on or after").tag(TransactionQueryDateOperation.isOnOrAfter)
                    Text("Is before").tag(TransactionQueryDateOperation.isBefore)
                    Text("Is on or before").tag(TransactionQueryDateOperation.isOnOrBefore)
                }
                DatePicker("Date", selection: $workflow.date, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .accessibilityIdentifier("transaction-filter-date-value")
            }
        }
        .actualistReviewCard()
    }

    private func fieldCard(_ field: TransactionFilterField) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink {
                TransactionFilterOptionsView(workflow: workflow, field: field)
            } label: {
                HStack(spacing: 8) {
                    ReviewSummaryRow(
                        title: field.title,
                        value: workflow.selectionSummary(for: field),
                        symbol: field.symbol
                    )
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("transaction-filter-select-\(field.rawValue)")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(field.title), \(workflow.selectionSummary(for: field))")

            Picker("\(field.title) condition", selection: Binding(
                get: { workflow.operation(for: field) },
                set: { workflow.setOperation($0, for: field) }
            )) {
                Text("Is").tag(TransactionQueryIDOperation.isEqual)
                Text("Is not").tag(TransactionQueryIDOperation.isNotEqual)
                Text("Is one of").tag(TransactionQueryIDOperation.isOneOf)
                Text("Is not one of").tag(TransactionQueryIDOperation.isNotOneOf)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("transaction-filter-operation-\(field.rawValue)")
        }
        .actualistReviewCard(padding: 12)
    }

    @ViewBuilder
    private var preservedConditionsCard: some View {
        if !workflow.preservedConditionSummaries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                compactHeading("Existing conditions kept as-is", symbol: "info.circle")
                ForEach(Array(workflow.preservedConditionSummaries.enumerated()), id: \.offset) { _, summary in
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .actualistReviewCard(padding: 12)
        }
    }

    private func compactHeading(_ title: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ActualistTheme.secondaryText)
                .frame(width: 24, height: 24)
                .background(ActualistTheme.control, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(ActualistTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var loadStateCard: some View {
        if workflow.isLoading {
            ProgressView("Loading filter options")
                .frame(maxWidth: .infinity)
        } else if let errorMessage = workflow.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                Text("Some filter options could not be loaded.")
                    .font(.headline)
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.secondaryText)
                Button("Retry") {
                    workflow.loadOptions(
                        budgetID: budgetID,
                        repository: repository,
                        availableAccounts: availableAccounts
                    )
                }
                .buttonStyle(.glass)
            }
            .actualistReviewCard(padding: 12)
        }
    }
}
