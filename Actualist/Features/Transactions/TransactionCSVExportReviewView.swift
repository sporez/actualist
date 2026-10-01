import SwiftUI

struct TransactionCSVExportReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let budgetID: String
    let accountID: String
    let repository: any TransactionCSVExportRepositoryProtocol
    @State private var workflow = TransactionCSVExportWorkflow()

    var body: some View {
        NavigationStack {
            ReviewSheetContent {
                ReviewSheetHeader(
                    title: "Export CSV",
                    subtitle: "Export every transaction in this account from your local budget."
                )
                stateCard
            }
            .navigationTitle("Export CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        workflow.cancel()
                        dismiss()
                    }
                }
            }
        }
        .presentationBackground(ActualistTheme.background)
        .task {
            await workflow.export(budgetID: budgetID, accountID: accountID, repository: repository)
        }
        .onDisappear { workflow.cancel() }
    }

    @ViewBuilder
    private var stateCard: some View {
        switch workflow.state {
        case .idle:
            EmptyView()
        case .exporting:
            ProgressView("Preparing local CSV…")
                .frame(maxWidth: .infinity)
                .actualistReviewCard()
        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(ActualistTheme.danger)
                Button("Try Again") {
                    Task { await workflow.export(budgetID: budgetID, accountID: accountID, repository: repository) }
                }
                .buttonStyle(.glass)
            }
            .actualistReviewCard()
        case .ready(let export):
            VStack(alignment: .leading, spacing: 12) {
                ReviewSummaryRow(title: "Transaction families", value: "\(export.exportedFamilyCount)", symbol: "rectangle.stack")
                ReviewSummaryRow(title: "CSV rows", value: "\(export.exportedRowCount)", symbol: "tablecells")
                Text("A split family counts once above and includes one CSV row for each transaction. This file contains budget data; share it only with people you trust.")
                    .font(.footnote)
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                ShareLink(
                    item: TransactionCSVTransfer(data: export.data, filename: export.suggestedFilename),
                    preview: SharePreview(export.suggestedFilename, image: Image(systemName: "doc.text"))
                ) {
                    Label("Share CSV…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            }
            .actualistReviewCard()
        }
    }
}
