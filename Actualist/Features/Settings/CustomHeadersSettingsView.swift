import SwiftUI

struct CustomHeadersSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: CustomHeadersSettingsViewModel

    init(store: LocalFirstActualStore, primaryURLString: String, fallbackURLString: String, context: CustomHeadersEditorContext = .settings) {
        _viewModel = State(initialValue: CustomHeadersSettingsViewModel(
            store: store, primaryURLString: primaryURLString, fallbackURLString: fallbackURLString, context: context
        ))
    }

    var body: some View {
        List {
            ForEach(viewModel.endpoints) { endpoint in
                Section {
                    Text(endpoint.serverLabel)
                        .foregroundStyle(ActualistTheme.secondaryText)
                    if endpoint.needsOriginReview && !endpoint.headers.isEmpty {
                        Text("The server address changed. These saved headers are not being sent to this server.")
                            .font(.footnote)
                            .foregroundStyle(ActualistTheme.warning)
                        Button("Use Saved Headers for This Server") {
                            viewModel.reviewOrigin(for: endpoint.id)
                        }
                        .disabled(endpoint.url == nil)
                    }
                    ForEach(endpoint.headers) { header in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Header Name", text: Binding(
                                get: { header.name },
                                set: { viewModel.updateHeader(header.id, role: endpoint.id, name: $0) }
                            ))
                            CustomHeaderValueField(value: Binding(
                                get: { header.value },
                                set: { viewModel.updateHeader(header.id, role: endpoint.id, value: $0) }
                            ))
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                    .onDelete { viewModel.removeHeaders(at: $0, role: endpoint.id) }
                    Button("Add Header", systemImage: "plus") {
                        viewModel.addHeader(to: endpoint.id)
                    }
                    .disabled(endpoint.url == nil)
                    Button {
                        viewModel.testConnection(for: endpoint.id)
                    } label: {
                        HStack {
                            Text("Test Connection")
                            if viewModel.phase == .testing(endpoint.id) { ProgressView() }
                        }
                    }
                    .disabled(endpoint.url == nil || viewModel.isTesting)
                    if case .result(let role, let result) = viewModel.phase, role == endpoint.id {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.title).font(.subheadline.weight(.semibold))
                            Text(result.message).font(.footnote)
                        }
                        .foregroundStyle(ActualistTheme.secondaryText)
                    }
                } header: {
                    Text(endpoint.title)
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Headers are sent with requests to this server. Values are stored securely on this device.")
                        if let guidance = endpoint.addressGuidance {
                            Text(guidance)
                        }
                        if let warning = endpoint.securityWarning {
                            Text(warning).foregroundStyle(ActualistTheme.warning)
                        }
                    }
                }
                .settingsSectionChrome()
            }
            if let message = viewModel.errorMessage {
                Section { Text(message).foregroundStyle(ActualistTheme.danger) }
                    .settingsSectionChrome()
            }
        }
        .scrollContentBackground(.hidden)
        .background(ActualistTheme.background)
        .foregroundStyle(ActualistTheme.primaryText)
        .tint(ActualistTheme.accent)
        .navigationTitle("Custom Headers")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { if viewModel.save() { dismiss() } }
                    .disabled(!viewModel.canSave)
            }
        }
        .onDisappear { viewModel.cancelTesting() }
    }
}

private struct CustomHeaderValueField: View {
    private enum Field: Hashable { case hidden, revealed }

    @Binding var value: String
    @State private var isRevealed = false
    @FocusState private var focusedField: Field?

    var body: some View {
        HStack {
            // Removing or hiding SecureField triggers iOS's Save Password prompt; keep it mounted.
            ZStack {
                SecureField("Value", text: $value)
                    .foregroundStyle(isRevealed ? Color.clear : ActualistTheme.primaryText)
                    .focused($focusedField, equals: .hidden)
                    .allowsHitTesting(!isRevealed)
                    .accessibilityHidden(isRevealed)
                    .zIndex(isRevealed ? 0 : 1)
                if isRevealed {
                    TextField("Value", text: $value)
                        .focused($focusedField, equals: .revealed)
                }
            }
            .privacySensitive()
            Button(isRevealed ? "Hide Header Value" : "Show Header Value",
                   systemImage: isRevealed ? "eye.slash" : "eye") {
                let wasFocused = focusedField != nil
                isRevealed.toggle()
                if wasFocused { focusedField = isRevealed ? .revealed : .hidden }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .frame(minWidth: 44, minHeight: 44)
        }
    }
}
