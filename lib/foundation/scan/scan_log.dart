/// Log labels for scan requests, and the two per-round overviews.
///
/// Contract: `specs/007-follow-up-closeout/contracts/scan-log-v1.md` (L1–L8).
///
/// Everything here is a **pure function**: labels and overview text are built
/// from values that are already in hand, so the whole contract is testable
/// without a database, a network stack or a log sink.  Nothing here reads a
/// clock, a store or a source.
///
/// The purpose is narrow and worth stating: a scan request log line used to be
/// anonymous (`Scan GET started`), which made "which source, which comic / which
/// page?" unanswerable.  It is now answerable from the log alone — and the label
/// is the *only* thing added, so a log line's structure and count do not change
/// (L8).
library;

import 'models.dart';

/// The hard cap on a label's **identity hint**, in characters (L4).
///
/// Ten, by contract, and it applies to the name — or to the identity prefix that
/// replaces it — **not** to the source key.  The source key is the other half of
/// the prefix and is host-owned configuration, so it is cleaned but not
/// truncated to ten; shortening it would make two sources indistinguishable.
const int kScanLogLabelMaxChars = 10;

/// A generous cap for the host-owned source key half of a label.
///
/// Not a security boundary — the key comes from configuration, not from a
/// source — only a guard against an absurd value making every log line
/// unreadable.
const int _kScanLogSourceMaxChars = 64;

/// Removes anything that could restructure a log line or smuggle a secret into
/// it, then truncates **by character**.
///
/// Contract L5 and L7 make this the boundary that source-provided text has to
/// pass:
///
///  * newlines, tabs and control characters become spaces or are dropped, so
///    nothing can forge a second log line;
///  * Unicode line/paragraph separators and bidirectional overrides are dropped
///    for the same reason — they are control characters that happen to be
///    printable;
///  * truncation counts **characters, not bytes**, so a Chinese name is never
///    cut in half;
///  * text that is, or contains, a URL, a bare hostname or a credential-shaped
///    `key=value` is **dropped entirely** rather than shortened.  A shortened
///    URL is still a URL, and comic names are source-provided, so the fail-closed
///    answer is to fall back to the identity prefix instead.
String sanitizeLabel(String? raw, {int maxChars = kScanLogLabelMaxChars}) {
  if (raw == null) return '';
  final cleaned = StringBuffer();
  for (final rune in raw.runes) {
    if (rune == 0x09 || rune == 0x0A || rune == 0x0D) {
      cleaned.write(' ');
      continue;
    }
    // C0/C1 controls, DEL, line/paragraph separators, bidi overrides.
    if (rune < 0x20 || rune == 0x7F) continue;
    if (rune >= 0x80 && rune <= 0x9F) continue;
    if (rune == 0x2028 || rune == 0x2029) continue;
    if (rune >= 0x202A && rune <= 0x202E) continue;
    if (rune >= 0x2066 && rune <= 0x2069) continue;
    cleaned.writeCharCode(rune);
  }
  final text = cleaned.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  if (_carriesForbiddenContent(text)) return '';
  return _truncateByCharacter(text, maxChars);
}

/// `sourceKey` + this comic's short name hint (L4).
///
/// The hint is the comic's display name when one is available, and the identity
/// itself otherwise — both through [sanitizeLabel], so both are capped and
/// cleaned the same way.  A name that cannot be used (missing, blank, or
/// forbidden by [sanitizeLabel]) falls back to the identity, which is the
/// documented "名称不可得" path.
String comicLabel(String sourceKey, String? displayName, String comicId) {
  final source = _sourcePart(sourceKey);
  var hint = sanitizeLabel(displayName);
  if (hint.isEmpty) hint = sanitizeLabel(comicId);
  return _join(source, hint);
}

/// `sourceKey` + a collection page's ordinal, from 1 (L4).
///
/// A consistency re-check of the same page is a separate call and must be
/// distinguishable from the data page, so it carries an extra marker.  The
/// current acquisition kernel performs no such call; the parameter exists so
/// that adding one cannot silently produce two identical log lines.
String pageLabel(String sourceKey, int pageOrdinal, {bool verify = false}) {
  final source = _sourcePart(sourceKey);
  final ordinal = pageOrdinal < 1 ? 1 : pageOrdinal;
  return _join(source, verify ? 'p$ordinal verify' : 'p$ordinal');
}

/// One source's line in the plan overview (L1).
class ScanPlanSourceLine {
  const ScanPlanSourceLine({
    required this.sourceKey,
    required this.unit,
    required this.workCount,
  });

  final String sourceKey;

  /// The acquisition unit: `comic` or `collection`.
  final String unit;

  final int workCount;

  @override
  String toString() => '$sourceKey $unit x$workCount';
}

/// The **plan** overview: at most two lines, independent of the work count (L1,
/// L8).
///
/// Line 1 answers "what is this round going to do": participating sources, each
/// one's work count and unit, and the count before and after the due rule
/// narrowed the list — the latter is what answers "why so few?".
///
/// [trigger] and [scopeSourceKeys] answer the question that the work counts
/// cannot: **who asked for this round, and which sources was it allowed to
/// visit** (`null` = every configured source).  Without them, `works=1/141`
/// looks the same whether the round really was one collection or whether a
/// hundred per-comic works were dropped by the due rule — which is exactly the
/// shape a "why is this source being scanned again?" investigation needs to tell
/// apart (Contract F1.4).
///
/// Line 2 answers "what was left out and why", by reason class (L3).  A single
/// total would not; the classification is the point.
///
/// No comic name appears here: per-comic identities appear only as the short
/// request-log prefixes of L4, which is what keeps this overview constant-sized.
List<String> formatPlanOverview({
  required List<ScanPlanSourceLine> perSource,
  required int worksBeforeNarrowing,
  required int worksAfterNarrowing,
  required Map<ScanSourceSkipReason, List<String>> skippedByReason,
  String? trigger,
  Set<String>? scopeSourceKeys,
}) {
  final units = perSource.map((line) => line.toString()).join('; ');
  final skippedTotal = skippedByReason.values.fold<int>(
    0,
    (sum, keys) => sum + keys.length,
  );
  final reasonCounts = ScanSourceSkipReason.values
      .map(
        (reason) => '${reason.value}=${skippedByReason[reason]?.length ?? 0}',
      )
      .join(' ');
  final skippedDetail = ScanSourceSkipReason.values
      .where((reason) => (skippedByReason[reason] ?? const []).isNotEmpty)
      .map((reason) => '${reason.value}: ${skippedByReason[reason]!.join(',')}')
      .join('; ');
  // Omitted entirely when the caller does not name a trigger — the Debug
  // "force scan all" entry point scans without one, and its line shape is
  // deliberately unchanged (L8).
  final attribution = trigger == null
      ? ''
      : ' trigger=${sanitizeLabel(trigger, maxChars: _kScanLogSourceMaxChars)}'
            ' scope=${_scopePart(scopeSourceKeys)}';
  return [
    'scan plan: sources=${perSource.length} works=$worksAfterNarrowing/'
        '$worksBeforeNarrowing${units.isEmpty ? '' : ' units: $units'}'
        '$attribution',
    'scan plan skipped: total=$skippedTotal $reasonCounts'
        '${skippedDetail.isEmpty ? '' : ' [$skippedDetail]'}',
  ];
}

/// The scope half of the plan line: `all`, `none`, or the sorted source keys.
///
/// Sorted so the line is stable across runs, and cleaned through the same
/// boundary as every other configuration-derived value (L5/L7) — a source key is
/// host-owned configuration, but it still must not be able to restructure a log
/// line.
String _scopePart(Set<String>? scopeSourceKeys) {
  if (scopeSourceKeys == null) return 'all';
  final cleaned =
      scopeSourceKeys
          .map((key) => sanitizeLabel(key, maxChars: _kScanLogSourceMaxChars))
          .where((key) => key.isNotEmpty)
          .toList()
        ..sort();
  return cleaned.isEmpty ? 'none' : cleaned.join(',');
}

/// The **settlement** overview: exactly one line (L2, L8).
///
/// [elapsedMs] is the whole round's wall-clock time — from the round's start to
/// its close — and deliberately not the sum of the individual request times: the
/// sum would answer a different question ("how much time went into requests?")
/// and would hide the queueing and judgment time that dominates a round.
List<String> formatSettlementOverview({
  required ScanProgress progress,
  required int elapsedMs,
  String? disposition,
}) {
  return [
    'scan round settled: discovered=${progress.discoveredWorks} '
        'succeeded=${progress.succeededWorks} failed=${progress.failedWorks} '
        'canceled=${progress.canceledWorks} '
        'persisted=${progress.persistedItems} elapsed=${elapsedMs}ms'
        '${disposition == null ? '' : ' disposition=$disposition'}',
  ];
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

String _join(String source, String hint) {
  if (source.isEmpty) return hint;
  if (hint.isEmpty) return source;
  return '$source $hint';
}

/// The source key half: cleaned, but not held to the identity-hint cap.
String _sourcePart(String sourceKey) =>
    sanitizeLabel(sourceKey, maxChars: _kScanLogSourceMaxChars);

String _truncateByCharacter(String text, int maxChars) {
  if (maxChars <= 0 || text.isEmpty) return '';
  final runes = text.runes.toList();
  if (runes.length <= maxChars) return text;
  return String.fromCharCodes(runes.take(maxChars));
}

/// Whether [text] would carry something the scan log must never contain (L7).
///
/// Fail-closed on purpose: a false positive costs a fallback to the identity
/// prefix, while a false negative puts source-provided text into a log line.
bool _carriesForbiddenContent(String text) {
  if (text.isEmpty) return false;
  final lower = text.toLowerCase();
  // A scheme, or the `www.` shorthand, anywhere in the text.
  if (RegExp(r'[a-z][a-z0-9+.\-]*://').hasMatch(lower)) return true;
  if (lower.contains('www.')) return true;
  // A bare hostname: labels are short, so a dotted TLD-shaped suffix is enough.
  if (RegExp(
    r'[a-z0-9\-]+(\.[a-z0-9\-]+)*\.(com|net|org|edu|gov|cn|io|me|tv|xyz|info|biz|dev|app|co|uk|jp|kr|ru|de|fr)\b',
  ).hasMatch(lower)) {
    return true;
  }
  // Credential- or header-shaped text.
  if (RegExp(
    r'(^|[^a-z])(cookie|set-cookie|authorization|bearer|token|password|passwd|secret|api[-_]?key)[=:\s]',
  ).hasMatch(lower)) {
    return true;
  }
  return false;
}
