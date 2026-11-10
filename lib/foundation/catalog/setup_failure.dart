import 'dart:async';
import 'dart:io';

import 'http_client.dart';
import 'models.dart';

enum CatalogSetupFailureKind {
  connectionFailed,
  contentPreparationFailed,
  invalidRepositorySource,
  repositoryHeadUnavailable,
  invalidRepositoryHead,
  storageUnavailable,
  operationInProgress,
  cancelled,
}

enum CatalogSetupStage {
  repositoryHead,
  indexValidation,
  snapshot,
  runtime,
  commit,
}

class CatalogSetupFailure {
  const CatalogSetupFailure(this.kind, {this.diagnostic});

  final CatalogSetupFailureKind kind;

  /// Technical details for diagnostics only; never render in ordinary UI.
  final String? diagnostic;

  static CatalogSetupFailure? fromError(Object error, CatalogSetupStage stage) {
    final code = switch (error) {
      CatalogHttpException() => error.code,
      CatalogRepositorySourceException() => error.code,
      _ => null,
    };
    if (code == 'cancelled') return null;
    if (stage == CatalogSetupStage.repositoryHead &&
        (error is SocketException ||
            error is HandshakeException ||
            error is HttpException ||
            error is TimeoutException)) {
      return CatalogSetupFailure(
        CatalogSetupFailureKind.connectionFailed,
        diagnostic: '${stage.name}:${error.runtimeType}',
      );
    }
    final kind = switch (stage) {
      CatalogSetupStage.repositoryHead => switch (code) {
        'invalid_repository_url' ||
        'invalid_branch' => CatalogSetupFailureKind.invalidRepositorySource,
        'timeout' ||
        'connection_failed' => CatalogSetupFailureKind.connectionFailed,
        'head_query_failed' =>
          CatalogSetupFailureKind.repositoryHeadUnavailable,
        'invalid_head_response' ||
        'response_too_large' => CatalogSetupFailureKind.invalidRepositoryHead,
        _ => CatalogSetupFailureKind.repositoryHeadUnavailable,
      },
      CatalogSetupStage.indexValidation => switch (code) {
        'timeout' ||
        'connection_failed' => CatalogSetupFailureKind.connectionFailed,
        'invalid_pointer' => CatalogSetupFailureKind.invalidRepositorySource,
        _ => CatalogSetupFailureKind.contentPreparationFailed,
      },
      CatalogSetupStage.commit =>
        error is FileSystemException
            ? CatalogSetupFailureKind.storageUnavailable
            : CatalogSetupFailureKind.contentPreparationFailed,
      CatalogSetupStage.snapshot || CatalogSetupStage.runtime =>
        CatalogSetupFailureKind.contentPreparationFailed,
    };
    return CatalogSetupFailure(
      kind,
      diagnostic: '${stage.name}:${code ?? error.runtimeType}',
    );
  }
}
