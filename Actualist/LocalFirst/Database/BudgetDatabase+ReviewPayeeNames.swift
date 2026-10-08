import Foundation
import GRDB

extension BudgetDatabase {
    /// Display names for review rows, read in the review's own transaction.
    /// Follows the feed: a merged payee resolves through `payee_mapping`, and a
    /// transfer payee with no name reads as its counterpart account. A missing
    /// entry means the caller keeps its generic row title.
    func reviewPayeeNames(
        payeeIDs: some Sequence<String?>,
        db: Database
    ) throws -> [String: String] {
        let ids = Set(payeeIDs.compactMap { $0 }.filter { !$0.isEmpty })
        guard !ids.isEmpty, try tableExists("payees", db: db) else { return [:] }
        let payeeColumns = try columnSet(for: "payees", db: db)
        guard payeeColumns.contains("id"), payeeColumns.contains("name") else { return [:] }
        let transferColumn = ["transfer_acct", "transfer_account"].first(where: payeeColumns.contains)
        var hasAccounts = false
        if try tableExists("accounts", db: db) {
            hasAccounts = try columnSet(for: "accounts", db: db).isSuperset(of: ["id", "name"])
        }
        let targets = try payeeMappingTargets(db: db)
        let transferSelect = transferColumn.map { ", \(quotedIdentifier($0)) AS transfer" } ?? ""

        var names: [String: String] = [:]
        for id in ids {
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT name\(transferSelect) FROM payees WHERE id = ?",
                arguments: [targets[id] ?? id]
            ) else { continue }
            if let name = (row["name"] as String?)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                names[id] = name
            } else if hasAccounts, transferColumn != nil,
                      let accountID = row["transfer"] as String?, !accountID.isEmpty,
                      let accountName = try String.fetchOne(
                          db, sql: "SELECT name FROM accounts WHERE id = ?", arguments: [accountID]
                      ), !accountName.isEmpty {
                names[id] = accountName
            }
        }
        return names
    }
}
