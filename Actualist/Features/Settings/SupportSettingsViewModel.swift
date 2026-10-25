import Observation

@MainActor
@Observable
final class SupportSettingsViewModel {
    private(set) var diagnosticReport: ActualistDiagnosticReport?

    func prepareDiagnosticReport(using appState: AppState) async {
        let bankSync = await appState.localFirstStore.bankSyncDiagnosticSnapshot()
        diagnosticReport = ActualistDiagnosticReportBuilder.make(appState: appState, bankSync: bankSync)
    }
}
