import Foundation
import Testing
@testable import Actualist

/// Wire-level coverage for the portable ZIP registration client: upload and
/// key-creation request shape (headers, bodies, status handling). Each test
/// owns its own StubHTTPEndpoint, so nothing is shared between tests. No server
/// is contacted.
@Suite(.serialized)
struct PortableBudgetRegistrationWireTests {
    private let endpoint = StubHTTPEndpoint()
    private let fileID = "file-1"
    private let keyID = "key-1"

    private func encryptedMeta() -> ActualEncryptedMetadata {
        ActualEncryptedMetadata(
            keyID: keyID,
            algorithm: "aes-256-gcm",
            iv: "aXY=",
            authTag: "dGFn"
        )
    }

    private func makeWireClient(statusCode: Int, body: String) -> ActualServerFileRegistrationClient {
        endpoint.respond(statusCode: statusCode, body: body)
        return ActualServerFileRegistrationClient(
            baseURL: URL(string: "https://registration.example")!,
            customHeaders: .empty,
            session: endpoint.makeSession()
        )
    }

    @Test func uploadRequestCarriesOracleHeadersAndBody() async throws {
        let client = makeWireClient(
            statusCode: 200,
            body: #"{"status":"ok","groupId":"group-1"}"#
        )
        let bytes = Data([0x0a, 0x0b, 0x0c])

        let response = try await client.uploadUserFile(
            fileID: fileID,
            name: "My Budget (2026) &/ Straße",
            groupID: "group-9",
            encryptMeta: encryptedMeta(),
            bytes: bytes,
            token: "tok"
        )

        #expect(response.groupID == "group-1")
        let request = try #require(endpoint.lastRequest)
        #expect(request.url?.absoluteString == "https://registration.example/sync/upload-user-file")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-ACTUAL-TOKEN") == "tok")
        #expect(request.value(forHTTPHeaderField: "X-ACTUAL-FILE-ID") == fileID)
        // JavaScript encodeURIComponent parity, as Actual decodes the header
        // with decodeURIComponent server-side.
        #expect(request.value(forHTTPHeaderField: "X-ACTUAL-NAME") == "My%20Budget%20(2026)%20%26%2F%20Stra%C3%9Fe")
        #expect(request.value(forHTTPHeaderField: "X-ACTUAL-FORMAT") == "2")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/encrypted-file")
        #expect(request.value(forHTTPHeaderField: "X-ACTUAL-GROUP-ID") == "group-9")
        let metaHeader = try #require(request.value(forHTTPHeaderField: "X-ACTUAL-ENCRYPT-META"))
        let decodedMeta = try JSONDecoder().decode(ActualEncryptedMetadata.self, from: Data(metaHeader.utf8))
        #expect(decodedMeta == encryptedMeta())
        #expect(endpoint.lastRequestBody == bytes)
    }

    @Test func uploadOmitsOptionalHeadersWhenAbsent() async throws {
        let client = makeWireClient(statusCode: 200, body: #"{"status":"ok"}"#)

        let response = try await client.uploadUserFile(
            fileID: fileID, name: "Budget", groupID: nil,
            encryptMeta: nil, bytes: Data([0x01]), token: "tok"
        )

        #expect(response.groupID == nil)
        let request = try #require(endpoint.lastRequest)
        #expect(request.value(forHTTPHeaderField: "X-ACTUAL-GROUP-ID") == nil)
        #expect(request.value(forHTTPHeaderField: "X-ACTUAL-ENCRYPT-META") == nil)
    }

    @Test func unreadableUploadBodyStillSucceedsWithoutGroup() async throws {
        let client = makeWireClient(statusCode: 200, body: "not-json")

        let response = try await client.uploadUserFile(
            fileID: fileID, name: "Budget", groupID: nil,
            encryptMeta: nil, bytes: Data([0x01]), token: "tok"
        )

        #expect(response.groupID == nil)
    }

    @Test func uploadMapsFileHasResetRejection() async throws {
        let client = makeWireClient(statusCode: 400, body: "file-has-reset")

        do {
            _ = try await client.uploadUserFile(
                fileID: fileID, name: "Budget", groupID: nil,
                encryptMeta: nil, bytes: Data([0x01]), token: "tok"
            )
            Issue.record("Expected a file-has-reset rejection")
        } catch let error as ActualAPIError {
            guard case .syncRejected(let status, let reason) = error else {
                Issue.record("Unexpected ActualAPIError: \(error)")
                return
            }
            #expect(status == 400)
            #expect(reason == .fileHasReset)
        }
    }

    @Test func createKeySendsJSONPayloadAndRequiresOKStatus() async throws {
        let client = makeWireClient(statusCode: 200, body: #"{"status":"ok"}"#)

        try await client.createUserKey(
            fileID: fileID, keyID: keyID, keySalt: "salt",
            testContent: "test-content", token: "tok"
        )

        let request = try #require(endpoint.lastRequest)
        #expect(request.url?.absoluteString == "https://registration.example/sync/user-create-key")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-ACTUAL-TOKEN") == "tok")
        let body = try #require(endpoint.lastRequestBody)
        let payload = try JSONDecoder().decode(ActualUserCreateKeyPayload.self, from: body)
        #expect(payload == ActualUserCreateKeyPayload(
            fileId: fileID, keyId: keyID, keySalt: "salt", testContent: "test-content"
        ))
    }

    @Test func deleteUserFileSendsFileIDBodyWithTokenHeader() async throws {
        let client = makeWireClient(statusCode: 200, body: #"{"status":"ok"}"#)
        try await client.deleteUserFile(fileID: fileID, token: "tok")
        let request = try #require(endpoint.lastRequest)
        #expect(request.url?.absoluteString == "https://registration.example/sync/delete-user-file")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-ACTUAL-TOKEN") == "tok")
        let body = try #require(endpoint.lastRequestBody)
        #expect(try JSONDecoder().decode(ActualDeleteUserFilePayload.self, from: body).fileId == fileID)
    }

    @Test func createKeyRefusesNonOKStatus() async throws {
        let client = makeWireClient(statusCode: 200, body: #"{"status":"error"}"#)

        await #expect(throws: ActualFileRegistrationError.keyRegistrationNotConfirmed) {
            try await client.createUserKey(
                fileID: fileID, keyID: keyID, keySalt: "salt",
                testContent: "test-content", token: "tok"
            )
        }
    }

    @Test func createKeySurfacesHTTPRejectionForUnknownFile() async throws {
        let client = makeWireClient(statusCode: 400, body: "file-not-found")

        do {
            try await client.createUserKey(
                fileID: fileID, keyID: keyID, keySalt: "salt",
                testContent: "test-content", token: "tok"
            )
            Issue.record("Expected an HTTP rejection")
        } catch let error as ActualAPIError {
            guard case .httpStatus(let status) = error else {
                Issue.record("Unexpected ActualAPIError: \(error)")
                return
            }
            #expect(status == 400)
        }
    }
}
