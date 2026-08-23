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
    /// Runtime-safe actions include the editable set plus `link-schedule`.
    /// This must not be folded into `canRoundTripAndEvaluate` or schedule-owned
    /// rules become editable from the payee flow.
    var canExecuteAtRuntime: Bool {
        if operation == "link-schedule" {
            if case .string(let scheduleID) = value { return !scheduleID.isEmpty }
            return false
        }
        return canRoundTripAndEvaluate
    }
}
