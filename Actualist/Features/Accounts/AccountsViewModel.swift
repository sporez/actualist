import Foundation
import Observation

@MainActor
@Observable
final class AccountsViewModel {
    enum GroupEditor: Equatable {
        case create
        case rename(ActualAccountGroup)

        var title: String {
            switch self {
            case .create: "New Group"
            case .rename: "Rename Group"
            }
        }
    }

    struct DeleteReview: Equatable, Identifiable, Sendable {
        var group: ActualAccountGroup
        var memberNames: [String]

        var id: String { group.id }
    }

    var isLoading = true
    var errorMessage: String?
    var isAddAccountPresented = false
    var addAccountViewModel = AddAccountViewModel()
    var contentRevision: UInt64 = 0
    var groupEditor: GroupEditor?
    var groupEditorName = ""
    var deleteReview: DeleteReview?

    private var budgetID: String?
    private var submitGeneration = 0
    /// Supersede token for `loadLocal`, separate from the write token above.
    private var loadGeneration = 0
    /// The write that owns the busy state. Cleared by that write when it ends,
    /// or by a budget change, which detaches the write without erasing busy
    /// state for a later one.
    private var runningOperationID: Int?
    private var operationCounter = 0

    var isSubmitting: Bool { runningOperationID != nil }

    private struct LayoutInputs: Equatable {
        var displays: [AccountDisplay]
        var groups: [ActualAccountGroup]
        var preferredIDs: [String]
    }

    /// The last layout and the inputs it was built from. Not observed: reading
    /// the sections during a render must not invalidate it.
    @ObservationIgnored private var layoutMemo: (inputs: LayoutInputs, sections: [AccountListLayout.Section])?
    /// Layouts actually built, for the work-count test.
    @ObservationIgnored private(set) var layoutBuildCount = 0

    /// One layout per distinct inputs, however many times a render asks.
    func sections(
        displays: [AccountDisplay],
        groups: [ActualAccountGroup],
        preferredIDs: [String]
    ) -> [AccountListLayout.Section] {
        let inputs = LayoutInputs(displays: displays, groups: groups, preferredIDs: preferredIDs)
        if let layoutMemo, layoutMemo.inputs == inputs { return layoutMemo.sections }
        let sections = AccountListLayout.sections(displays: displays, groups: groups, preferredIDs: preferredIDs)
        layoutBuildCount += 1
        layoutMemo = (inputs, sections)
        return sections
    }

    var canSubmitGroupEditor: Bool {
        !trimmedGroupEditorName.isEmpty && !isSubmitting
    }

    var trimmedGroupEditorName: String {
        groupEditorName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isGroupEditorPresented: Bool {
        get { groupEditor != nil }
        set {
            if !newValue {
                groupEditor = nil
                groupEditorName = ""
            }
        }
    }

    func loadLocal(
        budgetID: String?,
        hasCachedAccounts: Bool,
        repository: any AccountRepositoryProtocol
    ) async {
        loadGeneration += 1
        let generation = loadGeneration
        if budgetID != self.budgetID {
            self.budgetID = budgetID
            submitGeneration += 1
            runningOperationID = nil
            groupEditor = nil
            groupEditorName = ""
            deleteReview = nil
            errorMessage = nil
        }

        guard let budgetID else {
            isLoading = false
            errorMessage = nil
            return
        }

        isLoading = !hasCachedAccounts
        errorMessage = nil
        do {
            try await repository.refreshAccountsWithBalances(budgetID: budgetID)
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = hasCachedAccounts ? nil : error.userFacingMessage
        }
        guard generation == loadGeneration else { return }
        isLoading = false
        noteContentChange()
    }

    func refresh(
        budgetID: String?,
        hasCachedAccounts: Bool,
        repository: any AccountRepositoryProtocol,
        sync: () async -> Void
    ) async {
        guard budgetID != nil else {
            return
        }
        await sync()
        await loadLocal(
            budgetID: budgetID,
            hasCachedAccounts: hasCachedAccounts,
            repository: repository
        )
    }

    func presentCreateGroup() {
        groupEditor = .create
        groupEditorName = ""
        errorMessage = nil
    }

    func presentRename(_ group: ActualAccountGroup) {
        groupEditor = .rename(group)
        groupEditorName = group.name
        errorMessage = nil
    }

    func presentDelete(_ group: ActualAccountGroup, displays: [AccountDisplay]) {
        deleteReview = DeleteReview(
            group: group,
            memberNames: displays
                .filter { $0.account.accountGroupId == group.id }
                .map(\.account.name)
        )
        errorMessage = nil
    }

    func cancelDelete() {
        deleteReview = nil
    }

    func submitGroupEditor(
        budgetID: String?,
        repository: any AccountRepositoryProtocol
    ) async -> Bool {
        errorMessage = nil
        guard !isSubmitting else {
            return false
        }
        guard let budgetID, let editor = groupEditor else {
            errorMessage = "Choose a budget before editing groups."
            return false
        }
        let name = trimmedGroupEditorName
        guard !name.isEmpty else {
            errorMessage = "Enter a group name."
            return false
        }

        let (operationID, generation) = beginOperation()
        defer { endOperation(operationID) }

        do {
            switch editor {
            case .create:
                try await repository.createAccountGroupAndRefresh(budgetID: budgetID, name: name)
            case .rename(let group):
                try await repository.renameAccountGroupAndRefresh(
                    budgetID: budgetID,
                    groupID: group.id,
                    name: name
                )
            }
            guard generation == submitGeneration else {
                return false
            }
            groupEditor = nil
            groupEditorName = ""
            noteContentChange()
            return true
        } catch {
            guard generation == submitGeneration else {
                return false
            }
            errorMessage = error.userFacingMessage
            return false
        }
    }

    func confirmDelete(
        budgetID: String?,
        repository: any AccountRepositoryProtocol
    ) async {
        guard let budgetID, let review = deleteReview, !isSubmitting else {
            return
        }
        let (operationID, generation) = beginOperation()
        defer { endOperation(operationID) }
        do {
            try await repository.deleteAccountGroupAndRefresh(
                budgetID: budgetID,
                groupID: review.group.id
            )
            guard generation == submitGeneration else {
                return
            }
            deleteReview = nil
            noteContentChange()
        } catch {
            guard generation == submitGeneration else {
                return
            }
            errorMessage = error.userFacingMessage
        }
    }

    func moveAccount(
        _ account: AccountDisplay,
        toGroupID groupID: String?,
        budgetID: String?,
        repository: any AccountRepositoryProtocol
    ) async {
        guard let budgetID, !isSubmitting else {
            return
        }
        let (operationID, generation) = beginOperation()
        defer { endOperation(operationID) }
        do {
            try await repository.moveAccountToGroupAndRefresh(
                budgetID: budgetID,
                accountID: account.account.id,
                groupID: groupID
            )
            guard generation == submitGeneration else {
                return
            }
            noteContentChange()
        } catch {
            guard generation == submitGeneration else {
                return
            }
            errorMessage = error.userFacingMessage
        }
    }

    func moveGroup(
        _ group: ActualAccountGroup,
        beforeGroupID: String?,
        budgetID: String?,
        repository: any AccountRepositoryProtocol
    ) async {
        guard let budgetID, !isSubmitting else {
            return
        }
        let (operationID, generation) = beginOperation()
        defer { endOperation(operationID) }
        do {
            try await repository.moveAccountGroupAndRefresh(
                budgetID: budgetID,
                groupID: group.id,
                beforeGroupID: beforeGroupID
            )
            guard generation == submitGeneration else {
                return
            }
            noteContentChange()
        } catch {
            guard generation == submitGeneration else {
                return
            }
            errorMessage = error.userFacingMessage
        }
    }

    private func beginOperation() -> (id: Int, generation: Int) {
        operationCounter += 1
        runningOperationID = operationCounter
        submitGeneration += 1
        return (operationCounter, submitGeneration)
    }

    private func endOperation(_ id: Int) {
        if runningOperationID == id {
            runningOperationID = nil
        }
    }

    private func noteContentChange() {
        contentRevision &+= 1
    }

    func moveGroupUp(
        _ group: ActualAccountGroup,
        groups: [ActualAccountGroup],
        budgetID: String?,
        repository: any AccountRepositoryProtocol
    ) async {
        guard let index = groups.firstIndex(where: { $0.id == group.id }), index > 0 else {
            return
        }
        await moveGroup(
            group,
            beforeGroupID: groups[index - 1].id,
            budgetID: budgetID,
            repository: repository
        )
    }

    func moveGroupDown(
        _ group: ActualAccountGroup,
        groups: [ActualAccountGroup],
        budgetID: String?,
        repository: any AccountRepositoryProtocol
    ) async {
        guard let index = groups.firstIndex(where: { $0.id == group.id }),
              index < groups.count - 1 else {
            return
        }
        let beforeID = index + 2 < groups.count ? groups[index + 2].id : nil
        await moveGroup(
            group,
            beforeGroupID: beforeID,
            budgetID: budgetID,
            repository: repository
        )
    }
}
