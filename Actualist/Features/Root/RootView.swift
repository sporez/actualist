import SwiftUI

/// Delay before the shared launch placeholder draws. Long enough that a cached
/// launch goes straight from the system launch screen into the Budget, short
/// enough that a genuinely slow open — first import, migration, key access, old
/// hardware — still explains itself instead of showing an empty screen.
private let launchPlaceholderRevealDelay: Duration = .milliseconds(250)

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var budgetSession: AdaptiveBudgetSession?
    @State private var transactionPresenter = RootTransactionEditorPresenter()
    @State private var adaptiveSelection: AdaptiveRootDestination? = .budget
    @State private var isLaunchPlaceholderRevealed = false
    @State private var launchPlaceholderRevealTask: Task<Void, Never>?
    @State private var hasPresentedInitialBudget = false

    var body: some View {
        let theme = appState.settings.theme.palette

        Group {
            switch appState.setupPhase {
            case .needsConnection:
                OnboardingView()
            case .selectingBudget:
                BudgetPickerView()
            case .restoringBudget:
                sessionPlaceholder(theme: theme)
            case .credentialUnavailable:
                CredentialRecoveryView()
            case .ready:
                if appState.isReadyForMainTabs {
                    adaptiveShell(theme: theme)
                } else if appState.credentialRecoveryMessage != nil {
                    CredentialRecoveryView()
                } else if appState.hasSyncCredentials {
                    BudgetPickerView()
                } else {
                    OnboardingView()
                }
            }
        }
        .id("\(appState.settings.theme.rawValue)-\(appState.themeRevision)")
        .background(theme.background.ignoresSafeArea())
        .tint(theme.chromeForeground)
        .environment(\.actualistDensity, appState.settings.displayDensity)
        .environment(transactionPresenter)
        .onChange(of: appState.settings.selectedBudgetID) {
            reconcileTransactionPresenter()
        }
        .onChange(of: isLaunchGatePending, initial: true) { _, isPending in
            updateLaunchPlaceholderReveal(isPending)
        }
        .onChange(of: appState.setupPhase) { _, phase in
            handleSetupPhaseChange(phase)
        }
        .onChange(of: appState.settings.localFirstServerURLString) {
            reconcileTransactionPresenter()
        }
        .onChange(of: transactionPresenter.presentation?.id) { _, id in
            if id == nil { transactionPresenter.consumeNewTransaction(using: appState) }
        }
        .task {
            if budgetSession == nil {
                budgetSession = AdaptiveBudgetSession(repository: appState.localFirstStore)
            }
        }
    }

    private func reconcileTransactionPresenter() {
        transactionPresenter.reconcile(using: appState)
    }

    /// A session teardown unmounts the adaptive shell while RootView keeps this
    /// selection. Drop it so the next budget session starts on the current tab
    /// instead of restoring the destroyed session's Settings destination, and
    /// tell the app-session coordinator that no Budget is currently presented.
    private func handleSetupPhaseChange(_ phase: SetupPhase) {
        guard phase != .ready else { return }
        adaptiveSelection = nil
        appState.budgetDidPresent(nil)
    }

    /// The presented window: either the compact tab shell or the wide workspace,
    /// for the session's current context. Extracted from `body` so the launch
    /// gates above stay cheap for the type checker.
    private func adaptiveShell(theme: ActualistThemePalette) -> some View {
        GeometryReader { proxy in
            let mode = AdaptiveRootPresentationMode.mode(
                for: proxy.size.width,
                dynamicTypeScale: dynamicTypeSize.budgetLayoutScale
            )
            ZStack {
                if let budgetSession,
                   let context = budgetSession.presentedContext,
                   context.budgetID == appState.settings.selectedBudgetID {
                    switch context.mode {
                    case .compact:
                        MainTabView(budgetViewModel: budgetSession.compactModel)
                            .environment(\.budgetRootWidth, proxy.size.width)
                            .environment(\.budgetSidebarLayoutActive, false)
                            .transition(hasPresentedInitialBudget ? .opacity : .identity)
                            .onAppear {
                                hasPresentedInitialBudget = true
                                LaunchSignpost.event(LaunchStage.compactPresentation)
                                if let budgetID = context.budgetID {
                                    appState.budgetDidPresent(budgetID)
                                }
                            }
                    case .sidebar:
                        AdaptiveRootShell(
                            selection: $adaptiveSelection,
                            viewport: budgetSession.viewport,
                            budgetViewModel: budgetSession.compactModel,
                            rootWidth: proxy.size.width
                        )
                        .transition(hasPresentedInitialBudget ? .opacity : .identity)
                        .onAppear {
                            hasPresentedInitialBudget = true
                            LaunchSignpost.event(LaunchStage.sidebarPresentation)
                            if let budgetID = context.budgetID {
                                appState.budgetDidPresent(budgetID)
                            }
                        }
                    }
                } else {
                    sessionPlaceholder(theme: theme)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(
                hasPresentedInitialBudget && !reduceMotion ? .easeInOut(duration: 0.22) : nil,
                value: budgetSession?.presentedContext?.mode
            )
            .onChange(of: mode) { _, newMode in
                applyPresentationMode(newMode)
            }
            .onChange(of: budgetSession != nil) { _, ready in
                guard ready else { return }
                requestSessionUpdate(mode: mode)
            }
            .task(id: "\(appState.settings.selectedBudgetID ?? "none")-\(mode)") {
                requestSessionUpdate(mode: mode)
            }
        }
        .sheet(item: $transactionPresenter.presentation) { presentation in
            RootTransactionEditorContent(presentation: presentation)
                .appSwitcherPrivacyProtected(using: appState)
        }
    }

    private func requestSessionUpdate(mode: AdaptiveRootPresentationMode) {
        budgetSession?.update(
            mode: mode,
            budgetID: appState.settings.selectedBudgetID,
            appState: appState
        )
    }

    private func applyPresentationMode(_ mode: AdaptiveRootPresentationMode) {
        if mode == .compact {
            if let adaptiveSelection, adaptiveSelection.isAccount {
                AdaptiveRootRouting.activate(adaptiveSelection, using: appState)
            }
            adaptiveSelection = AdaptiveRootDestination(tab: appState.selectedTab)
        }
        requestSessionUpdate(mode: mode)
    }

    /// `true` while either launch gate is unresolved: restoring the saved budget,
    /// then preparing the session's first presentable month. Both draw the same
    /// placeholder.
    private var isLaunchGatePending: Bool {
        switch appState.setupPhase {
        case .restoringBudget:
            return true
        case .ready:
            guard appState.isReadyForMainTabs else { return false }
            return budgetSession?.presentedContext?.budgetID != appState.settings.selectedBudgetID
        case .needsConnection, .selectingBudget, .credentialUnavailable:
            return false
        }
    }

    /// Runs the reveal timer once per unresolved gate and cancels it the moment
    /// the Budget is presentable, so a late timer can never draw a loader over it.
    private func updateLaunchPlaceholderReveal(_ isPending: Bool) {
        guard isPending else {
            launchPlaceholderRevealTask?.cancel()
            launchPlaceholderRevealTask = nil
            isLaunchPlaceholderRevealed = false
            return
        }
        guard launchPlaceholderRevealTask == nil else { return }
        launchPlaceholderRevealTask = Task {
            try? await Task.sleep(for: launchPlaceholderRevealDelay)
            guard !Task.isCancelled else { return }
            isLaunchPlaceholderRevealed = true
        }
    }

    /// The one launch placeholder, shared by both sequential gates — restoring
    /// the saved budget and creating/preparing the adaptive session — so they
    /// read as one continuous load instead of two loaders. Keep this centered and
    /// framed; an intrinsic-sized placeholder inside `GeometryReader` lands in
    /// the top-leading corner instead. It stays invisible for the first
    /// `launchPlaceholderRevealDelay` so a normal cached launch transitions from
    /// the system launch experience straight into the Budget.
    private func sessionPlaceholder(theme: ActualistThemePalette) -> some View {
        VStack(spacing: 12) {
            if isLaunchPlaceholderRevealed {
                ProgressView()
                Text("Opening local budget")
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
