import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    var settings: AppSettings
    var setupPhase: SetupPhase
    var selectedTab: AppTab = .budget
    var budgets: [ActualBudget] = []
    var selectedBudget: ActualBudget?
    var lastErrorMessage: String?

    private let settingsStore: AppSettingsStore
    private let keychain: KeychainStore

    init(
        settingsStore: AppSettingsStore = .live,
        keychain: KeychainStore = .actualist
    ) {
        self.settingsStore = settingsStore
        self.keychain = keychain
        let loaded = settingsStore.load()
        self.settings = loaded
        if loaded.serverURLString.isEmpty || keychain.readAPIKey().isEmpty || loaded.selectedBudgetID == nil {
            self.setupPhase = .needsConnection
        } else {
            self.setupPhase = .ready
        }
    }

    var apiKey: String {
        keychain.readAPIKey()
    }

    var canUseAPI: Bool {
        !settings.serverURLString.isEmpty && !apiKey.isEmpty
    }

    func saveConnection(serverURLString: String, apiKey: String) {
        settings.serverURLString = ServerURLNormalizer.normalize(serverURLString)
        settingsStore.save(settings)
        keychain.saveAPIKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func selectBudget(_ budget: ActualBudget) {
        selectedBudget = budget
        settings.selectedBudgetID = budget.syncID
        settings.selectedBudgetName = budget.name
        settingsStore.save(settings)
        setupPhase = .ready
    }

    func clearSelectionForBudgetChange() {
        selectedBudget = nil
        settings.selectedBudgetID = nil
        settings.selectedBudgetName = nil
        settingsStore.save(settings)
        setupPhase = canUseAPI ? .selectingBudget : .needsConnection
    }

    func loadBudgets() async {
        guard let repository = makeBudgetRepository() else {
            setupPhase = .needsConnection
            return
        }

        do {
            budgets = Self.uniqueBudgets(try await repository.budgets())
            if budgets.count == 1, let budget = budgets.first {
                selectBudget(budget)
                return
            }

            if let selectedBudgetID = settings.selectedBudgetID,
               let budget = budgets.first(where: { $0.syncID == selectedBudgetID }) {
                selectedBudget = budget
                setupPhase = .ready
                return
            }

            setupPhase = .selectingBudget
        } catch {
            lastErrorMessage = error.localizedDescription
            setupPhase = .needsConnection
        }
    }

    func makeClient() -> ActualAPIClient? {
        let normalizedURLString = ServerURLNormalizer.normalize(settings.serverURLString)
        if normalizedURLString != settings.serverURLString {
            settings.serverURLString = normalizedURLString
            settingsStore.save(settings)
        }

        guard let baseURL = URL(string: normalizedURLString), !apiKey.isEmpty else {
            return nil
        }

        return ActualAPIClient(baseURL: baseURL, apiKey: apiKey)
    }

    func makeBudgetRepository() -> BudgetRepository? {
        guard let client = makeClient() else {
            return nil
        }

        return BudgetRepository(client: client)
    }

    private static func uniqueBudgets(_ budgets: [ActualBudget]) -> [ActualBudget] {
        var seenSyncIDs: Set<String> = []
        return budgets.filter { budget in
            seenSyncIDs.insert(budget.syncID).inserted
        }
    }
}

enum SetupPhase: Equatable {
    case needsConnection
    case selectingBudget
    case ready
}

enum ServerURLNormalizer {
    static func normalize(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: withScheme) else {
            return withScheme
        }

        if components.path.isEmpty || components.path == "/" {
            components.path = "/v1"
        }

        return components.string ?? withScheme
    }
}
