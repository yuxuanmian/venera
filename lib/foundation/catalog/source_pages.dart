import '../comic_source/comic_source.dart';

/// Adds supported defaults only when the user has no existing page selection.
/// Returns a patch without mutating the supplied settings or their lists.
Map<String, dynamic> defaultSourcePages(
  Map<String, dynamic> settings,
  ComicSource source,
) {
  final defaults = <String, List<String>>{
    'explore_pages': source.explorePages.map((page) => page.title).toList(),
    'categories': [if (source.categoryData != null) source.categoryData!.key],
    'favorites': [if (source.favoriteData != null) source.favoriteData!.key],
    'searchSources': [if (source.searchPageData != null) source.key],
  };
  for (final entry in defaults.entries) {
    final current = settings[entry.key] as List? ?? const [];
    if (entry.value.any(current.contains)) return {};
  }
  return {
    for (final entry in defaults.entries)
      if (entry.value.isNotEmpty)
        entry.key: {
          ...settings[entry.key] as List? ?? const [],
          ...entry.value,
        }.toList(),
  };
}
