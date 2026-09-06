import Foundation
import Observation

struct CustomHeadersEndpointDraft: Identifiable, Equatable {
    let id: ActualServerEndpointRole
    let url: URL?
    var headers: [CustomHTTPHeader]
    var needsOriginReview: Bool

    var title: String { id.title }
    var serverLabel: String { url?.host ?? "No server configured" }
    var securityWarning: String? {
        url.flatMap { ActualServerConnectionSecurity.warningMessage(for: $0.absoluteString) }
    }
}

@MainActor
@Observable
final class CustomHeadersSettingsViewModel {
    enum Phase: Equatable {
        case editing
        case testing(ActualServerEndpointRole)
        case result(ActualServerEndpointRole, CustomHTTPHeaderVerification)
        case failed(String)
        case saved
    }

    private(set) var endpoints: [CustomHeadersEndpointDraft] = []
    private(set) var phase: Phase = .editing
    private let store: LocalFirstActualStore
    private let verifier: CustomHTTPHeaderVerifier
    private var loadedConfiguration: CustomHTTPHeaderConfiguration?
    private var generation = 0
    private var testTask: Task<Void, Never>?

    init(store: LocalFirstActualStore, primaryURLString: String, fallbackURLString: String, verifier: CustomHTTPHeaderVerifier = .init()) {
        self.store = store
        self.verifier = verifier
        do {
            let configuration = try store.keychain.readCustomHTTPHeaders()
            loadedConfiguration = configuration
            endpoints = ActualServerEndpointRole.allCases.map { role in
                let text = role == .primary ? primaryURLString : fallbackURLString
                let url = URL(string: ActualServerURLNormalizer.normalize(text))
                    .flatMap { (try? HTTPOrigin(url: $0)) == nil ? nil : $0 }
                let saved = configuration[role]
                return CustomHeadersEndpointDraft(
                    id: role, url: url, headers: saved?.headers ?? [],
                    needsOriginReview: saved.map { endpoint in
                        url.map { !endpoint.applies(to: $0) } ?? true
                    } ?? false
                )
            }
        } catch {
            phase = .failed(CustomHTTPHeaderError.unreadableConfiguration.localizedDescription)
        }
    }

    var canSave: Bool { loadedConfiguration != nil && !isTesting }
    var isTesting: Bool { if case .testing = phase { true } else { false } }
    var errorMessage: String? { if case .failed(let message) = phase { message } else { nil } }

    func addHeader(to role: ActualServerEndpointRole) {
        edit(role) { $0.headers.append(.init(name: "", value: "")) }
    }

    func updateHeader(_ id: UUID, role: ActualServerEndpointRole, name: String? = nil, value: String? = nil) {
        edit(role) { draft in
            guard let index = draft.headers.firstIndex(where: { $0.id == id }) else { return }
            if let name { draft.headers[index].name = name }
            if let value { draft.headers[index].value = value }
        }
    }

    func removeHeaders(at offsets: IndexSet, role: ActualServerEndpointRole) {
        edit(role) { draft in
            draft.headers = draft.headers.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        }
    }

    func reviewOrigin(for role: ActualServerEndpointRole) {
        edit(role) { $0.needsOriginReview = false }
    }

    private func edit(_ role: ActualServerEndpointRole, change: (inout CustomHeadersEndpointDraft) -> Void) {
        guard let index = endpoints.firstIndex(where: { $0.id == role }) else { return }
        cancelTesting()
        change(&endpoints[index])
        phase = .editing
    }

    func cancelTesting() {
        generation &+= 1
        testTask?.cancel()
        testTask = nil
        if isTesting { phase = .editing }
    }

    private func validated(_ endpoint: CustomHeadersEndpointDraft) throws -> EndpointCustomHTTPHeaders? {
        guard !endpoint.headers.isEmpty else { return nil }
        guard !endpoint.needsOriginReview else { throw DraftError.reviewOrigin }
        guard let url = endpoint.url else { throw ActualAPIError.invalidURL }
        if ActualServerConnectionSecurity.blockedMessage(for: url.absoluteString) != nil {
            throw DraftError.remoteHTTP
        }
        return try EndpointCustomHTTPHeaders(url: url, headers: endpoint.headers)
    }

    func save() -> Bool {
        guard canSave else { return false }
        do {
            // Detect an erase or another editor's Save rather than restoring an
            // obsolete draft over the new persisted state.
            guard try store.keychain.readCustomHTTPHeaders() == loadedConfiguration else { throw DraftError.changed }
            var configuration = CustomHTTPHeaderConfiguration()
            for endpoint in endpoints { configuration[endpoint.id] = try validated(endpoint) }
            try store.saveCustomHTTPHeaders(configuration)
            loadedConfiguration = configuration
            phase = .saved
            return true
        } catch {
            phase = .failed(safeMessage(error))
            return false
        }
    }

    @discardableResult
    func testConnection(for role: ActualServerEndpointRole) -> Task<Void, Never>? {
        guard let endpoint = endpoints.first(where: { $0.id == role }) else { return nil }
        cancelTesting()
        do {
            _ = try validated(endpoint)
            guard let url = endpoint.url else { throw ActualAPIError.invalidURL }
            let attempt = generation
            phase = .testing(role)
            testTask = Task { [weak self, verifier] in
                do {
                    let result = try await verifier.verify(url: url, headers: endpoint.headers)
                    guard let self, self.generation == attempt, !Task.isCancelled else { return }
                    self.phase = .result(role, result)
                    self.testTask = nil
                } catch {
                    guard let self, self.generation == attempt, !Task.isCancelled else { return }
                    self.phase = .failed(self.safeMessage(error))
                    self.testTask = nil
                }
            }
        } catch {
            phase = .failed(safeMessage(error))
        }
        return testTask
    }

    private func safeMessage(_ error: Error) -> String {
        if let error = error as? CustomHTTPHeaderError { return error.localizedDescription }
        if let error = error as? DraftError { return error.localizedDescription }
        if let error = error as? ActualAPIError {
            switch error {
            case .serverRejected, .unsupportedAuthenticationMethod: return "The server rejected the connection test."
            default: return error.localizedDescription
            }
        }
        return "Custom headers could not be saved or tested. Please try again."
    }

    private enum DraftError: LocalizedError {
        case reviewOrigin, remoteHTTP, changed
        var errorDescription: String? {
            switch self {
            case .reviewOrigin: "The server address changed. Review the saved headers before using them for this server."
            case .remoteHTTP: ActualServerConnectionSecurity.remoteHTTPBlockedMessage
            case .changed: "Saved headers changed while this editor was open. Reopen Custom Headers before saving."
            }
        }
    }
}
