import SwiftUI

/// Support settings: diagnostics, help, privacy policy, licenses.
struct SupportSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var diagnosticReportCopied = false
    @State private var supportViewModel = SupportSettingsViewModel()
    @State private var viewModel = SettingsViewModel()

    private static let supportURL = URL(string: "https://actualist.app/support")!
    private static let privacyPolicyURL = URL(string: "https://actualist.app/privacy")!

    var body: some View {
        List {
            Section {
                Text("If something goes wrong, include a diagnostic report when you ask for help. It helps find the cause.")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)

                if let diagnosticReport = supportViewModel.diagnosticReport {
                    ShareLink(
                        item: diagnosticReport,
                        preview: SharePreview(
                            "Actualist Diagnostic Report",
                            image: Image(systemName: "doc.text")
                        )
                    ) {
                        SettingsActionLabel(
                            title: "Share Diagnostic Report",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .accessibilityIdentifier("diagnostic-report-share")
                }

                Button {
                    Task {
                        await viewModel.copyDiagnosticReport(using: appState)
                        diagnosticReportCopied = true
                    }
                } label: {
                    SettingsActionLabel(
                        title: diagnosticReportCopied ? "Diagnostic Report Copied" : "Copy Diagnostic Report",
                        systemImage: diagnosticReportCopied ? "checkmark" : "doc.on.doc"
                    )
                }
            }
            .settingsSectionChrome()

            Section {
                Link(destination: Self.supportURL) {
                    SettingsActionLabel(title: "Get Help", systemImage: "questionmark.bubble")
                }

                Link(destination: Self.privacyPolicyURL) {
                    SettingsActionLabel(title: "Privacy Policy", systemImage: "hand.raised")
                }

                NavigationLink {
                    OpenSourceLicensesView()
                } label: {
                    SettingsActionLabel(title: "Open Source Licenses", systemImage: "doc.text")
                }
            }
            .settingsSectionChrome()

            Section {
                Label {
                    Text("Reports do not include passwords, server addresses, names, or any budget details.")
                        .font(.caption)
                        .foregroundStyle(ActualistTheme.secondaryText)
                } icon: {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(ActualistTheme.positive)
                }
            }
            .settingsSectionChrome()
        }
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .tint(ActualistTheme.accent)
        .navigationTitle("Support")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.hydrate(from: appState)
        }
        .task {
            await supportViewModel.prepareDiagnosticReport(using: appState)
        }
    }
}
