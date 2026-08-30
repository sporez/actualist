import Foundation

/// Direct SimpleFIN bridge client (plan Phase 5, device-claim fallback).
/// Used only when the Actual server does not host SimpleFIN and the user
/// claimed a setup token on this device. Never used by background refresh.
///
/// The bridge API is `GET {access base}/accounts` with HTTP Basic auth,
/// optionally `?start-date=<unix>&end-date=<unix>&pending=1`. Responses are
/// decoded defensively into the same value types the server route path
/// produces, so the reconciler and store pipeline stay shared.
actor SimpleFINBridgeClient {
    /// Base URL without credentials (e.g. `https://bridge.example/user`).
    let baseURL: URL
    private let username: String
    private let password: String
    private let session: URLSession
    private let now: @Sendable () -> Date

    init(
        baseURL: URL,
        username: String,
        password: String,
        session: URLSession? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.session = session ?? URLSession(
            configuration: ActualServerSyncClient.secureSessionConfiguration()
        )
        self.now = now
    }

    /// One-time claim of a setup token. HTTP 403 and a 200 body starting
    /// `Forbidden` both mean the token was already claimed.
    static func claim(
        setupToken: String,
        session: URLSession? = nil
    ) async throws -> (baseURL: URL, username: String, password: String) {
        let claimURL = try SimpleFINBridgeCredentials.claimURL(fromSetupToken: setupToken)
        var request = URLRequest(url: claimURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("0", forHTTPHeaderField: "Content-Length")

        let usedSession = session ?? URLSession(
            configuration: ActualServerSyncClient.secureSessionConfiguration()
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await usedSession.data(for: request)
        } catch let error as URLError {
            throw ActualAPIError.transport(error.code)
        } catch {
            throw ActualAPIError.transport(nil)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SimpleFINBridgeError.invalidResponse
        }
        if httpResponse.statusCode == 403 {
            throw SimpleFINBridgeError.alreadyClaimed
        }
        guard httpResponse.statusCode == 200 else {
            throw SimpleFINBridgeError.unexpectedStatus(httpResponse.statusCode)
        }
        // Some bridges answer 200 with a plain-text rejection.
        let body = String(data: data, encoding: .utf8) ?? ""
        if body.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("forbidden") {
            throw SimpleFINBridgeError.alreadyClaimed
        }
        let credentials = try SimpleFINBridgeCredentials.accessCredentials(fromClaimBody: body)
        let baseURL = try SimpleFINBridgeCredentials.baseURL(fromClaimBody: body)
        return (baseURL, credentials.username, credentials.password)
    }

    /// All SimpleFIN-side accounts with their current balances. `balance` is
    /// a raw decimal string; opening-balance math uses it via
    /// `BankSyncAmounts`, never the server's `parseInt` trick.
    func remoteAccounts() async throws -> [SimpleFINRemoteAccount] {
        let request = try self.accountsRequest(startDate: nil, endDate: nil)
        let set = try await self.run(request)
        return (set.accounts ?? []).map(\.remoteAccount)
    }

    /// Account-keyed downloads for the requested accounts, shaped like the
    /// server route's response so the shared download → review → apply
    /// pipeline is unchanged. An account absent from the bridge answer gets
    /// an `ACCOUNT_MISSING` download entry.
    func transactions(
        accountIDs: [String],
        startDates: [String]
    ) async throws -> SimpleFINTransactionsResponse {
        let start = startDates.first.map(Self.unixSeconds(fromDay:)) ?? 0
        let request = try self.accountsRequest(
            startDate: start,
            endDate: Int(now().timeIntervalSince1970)
        )
        let set = try await self.run(request)
        var downloads: [String: SimpleFINAccountDownload] = [:]
        for accountID in accountIDs {
            guard let account = set.accounts?.first(where: { $0.id == accountID }) else {
                downloads[accountID] = SimpleFINAccountDownload(
                    transactions: [],
                    startingBalance: nil,
                    errorType: nil,
                    errorCode: "ACCOUNT_MISSING"
                )
                continue
            }
                        let transactions = ((account.transactions ?? []) + (account.pending ?? [])).map(\.remoteTransaction)
            downloads[accountID] = SimpleFINAccountDownload(
                transactions: transactions,
                startingBalance: nil,
                errorType: nil,
                errorCode: nil
            )
        }
        return SimpleFINTransactionsResponse(
            downloads: downloads,
            errorType: nil,
            errorCode: nil
        )
    }

    // MARK: - Requests

    private func accountsRequest(startDate: Int?, endDate: Int?) throws -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = "/" + [basePath, "accounts"].joined(separator: "/")
        var query: [URLQueryItem] = [URLQueryItem(name: "pending", value: "1")]
        if let startDate {
            query.append(URLQueryItem(name: "start-date", value: String(startDate)))
            query.append(URLQueryItem(name: "end-date", value: String(max(endDate ?? 0, startDate))))
        }
        components?.queryItems = query
        guard let url = components?.url else {
            throw SimpleFINBridgeError.invalidAccessURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            SimpleFINBridgeCredentials.basicAuthorization(username: username, password: password),
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    private func run(_ request: URLRequest) async throws -> BridgeAccountSet {
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
            throw SimpleFINBridgeError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(BridgeAccountSet.self, from: data)
            } catch {
                throw SimpleFINBridgeError.invalidResponse
            }
        case 402:
            throw SimpleFINBridgeError.paymentRequired
        case 403:
            throw SimpleFINBridgeError.accessRevoked
        default:
            throw SimpleFINBridgeError.unexpectedStatus(httpResponse.statusCode)
        }
    }

    /// `YYYY-MM-DD` (the lookback start the shared pipeline already builds)
    /// → UTC UNIX seconds for the bridge query.
    static func unixSeconds(fromDay day: String) -> Int {
        let characters = Array(day)
        guard characters.count == 10, day.split(separator: "-").count == 3 else {
            return 0
        }
        var components = DateComponents()
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = Int(day.prefix(4))
        components.month = Int(day.dropFirst(5).prefix(2))
        components.day = Int(day.suffix(2))
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return Int(calendar.date(from: components)?.timeIntervalSince1970 ?? 0)
    }
}

/// Bridge payload shapes (simplefin.org protocol). Optional/variant fields
/// decode defensively because the bridge has shipped several shapes.
private struct BridgeAccountSet: Decodable {
    let errors: [String]?
    let errlist: [BridgeErrorEntry]?
    let accounts: [BridgeAccount]?
}

private struct BridgeErrorEntry: Decodable {
    let code: String?
    let message: String?
}

private struct BridgeAccount: Decodable {
    let id: String
    let name: String?
    let balance: FlexibleString?
    let currency: String?
    let institution: String?
    let org: BridgeOrg?
    let transactions: [BridgeTransaction]?
    let pending: [BridgeTransaction]?

    var remoteAccount: SimpleFINRemoteAccount {
        SimpleFINRemoteAccount(
            accountID: id,
            name: name ?? "",
            balance: balance?.text,
            currency: currency,
            institution: institution,
            orgName: org?.name,
            orgDomain: org?.domain ?? org?.id,
            orgID: org?.id
        )
    }
}

private struct BridgeOrg: Decodable {
    let name: String?
    let domain: String?
    let id: String?
}

private struct BridgeTransaction: Decodable {
    let id: String?
    let posted: FlexibleUnixSeconds?
    let transactedAt: FlexibleUnixSeconds?
    let amount: FlexibleString?
    let description: String?
    let payee: String?
    let pending: SimpleFINFlexibleBool?
    let extra: Extra?

    var remoteTransaction: SimpleFINRemoteTransaction {
        let payeeName = (extra?.payee ?? payee ?? description)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SimpleFINRemoteTransaction(
            id: id,
            dateUnixSeconds: posted?.seconds ?? transactedAt?.seconds,
            amount: amount?.text,
            payeeName: payeeName?.isEmpty == true ? nil : payeeName,
            notes: extra?.notes,
            booked: pending?.value.map { !$0 },
            accountID: nil
        )
    }

    struct Extra: Decodable {
        let notes: String?
        let payee: String?
    }

    enum CodingKeys: String, CodingKey {
        case id
        case posted
        case amount
        case description
        case payee
        case pending
        case extra
        case transactedAt = "transacted_at"
    }
}
