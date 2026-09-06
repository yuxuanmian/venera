part of 'settings_page.dart';

/// Read-only Catalog diagnostics. User credentials and source account data are
/// intentionally not included here.
class CatalogDiagnostics extends StatelessWidget {
  const CatalogDiagnostics({super.key});

  @override
  Widget build(BuildContext context) {
    AppCatalogState? state;
    String? error;
    try {
      state = appdata.sessionCatalogState ?? appdata.readCatalogState();
    } catch (value) {
      error = value.toString();
    }
    final active = state?.active?.identity ?? 'none';
    final lkg = state?.lkg?.identity ?? 'none';
    final last = state?.lastAuthority;
    return Scaffold(
      appBar: Appbar(title: Text('Catalog Diagnostics'.tl)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _diagnosticRow('Active', active),
          _diagnosticRow('Last known good', lkg),
          _diagnosticRow('Last Authority server', last?.serverUrl ?? 'none'),
          _diagnosticRow(
            'Last Authority check',
            last?.checkedAt.toLocal().toString() ?? 'none',
          ),
          _diagnosticRow('Catalog cache', '${App.dataPath}/catalog_runtime'),
          if (error != null) _diagnosticRow('Catalog error', error),
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
