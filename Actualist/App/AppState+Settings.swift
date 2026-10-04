import Foundation

extension AppState {
    /// Updates the optional fallback server URL used when the primary server is
    /// unreachable (e.g. a Tailscale URL when away from home Wi-Fi). An empty
    /// string clears it. This does not affect the saved connection, sync token,
    /// or budget selection — the fallback is the same logical server reached via
    /// a different network path.
    /// Returns the rejection message, leaving every setting unchanged, when the
    /// address fails `ActualServerConnectionSecurity.rejection(for:)`.
    @discardableResult
    func updateFallbackServerURL(_ serverURL: String) -> String? {
        let normalized = ActualServerURLNormalizer.normalize(serverURL)
        if let rejection = ActualServerConnectionSecurity.rejection(for: normalized) {
            return rejection
        }
        settings.fallbackServerURLString = normalized
        localFirstStore.fallbackServerURLString = normalized.isEmpty ? nil : normalized
        settingsStore.save(settings)
        return nil
    }

    func updateDisplayDensity(_ density: ActualistDisplayDensity) {
        settings.displayDensity = density
        settingsStore.save(settings)
    }

    func updateMonthDisplayPreference(_ preference: MonthDisplayPreference) {
        settings.monthDisplayPreference = preference
        settingsStore.save(settings)
    }

    func updateGreenIncomeTransactionAmountsEnabled(_ isEnabled: Bool) {
        settings.greenIncomeTransactionAmountsEnabled = isEnabled
        settingsStore.save(settings)
    }

    func updateIncludeCarryoverCategoriesInOverspentAlerts(_ isEnabled: Bool) {
        settings.includeCarryoverCategoriesInOverspentAlerts = isEnabled
        settingsStore.save(settings)
    }

    func updateShowTotalAssigned(_ isEnabled: Bool) {
        settings.showTotalAssigned = isEnabled
        settingsStore.save(settings)
    }

    func updateMonthSwipingEnabled(_ isEnabled: Bool) {
        settings.monthSwipingEnabled = isEnabled
        settingsStore.save(settings)
    }

    func updateHideCarryoverArrows(_ isHidden: Bool) {
        settings.hideCarryoverArrows = isHidden
        settingsStore.save(settings)
    }

    func updateShowHiddenCategories(_ isEnabled: Bool) {
        settings.showHiddenCategories = isEnabled
        settingsStore.save(settings)
    }

    func updateRandomizedDisplayValuesEnabled(_ isEnabled: Bool) {
        settings.randomizedDisplayValuesEnabled = isEnabled
        settingsStore.save(settings)
    }

    func updateShortcutsEnabled(_ isEnabled: Bool) {
        settings.shortcutsEnabled = isEnabled
        settingsStore.save(settings)
    }

    func updateTheme(_ theme: ActualistThemeOption) {
        settings.theme = theme
        ActualistTheme.activate(theme)
        themeRevision += 1
        settingsStore.save(settings)
    }

    func orderedAccounts(_ accounts: [ActualAccount], budgetID: String) -> [ActualAccount] {
        AccountOrderPreference.ordered(
            accounts,
            preferredIDs: settings.accountOrderByBudgetID[budgetID] ?? []
        )
    }

    func updateAccountOrder(_ accountIDs: [String], budgetID: String) {
        settings.accountOrderByBudgetID[budgetID] = accountIDs
        settingsStore.save(settings)
    }

    func resetAccountOrder(budgetID: String) {
        settings.accountOrderByBudgetID[budgetID] = nil
        settingsStore.save(settings)
    }

    func defaultAccountID(forBudgetID budgetID: String) -> String? {
        settings.defaultAccountIDByBudgetID[budgetID]
    }

    func setDefaultAccountID(_ accountID: String?, budgetID: String) {
        settings.defaultAccountIDByBudgetID[budgetID] = accountID
        settingsStore.save(settings)
    }

    func updateReportCardOrder(_ reportCardOrder: [ReportCardKind]) {
        settings.reportCardOrder = ReportCardOrderPreference.normalized(reportCardOrder)
        settingsStore.save(settings)
    }

    func resetReportCardOrder() {
        settings.reportCardOrder = ReportCardOrderPreference.defaultOrder
        settingsStore.save(settings)
    }
}
