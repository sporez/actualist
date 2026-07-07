import CommonCrypto
import CryptoKit
import Foundation
import Security

struct ActualBudgetEncryptionContext: Equatable, Sendable {
    let keyID: String
    let keyData: Data
}

struct ActualEncryptedData: Equatable, Sendable {
    let data: Data
    let iv: Data
    let authTag: Data
}

enum ActualBudgetCrypto {
    static let algorithm = "aes-256-gcm"
    private static let keyByteCount = 32
    private static let nonceByteCount = 12
    private static let authTagByteCount = 16
    // Actual's sync protocol derives budget keys with 10k PBKDF2-HMAC-SHA512 rounds.
    // Do not raise this locally unless upstream changes the wire-compatible derivation.
    private static let iterations = 10_000

    static func deriveKey(password: String, salt: String) throws -> Data {
        guard let passwordData = password.data(using: .utf8),
              let saltData = salt.data(using: .utf8) else {
            throw LocalFirstError.invalidEncryptionKey
        }

        var key = Data(count: keyByteCount)
        let status = key.withUnsafeMutableBytes { keyBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                saltData.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        saltData.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        UInt32(iterations),
                        keyBytes.bindMemory(to: UInt8.self).baseAddress,
                        keyByteCount
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw LocalFirstError.invalidEncryptionKey
        }
        return key
    }

    static func decrypt(_ encrypted: ActualEncryptedData, keyData: Data) throws -> Data {
        guard encrypted.iv.count == nonceByteCount,
              encrypted.authTag.count == authTagByteCount,
              keyData.count == keyByteCount else {
            throw LocalFirstError.invalidEncryptedPayload
        }

        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: encrypted.iv),
                ciphertext: encrypted.data,
                tag: encrypted.authTag
            )
            return try Data(AES.GCM.open(sealedBox, using: SymmetricKey(data: keyData)))
        } catch {
            throw LocalFirstError.invalidEncryptionPassword
        }
    }

    static func encrypt(_ data: Data, context: ActualBudgetEncryptionContext) throws -> ActualEncryptedData {
        guard context.keyData.count == keyByteCount else {
            throw LocalFirstError.invalidEncryptionKey
        }

        var iv = Data(count: nonceByteCount)
        let status = iv.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, nonceByteCount, bytes.bindMemory(to: UInt8.self).baseAddress!)
        }
        guard status == errSecSuccess else {
            throw LocalFirstError.invalidEncryptionKey
        }

        do {
            let sealedBox = try AES.GCM.seal(
                data,
                using: SymmetricKey(data: context.keyData),
                nonce: AES.GCM.Nonce(data: iv)
            )
            return ActualEncryptedData(
                data: sealedBox.ciphertext,
                iv: iv,
                authTag: sealedBox.tag
            )
        } catch {
            throw LocalFirstError.invalidEncryptedPayload
        }
    }

    static func validateUserKeyResponse(
        _ response: ActualUserKeyResponse,
        password: String
    ) throws -> ActualBudgetEncryptionContext {
        guard let test = response.test else {
            throw LocalFirstError.invalidEncryptionKey
        }
        let keyData = try deriveKey(password: password, salt: response.salt)
        let testPayload = try JSONDecoder.actual.decode(
            ActualUserKeyResponse.TestPayload.self,
            from: Data(test.utf8)
        )
        guard testPayload.meta.algorithm == algorithm else {
            throw LocalFirstError.unsupportedEncryptionAlgorithm(testPayload.meta.algorithm ?? "")
        }
        let encrypted = try testPayload.encryptedData()
        _ = try decrypt(encrypted, keyData: keyData)
        return ActualBudgetEncryptionContext(keyID: response.id, keyData: keyData)
    }
}
