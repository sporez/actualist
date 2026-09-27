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

    var displayState: AccountTransactionsDisplayState? {
        guard let loaded = snapshot?.loaded else { return nil }
        return AccountTransactionFeedProjection(
            scope: .spending,
            loaded: loaded,
            activePage: loaded,
            statusFilter: .all,
            query: "",
            pendingNewTransactionIDs: [],
            privacyModeEnabled: isPrivacyModeEnabled,
            currency: currency
        ).displayState
    }

    var contributingCount: Int {
        snapshot?.contributingTransactionIDs.count ?? 0
    }

    func isContext(_ transaction: ActualTransaction) -> Bool {
        guard let id = transaction.id else { return true }
        return snapshot?.contributingTransactionIDs.contains(id) != true
    }

    func updatePrivacyMode(_ isEnabled: Bool) {
        isPrivacyModeEnabled = isEnabled
    }

    func retry() {
        requestIdentity = UUID()
    }

    func load(using appState: AppState, request: TransactionDrilldownRequest) async {
        guard let budgetID = appState.settings.selectedBudgetID else {
            snapshot = nil
            state = .failed("Open a budget before loading these transactions.")
            return
        }
        isPrivacyModeEnabled = appState.settings.randomizedDisplayValuesEnabled
        currency = appState.localFirstStore.budgetCurrency(budgetID: budgetID)
        state = .loading
        do {
            snapshot = try await appState.reportsRepository.reportTransactionDrilldown(
                budgetID: budgetID,
                request: request
            )
            guard !Task.isCancelled else { return }
            state = .loaded
        } catch {
            guard !error.isCancellation, !Task.isCancelled else { return }
            state = .failed(error.userFacingMessage ?? "These transactions could not be loaded.")
        }
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
                            if viewModel.isContext(row.transaction) {
                                Text("Split context — only matching split lines are counted")
                                    .font(.caption)
                                    .foregroundStyle(ActualistTheme.warning)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.top, 6)
                            }
                            TransactionRow(
                                transaction: row.transaction,
                                semantics: row.semantics,
                                accountName: row.accountName,
                                isPrivacyModeEnabled: viewModel.isPrivacyModeEnabled,
                                highlightsIncomeAmounts: true,
                                showsBottomSeparator: true
                            )
                        }
                        .background(ActualistTheme.surface)
                    }
                }
            }
        }
    }

    private var loadIdentity: ReportDrilldownLoadIdentity {
        ReportDrilldownLoadIdentity(
            signature: request.query.signature,
            requestID: viewModel.requestIdentity,
            budgetID: appState.settings.selectedBudgetID,
            sessionGeneration: appState.localFirstStore.budgetSessionGeneration
        )
    }
}

private struct ReportDrilldownLoadIdentity: Hashable {
    let signature: TransactionQuerySignature
    let requestID: UUID
    let budgetID: String?
    let sessionGeneration: Int
}
