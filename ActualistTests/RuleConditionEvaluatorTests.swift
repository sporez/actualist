import Foundation
import Testing
@testable import Actualist

struct RuleConditionEvaluatorTests {
    @Test func amountConditionsMatchPWAThresholdRangesAndDirections() {
        var context = makeContext(amount: 1_650)
        #expect(matches(.init(field: "amount", operation: "isapprox", value: .number(1_535)), context))
        context.amount = 1_651
        #expect(!matches(.init(field: "amount", operation: "isapprox", value: .number(1_535)), context))

        context.amount = -18
        #expect(matches(.init(
            field: "amount",
            operation: "isbetween",
            value: .object(["num1": .number(-16), "num2": .number(-20)])
        ), context))
        #expect(matches(.init(
            field: "amount",
            operation: "is",
            value: .number(18),
            options: ["outflow": .bool(true)]
        ), context))
        #expect(!matches(.init(
            field: "amount",
            operation: "is",
            value: .number(18),
            options: ["inflow": .bool(true)]
        ), context))

        context.amount = 18
        #expect(matches(.init(
            field: "amount",
            operation: "is",
            value: .number(18),
            options: ["inflow": .bool(true)]
        ), context))

        context.amount = .min
        #expect(matches(.init(
            field: "amount",
            operation: "is",
            value: .number(-Double(Int.min)),
            options: ["outflow": .bool(true)]
        ), context))
    }

    @Test func dateConditionsSupportExactMonthYearComparisonsAndApproximateBoundaries() {
        let context = makeContext(date: Self.date("2026-08-12"))
        #expect(matches(.init(field: "date", operation: "is", value: .string("2026")), context))
        #expect(matches(.init(field: "date", operation: "is", value: .string("2026-08")), context))
        #expect(matches(.init(field: "date", operation: "is", value: .string("2026-08-12")), context))
        #expect(matches(.init(field: "date", operation: "isapprox", value: .string("2026-08-10")), context))
        #expect(!matches(.init(field: "date", operation: "isapprox", value: .string("2026-08-09")), context))
        #expect(matches(.init(field: "date", operation: "gt", value: .string("2026-08-11")), context))
        #expect(!matches(.init(field: "date", operation: "lt", value: .string("2026-08-11")), context))
    }

    @Test func importedPayeePayeeNameTagsAndMalformedRegexUsePWASemantics() {
        var context = makeContext(
            notes: "Trip #One #two #one",
            payeeName: "Neighborhood Market",
            importedPayee: "AMZN MKTP 123"
        )
        #expect(matches(.init(field: "imported_payee", operation: "contains", value: .string("amzn")), context))
        #expect(!matches(.init(field: "imported_payee", operation: "contains", value: .string("market")), context))
        #expect(matches(.init(field: "payee_name", operation: "contains", value: .string("market")), context))
        #expect(matches(.init(field: "notes", operation: "hasTags", value: .string("one #one ##two")), context))
        #expect(matches(.init(field: "notes", operation: "hasAnyTag", value: .string("missing two")), context))
        #expect(!matches(.init(field: "notes", operation: "matches", value: .string("fo**")), context))

        context.notes = nil
        #expect(matches(.init(field: "notes", operation: "doesNotContain", value: .string("memo")), context))
    }

    @Test func entityNameBooleanNullAndBudgetConditionsAreDefensive() {
        var context = makeContext(
            accountID: "closed-card",
            accountName: "Closed Card",
            accountIsOffBudget: true,
            categoryID: nil,
            payeeID: nil,
            cleared: true,
            reconciled: true,
            isTransfer: false,
            isParent: true
        )
        #expect(matches(.init(field: "account", operation: "contains", value: .string("closed")), context))
        #expect(matches(.init(field: "account", operation: "offBudget", value: .null), context))
        #expect(!matches(.init(field: "account", operation: "onBudget", value: .null), context))
        #expect(!matches(.init(field: "category", operation: "doesNotContain", value: .string("food")), context))
        #expect(!matches(.init(field: "payee", operation: "notOneOf", value: .array([])), context))
        #expect(matches(.init(field: "payee", operation: "is", value: .null), context))
        #expect(matches(.init(field: "cleared", operation: "is", value: .bool(true)), context))
        #expect(matches(.init(field: "reconciled", operation: "is", value: .bool(true)), context))
        #expect(matches(.init(field: "parent", operation: "is", value: .bool(true)), context))

        context.payeeID = "coffee"
        context.isParent = false
        #expect(matches(.init(field: "payee", operation: "notOneOf", value: .array([])), context))
        #expect(!matches(.init(field: "payee", operation: "oneOf", value: .array([])), context))
        #expect(matches(.init(field: "parent", operation: "is", value: .bool(false)), context))
    }

    @Test func everySupportedConditionOperatorHasAnExecutableFixture() {
        let context = makeContext(
            amount: 100,
            categoryID: "groceries",
            notes: "memo #one #two",
            payeeID: "coffee",
            payeeName: "Coffee Shop",
            importedPayee: "AMZN Marketplace",
            cleared: true,
            reconciled: true,
            isTransfer: true,
            isParent: true
        )
        let conditions: [RuleCondition] = [
            .init(field: "account", operation: "is", value: .string("checking")),
            .init(field: "account", operation: "isNot", value: .string("tracking")),
            .init(field: "account", operation: "oneOf", value: .array([.string("checking"), .string("tracking")])),
            .init(field: "account", operation: "notOneOf", value: .array([.string("tracking")])),
            .init(field: "account", operation: "contains", value: .string("check")),
            .init(field: "account", operation: "doesNotContain", value: .string("track")),
            .init(field: "account", operation: "matches", value: .string("^check")),
            .init(field: "account", operation: "onBudget", value: .null),
            .init(field: "category", operation: "is", value: .string("groceries")),
            .init(field: "category", operation: "contains", value: .string("grocer")),
            .init(field: "category_group", operation: "matches", value: .string("every.*")),
            .init(field: "payee", operation: "oneOf", value: .array([.string("coffee")])),
            .init(field: "payee", operation: "doesNotContain", value: .string("market")),
            .init(field: "imported_payee", operation: "is", value: .string("amzn marketplace")),
            .init(field: "imported_payee", operation: "oneOf", value: .array([.string("amzn marketplace")])),
            .init(field: "payee_name", operation: "matches", value: .string("coffee.*")),
            .init(field: "notes", operation: "contains", value: .string("memo")),
            .init(field: "notes", operation: "doesNotContain", value: .string("missing")),
            .init(field: "notes", operation: "hasTags", value: .string("one two")),
            .init(field: "notes", operation: "hasAnyTag", value: .string("missing two")),
            .init(field: "amount", operation: "is", value: .number(100)),
            .init(field: "amount", operation: "isapprox", value: .number(95)),
            .init(field: "amount", operation: "isbetween", value: .object(["num1": .number(90), "num2": .number(110)])),
            .init(field: "amount", operation: "gt", value: .number(99)),
            .init(field: "amount", operation: "gte", value: .number(100)),
            .init(field: "amount", operation: "lt", value: .number(101)),
            .init(field: "amount", operation: "lte", value: .number(100)),
            .init(field: "date", operation: "is", value: .string("2026-08")),
            .init(field: "date", operation: "isapprox", value: .string("2026-08-14")),
            .init(field: "date", operation: "gt", value: .string("2026-08-11")),
            .init(field: "date", operation: "gte", value: .string("2026-08-12")),
            .init(field: "date", operation: "lt", value: .string("2026-08-13")),
            .init(field: "date", operation: "lte", value: .string("2026-08-12")),
            .init(field: "cleared", operation: "is", value: .bool(true)),
            .init(field: "reconciled", operation: "is", value: .bool(true)),
            .init(field: "transfer", operation: "is", value: .bool(true)),
            .init(field: "parent", operation: "is", value: .bool(true))
        ]

        for condition in conditions {
            #expect(condition.canRoundTripAndEvaluate)
            #expect(matches(condition, context))
        }
        #expect(!matches(.init(field: "account", operation: "oneOf", value: .array([.string("unknown")])), context))
    }

    @Test func orderedRulesSeeEarlierAccountCategoryAndPayeeActions() {
        let rules = [
            rule(
                id: "1",
                condition: .init(field: "payee", operation: "is", value: .string("coffee"), type: "id"),
                actions: [
                    .init(operation: "set", field: "account", value: .string("tracking"), type: "id"),
                    .init(operation: "set", field: "category", value: .string("groceries"), type: "id"),
                    .init(operation: "set", field: "payee", value: .string("market"), type: "id")
                ]
            ),
            rule(
                id: "2",
                conditions: [
                    .init(field: "account", operation: "offBudget", value: .null, type: "id"),
                    .init(field: "category_group", operation: "is", value: .string("everyday"), type: "id"),
                    .init(field: "payee_name", operation: "is", value: .string("Neighborhood Market"), type: "string")
                ],
                actions: [.init(operation: "append-notes", value: .string(" matched"))]
            )
        ]
        let result = RuleConditionEvaluator.applying(rules, to: makeContext())

        #expect(result.accountID == "tracking")
        #expect(result.categoryID == "groceries")
        #expect(result.payeeID == "market")
        #expect(result.notes == "start matched")
    }

    @Test func PWAConditionJSONRoundTripsSupportedMetadataExactly() throws {
        let json = """
        [{"field":"amount","op":"gte","options":{"outflow":true},"type":"number","value":1250}]
        """
        let decoded = try JSONDecoder().decode([RuleCondition].self, from: Data(json.utf8))
        let condition = try #require(decoded.first)
        #expect(condition.options == ["outflow": .bool(true)])
        #expect(condition.canRoundTripAndEvaluate)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        #expect(String(data: try encoder.encode(decoded), encoding: .utf8) == json)
    }

    @Test func unsupportedRecurrenceSavedAndUnknownMetadataStayReadOnly() {
        let recurrence = RuleCondition(
            field: "date",
            operation: "is",
            value: .object(["frequency": .string("monthly"), "start": .string("2026-01-01")]),
            type: "date"
        )
        let saved = RuleCondition(field: "saved", operation: "is", value: .string("filter"))
        let unknownOptions = RuleCondition(
            field: "payee",
            operation: "is",
            value: .string("coffee"),
            type: "id",
            options: ["future": .bool(true)]
        )
        let unknownDateOptions = RuleCondition(
            field: "date",
            operation: "is",
            value: .string("2026-08"),
            type: "date",
            options: ["month": .bool(true)]
        )

        #expect(!recurrence.canRoundTripAndEvaluate)
        #expect(!saved.canRoundTripAndEvaluate)
        #expect(!unknownOptions.canRoundTripAndEvaluate)
        #expect(!unknownDateOptions.canRoundTripAndEvaluate)
    }

    private func matches(_ condition: RuleCondition, _ context: RuleEvaluationContext) -> Bool {
        RuleConditionEvaluator.conditionMatches(condition, context: context)
    }

    private func rule(
        id: String,
        condition: RuleCondition,
        actions: [RuleAction]
    ) -> ManagedRule {
        rule(id: id, conditions: [condition], actions: actions)
    }

    private func rule(
        id: String,
        conditions: [RuleCondition],
        actions: [RuleAction]
    ) -> ManagedRule {
        ManagedRule(
            id: id,
            draft: RuleDraft(stage: .normal, conditionsJoin: .and, conditions: conditions, actions: actions),
            rawStage: nil,
            rawConditionsJSON: "[]",
            rawActionsJSON: "[]",
            payeeIDs: [],
            isCompletedScheduleRule: false
        )
    }

    private func makeContext(
        accountID: String = "checking",
        accountName: String = "Checking",
        accountIsOffBudget: Bool = false,
        amount: Int = -500,
        categoryID: String? = nil,
        date: Date = RuleConditionEvaluatorTests.date("2026-08-12"),
        notes: String? = "start",
        payeeID: String? = "coffee",
        payeeName: String = "Coffee Shop",
        importedPayee: String? = nil,
        cleared: Bool = false,
        reconciled: Bool = false,
        isTransfer: Bool = false,
        isParent: Bool = false
    ) -> RuleEvaluationContext {
        RuleEvaluationContext(
            accountID: accountID,
            accountName: accountName,
            accountIsOffBudget: accountIsOffBudget,
            amount: amount,
            categoryID: categoryID,
            categoryName: categoryID == "groceries" ? "Groceries" : nil,
            categoryGroupID: categoryID == "groceries" ? "everyday" : nil,
            categoryGroupName: categoryID == "groceries" ? "Everyday" : nil,
            date: date,
            notes: notes,
            payeeID: payeeID,
            payeeName: payeeName,
            importedPayee: importedPayee,
            cleared: cleared,
            reconciled: reconciled,
            isTransfer: isTransfer,
            isParent: isParent,
            accountNames: ["checking": "Checking", "tracking": "Tracking"],
            offBudgetAccountIDs: ["tracking"],
            categoryNames: ["groceries": "Groceries"],
            categoryGroupsByCategoryID: ["groceries": "everyday"],
            categoryGroupNames: ["everyday": "Everyday"],
            payeeNames: ["coffee": "Coffee Shop", "market": "Neighborhood Market"]
        )
    }

    private static func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
    }
}
