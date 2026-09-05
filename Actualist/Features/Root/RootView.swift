import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
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
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Opening local budget")
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                if appState.isReadyForMainTabs {
                    GeometryReader { proxy in
                        let mode = AdaptiveRootPresentationMode.mode(
                            for: proxy.size.width,
                            dynamicTypeScale: dynamicTypeSize.budgetLayoutScale
                        )
                        Group {
                            switch mode {
                            case .compact:
                                Group {
                                    if let budgetSession, budgetSession.presentedContext == .init(mode: mode, budgetID: appState.settings.selectedBudgetID) {
                                        MainTabView(budgetViewModel: budgetSession.compactModel)
                                    } else {
                                        ProgressView()
                                    }
                                }
                                    .environment(\.budgetRootWidth, proxy.size.width)
                                    .environment(\.budgetSidebarLayoutActive, false)
                            case .sidebar:
                                if let budgetSession, budgetSession.presentedContext == .init(mode: mode, budgetID: appState.settings.selectedBudgetID) {
                                    AdaptiveRootShell(
                                        selection: $adaptiveSelection,
                                        viewport: budgetSession.viewport,
                                        budgetViewModel: budgetSession.compactModel,
                                        rootWidth: proxy.size.width
                                    )
                                } else {
                                    ProgressView()
                                }
                            }
                        }
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
}
