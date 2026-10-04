import Foundation

/// Typed errors that `commitLocalPlan` rethrows unchanged instead of replacing
/// them with the generic "database transaction was rolled back" failure. Any
/// error type a plan can throw for callers to match on conforms here; anything
/// else (for example a SQLite error) is still wrapped.
protocol LocalCommitPassthroughError: Error {}

extension LocalFirstError: LocalCommitPassthroughError {}
extension BudgetModeWriteError: LocalCommitPassthroughError {}
extension ReconciledTransactionMutationError: LocalCommitPassthroughError {}
extension AccountLifecycleCommandError: LocalCommitPassthroughError {}
extension ScheduleMutationCommandError: LocalCommitPassthroughError {}
extension ScheduleConversionError: LocalCommitPassthroughError {}
extension SchedulePostingRefusal: LocalCommitPassthroughError {}
extension TransactionCSVImportError: LocalCommitPassthroughError {}

/// A plan that calls `Task.checkCancellation()` must surface as cancellation, not as a failed write.
extension CancellationError: LocalCommitPassthroughError {}
