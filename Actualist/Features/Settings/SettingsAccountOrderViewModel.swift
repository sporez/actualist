import SwiftUI
import Observation

@MainActor
@Observable
final class SettingsAccountOrderViewModel {
    /// One reorderable run of rows: an Accounts-screen bucket that has
    /// accounts. Rows only move within their bucket; changing an account's
    /// group is a synced write that stays on the Accounts screen.
    struct OrderBucket: Identifiable, Equatable {
        var kind: AccountListLayout.Kind
        var bucketID: AccountListLayout.Bucket.ID
        var sectionTitle: String?
        var groupName: String?
        var accounts: [ActualAccount]

        var id: String { "\(kind.rawValue)-\(bucketID)" }
    }

    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private var generation = 0

    func buckets(using appState: AppState) -> [OrderBucket] {
        Self.buckets(from: sections(using: appState))
    }

    static func buckets(from sections: [AccountListLayout.Section]) -> [OrderBucket] {
        sections.flatMap { section in
            section.buckets
                .filter { !$0.accounts.isEmpty }
                .enumerated()
                .map { index, bucket in
                    OrderBucket(
                        kind: section.kind,
                        bucketID: bucket.id,
                        sectionTitle: index == 0 ? section.kind.title : nil,
                        groupName: bucket.group?.name,
                        accounts: bucket.accounts.map(\.account)
                    )
                }
        }
    }

    func hasCustomOrder(using appState: AppState) -> Bool {
        appState.settings.selectedBudgetID.map { appState.settings.accountOrderByBudgetID[$0] != nil } ?? false
    }

    func load(using appState: AppState) async {
        await load(budgetID: appState.settings.selectedBudgetID, repository: appState.accountRepository)
    }

    func load(budgetID: String?, repository: any AccountRepositoryProtocol) async {
        generation += 1
        let request = generation
        errorMessage = nil
        guard let budgetID else { isLoading = false; return }
        isLoading = repository.accountDisplays(budgetID: budgetID).isEmpty
        defer { if generation == request { isLoading = false } }
        do {
            try await repository.refreshAccountsWithBalances(budgetID: budgetID)
        } catch {
            guard generation == request, let message = error.userFacingMessage else { return }
            errorMessage = repository.accountDisplays(budgetID: budgetID).isEmpty
                ? message : "Could not refresh accounts. Showing cached accounts."
        }
    }

    func refresh(using appState: AppState) async {
        guard let budgetID = appState.settings.selectedBudgetID else { return }
        _ = await appState.refreshLocalFirstData(budgetID: budgetID, force: true)
        await load(using: appState)
    }

    func move(
        in bucket: OrderBucket,
        from source: IndexSet,
        to destination: Int,
        using appState: AppState
    ) {
        guard let budgetID = appState.settings.selectedBudgetID,
              let ordered = AccountListLayout.preferredIDs(
                  in: sections(using: appState),
                  kind: bucket.kind,
                  bucketID: bucket.bucketID,
                  fromOffsets: source,
                  toOffset: destination
              ) else { return }
        appState.updateAccountOrder(ordered, budgetID: budgetID)
    }

    func reset(using appState: AppState) {
        guard let budgetID = appState.settings.selectedBudgetID else { return }
        appState.resetAccountOrder(budgetID: budgetID)
    }

    private func sections(using appState: AppState) -> [AccountListLayout.Section] {
        guard let budgetID = appState.settings.selectedBudgetID else { return [] }
        return AccountListLayout.sections(
            displays: appState.accountRepository.accountDisplays(budgetID: budgetID),
            groups: appState.accountRepository.accountGroups(budgetID: budgetID),
            preferredIDs: appState.settings.accountOrderByBudgetID[budgetID] ?? []
        )
    }
}
