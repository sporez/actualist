import SwiftUI

struct SchedulesLoadIdentity: Hashable, Sendable {
    let context: SchedulesViewContext
    let refreshRevision: UInt64
    let manualRefreshGeneration: UInt64
}

struct SchedulesView: View {
    @Environment(\.actualistDensity) private var density

    private let repository: any ScheduleRepositoryProtocol
    private let context: SchedulesViewContext
    private let refreshRevision: UInt64
    @State private var viewModel: SchedulesViewModel
    @State private var manualRefreshGeneration: UInt64 = 0

    init(
        repository: any ScheduleRepositoryProtocol,
        budgetID: String,
        budgetSessionGeneration: Int,
        currency: BudgetCurrency,
        isPrivacyModeEnabled: Bool,
        refreshRevision: UInt64,
        asOfDayID: String
    ) {
        let context = SchedulesViewContext(
            identity: SchedulesBudgetIdentity(
                budgetID: budgetID,
                sessionGeneration: budgetSessionGeneration
            ),
            currency: currency,
            isPrivacyModeEnabled: isPrivacyModeEnabled,
            asOfDayID: asOfDayID
        )
        self.repository = repository
        self.context = context
        self.refreshRevision = refreshRevision
        _viewModel = State(initialValue: SchedulesViewModel(context: context))
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        List {
            if context.isPrivacyModeEnabled {
                privacyNotice
            }

            if let errorMessage = viewModel.errorMessage,
               viewModel.snapshot != nil {
                errorBanner(errorMessage)
            }

            if viewModel.isLoading && viewModel.snapshot == nil {
                loadingState
            } else if let errorMessage = viewModel.errorMessage,
                      viewModel.snapshot == nil {
                unavailableState(
                    title: "Schedules Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: errorMessage,
                    showsRetry: true
                )
            } else {
                emptyState(viewModel.emptyState)

                ForEach(viewModel.sections) { section in
                    Section(section.kind.title) {
                        ForEach(section.rows) { row in
                            NavigationLink {
                                ScheduleDetailView(
                                    scheduleID: row.id,
                                    viewModel: viewModel
                                )
                            } label: {
                                ScheduleRowView(row: row)
                            }
                        }
                    }
                }

                if viewModel.completedScheduleCount > 0 {
                    Section {
                        Toggle(
                            "Show Completed (\(viewModel.completedScheduleCount))",
                            isOn: $viewModel.showsCompleted
                        )
                    } footer: {
                        Text("Completed schedules are hidden by default.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .tint(ActualistTheme.accent)
        .navigationTitle("Schedules")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText, prompt: "Search schedules")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing schedules")
                }
                Button {
                    requestRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh Schedules")
                .disabled(viewModel.isLoading || viewModel.isRefreshing)
            }
        }
        .task(id: SchedulesLoadIdentity(
            context: context,
            refreshRevision: refreshRevision,
            manualRefreshGeneration: manualRefreshGeneration
        )) {
            await viewModel.load(context: context, repository: repository)
        }
        .refreshable {
            await viewModel.load(context: context, repository: repository)
        }
    }

    private var privacyNotice: some View {
        Label {
            Text("Schedule names, accounts, payees, and amounts use sample values.")
        } icon: {
            Image(systemName: "eye.slash.fill")
                .foregroundStyle(ActualistTheme.warning)
        }
        .font(ActualistTypography.rowLabel(for: density))
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Loading schedules")
                .foregroundStyle(ActualistTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 28)
    }

    private func errorBanner(_ message: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(ActualistTypography.body(for: density))
                    .foregroundStyle(ActualistTheme.danger)
                Button("Retry", systemImage: "arrow.clockwise") {
                    requestRefresh()
                }
                .disabled(viewModel.isLoading || viewModel.isRefreshing)
            }
        }
    }

    @ViewBuilder
    private func emptyState(_ state: ScheduleListEmptyState) -> some View {
        switch state {
        case .none:
            EmptyView()
        case .noSchedules:
            unavailableState(
                title: "No Schedules",
                systemImage: "calendar.badge.clock",
                description: "Schedules created in Actual will appear here.",
                showsRetry: false
            )
        case .noActiveSchedules:
            unavailableState(
                title: "No Active Schedules",
                systemImage: "checkmark.circle",
                description: "Show completed schedules to review past items.",
                showsRetry: false
            )
        case .noMatches:
            unavailableState(
                title: "No Matching Schedules",
                systemImage: "magnifyingglass",
                description: "Try another name, account, payee, amount, date, or status.",
                showsRetry: false
            )
        }
    }

    private func unavailableState(
        title: String,
        systemImage: String,
        description: String,
        showsRetry: Bool
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        } actions: {
            if showsRetry {
                Button("Retry", systemImage: "arrow.clockwise") {
                    requestRefresh()
                }
                .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .listRowBackground(Color.clear)
    }

    private func requestRefresh() {
        manualRefreshGeneration &+= 1
    }
}

private struct ScheduleRowView: View {
    @Environment(\.actualistDensity) private var density
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let row: ScheduleRowPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            titleAndAmount

            Text(row.referenceText)
                .font(ActualistTypography.rowLabel(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

            HStack(spacing: 8) {
                Text(row.dateText)
                    .font(ActualistTypography.rowLabel(for: density))
                    .foregroundStyle(ActualistTheme.secondaryText)
                Spacer(minLength: 6)
                Text(row.statusText)
                    .font(ActualistTypography.rowBadge(for: density))
                    .foregroundStyle(row.tone.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(row.tone.color.opacity(0.14), in: Capsule())
            }

            if let limitationText = row.limitationText {
                Label(limitationText, systemImage: "exclamationmark.triangle.fill")
                    .font(ActualistTypography.rowLabel(for: density))
                    .foregroundStyle(ActualistTheme.warning)
            }
        }
        .padding(.vertical, density.transactionRowVerticalPadding / 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var titleAndAmount: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 3) {
                title
                amount
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                title
                Spacer(minLength: 8)
                amount
            }
        }
    }

    private var title: some View {
        Text(row.title)
            .font(ActualistTypography.rowTitle(for: density))
            .foregroundStyle(ActualistTheme.primaryText)
            .lineLimit(2)
    }

    private var amount: some View {
        Text(row.amountText)
            .font(ActualistTypography.rowValue(for: density))
            .foregroundStyle(row.tone.color)
            .minimumScaleFactor(0.72)
    }
}

extension SchedulePresentationTone {
    var color: Color {
        switch self {
        case .accent: ActualistTheme.accent
        case .positive: ActualistTheme.positive
        case .warning: ActualistTheme.warning
        case .danger: ActualistTheme.danger
        case .neutral: ActualistTheme.secondaryText
        }
    }
}
