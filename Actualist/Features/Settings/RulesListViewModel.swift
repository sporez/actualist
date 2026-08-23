import Foundation
import Observation

enum RulesListScope: Equatable, Sendable {
    case all
    case payee(String)
}

struct RulesListSection: Equatable, Identifiable {
    let stage: RuleStage
    let rules: [ManagedRule]

    var id: String { stage.rawValue }
}

@MainActor
@Observable
final class RulesListViewModel {
    var rules: [ManagedRule] = []
    var options: RuleEditorOptions?
    var searchText = ""
    var isLoading = false
    var isSubmitting = false
    var errorMessage: String?

    func displayedRules(for scope: RulesListScope) -> [ManagedRule] {
        let scoped = rules.filter { rule in
            guard !rule.isCompletedScheduleRule else { return false }
            if case .payee(let payeeID) = scope {
                return rule.payeeIDs.contains(payeeID)
            }
            return true
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return scoped }
        return scoped.filter { rule in
            rule.summary(options: options)
                .localizedCaseInsensitiveContains(query)
        }
    }

    func sections(for scope: RulesListScope) -> [RulesListSection] {
        let displayed = displayedRules(for: scope)
        return RuleStage.allCases.compactMap { stage in
            let matches = displayed.filter { ($0.draft?.stage ?? .normal) == stage }
            return matches.isEmpty ? nil : RulesListSection(stage: stage, rules: matches)
        }
    }

    func load(scope: RulesListScope, using appState: AppState) async {
        guard let budgetID = appState.settings.selectedBudgetID else { return }
        if let cached = appState.ruleRepository.cachedRules(budgetID: budgetID) {
            rules = cached
        }
        isLoading = rules.isEmpty
        options = try? await appState.ruleRepository.ruleEditorOptions(budgetID: budgetID)
        do {
            try await appState.ruleRepository.refreshRules(budgetID: budgetID)
            rules = appState.ruleRepository.cachedRules(budgetID: budgetID) ?? rules
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func save(ruleID: String?, draft: RuleDraft, using appState: AppState) async -> Bool {
        guard let budgetID = appState.settings.selectedBudgetID else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            if let ruleID {
                try await appState.ruleRepository.updateRuleAndRefresh(
                    budgetID: budgetID,
                    ruleID: ruleID,
                    draft: draft
                )
            } else {
                try await appState.ruleRepository.createRuleAndRefresh(budgetID: budgetID, draft: draft)
            }
            rules = appState.ruleRepository.cachedRules(budgetID: budgetID) ?? rules
            appState.recordLocalDataMutation()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func duplicate(_ rule: ManagedRule, using appState: AppState) async -> Bool {
        guard let draft = rule.draft else { return false }
        return await save(ruleID: nil, draft: draft, using: appState)
    }

    func delete(ruleID: String, using appState: AppState) async -> Bool {
        guard let budgetID = appState.settings.selectedBudgetID else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await appState.ruleRepository.deleteRuleAndRefresh(budgetID: budgetID, ruleID: ruleID)
            rules = appState.ruleRepository.cachedRules(budgetID: budgetID) ?? rules
            appState.recordLocalDataMutation()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
