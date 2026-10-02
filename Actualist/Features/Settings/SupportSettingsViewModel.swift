import Observation

@MainActor
@Observable
final class SupportSettingsViewModel {
    private(set) var diagnosticReport: ActualistDiagnosticReport?

    func prepareDiagnosticReport(using appState: AppState) {
        diagnosticReport = ActualistDiagnosticReportBuilder.make(appState: appState)
    }
}
