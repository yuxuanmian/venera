part of 'settings_page.dart';

/// Read-only Catalog diagnostics. Only stable classifications and runtime
/// identities are shown; legacy server addresses, credentials, response bodies
/// and raw exceptions stay out of this surface.
class CatalogDiagnostics extends StatelessWidget {
  const CatalogDiagnostics({super.key, this.controller});

  final CatalogController? controller;

  @override
  Widget build(BuildContext context) {
    final activeController = controller;
    if (activeController == null) {
      return Scaffold(
        appBar: Appbar(title: Text('Catalog Diagnostics'.tl)),
        body: Center(child: Text('Catalog Runtime 尚未初始化'.tl)),
      );
    }
    final runtime = activeController.runtimePointer;
    final latest = activeController.latestRepositoryCheck;
    CatalogRepositorySource? saved;
    try {
      saved = activeController.repositorySource;
    } on CatalogRepositorySourceException {
      saved = null;
    }
    AppCatalogState? state;
    try {
      state = activeController.sessionState ?? appdata.readCatalogState();
    } on CatalogFormatException {
      state = null;
    }
    final legacy = state?.lastAuthority;
    String cachePath;
    try {
      cachePath = '${App.dataPath}/catalog_runtime';
    } catch (_) {
      cachePath = 'unavailable';
    }
    return Scaffold(
      appBar: Appbar(title: Text('Catalog Diagnostics'.tl)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _diagnosticRow(
            'Saved repository',
            saved == null
                ? 'invalidRepositorySource'
                : '${saved.repositoryUrl}\n${saved.branch}',
          ),
          _diagnosticRow('Runtime repository', runtime?.catalogId ?? 'none'),
          _diagnosticRow('Runtime revision', runtime?.revision ?? 'none'),
          _diagnosticRow(
            'Runtime state',
            activeController.usingLocalFallback
                ? 'localFallback:'
                      '${activeController.localFallbackReason?.name ?? 'unknown'}'
                : 'published',
          ),
          _diagnosticRow('LKG revision', state?.lkg?.revision ?? 'none'),
          _diagnosticRow(
            'Latest check source',
            latest?.source == null
                ? 'none'
                : '${latest!.source!.repositoryUrl}\n${latest.source!.branch}',
          ),
          _diagnosticRow(
            'Latest check time',
            latest?.checkedAt.toLocal().toString() ?? 'none',
          ),
          _diagnosticRow('Latest check status', latest?.status.name ?? 'none'),
          _diagnosticRow('Latest revision', latest?.latest?.revision ?? 'none'),
          _diagnosticRow(
            'Latest failure',
            latest?.failure?.kind.name ?? 'none',
          ),
          if (legacy != null) ...[
            _diagnosticRow('Legacy Catalog identity', legacy.catalog.identity),
            _diagnosticRow(
              'Legacy Catalog check',
              legacy.checkedAt.toLocal().toString(),
            ),
          ],
          _diagnosticRow('Catalog cache', cachePath),
        ],
      ),
    );
  }

  Widget _diagnosticRow(String title, String value) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title.tl),
      subtitle: SelectableText(value),
    );
  }
}
