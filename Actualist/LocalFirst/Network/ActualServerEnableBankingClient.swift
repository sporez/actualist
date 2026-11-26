import Foundation

/// Transport seam for the Actual server's Enable Banking routes. Production
/// uses `ActualServerEnableBankingClient`; tests stub this protocol.
///
/// Enable Banking credentials are server-wide, so unlike SimpleFIN no
/// `X-ACTUAL-FILE-ID` is sent (loot-core `downloadEnableBankingTransactions`).
/// A server without these routes answers 404 / 405 / 501, surfaced as
/// `.unsupported` / `nil`; a connection failure or any other status throws.
protocol EnableBankingServerTransport: Sendable {
    /// `POST /enablebanking/status` → whether the server has Enable Banking
    /// credentials.
    func status(token: String) async throws -> SimpleFINServerSupport

    /// `POST /enablebanking/transactions` for one account. A provider failure
    /// arrives as HTTP 200 with `error_type` / `error_code` and becomes a
    /// download carrying that code, not a thrown error. `nil` when the
    /// routes are unsupported.
    func transactions(
        token: String,
        accountID: String,
        startDate: String,
        aspspName: String?
    ) async throws -> SimpleFINAccountDownload?
}

actor ActualServerEnableBankingClient: EnableBankingServerTransport {
    let baseURL: URL
    private let customHeaders: HTTPHeaderFields
    private let poster: ActualServerBankSyncPost

    init(baseURL: URL, customHeaders: HTTPHeaderFields = .empty, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.customHeaders = customHeaders
        poster = ActualServerBankSyncPost(
            requests: ActualServerRequestBuilder(baseURL: baseURL, customHeaders: customHeaders),
            session: session ?? URLSession(configuration: ActualServerSyncClient.secureSessionConfiguration())
        )
    }

    func status(token: String) async throws -> SimpleFINServerSupport {
        guard let data = try await post(path: "/enablebanking/status", token: token, body: EmptyPayload()) else {
            return .unsupported
        }
        guard let response = try? JSONDecoder.actual.decode(StatusEnvelope.self, from: data),
              let configured = response.data?.configured else {
            throw ActualAPIError.decoding
        }
        return configured ? .configured : .notConfigured
    }

    func transactions(
        token: String,
        accountID: String,
        startDate: String,
        aspspName: String?
    ) async throws -> SimpleFINAccountDownload? {
        guard let data = try await post(
            path: "/enablebanking/transactions",
            token: token,
            body: TransactionsPayload(accountId: accountID, startDate: startDate, aspspName: aspspName)
        ) else {
            return nil
        }
        let download = try Self.decodeTransactionsResponse(from: data)
        guard ![download.errorCode, download.errorType].contains(where: customHeaders.containsCredential(in:)) else {
            throw ActualAPIError.invalidResponse
        }
        return download
    }

    private func post(path: String, token: String, body: some Encodable) async throws -> Data? {
        try await poster.post(
            path: path,
            fileID: nil,
            token: token,
            jsonBody: JSONEncoder.actual.encode(body),
            limitError: ActualAPIError.invalidResponse
        )
    }

    // MARK: - Decoding

    /// `{status: "ok", data: {...}}`. `data` holds either the download
    /// (`transactions.all`, `balances`, `startingBalance`) or a provider
    /// failure (`error_type`, `error_code`). The server already normalized
    /// every row (`normalizeTransaction`): `transactionId` (may be empty),
    /// `date` as `YYYY-MM-DD`, a signed decimal `transactionAmount`,
    /// `payeeName`, `notes` and `booked`, next to the bank's own snake_case
    /// fields, which stay available to custom mappings.
    static func decodeTransactionsResponse(from data: Data) throws -> SimpleFINAccountDownload {
        guard let envelope = try? JSONDecoder.actual.decode(TransactionsEnvelope.self, from: data),
              let payload = envelope.data else {
            throw ActualAPIError.decoding
        }
        if let errorCode = payload.errorCode {
            return SimpleFINAccountDownload(
                transactions: [],
                startingBalance: nil,
                errorType: payload.errorType,
                errorCode: errorCode
            )
        }
        // loot-core reads `transactions.all` unconditionally; a download
        // without it is not a download.
        guard let rows = payload.transactions?.all else {
            throw ActualAPIError.decoding
        }
        return SimpleFINAccountDownload(
            transactions: rows.map { row in
                SimpleFINRemoteTransaction(
                    id: row.transactionID,
                    dateUnixSeconds: row.date.flatMap(FlexibleUnixSeconds.unixSeconds(fromDay:)),
                    amount: row.amount?.amount,
                    currency: row.amount?.currency,
                    payeeName: row.payeeName,
                    notes: row.notes,
                    booked: row.booked,
                    accountID: nil,
                    rawFields: row.rawFields
                )
            },
            startingBalance: nil,
            minorUnitBalance: minorUnitBalance(payload),
            errorType: nil,
            errorCode: nil
        )
    }

    /// The server's `startingBalance` is the CLAV balance, else the first
    /// one, scaled by 100. With no balance at all it sends 0, which is not
    /// evidence of a balance, so that case has none.
    private static func minorUnitBalance(_ payload: TransactionsData) -> BankSyncMinorUnitBalance? {
        let balances = payload.balances ?? []
        guard let amount = payload.startingBalance?.value,
              let preferred = balances.first(where: { $0.balanceType == "CLAV" }) ?? balances.first else {
            return nil
        }
        return BankSyncMinorUnitBalance(amount: amount, currency: preferred.balanceAmount?.currency)
    }

    private struct EmptyPayload: Encodable {}

    private struct TransactionsPayload: Encodable {
        let accountId: String
        let startDate: String
        /// The linked bank's name; the server uses it to leave out PSU
        /// headers for banks that refuse them.
        let aspspName: String?
    }

    private struct StatusEnvelope: Decodable {
        let data: StatusData?

        struct StatusData: Decodable {
            let configured: Bool?
        }
    }

    private struct TransactionsEnvelope: Decodable {
        let data: TransactionsData?
    }

    private struct TransactionsData: Decodable {
        let transactions: Collections?
        let balances: [Balance]?
        let startingBalance: IntegerNumber?
        let errorType: String?
        let errorCode: String?

        struct Collections: Decodable {
            let all: [Row]?
        }

        enum CodingKeys: String, CodingKey {
            case transactions
            case balances
            case startingBalance
            case errorType = "error_type"
            case errorCode = "error_code"
        }
    }

    private struct Balance: Decodable {
        let balanceAmount: BalanceAmount?
        let balanceType: String?

        struct BalanceAmount: Decodable {
            let currency: String?
        }
    }

    /// One normalized row. Every field decodes leniently: an unreadable value
    /// becomes `nil` and the planner reports it, instead of failing the
    /// whole download.
    private struct Row: Decodable {
        let transactionID: String?
        let date: String?
        let amount: Amount?
        let payeeName: String?
        let notes: String?
        let booked: Bool?
        let rawFields: SimpleFINRawFields

        struct Amount: Decodable {
            let amount: String?
            let currency: String?
        }

        enum CodingKeys: String, CodingKey {
            case transactionID = "transactionId"
            case date
            case amount = "transactionAmount"
            case payeeName
            case notes
            case booked
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            transactionID = try? container.decodeIfPresent(String.self, forKey: .transactionID)
            date = try? container.decodeIfPresent(String.self, forKey: .date)
            amount = try? container.decodeIfPresent(Amount.self, forKey: .amount)
            payeeName = try? container.decodeIfPresent(String.self, forKey: .payeeName)
            notes = try? container.decodeIfPresent(String.self, forKey: .notes)
            booked = try? container.decodeIfPresent(Bool.self, forKey: .booked)
            rawFields = (try? SimpleFINRawFields(from: decoder)) ?? SimpleFINRawFields()
        }
    }

    /// A JSON integer, or a float that is exactly one.
    private struct IntegerNumber: Decodable {
        let value: Int?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let integer = try? container.decode(Int.self) {
                value = integer
            } else if let double = try? container.decode(Double.self) {
                value = Int(exactly: double)
            } else {
                value = nil
            }
        }
    }
}
