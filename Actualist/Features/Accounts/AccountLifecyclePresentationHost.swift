import SwiftUI

struct AccountLifecycleMenu: View {
    @Environment(AppState.self) private var appState
    let accountID: String
    let coordinator: AccountLifecycleCoordinator

    private var context: AccountLifecycleMenuContext? {
        let budgetID = appState.settings.selectedBudgetID
        return AccountLifecycleMenuContext(
            budgetID: budgetID,
            accountID: accountID,
            accounts: budgetID.map { appState.accountRepository.accountDisplays(budgetID: $0).map(\.account) } ?? []
        )
    }

    var body: some View {
        if let context {
            Button {
                coordinator.beginRename(
                    identity: context.identity,
                    account: context.account,
                    existingAccounts: context.accounts
                )
            } label: {
                Label("Rename Account", systemImage: "pencil")
            }
            .disabled(appState.settings.randomizedDisplayValuesEnabled || coordinator.isSubmitting)
            .accessibilityIdentifier("account-lifecycle-rename-action")

            if context.account.isClosed {
                Button {
                    coordinator.beginReopen(identity: context.identity, account: context.account)
                } label: {
                    Label("Reopen Account", systemImage: "arrow.uturn.backward")
                }
                .disabled(appState.settings.randomizedDisplayValuesEnabled || coordinator.isSubmitting)
                .accessibilityIdentifier("account-lifecycle-reopen-action")
            } else {
                Button(role: .destructive) {
                    coordinator.loadReview(
                        request: AccountLifecycleReviewRequest(
                            budgetID: context.identity.budgetID,
                            accountID: context.identity.accountID,
                            requestedAction: .close(
                                destinationAccountID: nil,
                                categoryID: nil
                            )
                        ),
                        repository: appState.localFirstStore
                    )
                } label: {
                    Label("Close Account", systemImage: "xmark.circle")
                }
                .disabled(appState.settings.randomizedDisplayValuesEnabled || coordinator.isSubmitting)
                .accessibilityIdentifier("account-lifecycle-close-action")
            }
        }
    }
}

/// The same coordinator-driven sheet is composed into both account entry points.
/// Its bindings only dismiss presentation; commands and errors stay in the coordinator.
struct AccountLifecyclePresentationHost: ViewModifier {
    @Environment(AppState.self) private var appState
    @Environment(\.budgetCurrency) private var currency
    let coordinator: AccountLifecycleCoordinator

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: sheetBinding) {
                sheetContent
                    .appSwitcherPrivacyProtected(using: appState)
                    .interactiveDismissDisabled(coordinator.isSubmitting)
                    .presentationBackground(ActualistTheme.background)
            }
            .onChange(of: appState.settings.selectedBudgetID) { coordinator.cancel() }
            .onChange(of: appState.localFirstStore.budgetSessionGeneration) { coordinator.cancel() }
            .onChange(of: appState.settings.randomizedDisplayValuesEnabled, initial: true) {
                coordinator.updatePrivacyMode(appState.settings.randomizedDisplayValuesEnabled)
            }
    }

    private var sheetBinding: Binding<Bool> {
        Binding(
            get: { AccountLifecyclePresentation.mutationSheet(for: coordinator.state) != nil },
            set: { if !$0 { coordinator.cancel() } }
        )
    }

    @ViewBuilder
    private var sheetContent: some View {
        switch AccountLifecyclePresentation.mutationSheet(for: coordinator.state) {
        case .savedRefreshPending:
            let receiptID = appState.routeCoordinator.pendingAccountLifecycleReceipt?.id
            NavigationStack {
                ReviewSheetContent {
                    ReviewSheetHeader(
                        title: "Account Change Saved",
                        subtitle: "Your change is saved on this device."
                    )
                    Label(
                        "Pull to refresh the account list to update its display.",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .actualistReviewCard()
                }
                .reviewSheetBottomBar {
                    Spacer(minLength: 0)
                    Button { coordinator.cancel() } label: {
                        Text("Done")
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(ActualistTheme.accent)
                }
                .toolbar(.hidden, for: .navigationBar)
            }
            .presentationDetents([.medium])
            .onDisappear {
                if let receiptID {
                    appState.routeCoordinator.accountLifecycleSavedNoticeDismissed(receiptID: receiptID)
                }
            }
        case .rename:
            AccountRenameSheet(coordinator: coordinator) {
                coordinator.submitRename(
                    repository: appState.localFirstStore,
                    onCommitted: AccountLifecycleRouting.completionHandler(using: appState)
                )
            } onRetry: {
                coordinator.retry(repository: appState.localFirstStore)
            }
        case .reopen:
            AccountReopenSheet(coordinator: coordinator) {
                coordinator.confirmReopen(
                    repository: appState.localFirstStore,
                    onCommitted: AccountLifecycleRouting.completionHandler(using: appState)
                )
            } onRetry: {
                coordinator.retry(repository: appState.localFirstStore)
            }
        case .review:
            reviewSheet
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var reviewSheet: some View {
        if let review = coordinator.review {
            AccountLifecycleReviewSheet(
                presentation: AccountLifecyclePresentation.review(
                    review,
                    currency: currency,
                    privacyModeEnabled: coordinator.isPrivacyModeEnabled
                ),
                didReplaceReview: coordinator.didReplaceReview,
                isSubmitting: coordinator.isSubmitting,
                isRefreshing: coordinator.isRefreshingReview,
                onDestinationChange: {
                    coordinator.selectCloseDestination(
                        $0,
                        repository: appState.localFirstStore
                    )
                },
                onCategoryChange: {
                    coordinator.selectCloseCategory(
                        $0,
                        repository: appState.localFirstStore
                    )
                },
                onConfirm: {
                    coordinator.confirmReview(
                        repository: appState.localFirstStore,
                        onCommitted: AccountLifecycleRouting.completionHandler(using: appState)
                    )
                },
                onCancel: { coordinator.cancel() }
            )
        } else if let error = coordinator.errorMessage {
            NavigationStack {
                ReviewSheetContent {
                    ReviewSheetHeader(
                        title: "Account Review Unavailable",
                        subtitle: "The account effects could not be loaded."
                    )
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(ActualistTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .actualistReviewCard()
                }
                .reviewSheetBottomBar {
                    Button(role: .cancel) { coordinator.cancel() } label: {
                        Text("Cancel")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 32)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.glass)
                    Button {
                        coordinator.retry(repository: appState.localFirstStore)
                    } label: {
                        Text("Review Again")
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(ActualistTheme.accent)
                }
                .toolbar(.hidden, for: .navigationBar)
            }
            .presentationDetents([.medium])
        } else {
            NavigationStack {
                ReviewSheetContent {
                    ReviewSheetHeader(
                        title: "Reviewing Account",
                        subtitle: "Checking the effects of closing this account."
                    )
                    ProgressView("Reviewing account…")
                        .frame(maxWidth: .infinity)
                        .actualistReviewCard(padding: 18)
                }
                .reviewSheetBottomBar {
                    Button(role: .cancel) { coordinator.cancel() } label: {
                        Text("Cancel")
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 32)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.glass)
                    Spacer(minLength: 0)
                }
                .toolbar(.hidden, for: .navigationBar)
            }
            .presentationDetents([.medium])
        }
    }
}
