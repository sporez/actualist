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

    @Test func identifierBooleanNullAndBudgetConditionsAreDefensive() {
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
        #expect(matches(.init(field: "account", operation: "is", value: .string("closed-card")), context))
        #expect(matches(.init(field: "account", operation: "offBudget", value: .null), context))
        #expect(!matches(.init(field: "account", operation: "onBudget", value: .null), context))
        #expect(matches(.init(field: "category", operation: "is", value: .null), context))
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

    @Test func identifierFieldsExcludeTextComparisonsWithoutChangingStringFields() {
        let identityOperations = ["is", "oneOf", "isNot", "notOneOf"]
        let textOperations = ["contains", "matches", "doesNotContain"]

        for field in ["account", "category", "category_group", "payee"] {
            let operations = RuleCondition.operations(for: field)
            for operation in identityOperations {
                #expect(operations.contains(operation))
            }
            for operation in textOperations {
                #expect(!operations.contains(operation))
                #expect(!RuleCondition(
                    field: field,
                    operation: operation,
                    value: .string("display name"),
                    type: "id"
                ).canRoundTripAndEvaluate)
            }
        }

        #expect(RuleCondition.operations(for: "account").contains("onBudget"))
        #expect(RuleCondition.operations(for: "account").contains("offBudget"))
        #expect(!RuleCondition.operations(for: "payee").contains("onBudget"))

        for field in ["imported_payee", "payee_name", "notes"] {
            let operations = RuleCondition.operations(for: field)
            for operation in textOperations {
                #expect(operations.contains(operation))
                #expect(RuleCondition(
                    field: field,
                    operation: operation,
                    value: .string("display name"),
                    type: "string"
                ).canRoundTripAndEvaluate)
            }
        }
    }

    @Test func pwaDescriptionFieldUsesPayeeSemantics() {
        let payeeID = "ABCDEF12-3456-4789-ABCD-EF1234567890"
        let context = makeContext(payeeID: payeeID, payeeName: "Coffee Shop")
        let condition = RuleCondition(
            field: "description",
            operation: "oneOf",
            value: .array([.string(payeeID), .string("market")]),
            type: "id"
        )

        #expect(condition.editorField == "payee")
        #expect(RuleCondition.serializedField("payee") == "description")
        #expect(condition.canRoundTripAndEvaluate)
        #expect(matches(condition, context))
        #expect(RulePresentation.fieldName("description") == "Payee")
    }

    @Test func pwaDescriptionSetActionUsesPayeeSemantics() {
        let action = RuleAction(
            operation: "set",
            field: "description",
            value: .string("market"),
            type: "id"
        )
        let managedRule = rule(
            id: "set-payee",
            condition: .init(field: "notes", operation: "contains", value: .string("start")),
            actions: [action]
        )

        let result = RuleConditionEvaluator.applying([managedRule], to: makeContext())

        #expect(action.editorField == "payee")
        #expect(action.canRoundTripAndEvaluate)
        #expect(result.payeeID == "market")
        #expect(result.payeeName == "Neighborhood Market")
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
            .init(field: "account", operation: "onBudget", value: .null),
            .init(field: "category", operation: "is", value: .string("groceries")),
            .init(field: "category_group", operation: "is", value: .string("everyday")),
            .init(field: "payee", operation: "oneOf", value: .array([.string("coffee")])),
            .init(field: "imported_payee", operation: "is", value: .string("amzn marketplace")),
            .init(field: "imported_payee", operation: "oneOf", value: .array([.string("amzn marketplace")])),
            .init(field: "imported_payee", operation: "contains", value: .string("market")),
            .init(field: "imported_payee", operation: "doesNotContain", value: .string("missing")),
            .init(field: "imported_payee", operation: "matches", value: .string("amzn.*")),
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

    @Test func savedRuleSummaryResolvesEntityIDsWithoutChangingRuleValues() {
        let condition = RuleCondition(
            field: "payee",
            operation: "is",
            value: .string("payee-id"),
            type: "id"
        )
        let action = RuleAction(
            operation: "set",
            field: "category",
            value: .string("category-id"),
            type: "id"
        )
        let rule = self.rule(id: "summary", condition: condition, actions: [action])
        let options = RuleEditorOptions(
            accounts: [RuleEditorChoice(id: "account-id", name: "Checking")],
            categories: [RuleEditorChoice(id: "category-id", name: "Groceries")],
            categoryGroups: [RuleEditorChoice(id: "group-id", name: "Everyday")],
            payees: [RuleEditorChoice(id: "payee-id", name: "Coffee Shop")]
        )

        #expect(rule.summary(options: options) == "If payee is Coffee Shop, then set category Groceries")
        #expect(rule.draft?.conditions.first?.value == .string("payee-id"))
        #expect(rule.draft?.actions.first?.value == .string("category-id"))
    }

    @Test func savedRuleSummaryResolvesMultiValueIDsAndNeverExposesUnknownIDs() {
        let unknownPayeeID = "11111111-1111-4111-8111-111111111111"
        let unknownCategoryID = "22222222-2222-4222-8222-222222222222"
        let rule = self.rule(
            id: "summary",
            conditions: [
                RuleCondition(
                    field: "account",
                    operation: "oneOf",
                    value: .array([.string("checking"), .string("card")]),
                    type: "id"
                ),
                RuleCondition(
                    field: "payee",
                    operation: "is",
                    value: .string(unknownPayeeID),
                    type: "id"
                )
            ],
            actions: [
                RuleAction(
                    operation: "set",
                    field: "category",
                    value: .string(unknownCategoryID),
                    type: "id"
                )
            ]
        )
        let options = RuleEditorOptions(
            accounts: [
                RuleEditorChoice(id: "checking", name: "Checking"),
                RuleEditorChoice(id: "card", name: "Credit Card")
            ],
            categories: [],
            categoryGroups: [],
            payees: []
        )

        let resolved = rule.summary(options: options)
        #expect(resolved.contains("account is one of Checking, Credit Card"))
        #expect(!resolved.contains("oneOf"))
        #expect(resolved.contains("Deleted payee"))
        #expect(resolved.contains("Deleted category"))
        #expect(!resolved.contains(unknownPayeeID))
        #expect(!resolved.contains(unknownCategoryID))

        let loading = rule.summary(options: nil)
        #expect(loading.contains("…"))
        #expect(!loading.contains(unknownPayeeID))
        #expect(!loading.contains(unknownCategoryID))
    }

    @Test func rulePresentationFormatsEveryValueKindWithoutWireValues() {
        let rule = ManagedRule(
            id: "presentation",
            draft: RuleDraft(
                stage: .normal,
                conditionsJoin: .or,
                conditions: [
                    RuleCondition(
                        field: "amount",
                        operation: "isbetween",
                        value: .object(["num1": .number(1_250), "num2": .number(2_500)]),
                        type: "number"
                    ),
                    RuleCondition(field: "cleared", operation: "is", value: .bool(true), type: "boolean"),
                    RuleCondition(field: "account", operation: "onBudget", value: .null, type: "id")
                ],
                actions: [RuleAction(operation: "append-notes", value: .string("reviewed"), type: "string")]
            ),
            rawStage: nil,
            rawConditionsJSON: "[]",
            rawActionsJSON: "[]",
            payeeIDs: [],
            isCompletedScheduleRule: false
        )

        let summary = rule.summary(options: RuleEditorOptions(accounts: [], categories: [], categoryGroups: [], payees: []))
        #expect(summary.contains("amount is between"))
        #expect(summary.contains("12.50"))
        #expect(summary.contains("25.00"))
        #expect(summary.contains("cleared is Yes"))
        #expect(summary.contains("account is on budget"))
        #expect(summary.contains("append notes with reviewed"))
        #expect(!summary.contains("isbetween"))
        #expect(!summary.contains("onBudget"))
        #expect(!summary.contains("num1"))
        #expect(!summary.contains("true"))
        #expect(!summary.contains("1250"))
    }

    @Test func readOnlyRuleDetailsNeverExposeRawKeysOperationsOrEntityIDs() {
        let payeeID = "11111111-1111-4111-8111-111111111111"
        let categoryID = "22222222-2222-4222-8222-222222222222"
        let unknownID = "33333333-3333-4333-8333-333333333333"
        let rule = ManagedRule(
            id: "read-only",
            draft: nil,
            rawStage: "future-stage",
            rawConditionsJSON: """
            [
              {"field":"payee","op":"oneOf","type":"id","value":["\(payeeID)"]},
              {"field":"future_field","op":"futureComparison","value":"\(unknownID)"}
            ]
            """,
            rawActionsJSON: """
            [
              {"op":"set","field":"category","type":"id","value":"\(categoryID)"},
              {"op":"future-action","field":"future_field","value":"\(unknownID)"}
            ]
            """,
            payeeIDs: [],
            isCompletedScheduleRule: false
        )
        let details = rule.readOnlyDetails(
            options: RuleEditorOptions(accounts: [], categories: [], categoryGroups: [], payees: [])
        ).joined(separator: " ")

        #expect(details.contains("Payee is one of Deleted payee"))
        #expect(details.contains("Set Category Deleted category"))
        #expect(details.contains("Unsupported condition"))
        #expect(details.contains("Unsupported action"))
        for leakedValue in [
            payeeID,
            categoryID,
            unknownID,
            "oneOf",
            "future_field",
            "futureComparison",
            "future-action",
            "future-stage",
            "\"field\"",
            "\"op\""
        ] {
            #expect(!details.contains(leakedValue))
        }
    }

    @Test func scheduleOwnedRuleHasReadableReadOnlyPresentation() {
        let payeeID = "44444444-4444-4444-8444-444444444444"
        let accountID = "55555555-5555-4555-8555-555555555555"
        let scheduleID = "66666666-6666-4666-8666-666666666666"
        let rule = ManagedRule(
            id: "schedule-rule",
            draft: nil,
            rawStage: nil,
            rawConditionsJSON: """
            [
              {"op":"is","field":"description","value":"\(payeeID)"},
              {"op":"is","field":"acct","value":"\(accountID)"},
              {"op":"is","field":"date","value":"2026-08-11"},
              {"op":"isapprox","field":"amount","value":-14000}
            ]
            """,
            rawActionsJSON: "[{\"op\":\"link-schedule\",\"value\":\"\(scheduleID)\"}]",
            payeeIDs: [payeeID],
            isCompletedScheduleRule: false
        )
        let options = RuleEditorOptions(
            accounts: [RuleEditorChoice(id: accountID, name: "Checking")],
            categories: [],
            categoryGroups: [],
            payees: [RuleEditorChoice(id: payeeID, name: "Internet Provider")]
        )

        let summary = rule.summary(options: options)
        let details = rule.readOnlyDetails(options: options).joined(separator: " ")

        #expect(rule.isScheduleOwned)
        #expect(summary.contains("payee is Internet Provider"))
        #expect(summary.contains("account is Checking"))
        #expect(summary.contains("date is 2026-08-11"))
        #expect(summary.contains("amount is approximately"))
        #expect(summary.contains("then link to schedule"))
        #expect(details.contains("Action: Link to schedule"))
        #expect(!summary.contains(payeeID))
        #expect(!summary.contains(accountID))
        #expect(!summary.contains(scheduleID))
    }

    @Test func presentationUsesSafeFallbacksForMissingMalformedAndNonfiniteValues() {
        #expect(RulePresentation.fieldName("future_field") == "Unsupported field")
        #expect(RulePresentation.operationName("futureComparison") == "Uses an unsupported comparison")
        #expect(RulePresentation.actionName("future-action") == "Unsupported action")
        #expect(RulePresentation.valueText(.string("raw-id"), field: "payee", options: nil) == "…")
        #expect(RulePresentation.valueText(
            .string("raw-id"),
            field: "payee",
            options: RuleEditorOptions(accounts: [], categories: [], categoryGroups: [], payees: [])
        ) == "Deleted payee")
        #expect(RulePresentation.valueText(.number(.infinity), field: "amount", options: nil) == "Unsupported value")
        #expect(RulePresentation.valueText(.object(["raw": .string("secret")]), field: "notes", options: nil) == "Unsupported value")
    }

    @Test func conditionSetMatchingHonorsAllAndAnyWithoutTreatingEmptyAsAll() {
        let payee = RuleCondition(
            field: "payee",
            operation: "oneOf",
            value: .array([.string("coffee"), .string("market")]),
            type: "id"
        )
        let category = RuleCondition(
            field: "category",
            operation: "is",
            value: .string("utilities"),
            type: "id"
        )
        var draft = RuleDraft(
            stage: .normal,
            conditionsJoin: .and,
            conditions: [payee, category],
            actions: [.init(operation: "append-notes", value: .string(" matched"))]
        )
        let context = makeContext(categoryID: "groceries", payeeID: "coffee")

        #expect(!RuleConditionEvaluator.conditionsMatch(draft, context: context))
        draft.conditionsJoin = .or
        #expect(RuleConditionEvaluator.conditionsMatch(draft, context: context))
        draft.conditions = []
        #expect(!RuleConditionEvaluator.conditionsMatch(draft, context: context))
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
