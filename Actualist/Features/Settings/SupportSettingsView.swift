import SwiftUI

/// Support settings: diagnostics, bug reports, privacy policy, licenses.
struct SupportSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var diagnosticReportCopied = false
    @State private var supportViewModel = SupportSettingsViewModel()
    @State private var viewModel = SettingsViewModel()

    private static let newIssueURL = URL(string: "https://github.com/sporez/actualist/issues/new")!
    private static let privacyPolicyURL = URL(string: "https://github.com/sporez/actualist/blob/main/PRIVACY.md")!

    var body: some View {
        List {
            Section {
                Text("Actualist is in beta. If something goes wrong, include a diagnostic report with your bug report so the app, sync, and background state can be investigated.")
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
                    viewModel.copyDiagnosticReport(using: appState)
                    diagnosticReportCopied = true
                } label: {
                    SettingsActionLabel(
                        title: diagnosticReportCopied ? "Diagnostic Report Copied" : "Copy Diagnostic Report",
                        systemImage: diagnosticReportCopied ? "checkmark" : "doc.on.doc"
                    )
                }
            }
            .settingsSectionChrome()

            Section {
                Link(destination: Self.newIssueURL) {
                    SettingsActionLabel(title: "Submit a Bug Report", systemImage: "ladybug")
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
                    Text("Reports exclude credentials, server addresses, identifiers, names, budget contents, transaction details, and financial amounts.")
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
            supportViewModel.prepareDiagnosticReport(using: appState)
        }
    }
}
