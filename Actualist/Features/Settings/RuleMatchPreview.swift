import Observation
import SwiftUI

@MainActor
@Observable
final class RuleEditorViewModel {
    var draft: RuleDraft
    var options: RuleEditorOptions?
    var matchPreview: RuleTransactionMatchPreview?
    var isLoadingMatches = false
    var matchErrorMessage: String?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    init(draft: RuleDraft) {
        self.draft = draft
    }

    func load(using appState: AppState) async {
        guard let budgetID = appState.settings.selectedBudgetID else { return }
        options = try? await appState.ruleRepository.ruleEditorOptions(budgetID: budgetID)
        await refreshMatches(for: draft, budgetID: budgetID, using: appState)
    }

    func scheduleMatchRefresh(using appState: AppState) {
        previewTask?.cancel()
        let requestedDraft = draft
        previewTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled,
                      let self,
                      let budgetID = appState.settings.selectedBudgetID else { return }
                await self.refreshMatches(for: requestedDraft, budgetID: budgetID, using: appState)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    func cancelMatchRefresh() {
        previewTask?.cancel()
    }

    private func refreshMatches(
        for requestedDraft: RuleDraft,
        budgetID: String,
        using appState: AppState
    ) async {
        guard !requestedDraft.conditions.isEmpty else {
            matchPreview = RuleTransactionMatchPreview(transactions: [], totalCount: 0)
            matchErrorMessage = nil
            isLoadingMatches = false
            return
        }
        isLoadingMatches = true
        do {
            let preview = try await appState.ruleRepository.matchingTransactions(
                budgetID: budgetID,
                draft: requestedDraft,
                limit: 25
            )
            guard draft == requestedDraft else { return }
            matchPreview = preview
            matchErrorMessage = nil
        } catch {
            guard draft == requestedDraft else { return }
            matchErrorMessage = error.localizedDescription
        }
        if draft == requestedDraft {
            isLoadingMatches = false
        }
    }
}

struct RuleTransactionMatchRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.budgetCurrency) private var currency
    let transaction: RuleTransactionMatch

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.payeeName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(ActualistTheme.primaryText)
                    .lineLimit(1)
                Text("\(dateText) · \(transaction.categoryName) · \(transaction.accountName)")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(amountText)
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(ActualistTheme.primaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var dateText: String {
        transaction.date.actualDate?.formatted(date: .numeric, time: .omitted) ?? transaction.date
    }

    private var amountText: String {
        if appState.settings.randomizedDisplayValuesEnabled {
            return PrivacyDisplay.money(
                transaction.amountMinorUnits,
                seed: "rule-match-\(transaction.id)",
                currency: currency,
                maximumDollars: 275
            )
        }
        return currency.formatted(transaction.amountMinorUnits)
    }
}
