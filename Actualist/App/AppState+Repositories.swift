extension AppState {
    var budgetRepository: any BudgetRepositoryProtocol { localFirstStore.budget }
    var transactionRepository: any TransactionRepositoryProtocol { localFirstStore }
    var accountRepository: any AccountRepositoryProtocol { localFirstStore.accounts }
    var payeeRepository: any PayeeRepositoryProtocol { localFirstStore.payees }
    var ruleRepository: any RuleRepositoryProtocol { localFirstStore.rules }
    var reportsRepository: any ReportsRepositoryProtocol { localFirstStore.reports }

    func recordLocalDataMutation() {
        localDataRevision &+= 1
    }
}
