import Foundation

struct ActualSyncRemoteFile: Decodable, Identifiable, Hashable, Sendable {
    let fileID: String
    let groupID: String?
    let name: String
    let deleted: Bool
    let encryptKeyID: String?
    let encryptMeta: ActualEncryptedMetadata?
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

    init(
        fileID: String,
        groupID: String?,
        name: String,
        deleted: Bool = false,
        encryptKeyID: String? = nil,
        encryptMeta: ActualEncryptedMetadata? = nil,
        requiresEncryptionPassword: Bool = false
    ) {
        self.fileID = fileID
        self.groupID = groupID
        self.name = name
        self.deleted = deleted
        self.encryptKeyID = encryptKeyID
        self.encryptMeta = encryptMeta
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
        let decodedEncryptMeta = try container.decodeIfPresent(ActualEncryptedMetadata.self, forKey: .encryptMeta)
        let hasEncryptMeta = decodedEncryptMeta != nil
        if let topLevelKeyID = try container.decodeFirstPresentString(for: [.encryptKeyID, .encryptionKeyID]) {
            encryptKeyID = topLevelKeyID
        } else if let decodedEncryptMeta {
            encryptKeyID = decodedEncryptMeta.keyID
        } else {
            encryptKeyID = nil
        }
        encryptMeta = decodedEncryptMeta
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

struct ActualEncryptedMetadata: Codable, Hashable, Sendable {
    let keyID: String
    let algorithm: String?
    let iv: String?
    let authTag: String?

    enum CodingKeys: String, CodingKey {
        case keyID = "keyId"
        case algorithm, iv, authTag
    }

    func encryptedData(_ data: Data) throws -> ActualEncryptedData {
        guard let algorithm, algorithm == ActualBudgetCrypto.algorithm else {
            throw LocalFirstError.unsupportedEncryptionAlgorithm(algorithm ?? "")
        }
        guard let iv,
              let authTag,
              let ivData = Data(base64Encoded: iv),
              let authTagData = Data(base64Encoded: authTag) else {
            throw LocalFirstError.invalidEncryptedPayload
        }
        return ActualEncryptedData(data: data, iv: ivData, authTag: authTagData)
    }
}

enum ActualAuthenticationMethod: Hashable, Sendable {
    case password
    case openID
    case header
    case unsupported(String)

    init(identifier: String) {
        switch identifier.lowercased() {
        case "password":
            self = .password
        case "openid":
            self = .openID
        case "header":
            self = .header
        default:
            self = .unsupported(identifier)
        }
    }

    var identifier: String {
        switch self {
        case .password:
            "password"
        case .openID:
            "openid"
        case .header:
            "header"
        case .unsupported(let identifier):
            identifier
        }
    }
}

struct ActualLoginMethod: Decodable, Hashable, Sendable {
    let identifier: String
    let displayName: String?
    let isActive: Bool

    var authenticationMethod: ActualAuthenticationMethod {
        ActualAuthenticationMethod(identifier: identifier)
    }

    init(identifier: String, displayName: String? = nil, isActive: Bool = true) {
        self.identifier = identifier
        self.displayName = displayName
        self.isActive = isActive
    }

    enum CodingKeys: String, CodingKey {
        case method
        case displayName
        case active
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let identifier = try? container.decode(String.self) {
            self.init(identifier: identifier)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let identifier = try container.decode(String.self, forKey: .method)
        let displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        let isActive = try container.decodeFlexibleBoolIfPresent(for: .active) ?? true
        self.init(identifier: identifier, displayName: displayName, isActive: isActive)
    }
}

struct ActualLoginMethodsResponse: Decodable, Hashable, Sendable {
    let loginMethods: [ActualLoginMethod]

    var methods: [String] {
        loginMethods.filter(\.isActive).map(\.identifier)
    }

    // Actual may advertise usable fallback methods as inactive rows.
    var availableLoginMethods: [ActualLoginMethod] {
        loginMethods
    }

    enum CodingKeys: String, CodingKey {
        case methods
        case data
        case loginMethod = "loginMethod"
        case method
    }

    enum DataCodingKeys: String, CodingKey {
        case methods
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.methods) {
            loginMethods = Self.decodeMethods(from: try container.superDecoder(forKey: .methods))
        } else if let method = try container.decodeIfPresent(String.self, forKey: .loginMethod)
            ?? container.decodeIfPresent(String.self, forKey: .method) {
            loginMethods = [ActualLoginMethod(identifier: method)]
        } else if let data = try? container.nestedContainer(keyedBy: DataCodingKeys.self, forKey: .data) {
            if data.contains(.methods) {
                loginMethods = Self.decodeMethods(from: try data.superDecoder(forKey: .methods))
            } else {
                loginMethods = []
            }
        } else {
            loginMethods = []
        }
    }

    private static func decodeMethods(from decoder: Decoder) -> [ActualLoginMethod] {
        guard var container = try? decoder.unkeyedContainer() else {
            return []
        }

        var methods: [ActualLoginMethod] = []
        while !container.isAtEnd {
            guard let itemDecoder = try? container.superDecoder() else {
                continue
            }
            if let method = try? ActualLoginMethod(from: itemDecoder) {
                methods.append(method)
            }
        }
        return methods
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

struct ActualOpenIDStartResponse: Decodable, Hashable, Sendable {
    let returnURL: URL

    enum CodingKeys: String, CodingKey {
        case returnURL = "returnUrl"
        case data
    }

    enum DataCodingKeys: String, CodingKey {
        case returnURL = "returnUrl"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let returnURL = try container.decodeIfPresent(URL.self, forKey: .returnURL) {
            self.returnURL = returnURL
            return
        }

        let data = try container.nestedContainer(keyedBy: DataCodingKeys.self, forKey: .data)
        returnURL = try data.decode(URL.self, forKey: .returnURL)
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

struct ActualUserKeyResponse: Decodable, Hashable, Sendable {
    let id: String
    let salt: String
    let test: String?

    enum CodingKeys: String, CodingKey {
        case id, keyID = "keyId", salt, test, data
    }

    enum DataCodingKeys: String, CodingKey {
        case id, keyID = "keyId", salt, test
    }

    struct TestPayload: Codable, Hashable, Sendable {
        let value: String
        let meta: ActualEncryptedMetadata

        func encryptedData() throws -> ActualEncryptedData {
            guard let data = Data(base64Encoded: value) else {
                throw LocalFirstError.invalidEncryptedPayload
            }
            return try meta.encryptedData(data)
        }
    }

    init(id: String, salt: String, test: String?) {
        self.id = id
        self.salt = salt
        self.test = test
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? container.decodeIfPresent(String.self, forKey: .keyID),
           let salt = try container.decodeIfPresent(String.self, forKey: .salt) {
            self.id = id
            self.salt = salt
            self.test = try container.decodeIfPresent(String.self, forKey: .test)
            return
        }

        let data = try container.nestedContainer(keyedBy: DataCodingKeys.self, forKey: .data)
        id = try data.decodeIfPresent(String.self, forKey: .id)
            ?? data.decode(String.self, forKey: .keyID)
        salt = try data.decode(String.self, forKey: .salt)
        test = try data.decodeIfPresent(String.self, forKey: .test)
    }
}

extension ActualBudget {
    var localFirstFileID: String? {
        cloudFileId ?? budgetID
    }
}

extension ActualTransaction {
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
            reconciled: reconciled,
            subtransactions: subtransactions,
            isParent: isParent,
            isChild: isChild,
            parentID: parentID,
            schedule: schedule,
            error: error
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
