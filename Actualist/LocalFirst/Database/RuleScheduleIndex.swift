import Foundation

/// Live `schedules.rule` relationship used by loot-core `runRules$1`.
///
/// Completed and tombstoned schedule rows are excluded from the active map so
/// they never force-exec or suppress ordinary rules. `link-schedule` still
/// executes from raw rule actions; this index only answers skip / force-exec.
struct RuleScheduleIndex: Hashable, Sendable {
    static let empty = RuleScheduleIndex(ruleIDByScheduleID: [:], completedRuleIDs: [])

    /// Active, non-tombstoned, non-completed `schedules.id -> schedules.rule`.
    let ruleIDByScheduleID: [String: String]
    let completedRuleIDs: Set<String>

    var liveLinkedRuleIDs: Set<String> {
        Set(ruleIDByScheduleID.values)
    }

    func ruleID(forScheduleID scheduleID: String?) -> String? {
        guard let scheduleID, !scheduleID.isEmpty else { return nil }
        return ruleIDByScheduleID[scheduleID]
    }

    func shouldForceExecute(ruleID: String, attachedRuleID: String?) -> Bool {
        guard let attachedRuleID else { return false }
        return ruleID == attachedRuleID && !completedRuleIDs.contains(ruleID)
    }

    func shouldSkip(ruleID: String, attachedRuleID: String?) -> Bool {
        if completedRuleIDs.contains(ruleID) { return true }
        guard let attachedRuleID else { return false }
        return ruleID != attachedRuleID && liveLinkedRuleIDs.contains(ruleID)
    }
}

extension ManagedRule {
    /// Conditions and actions that can run even when the rule is not editable.
    /// `link-schedule` rules have no `draft` because they cannot round-trip
    /// through the payee editor; runtime still decodes the raw JSON.
    func executionDraft() -> RuleDraft? {
        if let draft { return draft }
        let decoder = JSONDecoder()
        guard let conditionData = rawConditionsJSON.data(using: .utf8),
              let actionData = rawActionsJSON.data(using: .utf8),
              let conditions = try? decoder.decode([RuleCondition].self, from: conditionData),
              let actions = try? decoder.decode([RuleAction].self, from: actionData),
              !conditions.isEmpty,
              !actions.isEmpty else {
            return nil
        }
        let join = rawConditionsJoin.flatMap(RuleConditionJoin.init(rawValue:)) ?? .and
        let stage = rawStage.flatMap(RuleStage.init(rawValue:)) ?? .normal
        return RuleDraft(
            stage: stage,
            conditionsJoin: join,
            conditions: conditions,
            actions: actions
        )
    }
}

extension RuleAction {
    /// Runtime-safe actions include the editable set plus `link-schedule` and
    /// one-based split actions. This must not be folded into
    /// `canRoundTripAndEvaluate` or schedule-owned / imported split rules become
    /// editable from the payee flow.
    var canExecuteAtRuntime: Bool {
        if operation == "link-schedule" {
            if case .string(let scheduleID) = value { return !scheduleID.isEmpty }
            return false
        }
        if targetsSplitTransaction {
            return canExecuteSplitAction
        }
        return canRoundTripAndEvaluate
    }

    /// One-based Actual 26.8.1 split contract. Index 0 is apply-to-all.
    /// Formula `set` / Handlebars / QUERY stay fail-closed.
    var canExecuteSplitAction: Bool {
        guard hasSupportedSplitRuntimeOptions else { return false }
        switch operation {
        case "set-split-amount":
            guard let method = splitMethod,
                  ["fixed-amount", "fixed-percent", "remainder", "formula"].contains(method) else {
                return false
            }
            if method == "formula" {
                guard case .string(let formula) = options?["formula"], formula.hasPrefix("=") else {
                    return false
                }
            } else if options?["formula"] != nil {
                return false
            }
            return true
        case "set":
            guard options?["formula"] == nil, options?["template"] == nil else { return false }
            switch editorField {
            case "account", "category", "date", "notes", "payee": return value.isStringLike
            case "amount": return value.isNumberLike
            case "cleared": if case .bool = value { return true } else { return false }
            default: return false
            }
        case "prepend-notes", "append-notes":
            return field == nil && value.isStringLike && splitMethod == nil
        default:
            return false
        }
    }

    private var hasSupportedSplitRuntimeOptions: Bool {
        let options = options ?? [:]
        let allowed: Set<String> = ["splitIndex", "method", "formula"]
        guard Set(options.keys).isSubset(of: allowed) else { return false }
        if let index = options["splitIndex"] {
            switch index {
            case .number(let number):
                guard number.isFinite, number >= 0, number == number.rounded(), number < 100 else {
                    return false
                }
            case .string(let text):
                guard let value = Int(text), value >= 0, value < 100 else { return false }
            default:
                return false
            }
        }
        if let method = options["method"] {
            guard case .string(let name) = method,
                  ["fixed-amount", "fixed-percent", "remainder", "formula"].contains(name) else {
                return false
            }
        }
        if let formula = options["formula"] {
            guard case .string = formula else { return false }
        }
        return true
    }
}
