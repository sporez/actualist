import Foundation

struct ScheduleInteropHandshake: Decodable {
    let schemaVersion: Int
    let runID: String
    let actualRevision: String
    let freezeID: String
    let scheduleID: String
    let occurrenceDayID: String
    let automaticActualistRole: String

    func validate(against configuration: LocalFirstActualStoreScheduleInteropTests.Configuration) throws {
        guard schemaVersion == 1,
              runID == configuration.runID,
              actualRevision == configuration.actualRevision,
              freezeID == configuration.freezeID,
              !scheduleID.isEmpty,
              occurrenceDayID.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              automaticActualistRole == "BLOCKED" else {
            throw InteropError.handshakeMismatch
        }
    }
}

struct ScheduleInteropFixtureHandoff: Decodable {
    let schemaVersion: Int
    let runID: String
    let actualRevision: String
    let freezeID: String
    let serverOrigin: URL
    let fileID: String
    let groupID: String
    let budgetName: String
    let fixtureArchiveSHA256: String
    let syncToken: String

    func validate(
        against configuration: LocalFirstActualStoreScheduleInteropTests.Configuration,
        handshake: ScheduleInteropHandshake
    ) throws {
        guard schemaVersion == 1,
              runID == configuration.runID,
              actualRevision == configuration.actualRevision,
              freezeID == configuration.freezeID,
              !fileID.isEmpty,
              !groupID.isEmpty,
              !budgetName.isEmpty,
              !syncToken.isEmpty,
              !handshake.scheduleID.isEmpty,
              fixtureArchiveSHA256.range(
                of: #"^[0-9a-f]{64}$"#,
                options: .regularExpression
              ) != nil else {
            throw InteropError.handshakeMismatch
        }
        _ = try LocalFirstActualStoreScheduleInteropTests.loopbackOrigin(serverOrigin.absoluteString)
    }
}

struct ScheduleInteropSwiftResult: Encodable {
    let schemaVersion: Int
    let runID: String
    let fixtureArchiveSHA256: String
    let scheduleID: String
    let transactionID: String
    let occurrenceDayID: String
    let postedDayID: String
    let appliedMessageCount: Int
}

struct ScheduleInteropControlClient {
    let origin: URL
    let runID: String

    func handshake() async throws -> ScheduleInteropHandshake {
        try await request(path: "v1/handshake", method: "GET", body: nil)
    }

    func fixtureHandoff() async throws -> ScheduleInteropFixtureHandoff {
        try await request(path: "v1/fixture-handoff", method: "GET", body: nil)
    }

    func fixtureArchive() async throws -> Data {
        try await rawRequest(path: "v1/fixture-archive", maximumBytes: 256 * 1_024 * 1_024)
    }

    func recordSwiftResult(_ result: ScheduleInteropSwiftResult) async throws {
        let body = try JSONEncoder().encode(result)
        let acknowledgement: ScheduleInteropAcknowledgement = try await request(
            path: "v1/swift-result",
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        guard acknowledgement.accepted else { throw InteropError.controlRejected }
    }

    private func request<Value: Decodable>(
        path: String,
        method: String,
        body: Data?,
        contentType: String? = nil
    ) async throws -> Value {
        let data = try await data(path: path, method: method, body: body, contentType: contentType)
        guard data.count <= 1_048_576 else { throw InteropError.controlRejected }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private func rawRequest(path: String, maximumBytes: Int) async throws -> Data {
        let data = try await data(path: path, method: "GET", body: nil, contentType: nil)
        guard data.count <= maximumBytes else { throw InteropError.controlRejected }
        return data
    }

    private func data(
        path: String,
        method: String,
        body: Data?,
        contentType: String?
    ) async throws -> Data {
        var request = URLRequest(url: origin.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 120
        request.httpBody = body
        request.setValue(runID, forHTTPHeaderField: "X-Schedule-Interop-Run-ID")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw InteropError.controlRejected
        }
        return data
    }
}

private struct ScheduleInteropAcknowledgement: Decodable {
    let accepted: Bool
}

enum InteropError: Error {
    case missingConfiguration(String)
    case invalidConfiguration(String)
    case sourceMismatch(String)
    case handshakeMismatch
    case controlRejected
}
