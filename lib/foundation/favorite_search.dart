/// Builds the normalized, partial-match text stored with a cached favorite.
///
/// The same contract is used by in-memory cache search and follow-up SQL so a
/// local query cannot drift from what was written to `favorite_items`.
String buildFavoriteSearchText(String comicId, Map<String, dynamic> json) {
  final tags = json['tags'];
  final tagValues = tags is Iterable
      ? tags.map((tag) => tag.toString())
      : const Iterable<String>.empty();
  return normalizeFavoriteSearchText(
    [
      comicId,
      json['title']?.toString() ?? '',
      json['subTitle']?.toString() ?? json['subtitle']?.toString() ?? '',
      ...tagValues,
    ].join(' '),
  );
}

/// The normalized token list used for every cached favorite search.
List<String> favoriteSearchTokens(String query) => normalizeFavoriteSearchText(
  query,
).split(' ').where((token) => token.isNotEmpty).toList();

/// Escapes a token for a `LIKE ... ESCAPE '\'` expression.
String escapeFavoriteSearchLikeToken(String value) => value
    .replaceAll('\\', '\\\\')
    .replaceAll('%', '\\%')
    .replaceAll('_', '\\_');

/// Applies the cache's existing title/author/tag normalization rules.
String normalizeFavoriteSearchText(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'[\s\-_.\\/:|,，。；;、（）()\[\]{}]+'), ' ')
    .trim();
