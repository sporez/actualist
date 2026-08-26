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
    var isSubmitting = false
    var contentRevision: UInt64 = 0
    var groupEditor: GroupEditor?
    var groupEditorName = ""
    var deleteReview: DeleteReview?
    var movingAccount: AccountDisplay?
    var isMovePresented = false
    var addingToGroup: ActualAccountGroup?
    var isAddToGroupPresented = false

    private var budgetID: String?
    private var submitGeneration = 0

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
        if budgetID != self.budgetID {
            self.budgetID = budgetID
            submitGeneration += 1
            groupEditor = nil
            groupEditorName = ""
            deleteReview = nil
            movingAccount = nil
            isMovePresented = false
            addingToGroup = nil
            isAddToGroupPresented = false
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
            errorMessage = hasCachedAccounts ? nil : error.localizedDescription
        }
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

    func presentMove(_ account: AccountDisplay) {
        movingAccount = account
        isMovePresented = true
        errorMessage = nil
    }

    func presentAddToGroup(_ group: ActualAccountGroup) {
        addingToGroup = group
        isAddToGroupPresented = true
        errorMessage = nil
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

        isSubmitting = true
        submitGeneration += 1
        let generation = submitGeneration
        defer {
            if generation == submitGeneration {
                isSubmitting = false
            }
        }

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
            errorMessage = error.localizedDescription
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
        isSubmitting = true
        submitGeneration += 1
        let generation = submitGeneration
        defer {
            if generation == submitGeneration {
                isSubmitting = false
            }
        }
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
            errorMessage = error.localizedDescription
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
        isMovePresented = false
        isAddToGroupPresented = false
        isSubmitting = true
        submitGeneration += 1
        let generation = submitGeneration
        defer {
            if generation == submitGeneration {
                isSubmitting = false
            }
        }
        do {
            try await repository.moveAccountToGroupAndRefresh(
                budgetID: budgetID,
                accountID: account.account.id,
                groupID: groupID
            )
            guard generation == submitGeneration else {
                return
            }
            movingAccount = nil
            addingToGroup = nil
            noteContentChange()
        } catch {
            guard generation == submitGeneration else {
                return
            }
            errorMessage = error.localizedDescription
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
        isSubmitting = true
        submitGeneration += 1
        let generation = submitGeneration
        defer {
            if generation == submitGeneration {
                isSubmitting = false
            }
        }
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
            errorMessage = error.localizedDescription
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
