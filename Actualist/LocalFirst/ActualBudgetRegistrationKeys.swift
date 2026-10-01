import Foundation
import Security

/// Key material for one encrypted portable-budget registration: a fresh key
/// ID and salt, the PBKDF2-derived key, the wire encrypt-meta sent as
/// `X-ACTUAL-ENCRYPT-META`, the password test content in Actual's keyMake
/// envelope, and the archive ciphertext to upload. The password is consumed
/// here and never stored or logged. Kept out of `ActualBudgetCrypto`, which
/// stays a pure primitive owner.
struct ActualBudgetRegistrationKeySet: Sendable {
    /// The key-test plaintext. The value is arbitrary; the envelope shape and
    /// the deriving key are what Actual's key-test verifies.
    static let keyTestPlaintext = "actualist-d0-key-test"

    let keyID: String
    let salt: String
    let keyData: Data
    let encryptMeta: ActualEncryptedMetadata
    let testContent: String
    let encryptedArchiveBytes: Data

    static func make(
        password: String,
        archiveBytes: Data,
        keyID: String = UUID().uuidString
    ) throws -> ActualBudgetRegistrationKeySet {
        guard !password.isEmpty else {
            throw LocalFirstError.missingPassword
        }
        let salt = try freshSalt()
        let keyData = try ActualBudgetCrypto.deriveKey(password: password, salt: salt)
        let context = ActualBudgetEncryptionContext(keyID: keyID, keyData: keyData)

        let encryptedArchive = try ActualBudgetCrypto.encrypt(archiveBytes, context: context)
        let encryptedTest = try ActualBudgetCrypto.encrypt(
            Data(keyTestPlaintext.utf8),
            context: context
        )
        let testPayload = ActualUserKeyResponse.TestPayload(
            value: encryptedTest.data.base64EncodedString(),
            meta: meta(keyID: keyID, encrypted: encryptedTest)
        )
        let testContentData = try JSONEncoder.actual.encode(testPayload)
        guard let testContent = String(data: testContentData, encoding: .utf8) else {
            throw LocalFirstError.invalidEncryptionKey
        }

        return ActualBudgetRegistrationKeySet(
            keyID: keyID,
            salt: salt,
            keyData: keyData,
            encryptMeta: meta(keyID: keyID, encrypted: encryptedArchive),
            testContent: testContent,
            encryptedArchiveBytes: encryptedArchive.data
        )
    }

    private static func meta(
        keyID: String,
        encrypted: ActualEncryptedData
    ) -> ActualEncryptedMetadata {
        ActualEncryptedMetadata(
            keyID: keyID,
            algorithm: ActualBudgetCrypto.algorithm,
            iv: encrypted.iv.base64EncodedString(),
            authTag: encrypted.authTag.base64EncodedString()
        )
    }

    /// Actual generates a 32-byte base64 salt for every registered key.
    private static func freshSalt() throws -> String {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw LocalFirstError.invalidEncryptionKey
        }
        return bytes.base64EncodedString()
    }
}
