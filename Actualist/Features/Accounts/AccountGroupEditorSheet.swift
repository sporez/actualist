import SwiftUI

struct AccountGroupEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.actualistDensity) private var density

    let title: String
    @Binding var name: String
    let errorMessage: String?
    let isSubmitting: Bool
    let canSubmit: Bool
    let onCancel: () -> Void
    let onSubmit: () async -> Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Name")
                            .font(ActualistTypography.rowLabel(for: density))
                            .foregroundStyle(ActualistTheme.secondaryText)

                        TextField("Cash", text: $name)
                            .font(ActualistTypography.rowTitle(for: density))
                            .foregroundStyle(ActualistTheme.primaryText)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .onSubmit {
                                Task { await submit() }
                            }
                    }
                    .padding(16)
                    .background(ActualistTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                    if let errorMessage {
                        Text(errorMessage)
                            .font(ActualistTypography.rowTitle(for: density))
                            .foregroundStyle(ActualistTheme.danger)
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Save")
                                .font(ActualistTypography.control(for: density))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(ActualistTheme.accent)
                    .disabled(!canSubmit)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(ActualistTheme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
            }
        }
    }

    private func submit() async {
        guard await onSubmit() else {
            return
        }
        dismiss()
    }
}
