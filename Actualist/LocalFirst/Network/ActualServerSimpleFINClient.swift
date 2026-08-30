import Foundation

/// Transport seam for the Actual server's SimpleFIN bank-sync routes.
/// Production uses `ActualServerSimpleFINClient`; tests stub this protocol.
///
/// Unsupported-route semantics: a server that does not host SimpleFIN answers
/// 404 / 405 / 501, which these methods surface as `nil` ("cannot sync"), not
/// as a thrown error. A connection failure or any other HTTP status throws —
/// an unreachable server is not the same as an unconfigured one.
protocol SimpleFINServerTransport: Sendable {
    /// `POST /simplefin/status` → whether the server has a SimpleFIN setup
    /// token. `nil` when the routes are unsupported.
    func simpleFINStatus(token: String) async throws -> SimpleFINServerSupport

    /// `POST /simplefin/accounts` → the SimpleFIN-side accounts the server
    /// can see. `nil` when the routes are unsupported.
    func simpleFINAccounts(token: String) async throws -> [SimpleFINRemoteAccount]?

    /// `POST /simplefin/transactions` → account-keyed downloads. `startDate`
    /// and `accountID` arrays are positional and must always be sent as
    /// arrays, even for a single account. `nil` when the routes are
    /// unsupported.
    func simpleFINTransactions(
        token: String,
        accountIDs: [String],
        startDates: [String]
    ) async throws -> SimpleFINTransactionsResponse?
}

/// Whether the connected Actual server can drive SimpleFIN bank sync.
enum SimpleFINServerSupport: Equatable, Sendable {
    /// The server answered and has a SimpleFIN setup token.
    case configured
    /// The server answered and has no SimpleFIN setup token.
    case notConfigured
    /// 404 / 405 / 501: this server does not host the SimpleFIN routes.
    case unsupported
}

/// An account on the SimpleFIN side, as returned by `/simplefin/accounts`.
/// Field names follow the server's `SyncServerSimpleFinAccount` shape; values
/// decode defensively because bridge payloads vary across server versions.
struct SimpleFINRemoteAccount: Equatable, Sendable {
    let accountID: String
    let name: String
    /// Raw decimal balance string from the bridge, preferred over the
    /// server-computed starting balance for opening-balance math.
    let balance: String?
    let currency: String?
    let institution: String?
    /// SimpleFIN organization display name; loot-core uses it as the
    /// `banks.name` half of the `(bank_id, name)` find-or-create key.
    var orgName: String?
    let orgDomain: String?
    let orgID: String?
}

/// One normalized transaction row inside an account download. The server
/// forwards SimpleFIN bridge values: `posted`/`transacted_at` are UNIX
/// seconds and `amount` is a decimal string in the account's currency.
struct SimpleFINRemoteTransaction: Equatable, Sendable {
    let id: String?
    /// UNIX seconds, UTC-interpreted by the caller.
    let dateUnixSeconds: Int64?
    /// Raw decimal string; converted with `BankSyncAmounts`, never `* 100`.
    let amount: String?
    let payeeName: String?
    let notes: String?
    /// Booked (posted) vs pending. `nil` when the bridge did not say.
    let booked: Bool?
    /// SimpleFIN-side account id, when present on the row.
    let accountID: String?
}

/// Per-account download from `/simplefin/transactions`.
struct SimpleFINAccountDownload: Equatable, Sendable {
    let transactions: [SimpleFINRemoteTransaction]
    /// Server-computed opening balance in minor units. Only trust this for
    /// zero-decimal confirmation per the plan; prefer the raw decimal
    /// `balance` from `/simplefin/accounts` when available.
    let startingBalance: Int?
    let errorType: String?
    let errorCode: String?

    var hasError: Bool { errorCode != nil }
}

/// The whole `/simplefin/transactions` response: account-keyed downloads plus
/// optional whole-request failure. Account entries may be absent or null when
/// the bridge could not answer for that account.
struct SimpleFINTransactionsResponse: Equatable, Sendable {
    let downloads: [String: SimpleFINAccountDownload]
    let errorType: String?
    let errorCode: String?

    var hasWholeRequestError: Bool { errorCode != nil }
}

actor ActualServerSimpleFINClient: SimpleFINServerTransport {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.session = session ?? URLSession(
            configuration: ActualServerSyncClient.secureSessionConfiguration()
        )
    }

    func simpleFINStatus(token: String) async throws -> SimpleFINServerSupport {
        guard let data = try await post(path: "/simplefin/status", token: token, body: EmptyPayload()) else {
            return .unsupported
        }
        let response = try Self.decode(SimpleFINStatusResponse.self, from: data)
        return response.configured ? .configured : .notConfigured
    }

    func simpleFINAccounts(token: String) async throws -> [SimpleFINRemoteAccount]? {
        guard let data = try await post(path: "/simplefin/accounts", token: token, body: EmptyPayload()) else {
            return nil
        }
        let response = try Self.decode(SimpleFINAccountsResponse.self, from: data)
        return (response.data?.accounts ?? []).map { account in
            SimpleFINRemoteAccount(
                accountID: account.accountID,
                name: account.name,
                balance: account.balance?.text,
                currency: account.currency,
                institution: account.institution,
                orgName: account.org?.name,
                orgDomain: account.org?.domain ?? account.orgDomain,
                orgID: account.org?.id ?? account.orgID
            )
        }
    }

    func simpleFINTransactions(
        token: String,
        accountIDs: [String],
        startDates: [String]
    ) async throws -> SimpleFINTransactionsResponse? {
        guard let data = try await post(
            path: "/simplefin/transactions",
            token: token,
            body: TransactionsRequestPayload(
                accountId: accountIDs,
                startDate: startDates
            )
        ) else {
            return nil
        }
        return try Self.decodeTransactionsResponse(from: data)
    }

    // MARK: - HTTP

    private struct EmptyPayload: Encodable {}
    private struct TransactionsRequestPayload: Encodable {
        let accountId: [String]
        let startDate: [String]
    }

    private struct SimpleFINStatusResponse: Decodable {
        let configured: Bool
    }

    private struct SimpleFINAccountsResponse: Decodable {
        let data: AccountsData?

        struct AccountsData: Decodable {
            let accounts: [FlexibleAccount]?
        }
    }

    /// Server-side `SyncServerSimpleFinAccount` shape; `balance` may be a
    /// JSON number or a decimal string depending on the server version.
    private struct FlexibleAccount: Decodable {
        let accountID: String
        let name: String
        let balance: FlexibleString?
        let currency: String?
        let institution: String?
        let org: Org?
        let orgDomain: String?
        let orgID: String?

        struct Org: Decodable {
            let name: String?
            let domain: String?
            let id: String?
        }

        enum CodingKeys: String, CodingKey {
            case accountID = "account_id"
            case name
            case balance
            case currency
            case institution
            case org
            case orgDomain
            case orgID = "orgId"
        }
    }

    /// `transactions.all` mirrors the GoCardless-style envelope loot-core
    /// consumes; `startingBalance` is the server-computed opening balance.
    private struct TransactionEnvelope: Decodable {
        let all: [FlexibleTransaction]?
    }

    private struct FlexibleAccountEntry: Decodable {
        let transactions: TransactionEnvelope?
        let startingBalance: FlexibleNumber?
        let errorType: String?
        let errorCode: String?

        enum CodingKeys: String, CodingKey {
            case transactions
            case startingBalance
            case errorType = "error_type"
            case errorCode = "error_code"
        }
    }

    private struct FlexibleTransaction: Decodable {
        let id: String?
        let amount: FlexibleString?
        let payeeName: String?
        let notes: String?
        let booked: SimpleFINFlexibleBool?
        let account: String?
        let date: FlexibleUnixSeconds?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decodeIfPresent(String.self, forKey: .id)
            amount = try? container.decodeIfPresent(FlexibleString.self, forKey: .amount)
            payeeName = try? container.decodeIfPresent(String.self, forKey: .payeeName)
                ?? container.decodeIfPresent(String.self, forKey: .payeeNameSnake)
            notes = try? container.decodeIfPresent(String.self, forKey: .notes)
                ?? container.decodeIfPresent(String.self, forKey: .memo)
            booked = try? container.decodeIfPresent(SimpleFINFlexibleBool.self, forKey: .booked)
                ?? container.decodeIfPresent(SimpleFINFlexibleBool.self, forKey: .cleared)
            account = try? container.decodeIfPresent(String.self, forKey: .account)
            date = try? container.decodeIfPresent(FlexibleUnixSeconds.self, forKey: .date)
                ?? container.decodeIfPresent(FlexibleUnixSeconds.self, forKey: .posted)
                ?? container.decodeIfPresent(FlexibleUnixSeconds.self, forKey: .transactedAt)
        }

        enum CodingKeys: String, CodingKey {
            case id
            case amount
            case payeeName
            case payeeNameSnake = "payee_name"
            case notes
            case memo
            case booked
            case cleared
            case account
            case date
            case posted
            case transactedAt = "transacted_at"
        }
    }

    private struct FlexibleNumber: Decodable {
        let intValue: Int?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int.self) {
                intValue = value
            } else if let value = try? container.decode(Double.self) {
                intValue = Int(value)
            } else if let text = try? container.decode(String.self),
                      let value = Double(text) {
                intValue = Int(value)
            } else {
                intValue = nil
            }
        }
    }

    private func post(path: String, token: String, body: some Encodable) async throws -> Data? {
        var request = try Self.endpointURL(baseURL: baseURL, path: path)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(token, forHTTPHeaderField: "X-ACTUAL-TOKEN")
        request.httpBody = try JSONEncoder.actual.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ActualAPIError.transport(error.code)
        } catch {
            throw ActualAPIError.transport(nil)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ActualAPIError.invalidResponse
        }
        let statusCode = httpResponse.statusCode
        // A server without these routes is "cannot sync", not an error.
        if statusCode == 404 || statusCode == 405 || statusCode == 501 {
            return nil
        }
        guard (200..<300).contains(statusCode) else {
            throw ActualAPIError.httpStatus(statusCode)
        }
        return data
    }

    private static func endpointURL(baseURL: URL, path: String) throws -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.path = "/" + [basePath, endpointPath].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components?.url else {
            throw ActualAPIError.invalidURL
        }
        return URLRequest(url: url)
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder.actual.decode(Value.self, from: data)
        } catch {
            throw ActualAPIError.decoding
        }
    }

    /// Transaction responses are account-keyed maps, not a wrapper object, so
    /// decode dynamically: every key except `errors` is a remote account id.
    /// Top-level `errors` maps account ids to per-account failure entries.
    static func decodeTransactionsResponse(from data: Data) throws -> SimpleFINTransactionsResponse {
        guard let payload = try? JSONDecoder().decode(RawTransactionsPayload.self, from: data) else {
            throw ActualAPIError.decoding
        }

        var downloads: [String: SimpleFINAccountDownload] = [:]
        for (accountID, entry) in payload.accounts {
            guard let entry else {
                // Null entry: the bridge had nothing for this account.
                // Phase 3 maps the absence to `account-missing`.
                continue
            }
            var errorType = entry.errorType
            var errorCode = entry.errorCode
            if errorCode == nil, let firstError = payload.errors?[accountID]?.first {
                errorType = errorType ?? firstError.errorType
                errorCode = errorCode ?? firstError.errorCode
            }
            let transactions = (entry.transactions?.all ?? []).map { transaction in
                SimpleFINRemoteTransaction(
                    id: transaction.id,
                    dateUnixSeconds: transaction.date?.seconds,
                    amount: transaction.amount?.text,
                    payeeName: transaction.payeeName,
                    notes: transaction.notes,
                    booked: transaction.booked?.value,
                    accountID: transaction.account
                )
            }
            downloads[accountID] = SimpleFINAccountDownload(
                transactions: transactions,
                startingBalance: entry.startingBalance?.intValue,
                errorType: errorType,
                errorCode: errorCode
            )
        }

        // Accounts that only appear in the batch error map still get an
        // (empty) download entry so callers see the failure, mirroring
        // loot-core's batch-error handling.
        if let batchErrors = payload.errors {
            for (accountID, errorList) in batchErrors {
                guard downloads[accountID] == nil, let error = errorList.first else {
                    continue
                }
                downloads[accountID] = SimpleFINAccountDownload(
                    transactions: [],
                    startingBalance: nil,
                    errorType: error.errorType,
                    errorCode: error.errorCode
                )
            }
        }

        return SimpleFINTransactionsResponse(
            downloads: downloads,
            errorType: payload.errorType,
            errorCode: payload.errorCode
        )
    }
    private struct RawTransactionsPayload: Decodable {
        let accounts: [String: FlexibleAccountEntry?]
        let errors: [String: [FlexibleErrorEntry]]?
        let errorType: String?
        let errorCode: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            var accountEntries: [String: FlexibleAccountEntry?] = [:]
            var batchErrors: [String: [FlexibleErrorEntry]]?
            var decodedErrorType: String?
            var decodedErrorCode: String?
            for key in container.allKeys {
                if key.stringValue == "errors" {
                    batchErrors = try? container.decodeIfPresent(
                        [String: [FlexibleErrorEntry]].self,
                        forKey: key
                    )
                } else if key.stringValue == "error_type" {
                    decodedErrorType = try? container.decodeIfPresent(String.self, forKey: key)
                } else if key.stringValue == "error_code" {
                    decodedErrorCode = try? container.decodeIfPresent(String.self, forKey: key)
                } else {
                    accountEntries[key.stringValue] = try? container.decodeIfPresent(
                        FlexibleAccountEntry.self,
                        forKey: key
                    )
                }
            }
            accounts = accountEntries
            errors = batchErrors
            errorType = decodedErrorType
            errorCode = decodedErrorCode
        }
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    private struct FlexibleErrorEntry: Decodable {
        let errorType: String?
        let errorCode: String?

        enum CodingKeys: String, CodingKey {
            case errorType = "error_type"
            case errorCode = "error_code"
        }
    }
}

