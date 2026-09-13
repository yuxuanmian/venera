/// Mapping declaration and comparable-label computation.
///
/// Contract: `specs/005-tracking-reconnect/contracts/comparability-v1.md`
/// (Contract C0 terminology, C1 declaration shape, C2 known fields,
/// C3 declaration values, C4 granularity marker, C5 normalization,
/// C6 validity table, C7 label-change semantics).
///
/// The label is an opaque host-internal string derived from a source's
/// `fieldSource` declaration.  It never enters an observation payload and is
/// never parsed back into a declaration.
library;

/// The closed set of standard field names a declaration key may use
/// (Contract C2).  Any other key makes the whole declaration invalid.
const Set<String> comparableLabelKnownFields = {
  'updatedAt',
  'latestChapterId',
  'chapterCount',
  'recentChapterIds',
  'sourceUnread',
};

/// Granularity suffixes allowed only on `updatedAt` (Contract C4).
const Set<String> comparableLabelGranularities = {'day', 'instant'};

/// Outcome of validating one branch declaration (Contract C6).
class ComparableLabelValidation {
  const ComparableLabelValidation._(this.isValid, this.reason);

  const ComparableLabelValidation.valid() : this._(true, null);

  const ComparableLabelValidation.invalid(String reason)
    : this._(false, reason);

  final bool isValid;
  final String? reason;

  @override
  String toString() => isValid ? 'valid' : 'invalid: $reason';
}

/// Normalization and comparison of mapping declarations (Contract C5).
abstract final class ComparableLabel {
  /// Computes the canonical label of a declaration.
  ///
  /// Steps (Contract C5): trim + lowercase every value, sort by key, skip
  /// key/value pairs that normalization makes invalid, then join into a
  /// whitespace-free canonical JSON shape.
  ///
  /// Separator folding is deliberately *not* performed: `last_chapter.id`
  /// and `last-chapter.id` stay distinct labels.
  static String of(Map<String, String> declaration) {
    final keys = declaration.keys.toList()..sort();
    final parts = <String>[];
    for (final key in keys) {
      final value = declaration[key];
      if (value is! String) continue;
      final normalized = value.trim().toLowerCase();
      if (normalized.isEmpty) continue;
      if (!comparableLabelKnownFields.contains(key)) continue;
      parts.add('${_encode(key)}:${_encode(normalized)}');
    }
    return '{${parts.join(',')}}';
  }

  /// Whether a recorded label still describes the current declaration.
  ///
  /// A missing recorded label means "no previous evidence" (Contract C7), so
  /// it never matches.
  static bool matches(String? recorded, String current) {
    if (recorded == null) return false;
    return recorded == current;
  }

  /// Validates a raw declaration against the Contract C6 table.
  static ComparableLabelValidation validate(Object? declaration) {
    if (declaration == null) {
      return const ComparableLabelValidation.invalid('declaration is required');
    }
    if (declaration is! Map) {
      return const ComparableLabelValidation.invalid(
        'declaration must be an object',
      );
    }
    if (declaration.isEmpty) {
      return const ComparableLabelValidation.invalid(
        'declaration must declare at least one field',
      );
    }
    for (final entry in declaration.entries) {
      final key = entry.key;
      if (key is! String) {
        return const ComparableLabelValidation.invalid(
          'declaration keys must be strings',
        );
      }
      if (!comparableLabelKnownFields.contains(key)) {
        return ComparableLabelValidation.invalid('unknown field: $key');
      }
      final value = entry.value;
      if (value is! String) {
        return ComparableLabelValidation.invalid(
          'field $key must map to a string',
        );
      }
      final normalized = value.trim();
      if (normalized.isEmpty) {
        return ComparableLabelValidation.invalid('field $key is empty');
      }
      final granularity = _granularityOf(normalized);
      if (granularity == null) continue;
      // The suffix is only a granularity when it is attached to a source
      // description: `updated_at@day` declares one, `@day` does not.
      if (_descriptionOf(normalized).isEmpty) {
        return ComparableLabelValidation.invalid(
          'field $key has no source description',
        );
      }
      if (key != 'updatedAt') {
        return ComparableLabelValidation.invalid(
          'only updatedAt may carry a granularity',
        );
      }
      if (!comparableLabelGranularities.contains(granularity)) {
        return ComparableLabelValidation.invalid(
          'unknown granularity: $granularity',
        );
      }
    }
    return const ComparableLabelValidation.valid();
  }

  /// Extracts the declared granularity suffix of a declaration value, or null
  /// when the value carries none.
  ///
  /// The host never evaluates the declaration value itself (Contract C3); this
  /// only reads the `@`-suffix defined by Contract C4.  C4 assigns the
  /// granularity three consumers: source-side verification, Debug showing a
  /// source's comparison precision, and identifying sources that do not meet
  /// the future standard evidence form.  The value also travels inside the
  /// label, so this reader exists for those consumers rather than for the
  /// comparison engine itself.
  static String? granularityOf(String key, String value) {
    if (key != 'updatedAt') return null;
    return _granularityOf(value.trim());
  }

  static String? _granularityOf(String value) {
    final index = value.indexOf('@');
    if (index < 0) return null;
    return value.substring(index + 1).trim().toLowerCase();
  }

  static String _descriptionOf(String value) {
    final index = value.indexOf('@');
    final description = index < 0 ? value : value.substring(0, index);
    return description.trim();
  }

  static String _encode(String value) {
    final buffer = StringBuffer('"');
    for (final rune in value.runes) {
      switch (rune) {
        case 0x22:
          buffer.write(r'\"');
        case 0x5c:
          buffer.write(r'\\');
        case 0x08:
          buffer.write(r'\b');
        case 0x0c:
          buffer.write(r'\f');
        case 0x0a:
          buffer.write(r'\n');
        case 0x0d:
          buffer.write(r'\r');
        case 0x09:
          buffer.write(r'\t');
        default:
          if (rune < 0x20) {
            buffer.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
          } else {
            buffer.writeCharCode(rune);
          }
      }
    }
    buffer.write('"');
    return buffer.toString();
  }
}
