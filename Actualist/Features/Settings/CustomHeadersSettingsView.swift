import SwiftUI

struct CustomHeadersSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: CustomHeadersSettingsViewModel

    init(store: LocalFirstActualStore, primaryURLString: String, fallbackURLString: String) {
        _viewModel = State(initialValue: CustomHeadersSettingsViewModel(
            store: store, primaryURLString: primaryURLString, fallbackURLString: fallbackURLString
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
                            SecureField("Value", text: Binding(
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
                        Text("Custom headers are sent only to the selected Actual server. Values are stored securely on this device.")
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
