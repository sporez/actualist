import Foundation
import UserNotifications

@MainActor
struct NewTransactionNotificationCoordinator {
    func pendingIDs(
        in storage: [String: [String]],
        budgetID: String,
        accountID: String
    ) -> Set<String> {
        Set(storage[key(budgetID: budgetID, accountID: accountID)] ?? [])
    }

    func pendingIDs(
        in storage: [String: [String]],
        budgetID: String
    ) -> Set<String> {
        let prefix = "\(budgetID)|"
        return storage.reduce(into: Set<String>()) { result, entry in
            guard entry.key.hasPrefix(prefix) else {
                return
            }
            result.formUnion(entry.value)
        }
    }

    func record(
        _ transactionIDs: [String],
        budgetID: String,
        accountID: String,
        in storage: inout [String: [String]]
    ) {
        let storageKey = key(budgetID: budgetID, accountID: accountID)
        var existing = Set(storage[storageKey] ?? [])
        existing.formUnion(transactionIDs)
        storage[storageKey] = existing.sorted()
    }

    @discardableResult
    func clear(
        budgetID: String,
        accountID: String,
        in storage: inout [String: [String]]
    ) -> Bool {
        let storageKey = key(budgetID: budgetID, accountID: accountID)
        guard storage[storageKey] != nil else {
            return false
        }
        storage[storageKey] = nil
        return true
    }

    @discardableResult
    func clear(
        budgetID: String,
        in storage: inout [String: [String]]
    ) -> Bool {
        let prefix = "\(budgetID)|"
        let keys = storage.keys.filter { $0.hasPrefix(prefix) }
        guard !keys.isEmpty else {
            return false
        }
        for key in keys {
            storage[key] = nil
        }
        return true
    }

    func post(
        budgetID: String,
        trigger: UNNotificationTrigger? = nil
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = NewTransactionsNotificationCopy.title
        content.body = NewTransactionsNotificationCopy.body
        content.sound = .default
        content.userInfo = [
            "budgetID": budgetID
        ]

        let request = UNNotificationRequest(
            identifier: "actualist.new-transactions.\(budgetID).\(Date().timeIntervalSince1970)",
            content: content,
            trigger: trigger
        )
        try await UNUserNotificationCenter.current().add(request)
    }

    #if DEBUG
    func postDebug(
        budgetID: String,
        repository: any AccountRepositoryProtocol
    ) async throws {
        let notificationCenter = UNUserNotificationCenter.current()
        let notificationSettings = await notificationCenter.notificationSettings()
        if notificationSettings.authorizationStatus != .authorized {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
            guard granted else {
                throw DebugNotificationError.notificationsDenied
            }
        }

        if repository.accountDisplays(budgetID: budgetID).isEmpty {
            try await repository.refreshAccountsWithBalances(budgetID: budgetID)
        }

        let accounts = repository.accountDisplays(budgetID: budgetID).map(\.account)
        guard accounts.contains(where: { !$0.closed }) || !accounts.isEmpty else {
            throw DebugNotificationError.noAccounts
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        try await post(budgetID: budgetID, trigger: trigger)
    }
    #endif

    private func key(budgetID: String, accountID: String) -> String {
        "\(budgetID)|\(accountID)"
    }
}

#if DEBUG
enum DebugNotificationError: LocalizedError {
    case missingBudget
    case noAccounts
    case notificationsDenied

    var errorDescription: String? {
        switch self {
        case .missingBudget:
            "Select a budget before posting a test notification."
        case .noAccounts:
            "No accounts are loaded for the selected budget."
        case .notificationsDenied:
            "Notification permission is not granted."
        }
    }
}
#endif
