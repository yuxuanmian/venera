import 'judgment_state.dart';

/// Judgment state storage boundary.
///
/// Contract: `specs/005-tracking-reconnect/plan.md` (stable interfaces) and
/// `specs/005-tracking-reconnect/data-model.md` section 2.
///
/// The interface deliberately exposes no transaction primitive: the
/// all-or-nothing batch is an implementation detail.  It also has no
/// `replay()`; a full rerun is `clear()` followed by `run()`.
abstract class JudgmentStateRepository {
  /// Opens (and creates/migrates) the judgment state database.
  Future<void> ensureOpen();

  /// Reads every stored state, keyed by `(sourceKey, comicId)`.
  Future<Map<String, JudgmentState>> readSnapshot();

  /// Reads one state, or null when this identity has never been judged.
  Future<JudgmentState?> readFor(String sourceKey, String comicId);

  /// Writes the batch inside one transaction and returns the row count.
  ///
  /// Only judgment-owned columns may be written; see the implementation for
  /// the explicit column ownership note.
  Future<int> applyBatch(List<JudgmentState> rows);

  /// Deletes every judgment state row.  Scan evidence is untouched.
  Future<void> clear();

  Future<void> close();
}

/// Raised when the judgment state store cannot be read or written.
///
/// Kept distinct from scan acquisition and scan storage failures so Debug can
/// attribute the failure correctly (data-model section 4).
class JudgmentStorageException implements Exception {
  const JudgmentStorageException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'Judgment storage error: $message';
}
