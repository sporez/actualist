import SwiftUI

struct SettingsAccountOrderSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density
    @Environment(\.dismiss) private var dismiss

    @State private var model = SettingsAccountOrderViewModel()

    private var buckets: [SettingsAccountOrderViewModel.OrderBucket] { model.buckets(using: appState) }

    var body: some View {
        List {
            ReviewSheetListHeader(
                title: "Account Order",
                subtitle: "Drag accounts to reorder them."
            )
            if model.isLoading {
                ProgressView("Loading accounts")
                    .settingsRowChrome()
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(ActualistTypography.rowTitle(for: density))
                    .foregroundStyle(ActualistTheme.danger)
                    .settingsRowChrome()
            }

            if appState.settings.selectedBudgetID == nil {
                Section("Accounts") {
                    Text("Select a budget before setting account order.")
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                .settingsSectionChrome()
            } else if buckets.isEmpty && !model.isLoading {
                Section("Accounts") {
                    Text("No accounts loaded.")
                        .font(ActualistTypography.rowTitle(for: density))
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                .settingsSectionChrome()
            } else {
                ForEach(buckets) { bucket in
                    Section {
                        ForEach(bucket.accounts) { account in
                            SettingsAccountOrderRow(account: account)
                        }
                        .onMove { model.move(in: bucket, from: $0, to: $1, using: appState) }
                    } header: {
                        SettingsAccountOrderBucketHeader(bucket: bucket)
                    }
                    .settingsSectionChrome()
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .reviewSheetList()
        .reviewSheetBottomBar {
            ReviewSheetSecondaryButton(title: "Reset", role: nil) {
                model.reset(using: appState)
            }
            .disabled(!model.hasCustomOrder(using: appState))
            ReviewSheetPrimaryButton { dismiss() } label: {
                Text("Done")
            }
        }
        .task {
            await model.load(using: appState)
        }
        .refreshable {
            await model.refresh(using: appState)
        }
        .reviewSheetPresentation(detents: [.medium, .large], appState: appState)
    }
}

private struct SettingsAccountOrderBucketHeader: View {
    let bucket: SettingsAccountOrderViewModel.OrderBucket

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sectionTitle = bucket.sectionTitle {
                Text(sectionTitle)
            }
            if let groupName = bucket.groupName {
                Label(groupName, systemImage: "folder")
                    .textCase(nil)
            }
        }
    }
}

private struct SettingsAccountOrderRow: View {
    @Environment(AppState.self) private var appState
    @Environment(\.actualistDensity) private var density

    let account: ActualAccount

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: account.offbudget ? "tray.full.fill" : "banknote.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(ActualistTheme.accent)
                .frame(width: density.iconSize, height: density.iconSize)

            Text(displayName)
                .font(ActualistTypography.rowTitle(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
        }
        .padding(.vertical, 2)
    }

    private var displayName: String {
        guard appState.settings.randomizedDisplayValuesEnabled else {
            return account.name
        }

        return PrivacyDisplay.name(for: .account, seed: account.id)
    }
}
