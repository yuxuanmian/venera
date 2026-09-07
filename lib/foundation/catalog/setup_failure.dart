import 'http_client.dart';

enum CatalogSetupFailureKind {
  invalidServerAddress,
  connectionFailed,
  incompatibleServer,
  catalogNotActivated,
  contentPreparationFailed,
}

enum CatalogSetupStage { authority, snapshot, runtime, commit }

class CatalogSetupFailure {
  const CatalogSetupFailure(this.kind, {this.diagnostic});

  final CatalogSetupFailureKind kind;

  /// Technical details for diagnostics only; never render in ordinary UI.
  final String? diagnostic;

  static CatalogSetupFailure? fromError(Object error, CatalogSetupStage stage) {
    final code = error is CatalogHttpException ? error.code : null;
    if (code == 'cancelled') return null;
    final kind = stage != CatalogSetupStage.authority
        ? CatalogSetupFailureKind.contentPreparationFailed
        : switch (code) {
            'invalid_server_url' =>
              CatalogSetupFailureKind.invalidServerAddress,
            'timeout' ||
            'connection_failed' => CatalogSetupFailureKind.connectionFailed,
            'catalog_not_activated' =>
              CatalogSetupFailureKind.catalogNotActivated,
            'catalog_state_invalid' =>
              CatalogSetupFailureKind.contentPreparationFailed,
            _ => CatalogSetupFailureKind.incompatibleServer,
          };
    return CatalogSetupFailure(kind, diagnostic: '${stage.name}: $error');
  }
}
