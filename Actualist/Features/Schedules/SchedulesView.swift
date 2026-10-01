import SwiftUI

private enum SchedulesWorkflowSheet: String, Identifiable, Hashable {
    case management
    case posting

    var id: String { rawValue }
}

struct SchedulesLoadIdentity: Hashable, Sendable {
    let context: SchedulesViewContext
    let refreshRevision: UInt64
    let manualRefreshGeneration: UInt64
}

struct SchedulesView: View {
    @Environment(\.actualistDensity) private var density

    private let repository: any ScheduleRepositoryProtocol
    private let mutationRepository: any ScheduleMutationRepositoryProtocol
    private let postingRepository: any SchedulePostingRepositoryProtocol
    private let transactionRepository: any TransactionRepositoryProtocol
    private let context: SchedulesViewContext
    private let refreshRevision: UInt64
    @State private var viewModel: SchedulesViewModel
    @State private var managementCoordinator = ScheduleManagementCoordinator()
    @State private var postingCoordinator = SchedulePostingCoordinator()
    @State private var workflowSheet: SchedulesWorkflowSheet?
    @State private var manualRefreshGeneration: UInt64 = 0

    init(
        repository: any ScheduleRepositoryProtocol,
        mutationRepository: any ScheduleMutationRepositoryProtocol,
        postingRepository: any SchedulePostingRepositoryProtocol,
        transactionRepository: any TransactionRepositoryProtocol,
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
        self.mutationRepository = mutationRepository
        self.postingRepository = postingRepository
        self.transactionRepository = transactionRepository
        self.context = context
        self.refreshRevision = refreshRevision
        _viewModel = State(initialValue: SchedulesViewModel(context: context))
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        ReviewSheetContent {
            // Top search field (the app's picker pattern). A `.searchable`
            // drawer would take over the navigation bar while searching,
            // hiding the add/refresh toolbar actions.
            TextField("Search schedules", text: $viewModel.searchText)
                .reviewSheetFieldStyle()
                .accessibilityIdentifier("Search schedules")

            if context.isPrivacyModeEnabled {
                privacyNotice
            }

            if let errorMessage = viewModel.errorMessage,
               viewModel.snapshot != nil {
                errorBanner(errorMessage)
            }

            if viewModel.showsAuthoringUnavailableNotice {
                authoringUnavailableNotice
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
                    Text(section.kind.title)
                        .font(.headline.weight(.bold))
                    LazyVStack(spacing: 10) {
                        ForEach(section.rows) { row in
                            NavigationLink {
                                ScheduleDetailView(
                                    scheduleID: row.id,
                                    viewModel: viewModel,
                                    onEdit: beginEdit,
                                    onAction: beginActionReview,
                                    onPost: beginPostReview
                                )
                            } label: {
                                HStack(spacing: 10) {
                                    ScheduleRowView(row: row)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(ActualistTheme.secondaryText)
                                        .accessibilityHidden(true)
                                }
                                .actualistReviewCard()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if viewModel.completedScheduleCount > 0 {
                    Toggle(
                        "Show Completed (\(viewModel.completedScheduleCount))",
                        isOn: $viewModel.showsCompleted
                    )
                    .font(.subheadline)
                    .actualistReviewCard()
                    Text("Completed schedules are hidden by default.")
                        .font(.footnote)
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
            }
        }
        .navigationTitle("Schedules")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if viewModel.canAddSchedule {
                    Button {
                        beginCreate()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Schedule")
                    .accessibilityIdentifier("schedule-add")
                }

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
        .sheet(item: workflowSheetBinding) { route in
            switch route {
            case .management:
                ScheduleManagementSheet(
                    coordinator: managementCoordinator,
                    mutationRepository: mutationRepository,
                    currency: context.currency
                )
            case .posting:
                SchedulePostingReviewView(
                    coordinator: postingCoordinator,
                    postingRepository: postingRepository
                )
            }
        }
        .onChange(of: managementCoordinator.contentRevision) { requestRefresh() }
        .onChange(of: managementCoordinator.isPresented) { _, isPresented in
            if !isPresented, workflowSheet == .management {
                workflowSheet = nil
            }
        }
        .onChange(of: postingCoordinator.isPresented) { _, isPresented in
            if !isPresented, workflowSheet == .posting {
                workflowSheet = nil
            }
        }
        .onChange(of: postingCoordinator.state) { _, state in
            switch state {
            case .committed, .committedRefreshPending:
                requestRefresh()
            default:
                break
            }
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
        .actualistReviewCard()
    }

    private var authoringUnavailableNotice: some View {
        Label {
            Text("This budget's schedule data is from an older version of Actual, so new schedules can't be added here.")
        } icon: {
            Image(systemName: "lock.fill")
                .foregroundStyle(ActualistTheme.warning)
        }
        .font(ActualistTypography.rowLabel(for: density))
        .actualistReviewCard()
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
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(ActualistTypography.body(for: density))
                .foregroundStyle(ActualistTheme.danger)
            Button("Retry", systemImage: "arrow.clockwise") {
                requestRefresh()
            }
            .buttonStyle(.glass)
            .disabled(viewModel.isLoading || viewModel.isRefreshing)
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
    }

    private func requestRefresh() {
        manualRefreshGeneration &+= 1
    }

    private var workflowSheetBinding: Binding<SchedulesWorkflowSheet?> {
        Binding(
            get: { workflowSheet },
            set: { route in
                guard let route else {
                    dismissWorkflowSheet()
                    return
                }
                guard workflowSheet == nil || workflowSheet == route else { return }
                workflowSheet = route
            }
        )
    }

    private func beginCreate() {
        guard workflowSheet == nil else { return }
        managementCoordinator.beginCreate(
            expectedBudgetID: context.identity.budgetID,
            expectedGeneration: context.identity.sessionGeneration,
            today: context.asOfDayID,
            currency: context.currency,
            isPrivacyModeEnabled: context.isPrivacyModeEnabled,
            mutationRepository: mutationRepository,
            transactionRepository: transactionRepository
        )
        workflowSheet = .management
    }

    private func beginEdit(scheduleID: String) {
        guard workflowSheet == nil else { return }
        guard let detail = viewModel.scheduleDetail(id: scheduleID) else { return }
        managementCoordinator.beginEdit(
            detail: detail,
            expectedBudgetID: context.identity.budgetID,
            expectedGeneration: context.identity.sessionGeneration,
            today: context.asOfDayID,
            currency: context.currency,
            isPrivacyModeEnabled: context.isPrivacyModeEnabled,
            scheduleRepository: repository,
            mutationRepository: mutationRepository,
            transactionRepository: transactionRepository
        )
        workflowSheet = .management
    }

    private func beginActionReview(_ action: ScheduleManagementAction, scheduleID: String) {
        guard workflowSheet == nil else { return }
        guard let detail = viewModel.scheduleDetail(id: scheduleID) else { return }
        managementCoordinator.beginActionReview(
            action,
            detail: detail,
            expectedBudgetID: context.identity.budgetID,
            expectedGeneration: context.identity.sessionGeneration,
            currency: context.currency,
            isPrivacyModeEnabled: context.isPrivacyModeEnabled,
            today: context.asOfDayID,
            scheduleRepository: repository,
            mutationRepository: mutationRepository
        )
        workflowSheet = .management
    }

    private func beginPostReview(scheduleID: String) {
        guard workflowSheet == nil else { return }
        postingCoordinator.beginReview(
            scheduleID: scheduleID,
            expectedBudgetID: context.identity.budgetID,
            expectedGeneration: context.identity.sessionGeneration,
            today: context.asOfDayID,
            currency: context.currency,
            isPrivacyModeEnabled: context.isPrivacyModeEnabled,
            scheduleRepository: repository,
            postingRepository: postingRepository
        )
        workflowSheet = .posting
    }

    private func dismissWorkflowSheet() {
        switch workflowSheet {
        case .management:
            _ = managementCoordinator.cancel()
        case .posting:
            _ = postingCoordinator.cancel()
        case nil:
            break
        }
        workflowSheet = nil
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
            .foregroundStyle(ActualistTheme.primaryText)
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
