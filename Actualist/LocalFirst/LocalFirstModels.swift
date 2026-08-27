import Foundation

enum LocalFirstRecoveryGuidance {
    static let encryptionPasswordNotice = """
        This encryption password cannot be recovered by Actualist. Store it securely somewhere \
        you can access if this iPhone is lost or replaced. Actualist stores only the unlocked \
        budget key on this device, not the password. Neither is included in device backups.
        """
}

enum LocalFirstError: LocalizedError, Equatable {
    case missingServerURL
    case missingPassword
    case missingSyncToken
    case missingBudgetFileID
    case noBudgetsAvailable
    case selectedBudgetUnavailable
    case invalidBudgetFileID
    case numericValueOutOfRange
    case unsupportedWrite
    case unsupportedTransferWrite
    case unsupportedSplitWrite
    case encryptedBudgetRequiresPassword
    case invalidEncryptionPassword
    case invalidEncryptionKey
    case invalidEncryptedPayload
    case unsupportedEncryptionAlgorithm(String)
    case missingImportedDatabase
    case invalidDownloadedBudget
    case localBudgetHardeningFailed
    case remoteDataLimitExceeded
    case insufficientStorage
    case invalidLocalWrite(String)
    case budgetNotOpened
    case unsupportedTemplate(String)
    case keychainFailure(String, OSStatus)
    case hybridLogicalClockOverflow
    case localWriteSuperseded
    case syncUploadNotConfirmed(Int)
    case unauthenticatedPlaintextEnvelope

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
        case .noBudgetsAvailable:
            "This Actual server has no budgets available."
        case .selectedBudgetUnavailable:
            "The selected budget is not available on this Actual server."
        case .invalidBudgetFileID:
            "The Actual budget file ID is not safe to use."
        case .numericValueOutOfRange:
            "Actualist found a numeric value outside the supported range."
        case .unsupportedWrite:
            "This local-first write is not available yet."
        case .unsupportedTransferWrite:
            "This transfer write is not available."
        case .unsupportedSplitWrite:
            "This split transaction write is not available."
        case .encryptedBudgetRequiresPassword:
            "This encrypted budget needs an encryption password before Actualist can open it."
        case .invalidEncryptionPassword:
            "The encryption password could not unlock this budget."
        case .invalidEncryptionKey:
            "Actualist could not load this budget's encryption key."
        case .invalidEncryptedPayload:
            "Actualist could not read encrypted budget data from the server."
        case .unsupportedEncryptionAlgorithm(let algorithm):
            "Actualist does not support this budget encryption algorithm: \(algorithm)."
        case .missingImportedDatabase:
            "Actualist could not find db.sqlite in the imported budget."
        case .invalidDownloadedBudget:
            "The downloaded budget file could not be imported."
        case .localBudgetHardeningFailed:
            "Actualist could not secure the local budget files."
        case .remoteDataLimitExceeded:
            "The server response exceeded Actualist's safe resource limits."
        case .insufficientStorage:
            "This device does not have enough free storage to import the budget safely."
        case .invalidLocalWrite(let reason):
            "Actualist could not apply the local-first write: \(reason)"
        case .budgetNotOpened:
            "Open a local-first budget before loading this screen."
        case .unsupportedTemplate(let reason):
            "This budget template can't be applied locally yet: \(reason)"
        case .keychainFailure(let operation, let status):
            "Actualist could not \(operation) Keychain data. OSStatus: \(status)"
        case .hybridLogicalClockOverflow:
            "Actualist could not create a local sync timestamp because the clock counter overflowed."
        case .localWriteSuperseded:
            "Actualist did not save the change because a newer local value already exists."
        case .syncUploadNotConfirmed(let count):
            "The Actual server did not confirm \(count) uploaded sync message\(count == 1 ? "" : "s"). The changes remain pending on this device."
        case .unauthenticatedPlaintextEnvelope:
            "The Actual server returned unauthenticated plaintext data for an encrypted budget."
        }
    }
}

// A goal_def entry from Actual's template JSON.
struct BudgetTemplateEntry: Decodable, Equatable, Sendable {
    let type: String
    let directive: String?
    let priority: Int?
    let monthly: Double?
    let amount: Double?
    let percentage: Double?
    let period: BudgetTemplatePeriod?
    let starting: String?
    let lookBack: Int?
    let limit: BudgetTemplateLimit?
    let standaloneLimit: BudgetTemplateLimit?
    let month: String?
    let annual: Bool?
    let repeatInterval: Int?
    let weight: Double?

    // `goal` entries are display-only; `template` entries change the budget.
    var setsBudget: Bool { (directive ?? "template") == "template" }

    private enum CodingKeys: String, CodingKey {
        case type
        case directive
        case priority
        case monthly
        case amount
        case percentage
        case period
        case starting
        case lookBack
        case limit
        case hold
        case start
        case month
        case annual
        case repeatInterval = "repeat"
        case weight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        directive = try container.decodeIfPresent(String.self, forKey: .directive)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority)
        monthly = try container.decodeIfPresent(Double.self, forKey: .monthly)
        amount = try container.decodeIfPresent(Double.self, forKey: .amount)
        percentage = try container.decodeIfPresent(Double.self, forKey: .percentage)
        starting = try container.decodeIfPresent(String.self, forKey: .starting)
        lookBack = try container.decodeIfPresent(Int.self, forKey: .lookBack)
        limit = try container.decodeIfPresent(BudgetTemplateLimit.self, forKey: .limit)
        month = try container.decodeIfPresent(String.self, forKey: .month)
        annual = try container.decodeIfPresent(Bool.self, forKey: .annual)
        repeatInterval = try container.decodeIfPresent(Int.self, forKey: .repeatInterval)
        weight = try container.decodeIfPresent(Double.self, forKey: .weight)

        if type == "limit" {
            period = nil
            standaloneLimit = BudgetTemplateLimit(
                amount: amount,
                period: try container.decodeIfPresent(String.self, forKey: .period),
                hold: try container.decodeIfPresent(Bool.self, forKey: .hold),
                start: try container.decodeIfPresent(String.self, forKey: .start)
            )
        } else {
            period = try container.decodeIfPresent(BudgetTemplatePeriod.self, forKey: .period)
            standaloneLimit = nil
        }
    }
}

struct BudgetTemplatePeriod: Decodable, Equatable, Sendable {
    let amount: Int?
    let period: String?
}

struct BudgetTemplateLimit: Decodable, Equatable, Sendable {
    let amount: Double?
    let period: String?
    let hold: Bool?
    let start: String?
}

struct LocalFirstSyncStatus: Equatable, Sendable {
    var fileID: String
    var groupID: String?
    var lastSyncedAt: Date?
    var lastAppliedMessageCount: Int
    var lastUploadedMessageCount: Int
    var lastSyncAttemptAt: Date?
    var lastError: String?
    var encryptionKeyID: String?
    var pendingLocalMessageCount: Int
    /// `true` when the most recent successful sync reached the server through
    /// the fallback endpoint. Reflects the last successful sync only; failed
    /// attempts do not change it.
    var lastSyncUsedFallback: Bool = false

    init(
        fileID: String,
        groupID: String?,
        lastSyncedAt: Date? = nil,
        lastAppliedMessageCount: Int = 0,
        lastUploadedMessageCount: Int = 0,
        lastSyncAttemptAt: Date? = nil,
        lastError: String? = nil,
        encryptionKeyID: String? = nil,
        pendingLocalMessageCount: Int = 0,
        lastSyncUsedFallback: Bool = false
    ) {
        self.fileID = fileID
        self.groupID = groupID
        self.lastSyncedAt = lastSyncedAt
        self.lastAppliedMessageCount = lastAppliedMessageCount
        self.lastUploadedMessageCount = lastUploadedMessageCount
        self.lastSyncAttemptAt = lastSyncAttemptAt
        self.lastError = lastError
        self.encryptionKeyID = encryptionKeyID
        self.pendingLocalMessageCount = pendingLocalMessageCount
        self.lastSyncUsedFallback = lastSyncUsedFallback
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

    private enum EncryptMetaCodingKeys: String, CodingKey {
        case keyID = "keyId"
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

    var activeLoginMethods: [ActualLoginMethod] {
        loginMethods.filter(\.isActive)
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
            schedule: schedule
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
