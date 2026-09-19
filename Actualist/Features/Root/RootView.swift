import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var budgetSession: AdaptiveBudgetSession?
    @State private var transactionPresenter = RootTransactionEditorPresenter()
    @State private var adaptiveSelection: AdaptiveRootDestination? = .budget

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
            case .ready:
                if appState.isReadyForMainTabs {
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
                                        .transition(.opacity)
                                case .sidebar:
                                    AdaptiveRootShell(
                                        selection: $adaptiveSelection,
                                        viewport: budgetSession.viewport,
                                        budgetViewModel: budgetSession.compactModel,
                                        rootWidth: proxy.size.width
                                    )
                                    .transition(.opacity)
                                }
                            } else {
                                sessionPlaceholder(theme: theme)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.22),
                            value: budgetSession?.presentedContext?.mode
                        )
                        .onChange(of: mode) { _, newMode in
                            if newMode == .compact {
                                if let adaptiveSelection, adaptiveSelection.isAccount {
                                    AdaptiveRootRouting.activate(adaptiveSelection, using: appState)
                                }
                                adaptiveSelection = AdaptiveRootDestination(tab: appState.selectedTab)
                            }
                            budgetSession?.update(
                                mode: newMode,
                                budgetID: appState.settings.selectedBudgetID,
                                appState: appState
                            )
                        }
                        .onChange(of: budgetSession != nil) { _, ready in
                            guard ready else { return }
                            budgetSession?.update(
                                mode: mode,
                                budgetID: appState.settings.selectedBudgetID,
                                appState: appState
                            )
                        }
                        .task(id: "\(appState.settings.selectedBudgetID ?? "none")-\(mode)") {
                            budgetSession?.update(
                                mode: mode,
                                budgetID: appState.settings.selectedBudgetID,
                                appState: appState
                            )
                        }
                    }
                    .sheet(item: $transactionPresenter.presentation) { presentation in
                        RootTransactionEditorContent(presentation: presentation)
                            .appSwitcherPrivacyProtected(using: appState)
                    }
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
            transactionPresenter.reconcile(using: appState)
        }
        .onChange(of: appState.setupPhase) { _, phase in
            // A session teardown unmounts the adaptive shell while RootView
            // keeps this selection. Drop it so the next budget session starts on
            // the current tab instead of restoring the destroyed session's
            // Settings destination.
            if phase != .ready {
                adaptiveSelection = nil
            }
        }
        .onChange(of: appState.settings.localFirstServerURLString) {
            transactionPresenter.reconcile(using: appState)
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

    /// The one launch placeholder. `RootView` passes three sequential gates
    /// before the first month can draw — restoring the saved budget, creating
    /// the adaptive session, and preparing that session's first month read — so
    /// they must read as one continuous load. Keep this centered and framed;
    /// an intrinsic-sized placeholder inside `GeometryReader` lands in the
    /// top-leading corner instead.
    private func sessionPlaceholder(theme: ActualistThemePalette) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Opening local budget")
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
