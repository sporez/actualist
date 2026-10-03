extension AppState {
    var budgetRepository: any BudgetRepositoryProtocol { localFirstStore }
    var transactionRepository: any TransactionRepositoryProtocol { localFirstStore }
    var accountRepository: any AccountRepositoryProtocol { localFirstStore }
    var payeeRepository: any PayeeRepositoryProtocol { localFirstStore }
    var ruleRepository: any RuleRepositoryProtocol { localFirstStore }
    var reportsRepository: any ReportsRepositoryProtocol { localFirstStore }

    func recordLocalDataMutation() {
        localDataRevision &+= 1
    }
}
