import Foundation
import Testing
@testable import Actualist

/// Registration replies are small JSON; the wire client must stop reading an
/// oversized body at the cap instead of buffering it.
struct RegistrationResponseLimitTests {
    private let chunk = 16 * 1_024

    private func makeClient(host: String) -> (ActualServerFileRegistrationClient, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = ActualServerFileRegistrationClient(
            baseURL: URL(string: "https://\(host)")!,
            customHeaders: .empty,
            session: session
        )
        return (client, session)
    }

    @Test func oversizedUploadReplyThrowsWithoutBeingBuffered() async throws {
        let host = "registration-\(UUID().uuidString.lowercased()).example"
        let chunkCount = 64 // 1 MiB, far above the 64 KiB cap
        let recorder = ChunkedStubURLProtocol.register(
            host: host,
            script: .init(chunkSize: chunk, chunkCount: chunkCount, declaresLength: false)
        )
        let (client, session) = makeClient(host: host)
        defer { session.invalidateAndCancel() }

        await #expect(throws: LocalFirstError.remoteDataLimitExceeded) {
            _ = try await client.uploadUserFile(
                fileID: "file", name: "Budget", groupID: nil,
                encryptMeta: nil, bytes: Data([1]), token: "token"
            )
        }
        await recorder.stopped.wait()
        #expect(recorder.deliveredBytes < chunkCount * chunk)
    }

    @Test func oversizedKeyReplyThrowsTheLimitErrorNotAnUnconfirmedKey() async throws {
        let host = "registration-\(UUID().uuidString.lowercased()).example"
        ChunkedStubURLProtocol.register(
            host: host,
            script: .init(chunkSize: chunk, chunkCount: 8, declaresLength: false)
        )
        let (client, session) = makeClient(host: host)
        defer { session.invalidateAndCancel() }

        await #expect(throws: LocalFirstError.remoteDataLimitExceeded) {
            try await client.createUserKey(
                fileID: "file", keyID: "key", keySalt: "salt", testContent: "x", token: "token"
            )
        }
    }

    @Test func oversizedDeleteReplyThrows() async throws {
        let host = "registration-\(UUID().uuidString.lowercased()).example"
        ChunkedStubURLProtocol.register(
            host: host,
            script: .init(chunkSize: chunk, chunkCount: 8, declaresLength: false)
        )
        let (client, session) = makeClient(host: host)
        defer { session.invalidateAndCancel() }

        await #expect(throws: LocalFirstError.remoteDataLimitExceeded) {
            try await client.deleteUserFile(fileID: "file", token: "token")
        }
    }
}
