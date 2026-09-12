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
                                ProgressView()
                            }
                        }
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
