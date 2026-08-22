import 'dart:convert';

const Duration kFollowUpdateHotWindow = Duration(days: 14);
const Duration kFollowUpdateHotInterval = Duration(hours: 12);

/// The first age at which the one-time legacy jitter is applied.
///
/// Keep this as the single source of truth for both scheduling and the
/// reset/rewind paths in the cache state layer.
const Duration kFollowUpdateOldScheduleJitterAge = Duration(days: 731);

const _normalScheduleBands = <({Duration beforeAge, Duration interval})>[
  (beforeAge: Duration(days: 184), interval: Duration(hours: 24)),
  (beforeAge: Duration(days: 366), interval: Duration(days: 2)),
  (beforeAge: Duration(days: 488), interval: Duration(days: 3)),
  (beforeAge: Duration(days: 610), interval: Duration(days: 4)),
  (beforeAge: Duration(days: 731), interval: Duration(days: 5)),
  (beforeAge: Duration(days: 1461), interval: Duration(days: 7)),
];

/// Returns the ordinary follow-up interval for elapsed activity age.
///
/// The comparison is duration-based so leap years and calendar boundaries do
/// not change the documented thresholds.
Duration normalIntervalFor({
  required DateTime now,
  required DateTime effectiveActivityAt,
}) {
  final age = now.difference(effectiveActivityAt);
  if (age.isNegative) return const Duration(hours: 24);
  for (final band in _normalScheduleBands) {
    if (age < band.beforeAge) return band.interval;
  }
  return const Duration(days: 14);
}

bool isAutoHotActive({required DateTime now, DateTime? autoHotUntil}) =>
    autoHotUntil != null && autoHotUntil.isAfter(now);

bool isManualHotActive({
  required DateTime now,
  required bool manualHotEnabled,
  DateTime? manualHotUntil,
}) => manualHotEnabled && manualHotUntil != null && manualHotUntil.isAfter(now);

bool isHotActive({
  required DateTime now,
  DateTime? autoHotUntil,
  required bool manualHotEnabled,
  DateTime? manualHotUntil,
}) =>
    isAutoHotActive(now: now, autoHotUntil: autoHotUntil) ||
    isManualHotActive(
      now: now,
      manualHotEnabled: manualHotEnabled,
      manualHotUntil: manualHotUntil,
    );

DateTime? effectiveHotUntil({
  DateTime? autoHotUntil,
  DateTime? manualHotUntil,
  bool manualHotEnabled = true,
  required DateTime now,
}) {
  final activeUntil = [
    if (isAutoHotActive(now: now, autoHotUntil: autoHotUntil)) autoHotUntil!,
    if (isManualHotActive(
      now: now,
      manualHotEnabled: manualHotEnabled,
      manualHotUntil: manualHotUntil,
    ))
      manualHotUntil!,
  ];
  if (activeUntil.isEmpty) return null;
  return activeUntil.reduce((a, b) => a.isAfter(b) ? a : b);
}

class ScheduleDecision {
  const ScheduleDecision({
    required this.hotActive,
    required this.interval,
    required this.nextCheckAt,
    required this.appliedOldScheduleJitter,
  });

  final bool hotActive;
  final Duration interval;
  final DateTime nextCheckAt;
  final bool appliedOldScheduleJitter;
}

/// Computes the next schedule from one captured completion time.
ScheduleDecision computeNextSchedule({
  required DateTime completedAt,
  required DateTime effectiveActivityAt,
  DateTime? autoHotUntil,
  required bool manualHotEnabled,
  DateTime? manualHotUntil,
  required bool oldScheduleJitterApplied,
  required String sourceKey,
  required String comicId,
}) {
  final hot = isHotActive(
    now: completedAt,
    autoHotUntil: autoHotUntil,
    manualHotEnabled: manualHotEnabled,
    manualHotUntil: manualHotUntil,
  );
  final interval = hot
      ? kFollowUpdateHotInterval
      : normalIntervalFor(
          now: completedAt,
          effectiveActivityAt: effectiveActivityAt,
        );
  var jitterApplied = oldScheduleJitterApplied;
  var offset = Duration.zero;
  if (!hot && !oldScheduleJitterApplied) {
    final age = completedAt.difference(effectiveActivityAt);
    if (age >= kFollowUpdateOldScheduleJitterAge) {
      final offsetDays = stableFollowUpdateJitterDays(sourceKey, comicId);
      offset = Duration(days: offsetDays);
      jitterApplied = true;
    }
  }
  final next = completedAt.add(interval).add(offset);
  return ScheduleDecision(
    hotActive: hot,
    interval: interval,
    nextCheckAt: next.isBefore(completedAt) ? completedAt : next,
    appliedOldScheduleJitter: jitterApplied,
  );
}

/// Stable -2..+2 day offset for old comics. Do not replace this with
/// [Object.hash] or [String.hashCode], both of which are not a persistence
/// contract across Dart processes.
int stableFollowUpdateJitterDays(String sourceKey, String comicId) {
  final bytes = utf8.encode('$sourceKey\u0000$comicId');
  var hash = 0x811c9dc5;
  for (final byte in bytes) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash % 5 - 2;
}

bool _isValidCalendarDate(int year, int month, int day) {
  final normalized = DateTime.utc(year, month, day);
  return normalized.year == year &&
      normalized.month == month &&
      normalized.day == day;
}

DateTime? parseFollowUpdateActivityTime(
  String? value, {
  required DateTime now,
}) {
  if (value == null || value.trim().isEmpty) return null;
  final text = value.trim();
  try {
    DateTime? parsed;
    final epoch = int.tryParse(text);
    if (epoch != null) {
      final milliseconds = epoch.abs() < 100000000000 ? epoch * 1000 : epoch;
      parsed = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    } else {
      final dateOnly = RegExp(
        r'^(\d{4})-(\d{1,2})-(\d{1,2})$',
      ).firstMatch(text);
      if (dateOnly != null) {
        final year = int.parse(dateOnly.group(1)!);
        final month = int.parse(dateOnly.group(2)!);
        final day = int.parse(dateOnly.group(3)!);
        if (!_isValidCalendarDate(year, month, day)) return null;
        parsed = DateTime(year, month, day);
      } else {
        final isoDate = RegExp(
          r'^(\d{4})-(\d{2})-(\d{2})(?=[Tt ]|$)',
        ).firstMatch(text);
        if (isoDate != null &&
            !_isValidCalendarDate(
              int.parse(isoDate.group(1)!),
              int.parse(isoDate.group(2)!),
              int.parse(isoDate.group(3)!),
            )) {
          return null;
        }
        parsed = DateTime.tryParse(text);
      }
    }
    if (parsed == null) return null;
    final earliest = DateTime(2000);
    final latest = now.add(const Duration(hours: 24));
    if (parsed.isBefore(earliest) || parsed.isAfter(latest)) return null;
    return parsed;
  } on Object {
    // DateTime.fromMillisecondsSinceEpoch and DateTime constructors can throw
    // for values outside the platform range. Old source metadata must never
    // make database initialization fail.
    return null;
  }
}

DateTime? chooseFollowUpdateActivityTime({
  String? updateTime,
  String? uploadTime,
  required DateTime now,
}) =>
    parseFollowUpdateActivityTime(updateTime, now: now) ??
    parseFollowUpdateActivityTime(uploadTime, now: now);
