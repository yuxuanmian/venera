class FollowUpdateMarkerParts {
  final String scheme;
  final String value;

  const FollowUpdateMarkerParts({required this.scheme, required this.value});

  bool get isVersioned => scheme != 'v1';
}

bool _isFollowUpdateMarkerScheme(String value) =>
    RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(value) && !value.contains('|');

String encodeFollowUpdateMarker(String markerScheme, String rawMarker) {
  if (!_isFollowUpdateMarkerScheme(markerScheme)) {
    throw ArgumentError.value(markerScheme, 'markerScheme');
  }
  return '$markerScheme|$rawMarker';
}

FollowUpdateMarkerParts decodeFollowUpdateMarker(String marker) {
  final separator = marker.indexOf('|');
  if (separator > 0) {
    final prefix = marker.substring(0, separator);
    if (_isFollowUpdateMarkerScheme(prefix)) {
      return FollowUpdateMarkerParts(
        scheme: prefix,
        value: marker.substring(separator + 1),
      );
    }
  }
  return FollowUpdateMarkerParts(scheme: 'v1', value: marker);
}

bool hasSameSchemeMarkerChanged(String? previous, String? candidate) {
  if (previous == null ||
      previous.isEmpty ||
      candidate == null ||
      candidate.isEmpty) {
    return false;
  }
  final previousParts = decodeFollowUpdateMarker(previous);
  final candidateParts = decodeFollowUpdateMarker(candidate);
  return previousParts.scheme == candidateParts.scheme && previous != candidate;
}
