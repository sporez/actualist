import SwiftUI

struct TransactionCSVExportReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let budgetID: String
    let accountID: String
    let repository: any TransactionCSVExportRepositoryProtocol
    @State private var workflow = TransactionCSVExportWorkflow()

    var body: some View {
        ReviewSheetContent {
            header
            if case .ready(let export) = workflow.state {
                summaryCard(for: export)
            } else {
                stateCard
            }
        }
        .reviewSheetBottomBar {
            if case .ready(let export) = workflow.state {
                Button(role: .cancel, action: close) {
                    Text("Done")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 32)
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.glass)
                shareCSVButton(for: export)
            } else {
                Button(role: .cancel, action: close) {
                    Text("Cancel")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 32)
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.glass)
                Spacer(minLength: 0)
            }
        }
        .background(ActualistTheme.background)
        .presentationBackground(ActualistTheme.background)
        .task {
            await workflow.export(budgetID: budgetID, accountID: accountID, repository: repository)
        }
        .onDisappear { workflow.cancel() }
    }

    private func close() {
        workflow.cancel()
        dismiss()
    }

    private var header: some View {
        ReviewSheetHeader(
            title: "Export CSV",
            subtitle: "Export every transaction in this account from your local budget."
        )
    }

    @ViewBuilder
    private var stateCard: some View {
        switch workflow.state {
        case .ready:
            EmptyView()
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
        }
    }

    private func summaryCard(for export: TransactionCSVExport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ReviewSummaryRow(title: "Transaction families", value: "\(export.exportedFamilyCount)", symbol: "rectangle.stack")
            ReviewSummaryRow(title: "CSV rows", value: "\(export.exportedRowCount)", symbol: "tablecells")
            Text("A split family counts once above and includes one CSV row for each transaction. This file contains budget data; share it only with people you trust.")
                .font(.footnote)
                .foregroundStyle(ActualistTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .actualistReviewCard()
    }

    private func shareCSVButton(for export: TransactionCSVExport) -> some View {
        ShareLink(
            item: TransactionCSVTransfer(data: export.data, filename: export.suggestedFilename),
            preview: SharePreview(export.suggestedFilename, image: Image(systemName: "doc.text"))
        ) {
            Label("Share CSV…", systemImage: "square.and.arrow.up")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.glassProminent)
        .tint(ActualistTheme.accent)
    }
}
