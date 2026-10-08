import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Whether a budget-picker host may offer Create New Budget and Import.
///
/// Both actions are offered on any server session, whether or not it already
/// has budgets. A non-empty list can only come from a successful discovery, so
/// it offers without a recorded attempt (onboarding skips its own load when
/// `AppState` already discovered budgets). An empty list offers only after a
/// successful discovery: list failure and cancellation arrive as
/// `discoverySucceeded == false` and are never treated as an empty server.
/// Demo mode has no server to create on and never offers. Offering beside a
/// single budget does not fight its auto-select
/// (`AppState.presentDiscoveredBudgets`), which runs during discovery.
enum EmptyBudgetPickerOffer: Equatable {
    /// A non-demo session with a known budget list.
    case offered
    case hidden(HiddenReason)

    enum HiddenReason: Equatable {
        /// Demo mode: the bundled budget is the whole session, not a server.
        case demoMode
        /// No budgets are listed and discovery has not completed successfully
        /// (failure, cancellation, or never ran).
        case discoveryIncomplete
    }

    static func decide(
        discoverySucceeded: Bool,
        isDemoMode: Bool,
        budgetCount: Int
    ) -> EmptyBudgetPickerOffer {
        if isDemoMode { return .hidden(.demoMode) }
        guard discoverySucceeded || budgetCount > 0 else { return .hidden(.discoveryIncomplete) }
        return .offered
    }
}

/// What the create form collected. The form binds raw controls; this value
/// interprets them once so neither the view nor the coordinator re-derives the
/// payload. An empty trimmed password with encryption requested stays invalid
/// (`isSubmittable == false`) rather than silently downgrading to plaintext —
/// the store refuses it as a fail-safe.
struct EmptyBudgetCreateInput: Equatable {
    let budgetName: String
    /// `nil` when the user did not request encryption.
    let encryptionPassword: String?

    static func make(
        budgetName: String,
        encryptionWanted: Bool,
        encryptionPassword: String
    ) -> EmptyBudgetCreateInput {
        EmptyBudgetCreateInput(
            budgetName: budgetName,
            encryptionPassword: encryptionWanted
                ? encryptionPassword.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
        )
    }

    var isSubmittable: Bool {
        !budgetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(encryptionPassword?.isEmpty ?? false)
    }
}

extension NewBudgetCreation {
    /// The identity handed to the existing selection path
    /// (`selectBudgetForCurrentBackend`) after a confirmed creation. It mirrors
    /// how `AppSessionRecovery` rebuilds discovered budgets: the registered
    /// file ID as the local/cloud identity, the receipt's group when present.
    var selectionBudgetIdentity: ActualBudget {
        ActualBudget(
            budgetID: fileID,
            cloudFileId: fileID,
            groupId: groupID,
            name: budgetName,
            state: nil
        )
    }
}

/// Owns the budget picker's Create New Budget / Import offer: when it appears
/// (see `EmptyBudgetPickerOffer`) and the create and import workflows behind it. Both `BudgetPickerView`
/// and `SettingsBudgetPickerSheet` call this coordinator; the views stay
/// presentation-only and never validate archives, name budgets, choose
/// encryption, upload, or open.
///
/// The offer decision reads live session state through `AppState`; the hosts
/// only record whether their most recent discovery attempt succeeded.
///
/// Import from a user-chosen ZIP runs through the injected import workflow:
/// `PortableBudgetArchive` validates the archive, the store registers it as a
/// new server file under one minted file ID, and BudgetFileManager's
/// new-directory install places the validated pair locally. The download
/// installer (`importBudgetZip`) and `reimportBudget` are never used for it.
@MainActor
@Observable
final class EmptyBudgetPickerCoordinator {
    enum Phase: Equatable {
        case idle
        case creating
        case importing
        case failed(message: String)
    }

    /// The store and selection calls behind the create and import workflows.
    /// Production uses `LocalFirstActualStore.createNewBudget` (which owns the
    /// no-selectable-budget-on-failure cleanup), the portable-import flow, and
    /// the existing `selectBudgetForCurrentBackend` handoff. Tests inject
    /// fakes.
    struct Workflows {
        var createNewBudget: @MainActor (
            _ appState: AppState,
            _ input: EmptyBudgetCreateInput
        ) async throws -> NewBudgetCreation
        /// Validates a user-chosen portable ZIP, registers it as a new server
        /// file, and installs the validated pair into a new local directory
        /// under one minted file ID. Production uses
        /// `LocalFirstActualStore.importPortableBudget`; tests inject fakes.
        var importPortableBudget: @MainActor (
            _ appState: AppState,
            _ archiveURL: URL
        ) async throws -> NewBudgetCreation = { appState, archiveURL in
            try await appState.localFirstStore.importPortableBudget(
                archiveAt: archiveURL,
                serverURLString: appState.settings.localFirstServerURLString
            )
        }
        var selectBudget: @MainActor (_ appState: AppState, _ budget: ActualBudget) async -> Void

        @MainActor
        static let production = Workflows(
            createNewBudget: { appState, input in
                try await appState.localFirstStore.createNewBudget(
                    named: input.budgetName,
                    serverURLString: appState.settings.localFirstServerURLString,
                    encryptionPassword: input.encryptionPassword
                )
            },
            selectBudget: { appState, budget in
                await appState.selectBudgetForCurrentBackend(budget)
            }
        )
    }

    private(set) var phase: Phase = .idle
    private var isDiscoverySucceeded = false
    private let workflows: Workflows

    init(workflows: Workflows = .production) {
        self.workflows = workflows
    }

    /// Hosts call this after each discovery attempt (initial load and pull to
    /// refresh). A failed or cancelled attempt must arrive as `false`.
    func recordDiscovery(succeeded: Bool) {
        isDiscoverySucceeded = succeeded
    }

    func offer(using appState: AppState) -> EmptyBudgetPickerOffer {
        EmptyBudgetPickerOffer.decide(
            discoverySucceeded: isDiscoverySucceeded,
            isDemoMode: appState.isDemoMode,
            budgetCount: appState.budgets.count
        )
    }

    /// Whether a create or import attempt is currently running. Hosts show
    /// progress and hold their entry points while this is true.
    var isWorkflowActive: Bool {
        phase == .creating || phase == .importing
    }

    /// Creates the new budget through `createNewBudget` and, only on a
    /// confirmed registration, hands the completed identity to the existing
    /// selection path. A create failure leaves the selection untouched — that
    /// cleanup lives in `createNewBudget`, not here.
    func createBudget(_ input: EmptyBudgetCreateInput, using appState: AppState) async {
        guard !isWorkflowActive else { return }
        phase = .creating
        appState.lastErrorMessage = nil
        do {
            let creation = try await workflows.createNewBudget(appState, input)
            let budget = creation.selectionBudgetIdentity
            await workflows.selectBudget(appState, budget)
            if appState.settings.selectedBudgetID == budget.syncID {
                phase = .idle
                // Played here because the picker host is replaced once the budget opens.
                ActualistHaptics.success()
            } else if let message = appState.lastErrorMessage {
                phase = .failed(message: message)
            } else {
                phase = .failed(message: String(localized: "The new budget could not be opened."))
            }
        } catch {
            // Cancellation ends the attempt without a user-facing failure.
            phase = error.isCancellation
                ? .idle
                : .failed(message: error.userFacingMessage ?? error.localizedDescription)
        }
    }

    /// Imports a user-chosen portable ZIP through the injected import
    /// workflow: the archive is validated, registered on the server, and
    /// installed into a new local directory under one minted file ID. Only a
    /// confirmed import is handed to the existing selection path; a failure
    /// leaves nothing selectable and no partial local directory.
    func importBudget(at archiveURL: URL, using appState: AppState) async {
        guard !isWorkflowActive else { return }
        phase = .importing
        appState.lastErrorMessage = nil
        do {
            let creation = try await workflows.importPortableBudget(appState, archiveURL)
            let budget = creation.selectionBudgetIdentity
            await workflows.selectBudget(appState, budget)
            if appState.settings.selectedBudgetID == budget.syncID {
                phase = .idle
                // Played here because the picker host is replaced once the budget opens.
                ActualistHaptics.success()
            } else if let message = appState.lastErrorMessage {
                phase = .failed(message: message)
            } else {
                phase = .failed(message: String(localized: "The imported budget could not be opened."))
            }
        } catch {
            // Cancellation ends the attempt without a user-facing failure.
            phase = error.isCancellation
                ? .idle
                : .failed(message: error.userFacingMessage ?? error.localizedDescription)
        }
    }
}

/// The Create New Budget / Import section both budget-picker hosts embed when
/// the coordinator offers it. Presentation only: it binds the create form's
/// controls and calls coordinator intents.
struct EmptyBudgetPickerSection: View {
    let coordinator: EmptyBudgetPickerCoordinator
    var onBudgetSelected: () -> Void = {}

    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @State private var isCreateFormPresented = false
    @State private var isImportPickerPresented = false

    var body: some View {
        Section {
            if case .failed(let message) = coordinator.phase {
                Text(message)
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if coordinator.isWorkflowActive {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(coordinator.phase == .importing ? "Importing Budget" : "Creating Budget")
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    Button {
                        isCreateFormPresented = true
                    } label: {
                        Label("Create New Budget", systemImage: "plus.circle.fill")
                            .font(ActualistTypography.control(for: density))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(ActualistTheme.accent)

                    Button {
                        isImportPickerPresented = true
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                            .font(ActualistTypography.control(for: density))
                    }
                    .buttonStyle(.glass)
                }
            }
        } header: {
            Text(appState.budgets.isEmpty ? "No Budgets" : "New Budget")
        }
        .sheet(isPresented: $isCreateFormPresented) {
            EmptyBudgetCreateForm(coordinator: coordinator, onCreated: onBudgetSelected)
                .environment(appState)
        }
        .fileImporter(
            isPresented: $isImportPickerPresented,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let archiveURL = urls.first else { return }
            Task { await coordinator.importBudget(at: archiveURL, using: appState) }
        }
    }
}

/// Collects the new budget's name and optional encryption password. The
/// interpretation of the raw controls lives in `EmptyBudgetCreateInput`.
private struct EmptyBudgetCreateForm: View {
    let coordinator: EmptyBudgetPickerCoordinator
    var onCreated: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var budgetName = ""
    @State private var encryptionWanted = false
    @State private var encryptionPassword = ""

    private var input: EmptyBudgetCreateInput {
        EmptyBudgetCreateInput.make(
            budgetName: budgetName,
            encryptionWanted: encryptionWanted,
            encryptionPassword: encryptionPassword
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("New Budget") {
                    TextField(
                        "Budget Name",
                        text: $budgetName,
                        prompt: Text("Required")
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    Toggle("Encrypt Budget", isOn: $encryptionWanted)

                    if encryptionWanted {
                        SecureField(
                            "Encryption Password",
                            text: $encryptionPassword,
                            prompt: Text("Required")
                        )
                    }
                }

                if case .failed(let message) = coordinator.phase {
                    Section {
                        Text(message)
                            .foregroundStyle(ActualistTheme.danger)
                    }
                }
            }
            .navigationTitle("Create Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            await coordinator.createBudget(input, using: appState)
                            if coordinator.phase == .idle,
                               appState.settings.selectedBudgetID != nil {
                                onCreated()
                                dismiss()
                            }
                        }
                    }
                    .disabled(!input.isSubmittable || coordinator.isWorkflowActive)
                }
            }
        }
    }
}
