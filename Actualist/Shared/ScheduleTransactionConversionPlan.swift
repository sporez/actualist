import Foundation

/// Pinned Actual conversion fields for a one-time schedule definition, as the
/// web app's `createSingleTimeScheduleFromTransaction` builds them. Replayed
/// against the Schedules oracle's `conversion` family.
struct ScheduleTransactionConversionPlan: Hashable, Sendable {
    let name: String
    let conditions: [RuleJSONValue]
    /// `link-schedule` first, then the copied fields, the order Actual's
    /// `rule-update` leaves them in.
    let actions: [RuleJSONValue]
    let postsTransaction: Bool
}

enum ScheduleTransactionConversionPlanner {
    static func plan(
        from transaction: ActualTransaction,
        scheduleID: String
    ) -> ScheduleTransactionConversionPlan {
        var conditions: [RuleJSONValue] = [condition("date", value: .string(transaction.date))]
        // Actual's transaction AQL view exposes IFNULL(amount, 0); nullable
        // SQLite values therefore become an exact zero condition upstream.
        conditions.append(condition("amount", value: .number(Double(transaction.amount ?? 0))))
        if let payeeID = transaction.payee, !payeeID.isEmpty {
            // The transaction's AQL payee ID under the stored field name: Actual's
            // server saves `payee` as `description`, and its unused-payee query
            // (db/index.ts orphanedPayeesQuery) matches only that name.
            conditions.append(condition("description", value: .string(payeeID)))
        }
        if !transaction.account.isEmpty {
            conditions.append(condition("account", value: .string(transaction.account)))
        }

        var actions: [RuleJSONValue] = [.object([
            "op": .string("link-schedule"),
            "value": .string(scheduleID)
        ])]
        if transaction.isParent {
            if let notes = nonempty(transaction.notes) {
                actions.append(setAction(
                    field: "notes",
                    value: .string(notes),
                    splitIndex: 0
                ))
            }
            for (index, split) in transaction.subtransactions.enumerated() {
                let splitIndex = index + 1
                actions.append(.object([
                    "op": .string("set-split-amount"),
                    "value": .number(Double(split.amount ?? 0)),
                    "options": .object([
                        "splitIndex": .number(Double(splitIndex)),
                        "method": .string("fixed-amount")
                    ])
                ]))
                if let category = nonempty(split.category) {
                    actions.append(setAction(
                        field: "category",
                        value: .string(category),
                        splitIndex: splitIndex
                    ))
                }
                if let notes = nonempty(split.notes) {
                    actions.append(setAction(
                        field: "notes",
                        value: .string(notes),
                        splitIndex: splitIndex
                    ))
                }
            }
        } else {
            if let category = nonempty(transaction.category) {
                actions.append(setAction(field: "category", value: .string(category)))
            }
            if let notes = nonempty(transaction.notes) {
                actions.append(setAction(field: "notes", value: .string(notes)))
            }
        }

        return ScheduleTransactionConversionPlan(
            name: "Auto-created future transaction (\(transaction.date)) · \(scheduleID.prefix(8))",
            conditions: conditions,
            actions: actions,
            postsTransaction: true
        )
    }

    private static func condition(_ field: String, value: RuleJSONValue) -> RuleJSONValue {
        .object(["op": .string("is"), "field": .string(field), "value": value])
    }

    private static func setAction(
        field: String,
        value: RuleJSONValue,
        splitIndex: Int? = nil
    ) -> RuleJSONValue {
        var action: [String: RuleJSONValue] = [
            "op": .string("set"),
            "field": .string(field),
            "value": value
        ]
        if let splitIndex {
            action["options"] = .object(["splitIndex": .number(Double(splitIndex))])
        }
        return .object(action)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
