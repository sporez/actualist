import Foundation

struct ScheduleRuleProjection: Hashable, Sendable {
    let rawConditionsJSON: String?
    let rawActionsJSON: String?
    let accountID: String?
    let payeeMappingID: String?
    let amount: ScheduleAmount
    let dateRule: ScheduleDateRule
    let occurrenceMatchingMode: ScheduleOccurrenceMatchingMode
    let capabilities: ScheduleMutationCapabilities
    let unsupportedReasons: [ScheduleUnsupportedReason]

    static func read(
        scheduleID: String,
        conditionsJSON: String?,
        actionsJSON: String?
    ) -> ScheduleRuleProjection {
        let decoder = JSONDecoder()
        guard let conditionsJSON,
              let conditionData = conditionsJSON.data(using: .utf8),
              let conditions = try? decoder.decode([RuleCondition].self, from: conditionData) else {
            return unsupported(
                scheduleID: scheduleID,
                conditionsJSON: conditionsJSON,
                actionsJSON: actionsJSON,
                reason: conditionsJSON == nil ? .missingRule : .malformedConditions
            )
        }
        guard let actionsJSON,
              let actionData = actionsJSON.data(using: .utf8),
              let actions = try? decoder.decode([RuleAction].self, from: actionData) else {
            return unsupported(
                scheduleID: scheduleID,
                conditionsJSON: conditionsJSON,
                actionsJSON: actionsJSON,
                reason: actionsJSON == nil ? .missingRule : .malformedActions
            )
        }

        let account = preferredReference(
            in: conditions,
            primaryField: "account",
            fallbackField: "acct"
        )
        let payee = preferredReference(
            in: conditions,
            primaryField: "payee",
            fallbackField: "description"
        )
        let amountConditions = conditions.filter { $0.field == "amount" }
        let dateConditions = conditions.filter { $0.field == "date" }
        let amountCondition = amountConditions.count == 1 ? amountConditions[0] : nil
        let dateCondition = dateConditions.count == 1 ? dateConditions[0] : nil

        let amount = amountCondition.map(amount(from:)) ?? .unavailable
        let dateRule = dateCondition.map(dateRule(from:)) ?? .unavailable
        let occurrenceMatchingMode: ScheduleOccurrenceMatchingMode =
            dateCondition?.operation == "isapprox" ? .approximate : .exact
        let actionsCanExecute = actions.allSatisfy(\.canExecuteAtRuntime)
        let editability = ScheduleRuleMutation.editability(
            scheduleID: scheduleID,
            conditionsJSON: conditionsJSON,
            actionsJSON: actionsJSON
        )
        let hasValidLinkage = editability.hasValidLink
        let accountConditions = conditions.filter { ["account", "acct"].contains($0.field) }
        var reasons: [ScheduleUnsupportedReason] = []
        if amountConditions.isEmpty { reasons.append(.missingAmount) }
        else if amountConditions.count > 1 { reasons.append(.unsupportedAmount) }
        else if amount == .unavailable { reasons.append(.unsupportedAmount) }
        if dateConditions.isEmpty { reasons.append(.missingDate) }
        else if dateConditions.count > 1 { reasons.append(.unsupportedDate) }
        else if dateRule == .unavailable { reasons.append(.unsupportedDate) }
        if !actionsCanExecute {
            reasons.append(.unsupportedActions)
        }
        if !hasValidLinkage {
            reasons.append(.corruptRuleLinkage)
        }

        let hasSupportedDate = dateRule != .unavailable
        let hasSupportedAmount = amount != .unavailable
        let canEditMetadata = hasValidLinkage
        let canEditAccount = canEditMetadata && editability.canEditAccount
            && accountConditions.count == 1 && hasSupportedDate
        let canEditPayee = canEditMetadata && editability.canEditPayee
        let canEditAmount = canEditMetadata && editability.canEditAmount
        let canEditDate = canEditMetadata && editability.canEditDate
        return ScheduleRuleProjection(
            rawConditionsJSON: conditionsJSON,
            rawActionsJSON: actionsJSON,
            accountID: account,
            payeeMappingID: payee,
            amount: amount,
            dateRule: dateRule,
            occurrenceMatchingMode: occurrenceMatchingMode,
            capabilities: ScheduleMutationCapabilities(
                canRead: true,
                canEditMetadata: canEditMetadata,
                canEditAccount: canEditAccount,
                canEditPayee: canEditPayee,
                canEditAmount: canEditAmount,
                canEditDate: canEditDate,
                canSkip: hasValidLinkage && dateRule.recurrence != nil,
                canComplete: hasValidLinkage && hasSupportedDate && dateRule.recurrence == nil,
                canDelete: hasValidLinkage,
                canPost: hasValidLinkage
                    && hasSupportedDate
                    && hasSupportedAmount
                    && actionsCanExecute
                    && account != nil
            ),
            unsupportedReasons: reasons
        )
    }

    static func recurrence(
        from ruleValue: RuleJSONValue,
        calendar: Calendar = .actualScheduleGregorian
    ) throws -> ActualScheduleRecurrence {
        guard case .object(let object) = ruleValue,
              let start = object["start"]?.string,
              let frequencyText = object["frequency"]?.string?.lowercased(),
              let frequency = ActualScheduleFrequency(rawValue: frequencyText) else {
            throw ActualScheduleRecurrenceError.invalidFrequency
        }
        let interval: Int
        if let rawInterval = object["interval"] {
            guard let parsedInterval = rawInterval.integer,
                  parsedInterval > 0 else {
                throw ActualScheduleRecurrenceError.invalidInterval
            }
            interval = parsedInterval
        } else {
            interval = 1
        }
        let skipWeekend: Bool
        if let rawSkipWeekend = object["skipWeekend"] {
            guard let parsed = rawSkipWeekend.bool else {
                throw ActualScheduleRecurrenceError.invalidSkipWeekend
            }
            skipWeekend = parsed
        } else {
            skipWeekend = false
        }
        let adjustmentText: String
        if let rawAdjustment = object["weekendSolveMode"] {
            guard let parsed = rawAdjustment.string else {
                throw ActualScheduleRecurrenceError.invalidWeekendAdjustment
            }
            adjustmentText = parsed
        } else if skipWeekend {
            throw ActualScheduleRecurrenceError.invalidWeekendAdjustment
        } else {
            adjustmentText = "after"
        }
        guard let adjustment = ActualScheduleWeekendAdjustment(rawValue: adjustmentText) else {
            throw ActualScheduleRecurrenceError.invalidWeekendAdjustment
        }
        return try ActualScheduleRecurrence(
            startDayID: start,
            frequency: frequency,
            interval: interval,
            patterns: try decodePatterns(object["patterns"]),
            skipWeekend: skipWeekend,
            weekendAdjustment: adjustment,
            ending: try decodeEnding(object),
            calendar: calendar
        )
    }

    private static func unsupported(
        scheduleID: String,
        conditionsJSON: String?,
        actionsJSON: String?,
        reason: ScheduleUnsupportedReason
    ) -> ScheduleRuleProjection {
        let linkage = ScheduleRuleMutation.editability(
            scheduleID: scheduleID,
            conditionsJSON: conditionsJSON,
            actionsJSON: actionsJSON
        )
        return ScheduleRuleProjection(
            rawConditionsJSON: conditionsJSON,
            rawActionsJSON: actionsJSON,
            accountID: nil,
            payeeMappingID: nil,
            amount: .unavailable,
            dateRule: .unavailable,
            occurrenceMatchingMode: .exact,
            capabilities: ScheduleMutationCapabilities(
                canRead: true,
                canEditMetadata: linkage.hasValidLink,
                canEditAccount: false,
                canEditPayee: false,
                canEditAmount: false,
                canEditDate: false,
                canSkip: false,
                canComplete: false,
                canDelete: linkage.hasValidLink,
                canPost: false
            ),
            unsupportedReasons: [reason]
        )
    }

    private static func preferredReference(
        in conditions: [RuleCondition],
        primaryField: String,
        fallbackField: String
    ) -> String? {
        conditions.first {
            $0.operation == "is" && $0.field == primaryField
        }?.value.string ?? conditions.first {
            $0.operation == "is" && $0.field == fallbackField
        }?.value.string
    }

    static func amount(from condition: RuleCondition) -> ScheduleAmount {
        switch condition.operation {
        case "is", "isapprox":
            guard let value = condition.value.number,
                  let amount = actualRounded(value) else { return .unavailable }
            return condition.operation == "is" ? .exact(amount) : .approximate(amount)
        case "isbetween":
            guard case .object(let range) = condition.value,
                  let lowerValue = range["num1"]?.number,
                  let upperValue = range["num2"]?.number,
                  lowerValue.isFinite,
                  upperValue.isFinite,
                  lowerValue <= upperValue,
                  let lower = actualRounded(lowerValue),
                  let upper = actualRounded(upperValue),
                  let posting = actualRounded((lowerValue + upperValue) / 2) else {
                return .unavailable
            }
            return .range(lower: lower, upper: upper, postingAmount: posting)
        default:
            return .unavailable
        }
    }

    static func dateRule(from condition: RuleCondition) -> ScheduleDateRule {
        guard ["is", "isapprox"].contains(condition.operation) else { return .unavailable }
        switch condition.value {
        case .string(let dayID):
            guard ActualScheduleRecurrence.date(from: dayID) != nil else { return .unavailable }
            return .oneTime(dayID: dayID, operation: condition.operation)
        case .object:
            guard let recurrence = try? recurrence(from: condition.value) else {
                return .unavailable
            }
            return .recurring(recurrence, operation: condition.operation)
        default:
            return .unavailable
        }
    }

    private static func actualRounded(_ amount: Double) -> Int? {
        guard amount.isFinite else { return nil }
        return Int(exactly: floor(amount + 0.5))
    }

    private static func decodePatterns(_ value: RuleJSONValue?) throws -> [ActualSchedulePattern] {
        guard let value else { return [] }
        guard case .array(let rawPatterns) = value else {
            throw ActualScheduleRecurrenceError.invalidPattern
        }
        return try rawPatterns.map { raw in
            guard case .object(let pattern) = raw,
                  let type = pattern["type"]?.string,
                  let integer = pattern["value"]?.integer else {
                throw ActualScheduleRecurrenceError.invalidPattern
            }
            if type == "day" { return .dayOfMonth(integer) }
            guard let weekday = ActualScheduleWeekday(rawValue: type) else {
                throw ActualScheduleRecurrenceError.invalidPattern
            }
            return .weekday(weekday, ordinal: integer)
        }
    }

    private static func decodeEnding(
        _ object: [String: RuleJSONValue]
    ) throws -> ActualScheduleEnding {
        let endMode: String
        if let rawEndMode = object["endMode"] {
            guard let parsed = rawEndMode.string else {
                throw ActualScheduleRecurrenceError.invalidEnding
            }
            endMode = parsed
        } else {
            endMode = "never"
        }
        switch endMode {
        case "", "never":
            return .never
        case "after_n_occurrences":
            guard let count = object["endOccurrences"]?.integer else {
                throw ActualScheduleRecurrenceError.invalidEnding
            }
            return .afterOccurrences(count)
        case "on_date":
            guard let dayID = object["endDate"]?.string else {
                throw ActualScheduleRecurrenceError.invalidEnding
            }
            return .onDate(dayID)
        default:
            throw ActualScheduleRecurrenceError.invalidEnding
        }
    }
}

extension RuleJSONValue {
    var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var number: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }

    var integer: Int? {
        guard let number,
              number.isFinite,
              number.rounded() == number else { return nil }
        return Int(exactly: number)
    }

    var bool: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
}
