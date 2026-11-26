import Foundation

/// Batched Bank Sync planning: one rule/metadata snapshot for every linked
/// account in the run. SimpleFIN accounts share one provider resolution, one
/// transactions request and one account-metadata request; Enable Banking
/// accounts then download one at a time (`EnableBankingWorkflows`), as Actual's
/// web Sync All does. A SimpleFIN failure does not stop the Enable Banking
/// accounts of the same run. Produces immutable review/apply plans and never
/// writes transaction data. The store owns it.
@MainActor
final class BankSyncPlanWorkflows {
    // The store creates this lazily and keeps it for its whole life, so the
    // store outlives every holder of it.
    private unowned let store: LocalFirstActualStore

    init(store: LocalFirstActualStore) {
        self.store = store
    }

    /// The plans of one download run.
    struct DownloadRun {
        /// In requested order. An account without a plan was not downloaded:
        /// its SimpleFIN batch failed, or a background deadline came first.
        var plans: [BankSyncReview.AccountPlan]
        /// The SimpleFIN part failed while Enable Banking accounts were in the
        /// same run. Those accounts' statuses are already recorded and they
        /// have no plan. A run with only SimpleFIN accounts throws instead.
        var simpleFINFailure: (any Error)?
    }

    /// `enableBankingDeadline` bounds the Enable Banking requests of a
    /// background run (`EnableBankingWorkflows.downloads`).
    func downloadBankSyncRun(
        accountIDs: [String],
        budgetID: String,
        deviceFallback: Bool = true,
        enableBankingDeadline: ContinuousClock.Instant? = nil
    ) async throws -> DownloadRun {
        guard !accountIDs.isEmpty else { return DownloadRun(plans: []) }
        try Task.checkCancellation()

        let database = try store.requireDatabase(for: budgetID)
        let sessionGeneration = store.budgetSessionGeneration
        var seen = Set<String>()
        let accountIDs = accountIDs.filter { seen.insert($0).inserted }
        let generations = Dictionary(uniqueKeysWithValues: accountIDs.map { id in
            let generation = UUID()
            store.bankSyncGenerationByAccount[id] = generation
            return (id, generation)
        })
        let linkedByID = Dictionary(uniqueKeysWithValues: try await BankSyncLinkSQL.bankSyncLinkedAccounts(in: database)
            .map { ($0.id, $0) })
        let linked = try accountIDs.map { accountID in
            guard let account = linkedByID[accountID] else {
                throw BankSyncWorkflows.BankSyncStoreError.notLinked
            }
            return account
        }
        let kinds = try linked.map { account in
            guard let kind = BankSyncProviderKind(syncSource: account.syncSource) else {
                throw BankSyncWorkflows.BankSyncStoreError.unsupportedProvider
            }
            return kind
        }
        let simpleFINIndices = linked.indices.filter { kinds[$0] == .simpleFIN }
        let enableBankingIndices = linked.indices.filter { kinds[$0] == .enableBanking }

        let storageID = try await BudgetModeSQL.fetchBudgetModeIdentity(in: database).storageID
        let links = linked.map { BankSyncLinkIdentity(storageID: storageID, accountID: $0.id,
            remoteAccountID: $0.remoteAccountID, syncSource: $0.syncSource) }
        let simpleFINLinks = simpleFINIndices.map { links[$0] }
        guard store.database === database else {
            throw BankSyncWorkflows.BankSyncStoreError.staleGeneration
        }
        // A run without SimpleFIN accounts never asks the server about SimpleFIN.
        // A SimpleFIN failure is recorded like before; it ends the run only when
        // no Enable Banking account is left to download, as Actual's web Sync
        // All carries on with the other providers.
        var simpleFINFailure: (any Error)?
        func failSimpleFIN(_ error: Error) async throws {
            await recordBankSyncFailure(error, links: simpleFINLinks, generations: generations,
                database: database, budgetID: budgetID)
            guard !enableBankingIndices.isEmpty, !error.isCancellation,
                  (error as? BankSyncWorkflows.BankSyncStoreError) != .staleGeneration else {
                throw error
            }
            simpleFINFailure = error
        }
        var provider: BankSyncWorkflows.BankSyncProvider?
        if !simpleFINIndices.isEmpty {
            do {
                provider = try await store.bankSync.bankSyncProvider(budgetID: budgetID, deviceFallback: deviceFallback)
            } catch {
                try await failSimpleFIN(error)
            }
        }

        let currency = try await bankSyncCurrency(database: database, budgetID: budgetID)
        let payees = try await PayeeSQL.fetchPayees(in: database)
        let categories = try await CategorySQL.fetchCategories(in: database)
        let payeeIDsByName = BankSyncDownloadPreparation.payeeIDsByName(payees)
        let payeeNames = Dictionary(uniqueKeysWithValues: payees.compactMap { payee in
            payee.id.map { ($0, payee.name) }
        })
        let categoryNames = categories.namesByID

        var startDates: [String] = []
        var accountHadLiveTransactions: [Bool] = []
        startDates.reserveCapacity(linked.count)
        accountHadLiveTransactions.reserveCapacity(linked.count)
        for account in linked {
            try Task.checkCancellation()
            let oldest = try await BankSyncLinkSQL.bankSyncOldestLiveTransactionDayID(
                accountID: account.id,
                in: database
            )
            startDates.append(BankSyncAmounts.lookbackStartDate(
                oldestLiveTransactionDayID: oldest
            ))
            accountHadLiveTransactions.append(oldest != nil)
        }

        var simpleFINResponse: SimpleFINTransactionsResponse?
        var remoteAccounts: [SimpleFINRemoteAccount] = []
        if let provider {
            let requestedStartDates = simpleFINIndices.map { startDates[$0] }
            async let responseRequest = provider.transactions(
                accountIDs: simpleFINIndices.map { linked[$0].remoteAccountID },
                startDates: requestedStartDates
            )
            // Balance metadata improves first-sync opening-balance accuracy but is
            // not allowed to discard an otherwise valid transaction batch. Server
            // startingBalance remains the 2-decimal fallback; direct mode simply
            // omits an opening balance if this optional request fails.
            let needsBalanceMetadata = simpleFINIndices.contains { !accountHadLiveTransactions[$0] }
            async let accountsRequest: [SimpleFINRemoteAccount]? = needsBalanceMetadata
                ? (try? await provider.remoteAccounts())
                : []
            do {
                simpleFINResponse = try await responseRequest
            } catch {
                try await failSimpleFIN(error)
            }
            remoteAccounts = await accountsRequest ?? []
        }
        let remoteByID = remoteAccounts.reduce(into: [String: SimpleFINRemoteAccount]()) { result, remote in
            if result[remote.accountID] == nil {
                result[remote.accountID] = remote
            }
        }

        let bankNames = try await BankSyncLinkSQL.bankSyncBankNames(
            accountIDs: enableBankingIndices.map { linked[$0].id },
            in: database
        )
        let enableBankingDownloads = try await store.enableBanking.downloads(
            enableBankingIndices.map { index in
                EnableBankingWorkflows.AccountRequest(
                    accountID: linked[index].id,
                    remoteAccountID: linked[index].remoteAccountID,
                    startDate: startDates[index],
                    aspspName: bankNames[linked[index].id]
                )
            },
            budgetID: budgetID,
            database: database,
            sessionGeneration: sessionGeneration,
            generations: generations,
            deadline: enableBankingDeadline
        )

        // The accounts that were downloaded, in requested order.
        var included: [(index: Int, download: SimpleFINAccountDownload)] = []
        for (index, account) in linked.enumerated() {
            switch kinds[index] {
            case .simpleFIN:
                if let simpleFINResponse {
                    included.append((index, resolvedDownload(for: account.remoteAccountID, response: simpleFINResponse)))
                }
            case .enableBanking:
                if let download = enableBankingDownloads[account.id] {
                    included.append((index, download))
                }
            }
        }

        var prepared: [BankSyncDownloadPreparation.Prepared] = []
        prepared.reserveCapacity(included.count)
        for (index, download) in included {
            try Task.checkCancellation()
            let account = linked[index]
            if download.hasError {
                prepared.append(BankSyncDownloadPreparation.Prepared(download: download))
            } else {
                prepared.append(try BankSyncDownloadPreparation.prepare(
                    download,
                    provider: kinds[index],
                    accountID: account.id,
                    currency: currency,
                    payeeIDsByName: payeeIDsByName,
                    preferences: try await BankSyncLinkSQL.bankSyncImportPreferences(
                        accountID: account.id,
                        in: database
                    )
                ))
            }
        }

        let allDrafts = prepared.flatMap(\.ruleDrafts)
        let previews = try await RulePreviewSQL.previewRules(
            for: allDrafts,
            dateTimeZone: ImportReconcileProjection.ruleDateTimeZone,
            in: database
        )
        guard previews.count == allDrafts.count else {
            throw LocalFirstError.invalidLocalWrite("missing bank sync rule preview")
        }
        var previewOffset = 0
        for position in prepared.indices {
            try Task.checkCancellation()
            let account = linked[included[position].index]
            let count = prepared[position].candidates.count
            let projection = ImportReconcileProjection.project(
                candidates: prepared[position].candidates,
                previews: Array(previews[previewOffset..<(previewOffset + count)]),
                accountID: account.id,
                accountIsOffBudget: account.offbudget
            )
            for source in projection.movedSources {
                prepared[position].problems.append(
                    .unsupportedAccountMove(remoteTransactionID: prepared[position].candidates[source].financialID)
                )
            }
            prepared[position].projectedCandidates = projection.candidates
            previewOffset += count
        }

        var plans: [BankSyncReview.AccountPlan] = []
        plans.reserveCapacity(included.count)
        for (position, (index, _)) in included.enumerated() {
            try Task.checkCancellation()
            let account = linked[index]
            guard let generation = generations[account.id], store.database === database,
                  store.bankSyncGenerationByAccount[account.id] == generation else {
                throw BankSyncWorkflows.BankSyncStoreError.staleGeneration
            }
            var plan = try await makeBankSyncPlan(
                account: account,
                link: links[index],
                generation: generation,
                prepared: prepared[position],
                remote: remoteByID[account.remoteAccountID],
                currency: currency,
                payeeNames: payeeNames,
                categoryNames: categoryNames,
                accountHadLiveTransactions: accountHadLiveTransactions[index],
                database: database
            )
            // A whole-request failure belongs to the SimpleFIN batch only.
            plan.wholeRequestFailure = kinds[index] == .simpleFIN ? simpleFINResponse?.wholeRequestFailure : nil
            plans.append(plan)
        }
        return DownloadRun(plans: plans, simpleFINFailure: simpleFINFailure)
    }

    /// Provider failures are shared status, but local setup and cancellation
    /// are not. Keep the original provider error if best-effort status recording fails.
    private func recordBankSyncFailure(
        _ error: Error,
        links: [BankSyncLinkIdentity],
        generations: [String: UUID],
        database: BudgetDatabase,
        budgetID: String
    ) async {
        guard !error.isCancellation, !Task.isCancelled,
              error is ActualAPIError || error is SimpleFINBridgeError else { return }
        if case ActualAPIError.invalidURL = error { return }
        if case ActualAPIError.localNetworkDenied = error { return }
        let status: ActualBankSyncDurableStatus
        if case ActualAPIError.transport(.timedOut) = error { status = .timedOut }
        else if case SimpleFINBridgeError.accessRevoked = error { status = .reauthRequired }
        else { status = .failed }
        for link in links {
            guard store.database === database, store.bankSyncGenerationByAccount[link.accountID] == generations[link.accountID] else { continue }
            var builder = LocalFirstSyncMessageBuilder()
            do {
                let messages = try await BankSyncRunSQL.makeBankSyncCompletionMessages(
                    accountID: link.accountID,
                    lastSyncEpochMilliseconds: nil,
                    status: status,
                    balanceDisposition: .preserve,
                    builder: &builder,
                    in: database
                )
                guard store.database === database, store.bankSyncGenerationByAccount[link.accountID] == generations[link.accountID] else { continue }
                store.bankSyncGenerationByAccount[link.accountID] = nil
                _ = try await BankSyncRunSQL.commitBankSyncMessages(messages, expectedLink: link, in: database)
                try await store.finishCommittedAccountWrite(database: database, budgetID: budgetID)
            } catch {
                // Stale links and rolled-back status writes have no durable effects.
                // The caller still reports the original provider failure.
            }
        }
    }

    private func makeBankSyncPlan(
        account: BankSyncLinkSQL.BankSyncLinkedAccount,
        link: BankSyncLinkIdentity,
        generation: UUID,
        prepared: BankSyncDownloadPreparation.Prepared,
        remote: SimpleFINRemoteAccount?,
        currency: BudgetCurrency,
        payeeNames: [String: String],
        categoryNames: [String: String],
        accountHadLiveTransactions: Bool,
        database: BudgetDatabase
    ) async throws -> BankSyncReview.AccountPlan {
        let candidateDayIDs = prepared.candidates.map(\.dayID)
        let outcome = try await ImportReconcileSteps.reconcileProjectedImport(
            database: database,
            accountID: account.id,
            accountIsOffBudget: account.offbudget,
            candidateDayIDs: candidateDayIDs,
            importedIDs: Set(prepared.candidates.compactMap(\.financialID)),
            projected: prepared.projectedCandidates,
            options: .bankSync
        )
        let existing = outcome.existing
        let reconciliation = outcome.plan

        let inserts = reconciliation.inserts
        let balanceDisposition = BankSyncBalancePlanning.disposition(
            download: prepared.download,
            fallbackRemote: remote,
            currency: currency
        )
        let openingBalance: BankSyncReconciliation.OpeningBalance?
        if prepared.problems.isEmpty,
           case .set(let currentBalance) = balanceDisposition {
            openingBalance = BankSyncReconciliation.openingBalance(
                currentBalanceMinorUnits: currentBalance,
                inserts: inserts,
                earliestDayID: candidateDayIDs.min(),
                accountHadLiveTransactions: accountHadLiveTransactions
            )
        } else {
            openingBalance = nil
        }

        let updates = outcome.matchedUpdates
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

        return BankSyncReview.AccountPlan(
            link: link,
            durableStatus: ActualBankSyncDurableStatus.from(
                errorCode: prepared.download.errorCode
            ),
            inserts: inserts,
            updates: updates,
            matchDetails: matchDetails,
            unchangedCount: reconciliation.entries.reduce(0) { count, entry in
                switch entry {
                case .unchanged, .skippedDeleted: return count + 1
                case .insert, .update: return count
                }
            },
            problems: prepared.problems,
            openingBalance: openingBalance,
            balanceDisposition: balanceDisposition,
            generation: generation,
            reviewedRows: outcome.reviewedRows
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
                currentBalance: download?.currentBalance,
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
        if let cached = store.currencyByBudget[budgetID] {
            return cached
        }
        return try await BudgetCurrencySQL.fetchBudgetCurrency(in: database)
    }

    /// Calendar-based read window around downloaded days. The reconciler owns
    /// the exact ±7-day check; this query bound ensures it receives eligible
    /// rows across month/year boundaries and leap days.
    static func monthWidenedWindow(
        candidateDayIDs: [String]
    ) -> ClosedRange<Int> {
        guard let firstID = candidateDayIDs.min(),
              let lastID = candidateDayIDs.max(),
              let first = BankSyncAmounts.date(fromDayID: firstID, timeZone: ActualDateOnly.utc),
              let last = BankSyncAmounts.date(fromDayID: lastID, timeZone: ActualDateOnly.utc) else {
            return 0...99_999_999
        }
        let calendar = Calendar.actualScheduleGregorian
        guard let lowerDate = calendar.date(byAdding: .day, value: -7, to: first),
              let upperDate = calendar.date(byAdding: .day, value: 7, to: last),
              let lower = Int(BankSyncAmounts.dayID(fromUnixSeconds: Int64(lowerDate.timeIntervalSince1970))),
              let upper = Int(BankSyncAmounts.dayID(fromUnixSeconds: Int64(upperDate.timeIntervalSince1970))) else {
            return 0...99_999_999
        }
        return lower...upper
    }
}
