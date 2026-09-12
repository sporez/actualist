import SwiftUI

struct EntityNotesView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isMarkdownHelpExpanded = false
    @State private var viewModel: EntityNotesViewModel

    let repository: any EntityNotesRepositoryProtocol
    let onSaved: () -> Void

    init(
        target: ActualNoteTarget,
        budgetID: String,
        isPrivacyModeEnabled: Bool,
        repository: any EntityNotesRepositoryProtocol,
        onSaved: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: EntityNotesViewModel(
            target: target,
            budgetID: budgetID,
            isPrivacyModeEnabled: isPrivacyModeEnabled
        ))
        self.repository = repository
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isPrivacyModeEnabled {
                    privacyContent
                } else if viewModel.isLoading || viewModel.phase == .idle {
                    loadingContent
                } else {
                    editorContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ActualistTheme.background)
            .navigationTitle(viewModel.target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(viewModel.isPrivacyModeEnabled ? "Done" : "Cancel") {
                        viewModel.cancel()
                        dismiss()
                    }
                }
                if !viewModel.isPrivacyModeEnabled {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task { await save() }
                        }
                        .disabled(!viewModel.canSave)
                    }
                }
            }
        }
        .interactiveDismissDisabled(viewModel.isSaving)
        .task {
            await viewModel.load(repository: repository)
        }
        .onDisappear {
            viewModel.cancel()
        }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Note")
                    .font(ActualistTypography.rowLabel(for: density))
                    .foregroundStyle(ActualistTheme.secondaryText)

                DisclosureGroup(isExpanded: $isMarkdownHelpExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: "**bold** → Bold")
                            .bold()
                        Text(verbatim: "*italic* → Italic")
                            .italic()
                    }
                    .font(.caption)
                    .foregroundStyle(ActualistTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("notes-markdown-examples")
                } label: {
                    Text("Supported Markdown")
                        .font(.caption)
                        .foregroundStyle(ActualistTheme.secondaryText)
                }
                .tint(ActualistTheme.secondaryText)
                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: isMarkdownHelpExpanded)
                .accessibilityIdentifier("notes-markdown-help")
            }

            TextEditor(text: Binding(
                get: { viewModel.text },
                set: { viewModel.text = $0 }
            ))
            .font(ActualistTypography.body(for: density))
            .foregroundStyle(ActualistTheme.primaryText)
            .accessibilityIdentifier("entity-notes-editor")
            .scrollContentBackground(.hidden)
            .padding(12)
            .background(
                ActualistTheme.surface,
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .disabled(viewModel.isSaving)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(ActualistTypography.rowLabel(for: density))
                    .foregroundStyle(ActualistTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
    }

    private var loadingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading note")
                .font(ActualistTypography.rowTitle(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
        }
    }

    private var privacyContent: some View {
        VStack(spacing: 14) {
            Image(systemName: "eye.slash")
                .font(.title2.weight(.semibold))
                .foregroundStyle(ActualistTheme.accent)
            Text("Notes are hidden while Sample Values is on.")
                .font(ActualistTypography.rowTitle(for: density))
                .foregroundStyle(ActualistTheme.primaryText)
                .multilineTextAlignment(.center)
            Text("Turn off Sample Values to view or edit this note.")
                .font(ActualistTypography.rowLabel(for: density))
                .foregroundStyle(ActualistTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }

    private func save() async {
        guard await viewModel.save(repository: repository) else {
            return
        }
        onSaved()
        dismiss()
    }
}
