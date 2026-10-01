import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class ReportTransactionDrilldownViewModel {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    private(set) var snapshot: ReportTransactionDrilldownSnapshot?
    private(set) var state: LoadState = .loading
    private(set) var isPrivacyModeEnabled = false
    private(set) var currency: BudgetCurrency = .usd
    private(set) var requestIdentity = UUID()
    private var loadGeneration = 0
    private var activeLoad: LoadContext?

    private struct LoadContext {
        let generation: Int
        let budgetID: String
        let sessionIdentity: ReportExplorerSessionIdentity
        let request: TransactionDrilldownRequest
    }

    var displayState: ReportTransactionDrilldownDisplayState? {
        snapshot.map {
            ReportTransactionDrilldownProjection(
                snapshot: $0,
                privacyModeEnabled: isPrivacyModeEnabled
            ).displayState
        }
    }

    var contributingCount: Int {
        snapshot?.contributingTransactionIDs.count ?? 0
    }

    func updatePrivacyMode(_ isEnabled: Bool) {
        isPrivacyModeEnabled = isEnabled
    }

    func retry() {
        invalidateActiveLoad()
        snapshot = nil
        state = .loading
        requestIdentity = UUID()
    }

    func load(using appState: AppState, request: TransactionDrilldownRequest) async {
        guard !Task.isCancelled else { return }
        guard let budgetID = appState.settings.selectedBudgetID else {
            invalidateActiveLoad()
            snapshot = nil
            state = .failed("Open a budget before loading these transactions.")
            return
        }
        await load(
            budgetID: budgetID,
            request: request,
            repository: appState.reportsRepository,
            privacyModeEnabled: appState.settings.randomizedDisplayValuesEnabled,
            currency: appState.localFirstStore.budgetCurrency(budgetID: budgetID)
        )
    }

    func load(
        budgetID: String,
        request: TransactionDrilldownRequest,
        repository: any ReportsRepositoryProtocol,
        privacyModeEnabled: Bool,
        currency: BudgetCurrency = .usd
    ) async {
        guard !Task.isCancelled else { return }
        let sessionIdentity = repository.reportExplorerSessionIdentity(budgetID: budgetID)
        loadGeneration &+= 1
        let context = LoadContext(
            generation: loadGeneration,
            budgetID: budgetID,
            sessionIdentity: sessionIdentity,
            request: request
        )
        activeLoad = context
        snapshot = nil
        isPrivacyModeEnabled = privacyModeEnabled
        self.currency = currency
        state = .loading
        do {
            let loaded = try await repository.reportTransactionDrilldown(
                budgetID: budgetID,
                request: request
            )
            guard loaded.request == context.request,
                  accepts(context, repository: repository),
                  !Task.isCancelled else { return }
            snapshot = loaded
            state = .loaded
        } catch {
            guard accepts(context, repository: repository),
                  !error.isCancellation,
                  !Task.isCancelled else { return }
            snapshot = nil
            state = .failed(error.userFacingMessage ?? "These transactions could not be loaded.")
        }
    }

    private func accepts(
        _ context: LoadContext,
        repository: any ReportsRepositoryProtocol
    ) -> Bool {
        guard let activeLoad else { return false }
        return loadGeneration == context.generation
            && activeLoad.generation == context.generation
            && activeLoad.budgetID == context.budgetID
            && activeLoad.request == context.request
            && activeLoad.sessionIdentity == context.sessionIdentity
            && repository.reportExplorerSessionIdentity(budgetID: context.budgetID)
                == context.sessionIdentity
    }

    private func invalidateActiveLoad() {
        loadGeneration &+= 1
        activeLoad = nil
    }
}

struct ReportTransactionDrilldownView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = ReportTransactionDrilldownViewModel()

    let title: String
    let request: TransactionDrilldownRequest

    var body: some View {
        Group {
            switch viewModel.state {
            case .loading:
                ProgressView("Loading transactions")
            case .failed(let message):
                ContentUnavailableView {
                    Label("Transactions Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { viewModel.retry() }
                        .buttonStyle(.glassProminent)
                }
            case .loaded:
                transactionList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ActualistTheme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadIdentity) {
            await viewModel.load(using: appState, request: request)
        }
        .onChange(of: appState.settings.randomizedDisplayValuesEnabled) { _, enabled in
            viewModel.updatePrivacyMode(enabled)
        }
        .environment(\.budgetCurrency, viewModel.currency)
        .accessibilityIdentifier("report-drilldown-view")
    }

    private var transactionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                Text("\(viewModel.contributingCount) contributing transaction\(viewModel.contributingCount == 1 ? "" : "s")")
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)

                ForEach(viewModel.displayState?.groups ?? []) { group in
                    Text(group.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(ActualistTheme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    ForEach(group.rows) { row in
                        VStack(spacing: 0) {
                            relationshipLabel(for: row)
                            TransactionRow(
                                transaction: row.transaction,
                                semantics: row.semantics,
                                accountName: row.accountName,
                                isPrivacyModeEnabled: viewModel.isPrivacyModeEnabled,
                                highlightsIncomeAmounts: true,
                                showsBottomSeparator: true
                            )
                        }
                        .padding(.leading, row.relationship.isSplitChild ? 22 : 0)
                        .background(row.role == .contributor
                            ? ActualistTheme.surface
                            : ActualistTheme.elevatedSurface)
                        .accessibilityIdentifier("report-drilldown-row-\(row.id)")
                    }
                }
            }
            // Keep the last rows clear of the floating tab bar, matching the
            // bottom clearance other scrolling tab screens use.
            .padding(.bottom, 28)
        }
    }

    private func relationshipLabel(
        for row: ReportTransactionDrilldownRowPresentation
    ) -> some View {
        HStack(spacing: 6) {
            if row.relationship.isSplitChild {
                Image(systemName: "arrow.turn.down.right")
                    .accessibilityHidden(true)
                Text("Split line")
            } else if row.semantics.isParent {
                Image(systemName: "square.split.1x2.fill")
                    .accessibilityHidden(true)
                Text("Split transaction")
            }
            Spacer(minLength: 8)
            if row.role == .contributor {
                Label("Counted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(ActualistTheme.positive)
                    .accessibilityIdentifier("report-drilldown-contributor-\(row.id)")
            } else {
                Label("Context only", systemImage: "info.circle.fill")
                    .foregroundStyle(ActualistTheme.warning)
                    .accessibilityIdentifier("report-drilldown-context-\(row.id)")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(ActualistTheme.secondaryText)
        .padding(.horizontal, 14)
        .padding(.top, 7)
    }

    private var loadIdentity: ReportDrilldownLoadIdentity {
        ReportDrilldownLoadIdentity(
            request: request,
            requestID: viewModel.requestIdentity,
            budgetID: appState.settings.selectedBudgetID,
            sessionGeneration: appState.localFirstStore.budgetSessionGeneration
        )
    }
}

struct ReportDrilldownLoadIdentity: Hashable {
    let request: TransactionDrilldownRequest
    let requestID: UUID
    let budgetID: String?
    let sessionGeneration: Int
}

private extension ReportTransactionDrilldownRelationship {
    var isSplitChild: Bool {
        if case .splitChild = self { true } else { false }
    }
}
