import Foundation

/// Batched Bank Sync planning: one provider resolution, one transactions
/// request, one account-metadata request, and one rule/metadata snapshot for
/// every linked account in the run. Produces immutable review/apply plans and
/// never writes transaction data.
extension LocalFirstActualStore {
    func downloadBankSyncPlan(
        accountID: String,
        budgetID: String,
        deviceFallback: Bool = true
    ) async throws -> BankSyncReview.AccountPlan {
        guard let plan = try await downloadBankSyncPlans(
            accountIDs: [accountID],
            budgetID: budgetID,
            deviceFallback: deviceFallback
        ).first else {
            throw LocalFirstError.invalidLocalWrite("missing bank sync plan")
        }
        return plan
    }

    func downloadBankSyncPlans(
        accountIDs: [String],
        budgetID: String,
        deviceFallback: Bool = true
    ) async throws -> [BankSyncReview.AccountPlan] {
        guard !accountIDs.isEmpty else { return [] }
        try Task.checkCancellation()

        let database = try requireDatabase(for: budgetID)
        let provider = try await bankSyncProvider(
            budgetID: budgetID,
            deviceFallback: deviceFallback
        )
        let linkedByID = Dictionary(uniqueKeysWithValues: try await database
            .bankSyncLinkedAccounts()
            .map { ($0.id, $0) })
        let linked = try accountIDs.map { accountID in
            guard let account = linkedByID[accountID] else {
                throw BankSyncStoreError.notLinked
            }
            guard account.syncSource == "simpleFin" else {
                throw BankSyncStoreError.notSimpleFINLinked
            }
            return account
        }

        let currency = try await bankSyncCurrency(database: database, budgetID: budgetID)
        let payees = try await database.fetchPayees()
        let categories = try await database.fetchCategories()
        let payeeIDsByName = payees.reduce(into: [String: String]()) { result, payee in
            guard payee.transferAccount == nil, let id = payee.id else { return }
            let key = payee.name.lowercased()
            if result[key] == nil {
                result[key] = id
            }
        }
        let payeeNames = Dictionary(uniqueKeysWithValues: payees.compactMap { payee in
            payee.id.map { ($0, payee.name) }
        })
        let categoryNames = Dictionary(uniqueKeysWithValues: categories.compactMap { category in
            category.id.map { ($0, category.name) }
        })

        var startDates: [String] = []
        var accountHadLiveTransactions: [Bool] = []
        startDates.reserveCapacity(linked.count)
        accountHadLiveTransactions.reserveCapacity(linked.count)
        for account in linked {
            try Task.checkCancellation()
            let oldest = try await database.bankSyncOldestLiveTransactionDayID(
                accountID: account.id
            )
            startDates.append(BankSyncAmounts.lookbackStartDate(
                oldestLiveTransactionDayID: oldest
            ))
            accountHadLiveTransactions.append(oldest != nil)
        }

        async let responseRequest = provider.transactions(
            accountIDs: linked.map(\.remoteAccountID),
            startDates: startDates
        )
        // Balance metadata improves first-sync opening-balance accuracy but is
        // not allowed to discard an otherwise valid transaction batch. Server
        // startingBalance remains the 2-decimal fallback; direct mode simply
        // omits an opening balance if this optional request fails.
        let needsBalanceMetadata = accountHadLiveTransactions.contains(false)
        async let accountsRequest: [SimpleFINRemoteAccount]? = needsBalanceMetadata
            ? (try? await provider.remoteAccounts())
            : []
        let response = try await responseRequest
        let remoteAccounts = await accountsRequest ?? []
        let remoteByID = remoteAccounts.reduce(into: [String: SimpleFINRemoteAccount]()) { result, remote in
            if result[remote.accountID] == nil {
                result[remote.accountID] = remote
            }
        }

        var prepared: [PreparedDownload] = []
        prepared.reserveCapacity(linked.count)
        for account in linked {
            try Task.checkCancellation()
            let download = resolvedDownload(
                for: account.remoteAccountID,
                response: response
            )
            if download.hasError {
                prepared.append(PreparedDownload(download: download))
            } else {
                prepared.append(try prepareDownload(
                    download,
                    accountID: account.id,
                    currency: currency,
                    payeeIDsByName: payeeIDsByName
                ))
            }
        }

        let allDrafts = prepared.flatMap(\.ruleDrafts)
        let previews = try await database.previewRules(for: allDrafts)
        guard previews.count == allDrafts.count else {
            throw LocalFirstError.invalidLocalWrite("missing bank sync rule preview")
        }
        var previewOffset = 0
        for index in prepared.indices {
            try Task.checkCancellation()
            let count = prepared[index].candidates.count
            let accountPreviews = previews[previewOffset..<(previewOffset + count)]
            prepared[index].projectedCandidates = zip(
                prepared[index].candidates,
                accountPreviews
            ).compactMap { candidate, preview in
                BankSyncReconciliation.applyingRulePreview(preview, to: candidate)
            }
            previewOffset += count
        }

        var plans: [BankSyncReview.AccountPlan] = []
        plans.reserveCapacity(linked.count)
        for (index, account) in linked.enumerated() {
            try Task.checkCancellation()
            plans.append(try await makeBankSyncPlan(
                account: account,
                prepared: prepared[index],
                remote: remoteByID[account.remoteAccountID],
                currency: currency,
                payeeNames: payeeNames,
                categoryNames: categoryNames,
                accountHadLiveTransactions: accountHadLiveTransactions[index],
                database: database
            ))
        }
        return plans
    }

    private struct PreparedDownload {
        let download: SimpleFINAccountDownload
        var candidates: [BankSyncReconciliation.Candidate] = []
        var ruleDrafts: [TransactionDraft] = []
        var projectedCandidates: [BankSyncReconciliation.Candidate] = []
        var problems: [BankSyncReview.Problem] = []
        var candidateAmounts: [Int] = []
        var dayIDs: [String] = []
        var earliestDayID: String?

        init(download: SimpleFINAccountDownload) {
            self.download = download
        }
    }

    private func prepareDownload(
        _ download: SimpleFINAccountDownload,
        accountID: String,
        currency: BudgetCurrency,
        payeeIDsByName: [String: String]
    ) throws -> PreparedDownload {
        var prepared = PreparedDownload(download: download)
        for transaction in download.transactions {
            try Task.checkCancellation()
            let problemID = transaction.id
            guard transaction.id?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                prepared.problems.append(.init(
                    remoteTransactionID: nil,
                    message: "Missing transaction ID"
                ))
                continue
            }
            if let transactionCurrency = BankSyncAmounts.normalizedCurrencyCode(transaction.currency),
               transactionCurrency != currency.code.uppercased() {
                prepared.problems.append(.init(
                    remoteTransactionID: problemID,
                    message: "Currency mismatch (\(transactionCurrency) bank transaction, \(currency.code.uppercased()) budget)"
                ))
                continue
            }
            guard let amount = BankSyncAmounts.minorUnits(
                fromDecimal: transaction.amount,
                currency: currency
            ) else {
                prepared.problems.append(.init(
                    remoteTransactionID: problemID,
                    message: "Unreadable amount"
                ))
                continue
            }
            guard let dayID = transaction.dateUnixSeconds.map(BankSyncAmounts.dayID(fromUnixSeconds:)) else {
                prepared.problems.append(.init(
                    remoteTransactionID: problemID,
                    message: "Unreadable date"
                ))
                continue
            }
            let payeeName = transaction.payeeName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard payeeName?.isEmpty == false else {
                prepared.problems.append(.init(
                    remoteTransactionID: problemID,
                    message: "Missing payee"
                ))
                continue
            }
            let escapedNotes = transaction.notes.map(BankSyncReconciliation.escapedNotes)
            let candidate = BankSyncReconciliation.Candidate(
                financialID: transaction.id,
                dayID: dayID,
                amountMinorUnits: amount,
                payeeID: payeeName.flatMap { payeeIDsByName[$0.lowercased()] },
                payeeName: payeeName,
                notes: escapedNotes?.isEmpty == false ? escapedNotes : nil,
                categoryID: nil,
                // Actual core uses `Boolean(trans.booked)`: an absent or
                // unreadable posted state must remain pending, not be asserted
                // as cleared.
                cleared: transaction.booked == true,
                importedPayee: payeeName
            )
            prepared.candidates.append(candidate)
            prepared.ruleDrafts.append(bankSyncPreviewDraft(
                candidate: candidate,
                accountID: accountID,
                dayID: dayID
            ))
            prepared.candidateAmounts.append(amount)
            prepared.dayIDs.append(dayID)
            if prepared.earliestDayID == nil || dayID < prepared.earliestDayID! {
                prepared.earliestDayID = dayID
            }
        }
        return prepared
    }

    private func makeBankSyncPlan(
        account: BudgetDatabase.BankSyncLinkedAccount,
        prepared: PreparedDownload,
        remote: SimpleFINRemoteAccount?,
        currency: BudgetCurrency,
        payeeNames: [String: String],
        categoryNames: [String: String],
        accountHadLiveTransactions: Bool,
        database: BudgetDatabase
    ) async throws -> BankSyncReview.AccountPlan {
        let openingBalance: BankSyncReconciliation.OpeningBalance?
        if prepared.problems.isEmpty && !prepared.download.hasError {
            let currentBalance = BankSyncAmounts.minorUnits(
                fromDecimal: remote?.balance,
                currency: currency
            ) ?? (currency.decimalPlaces == 2 ? prepared.download.startingBalance : nil)
            if let currentBalance {
                openingBalance = BankSyncReconciliation.openingBalance(
                    currentBalanceMinorUnits: currentBalance,
                    candidateAmounts: prepared.candidateAmounts,
                    earliestDayID: prepared.earliestDayID,
                    accountHadLiveTransactions: accountHadLiveTransactions
                )
            } else {
                openingBalance = nil
            }
        } else {
            openingBalance = nil
        }

        let existing = try await database.bankSyncExistingRows(
            accountID: account.id,
            window: Self.monthWidenedWindow(candidateDayIDs: prepared.dayIDs)
        )
        let reconciliation = BankSyncReconciliation.plan(
            candidates: prepared.projectedCandidates,
            existing: existing
        )
        let updates = reconciliation.entries.compactMap { entry in
            if case .update(let update) = entry { return update }
            return nil
        }
        let matchDetails = BankSyncMatchReview.details(
            updates: updates,
            existing: existing,
            payeeNames: payeeNames,
            categoryNames: categoryNames
        )
        guard matchDetails.count == updates.count,
              matchDetails.allSatisfy({ !$0.changes.isEmpty }) else {
            throw LocalFirstError.invalidLocalWrite("missing bank sync match review detail")
        }

        let generation = (bankSyncGenerationByAccount[account.id] ?? 0) + 1
        bankSyncGenerationByAccount[account.id] = generation
        return BankSyncReview.AccountPlan(
            accountID: account.id,
            remoteAccountID: account.remoteAccountID,
            durableStatus: ActualBankSyncDurableStatus.from(
                errorCode: prepared.download.errorCode
            ),
            inserts: reconciliation.inserts,
            updates: updates,
            matchDetails: matchDetails,
            unchangedCount: reconciliation.entries.reduce(0) { count, entry in
                if case .unchanged = entry { return count + 1 }
                return count
            },
            problems: prepared.problems,
            openingBalance: openingBalance,
            generation: generation
        )
    }

    private func resolvedDownload(
        for remoteAccountID: String,
        response: SimpleFINTransactionsResponse
    ) -> SimpleFINAccountDownload {
        var download = response.downloads[remoteAccountID]
        if download == nil, response.errorCode == nil {
            download = SimpleFINAccountDownload(
                transactions: [],
                startingBalance: nil,
                errorType: nil,
                errorCode: "ACCOUNT_MISSING"
            )
        }
        if response.hasWholeRequestError, download?.errorCode == nil {
            download = SimpleFINAccountDownload(
                transactions: download?.transactions ?? [],
                startingBalance: download?.startingBalance,
                errorType: response.errorType,
                errorCode: response.errorCode
            )
        }
        return download ?? SimpleFINAccountDownload(
            transactions: [],
            startingBalance: nil,
            errorType: nil,
            errorCode: "ACCOUNT_MISSING"
        )
    }

    private func bankSyncCurrency(
        database: BudgetDatabase,
        budgetID: String
    ) async throws -> BudgetCurrency {
        if let cached = currencyByBudget[budgetID] {
            return cached
        }
        return try await database.fetchBudgetCurrency()
    }

    /// Rule-preview draft uses raw provider values so conditions run before
    /// matching, exactly like Actual's `transactionsStep1`.
    private func bankSyncPreviewDraft(
        candidate: BankSyncReconciliation.Candidate,
        accountID: String,
        dayID: String
    ) -> TransactionDraft {
        TransactionDraft(
            accountID: accountID,
            date: BankSyncAmounts.date(fromDayID: dayID)
                ?? Date(timeIntervalSince1970: 0),
            amountMinorUnits: candidate.amountMinorUnits,
            payeeID: nil,
            payeeName: candidate.payeeName ?? "",
            categoryID: nil,
            notes: candidate.notes,
            cleared: candidate.cleared,
            isTransfer: false,
            importedPayee: candidate.importedPayee
        )
    }

    /// Calendar-based read window around downloaded days. The reconciler owns
    /// the exact ±7-day check; this query bound ensures it receives eligible
    /// rows across month/year boundaries and leap days.
    static func monthWidenedWindow(
        candidateDayIDs: [String]
    ) -> ClosedRange<Int> {
        guard let firstID = candidateDayIDs.min(),
              let lastID = candidateDayIDs.max(),
              let first = BankSyncAmounts.date(fromDayID: firstID),
              let last = BankSyncAmounts.date(fromDayID: lastID) else {
            return 0...99_999_999
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let lowerDate = calendar.date(byAdding: .day, value: -7, to: first),
              let upperDate = calendar.date(byAdding: .day, value: 7, to: last),
              let lower = Int(BankSyncAmounts.dayID(fromUnixSeconds: Int64(lowerDate.timeIntervalSince1970))),
              let upper = Int(BankSyncAmounts.dayID(fromUnixSeconds: Int64(upperDate.timeIntervalSince1970))) else {
            return 0...99_999_999
        }
        return lower...upper
    }
}
