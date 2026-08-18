import SwiftUI

/// Reports settings: chart/card ordering on the Reports screen.
struct ReportsSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var isReportOrderExpanded = true

    var body: some View {
        List {
            Section {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        isReportOrderExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Label("Chart Order", systemImage: "chart.xyaxis.line")
                            .foregroundStyle(ActualistTheme.primaryText)
                        Spacer(minLength: 8)
                        Image(systemName: isReportOrderExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(ActualistTheme.secondaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isReportOrderExpanded {
                    Text("Drag the handles to change the order of cards on the Reports screen.")
                        .font(.caption)
                        .foregroundStyle(ActualistTheme.secondaryText)

                    ForEach(appState.settings.reportCardOrder) { reportCard in
                        Label(reportCard.title, systemImage: reportCard.symbolName)
                            .foregroundStyle(ActualistTheme.primaryText)
                    }
                    .onMove(perform: moveReportCards)

                    Button {
                        appState.resetReportCardOrder()
                    } label: {
                        SettingsActionLabel(
                            title: "Reset Report Order",
                            systemImage: "arrow.counterclockwise"
                        )
                    }
                    .disabled(
                        appState.settings.reportCardOrder == ReportCardOrderPreference.defaultOrder
                    )
                }
            } header: {
                Text("Chart Order")
            } footer: {
                Text("Controls the order of cards on the Reports screen.")
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
            }
            .settingsSectionChrome()
        }
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .tint(ActualistTheme.accent)
        .environment(
            \.editMode,
            .constant(isReportOrderExpanded ? .active : .inactive)
        )
        .navigationTitle("Reports")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func moveReportCards(from source: IndexSet, to destination: Int) {
        var reportCardOrder = appState.settings.reportCardOrder
        reportCardOrder.move(fromOffsets: source, toOffset: destination)
        appState.updateReportCardOrder(reportCardOrder)
    }
}
