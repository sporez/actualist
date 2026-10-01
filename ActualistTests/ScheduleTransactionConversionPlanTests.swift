import Foundation
import Testing
@testable import Actualist

struct ScheduleTransactionConversionPlanTests {
    @Test func conversionKeepsPinnedPayeeAndNormalizesAbsentAmountToActualZero() throws {
        let transaction = ActualTransaction(
            id: "future",
            account: "checking",
            date: "2026-10-15",
            amount: nil,
            payee: "actual-target-id",
            payeeName: "Display name must not be authored",
            importedPayee: nil,
            category: "utilities",
            notes: "Memo",
            cleared: nil
        )

        let plan = ScheduleTransactionConversionPlanner.plan(from: transaction)
        let conditionFields = plan.conditions.compactMap(\.objectValue)
        #expect(conditionFields.contains { $0["field"] == .string("date") })
        #expect(conditionFields.contains { $0["field"] == .string("account") })
        #expect(conditionFields.contains { $0["field"] == .string("payee") && $0["value"] == .string("actual-target-id") })
        #expect(!conditionFields.contains { $0["field"] == .string("description") })
        #expect(conditionFields.contains { $0["field"] == .string("amount") && $0["value"] == .number(0) })
        #expect(plan.actions.count == 2)
        #expect(plan.postsTransaction)
    }

    @Test func conversionPreservesZeroAmountAndCreatesOneTimeSimpleActions() throws {
        let transaction = ActualTransaction(
            id: "future-zero",
            account: "checking",
            date: "2026-10-15",
            amount: 0,
            payee: nil,
            payeeName: nil,
            importedPayee: nil,
            category: "utilities",
            notes: "",
            cleared: nil
        )

        let plan = ScheduleTransactionConversionPlanner.plan(from: transaction)
        let condition = try #require(plan.conditions.compactMap(\.objectValue)
            .first { $0["field"] == .string("amount") })
        #expect(condition["value"] == .number(0))
        #expect(plan.actions.compactMap(\.objectValue).map { $0["field"] } == [.string("category")])
    }

    @Test func splitConversionUsesParentZeroAndOneBasedChildActionIndices() throws {
        let child = ActualTransaction(
            id: "child",
            account: "checking",
            date: "2026-10-15",
            amount: -400,
            payee: nil,
            payeeName: nil,
            importedPayee: nil,
            category: "groceries",
            notes: "Child memo",
            cleared: nil,
            isChild: true,
            parentID: "parent"
        )
        let parent = ActualTransaction(
            id: "parent",
            account: "checking",
            date: "2026-10-15",
            amount: -400,
            payee: nil,
            payeeName: nil,
            importedPayee: nil,
            category: nil,
            notes: "Parent memo",
            cleared: nil,
            subtransactions: [child],
            isParent: true
        )

        let plan = ScheduleTransactionConversionPlanner.plan(from: parent)
        let actions = plan.actions.compactMap(\.objectValue)
        #expect(actions.count == 4)
        #expect(actions[0]["options"]?.objectValue?["splitIndex"] == .number(0))
        #expect(actions[1]["op"] == .string("set-split-amount"))
        #expect(actions[1]["options"]?.objectValue?["splitIndex"] == .number(1))
        #expect(actions[2]["options"]?.objectValue?["splitIndex"] == .number(1))
        #expect(actions[3]["options"]?.objectValue?["splitIndex"] == .number(1))
    }

    @Test func splitNullAmountUsesActualZeroForParentConditionAndChildAction() throws {
        let child = ActualTransaction(
            id: "child", account: "checking", date: "2026-10-15", amount: nil,
            payee: nil, payeeName: nil, importedPayee: nil, category: nil, notes: nil,
            cleared: nil, isChild: true, parentID: "parent"
        )
        let parent = ActualTransaction(
            id: "parent", account: "checking", date: "2026-10-15", amount: nil,
            payee: nil, payeeName: nil, importedPayee: nil, category: nil, notes: nil,
            cleared: nil, subtransactions: [child], isParent: true
        )

        let plan = ScheduleTransactionConversionPlanner.plan(from: parent)
        let amount = try #require(plan.conditions.compactMap(\.objectValue)
            .first { $0["field"] == .string("amount") })
        #expect(amount["value"] == .number(0))
        #expect(plan.actions.compactMap(\.objectValue).first?["value"] == .number(0))
    }
}

private extension RuleJSONValue {
    var objectValue: [String: RuleJSONValue]? {
        guard case .object(let object) = self else { return nil }
        return object
    }
}
