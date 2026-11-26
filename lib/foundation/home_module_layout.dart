const homeModuleLayoutSetting = 'homeModuleLayout';

/// Persistent IDs also determine the layout for a device with no preference.
enum HomeModule {
  sync,
  history,
  recentUpdates,
  comicSource,
  imageFavorites,
  local;

  static List<HomeModule> readLayout(Object? value) {
    if (value is! List) return List.of(values);
    final ids = value.whereType<String>();
    final modulesById = {for (final module in values) module.name: module};
    return ids
        .map((id) => modulesById[id])
        .whereType<HomeModule>()
        .toSet()
        .toList();
  }
}
