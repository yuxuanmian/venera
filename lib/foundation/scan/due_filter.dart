import 'full_scan_planner.dart';
import 'target_provider.dart';

/// Computes the complete due set for one source (Contract S4).
///
/// The due condition is a disjunction of four:
///
/// ```
/// 到期(条目) ⇔  无对应观测
///            ∨  无对应排期记录
///            ∨  next_at 为空
///            ∨  next_at <= now
/// ```
///
/// The schedule store can answer the last two alone; the first two need the
/// observation store as well.  This function is the **only** place that merges
/// them, which is why it lives in the composition layer rather than in either
/// domain: the schedule store does not know what an observation is, and the
/// acquisition store does not know what a schedule is.
///
/// Two consequences that must not be "optimized away":
///
/// 1. **"no observation" outranks a schedule record.**  A row claiming "not due
///    yet" whose observation is gone is still due.  That is what makes deleting
///    the observation database a safe recovery action instead of leaving the
///    device spinning on a schedule for evidence that no longer exists.
/// 2. **Collection-type sources never need a special case.**  They write no
///    schedule rows (S2), so every one of their comics satisfies "no schedule
///    record" and stays due forever.  There is deliberately no
///    `if (producer == collection)` branch anywhere — the exclusion falls out
///    of the data.
class ScanDueSet {
  const ScanDueSet({
    required this.dueComicIds,
    required this.observedComicIds,
    required this.scheduledComicIds,
  });

  /// The comic ids that should be scanned this round.
  final Set<String> dueComicIds;

  /// Every comic id with a stored observation, for diagnostics.
  final Set<String> observedComicIds;

  /// Every comic id with a stored schedule row, for diagnostics.
  final Set<String> scheduledComicIds;
}

/// The complete due set (Contract S4), merged in one place.
///
/// Inputs, all already read — this function performs no I/O and reads no clock:
///
/// * [allComicIds] — the domain in scope this round (from the favorite cache).
/// * [observedComicIds] — the subset the observation store holds.
/// * [expiredComicIds] — what the schedule store answered alone: rows whose
///   `next_at` is null or already reached (`readExpired`).
/// * [futureScheduledComicIds] — rows the schedule store holds whose `next_at`
///   is still in the future.  Together with [expiredComicIds] this is exactly
///   "has a schedule record".
///
/// Read the body as the four disjuncts of S4:
///
/// | # | condition | how it is applied |
/// | --- | --- | --- |
/// | 1 | no observation | `!observedComicIds.contains(...)` |
/// | 2 | no schedule record | `!scheduled.contains(...)` |
/// | 3 | `next_at` is null | inside [expiredComicIds] |
/// | 4 | `next_at <= now` | inside [expiredComicIds] |
///
/// Conditions 3 and 4 arrive pre-answered because only the schedule store can
/// answer them.
///
/// The tempting simplification is `due = expiredComicIds`.  It passes every
/// test that only ever stores comics which already have schedule rows, and
/// breaks the moment the observation store is emptied: a surviving schedule row
/// saying "not due yet" would suppress an identity that has no evidence left,
/// so the comic is never re-read and the device spins on a schedule for data
/// that no longer exists.
ScanDueSet computeDueComicIds({
  required Set<String> allComicIds,
  required Set<String> observedComicIds,
  required Set<String> expiredComicIds,
  required Set<String> futureScheduledComicIds,
}) {
  final scheduled = <String>{...expiredComicIds, ...futureScheduledComicIds};
  final due = <String>{};
  for (final comicId in allComicIds) {
    // 1: nothing was ever observed for this identity.
    if (!observedComicIds.contains(comicId)) {
      due.add(comicId);
      continue;
    }
    // 2 ∨ 3 ∨ 4.
    if (!scheduled.contains(comicId) || expiredComicIds.contains(comicId)) {
      due.add(comicId);
    }
  }
  return ScanDueSet(
    dueComicIds: due,
    observedComicIds: observedComicIds,
    scheduledComicIds: scheduled,
  );
}

/// Narrows a target snapshot to the identities that are actually due.
///
/// `ScanTargetSnapshot` is the acquisition domain's frozen work list.  Dropping
/// entries is the only thing this does: it never adds work, never reorders, and
/// never inspects a source's producer type.  A collection-type work item is
/// therefore always kept, not because it is special-cased but because its
/// identity is never a member of a per-comic due set — see [ScanDueSet].
///
/// [dueComicIdsBySource] must already hold the complete due set for each
/// source; this function performs no I/O.
ScanTargetSnapshot filterTargetsByDue({
  required ScanTargetSnapshot snapshot,
  required Map<String, Set<String>> dueComicIdsBySource,
}) {
  final kept = <ScanWorkSpec>[];
  for (final work in snapshot.works) {
    // Only per-comic work carries a comic id to test.  A work item without one
    // cannot be expressed in a schedule table keyed by `(source, comic)` at
    // all, so it is always in scope.
    final comicId = work.comicId;
    if (comicId == null) {
      kept.add(work);
      continue;
    }
    final due = dueComicIdsBySource[work.sourceKey];
    if (due != null && due.contains(comicId)) kept.add(work);
  }
  return ScanTargetSnapshot(
    works: kept,
    cacheGeneration: snapshot.cacheGeneration,
    skippedSources: snapshot.skippedSources,
  );
}
