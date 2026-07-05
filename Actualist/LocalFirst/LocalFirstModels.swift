import Foundation

enum LocalFirstError: LocalizedError, Equatable {
    case missingServerURL
    case missingPassword
    case missingSyncToken
    case missingBudgetFileID
    case unsupportedWrite
    case encryptedBudgetRequiresPassword
    case missingImportedDatabase
    case invalidDownloadedBudget
    case invalidLocalWrite(String)
    case budgetNotOpened

    var errorDescription: String? {
        switch self {
        case .missingServerURL:
            "Enter an Actual server URL."
        case .missingPassword:
            "Enter your Actual server password."
        case .missingSyncToken:
            "Sign in to the Actual server before loading budgets."
        case .missingBudgetFileID:
            "The selected Actual budget does not include a file ID."
        case .unsupportedWrite:
            "Local-first mode is read-only in this proof."
        case .encryptedBudgetRequiresPassword:
            "This encrypted budget needs an encryption password before Actualist can open it."
        case .missingImportedDatabase:
            "Actualist could not find db.sqlite in the imported budget."
        case .invalidDownloadedBudget:
            "The downloaded budget file could not be imported."
        case .invalidLocalWrite(let reason):
            "Actualist could not apply the local-first write: \(reason)"
        case .budgetNotOpened:
            "Open a local-first budget before loading this screen."
        }
    }
}

struct LocalFirstSyncStatus: Equatable, Sendable {
    var fileID: String
    var groupID: String?
    var lastSyncedAt: Date?
    var lastAppliedMessageCount: Int
    var lastError: String?

    init(
        fileID: String,
        groupID: String?,
        lastSyncedAt: Date? = nil,
        lastAppliedMessageCount: Int = 0,
        lastError: String? = nil
    ) {
        self.fileID = fileID
        self.groupID = groupID
        self.lastSyncedAt = lastSyncedAt
        self.lastAppliedMessageCount = lastAppliedMessageCount
        self.lastError = lastError
    }
}

struct LocalFirstBudgetMetadata: Codable, Equatable, Sendable {
    let localBudgetID: String
    let cloudFileID: String
    let groupID: String?
    let budgetName: String
    let encryptionKeyID: String?
    let nodeID: String

    enum CodingKeys: String, CodingKey {
        case localBudgetID, budgetName, encryptionKeyID, nodeID
        case cloudFileID = "cloudFileId"
        case groupID = "groupId"
    }
}

struct ActualSyncRemoteFile: Decodable, Identifiable, Hashable, Sendable {
    let fileID: String
    let groupID: String?
    let name: String
    let deleted: Bool
    let encryptKeyID: String?
    let requiresEncryptionPassword: Bool

    var id: String { fileID }

    var syncEncryptionKeyID: String? {
        requiresEncryptionPassword ? encryptKeyID : nil
    }

    enum CodingKeys: String, CodingKey {
        case id
        case fileID = "fileId"
        case cloudFileID = "cloudFileId"
        case groupID = "groupId"
        case name
        case deleted
        case tombstone
        case encryptKeyID = "encryptKeyId"
        case encryptionKeyID = "encryptionKeyId"
        case encryptMeta
    }

    private enum EncryptMetaCodingKeys: String, CodingKey {
        case keyID = "keyId"
    }

    init(
        fileID: String,
        groupID: String?,
        name: String,
        deleted: Bool = false,
        encryptKeyID: String? = nil,
        requiresEncryptionPassword: Bool = false
    ) {
        self.fileID = fileID
        self.groupID = groupID
        self.name = name
        self.deleted = deleted
        self.encryptKeyID = encryptKeyID
        self.requiresEncryptionPassword = requiresEncryptionPassword
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileID = try container.decodeFirstString(for: [.fileID, .cloudFileID, .id])
        groupID = try container.decodeFirstPresentString(for: [.groupID])
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? fileID
        deleted = try container.decodeFlexibleBoolIfPresent(for: .deleted)
            ?? container.decodeFlexibleBoolIfPresent(for: .tombstone)
            ?? false
        let hasEncryptMeta = container.contains(.encryptMeta)
            ? !(try container.decodeNil(forKey: .encryptMeta))
            : false
        if let topLevelKeyID = try container.decodeFirstPresentString(for: [.encryptKeyID, .encryptionKeyID]) {
            encryptKeyID = topLevelKeyID
        } else if hasEncryptMeta,
                  let encryptMeta = try? container.nestedContainer(
                      keyedBy: EncryptMetaCodingKeys.self,
                      forKey: .encryptMeta
                  ) {
            encryptKeyID = try encryptMeta.decodeIfPresent(String.self, forKey: .keyID)
        } else {
            encryptKeyID = nil
        }
        requiresEncryptionPassword = hasEncryptMeta
    }

    var actualBudget: ActualBudget {
        ActualBudget(
            budgetID: fileID,
            cloudFileId: fileID,
            groupId: groupID,
            name: name,
            state: deleted ? "deleted" : nil
        )
    }
}

struct ActualLoginMethodsResponse: Decodable, Hashable, Sendable {
    let methods: [String]

    enum CodingKeys: String, CodingKey {
        case methods
        case data
        case loginMethod = "loginMethod"
        case method
    }

    private struct LoginMethod: Decodable, Hashable, Sendable {
        let method: String
        let active: Bool?

        enum CodingKeys: String, CodingKey {
            case method
            case active
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            method = try container.decode(String.self, forKey: .method)
            active = try container.decodeFlexibleBoolIfPresent(for: .active)
        }
    }

    enum DataCodingKeys: String, CodingKey {
        case methods
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let methods = try? container.decodeIfPresent([String].self, forKey: .methods) {
            self.methods = methods
        } else if let methods = try? container.decodeIfPresent([LoginMethod].self, forKey: .methods) {
            self.methods = methods
                .filter { $0.active ?? true }
                .map(\.method)
        } else if let method = try container.decodeIfPresent(String.self, forKey: .loginMethod)
            ?? container.decodeIfPresent(String.self, forKey: .method) {
            self.methods = [method]
        } else if let data = try? container.nestedContainer(keyedBy: DataCodingKeys.self, forKey: .data) {
            if let methods = try? data.decodeIfPresent([String].self, forKey: .methods) {
                self.methods = methods
            } else if let methods = try? data.decodeIfPresent([LoginMethod].self, forKey: .methods) {
                self.methods = methods
                    .filter { $0.active ?? true }
                    .map(\.method)
            } else {
                self.methods = []
            }
        } else {
            self.methods = []
        }
    }
}

struct ActualLoginResponse: Decodable, Hashable, Sendable {
    let token: String

    enum CodingKeys: String, CodingKey {
        case token
        case data
    }

    enum DataCodingKeys: String, CodingKey {
        case token
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let token = try container.decodeIfPresent(String.self, forKey: .token) {
            self.token = token
            return
        }

        let data = try container.nestedContainer(keyedBy: DataCodingKeys.self, forKey: .data)
        token = try data.decode(String.self, forKey: .token)
    }
}

struct ActualUserFilesResponse: Decodable, Hashable, Sendable {
    let groupID: String?
    let files: [ActualSyncRemoteFile]

    enum CodingKeys: String, CodingKey {
        case groupID = "groupId"
        case files
        case data
    }

    enum DataCodingKeys: String, CodingKey {
        case groupID = "groupId"
        case files
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let files = try container.decodeIfPresent([ActualSyncRemoteFile].self, forKey: .files) {
            self.groupID = try container.decodeIfPresent(String.self, forKey: .groupID)
            self.files = files
            return
        }
        if let files = try container.decodeIfPresent([ActualSyncRemoteFile].self, forKey: .data) {
            groupID = try container.decodeIfPresent(String.self, forKey: .groupID)
            self.files = files
            return
        }

        let data = try container.nestedContainer(keyedBy: DataCodingKeys.self, forKey: .data)
        groupID = try data.decodeIfPresent(String.self, forKey: .groupID)
        files = try data.decodeIfPresent([ActualSyncRemoteFile].self, forKey: .files) ?? []
    }
}

struct ActualUserFileInfoResponse: Decodable, Hashable, Sendable {
    let file: ActualSyncRemoteFile?

    enum CodingKeys: String, CodingKey {
        case data
        case file
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let file = try container.decodeIfPresent(ActualSyncRemoteFile.self, forKey: .data) {
            self.file = file
        } else {
            self.file = try container.decodeIfPresent(ActualSyncRemoteFile.self, forKey: .file)
        }
    }
}

extension ActualBudget {
    var localFirstFileID: String? {
        cloudFileId ?? budgetID
    }
}

extension ActualTransaction {
    /// Returns a copy with split children attached (parent rows are otherwise immutable).
    func replacingSubtransactions(_ subtransactions: [ActualTransaction]) -> ActualTransaction {
        ActualTransaction(
            id: id,
            account: account,
            date: date,
            amount: amount,
            payee: payee,
            payeeName: payeeName,
            importedPayee: importedPayee,
            category: category,
            notes: notes,
            cleared: cleared,
            subtransactions: subtransactions,
            isParent: isParent,
            isChild: isChild,
            parentID: parentID
        )
    }
}

extension KeyedDecodingContainer {
    func decodeFirstString(for keys: [Key]) throws -> String {
        for key in keys {
            if let value = try decodeIfPresent(String.self, forKey: key), !value.isEmpty {
                return value
            }
        }
        throw DecodingError.keyNotFound(
            keys.first!,
            DecodingError.Context(codingPath: codingPath, debugDescription: "No string found for keys \(keys)")
        )
    }

    func decodeFirstPresentString(for keys: [Key]) throws -> String? {
        for key in keys {
            if let value = try decodeIfPresent(String.self, forKey: key), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    func decodeFlexibleBoolIfPresent(for key: Key) throws -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return ["1", "true", "yes", "deleted"].contains(value.lowercased())
        }
        return nil
    }
}
