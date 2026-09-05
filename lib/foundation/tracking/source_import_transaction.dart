import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Durable source-only import journal. Callers hold the source commit lock from
/// backup through verified reload (or rollback). Cache cleanup never owns this
/// directory. Startup recovers an interrupted replacement before any JS loads.
class SourceImportTransaction {
  SourceImportTransaction(this.sourceRoot, {this.beforeCopy});

  final Directory sourceRoot;
  final Future<void> Function(String phase, File file)? beforeCopy;

  /// Deterministic filesystem fault boundary used by production import tests.
  static Future<void> Function(String phase, File file)? debugBeforeCopy;
  Directory get directory =>
      Directory(p.join(sourceRoot.parent.path, '.source-import'));
  Directory get backup => Directory(p.join(directory.path, 'previous'));
  File get journal => File(p.join(directory.path, 'journal.json'));

  void _record(String phase, bool hadRoot) {
    journal.writeAsStringSync(
      jsonEncode({'phase': phase, 'hadRoot': hadRoot}),
      flush: true,
    );
  }

  Future<void> _copy(Directory from, Directory to, String phase) async {
    to.createSync(recursive: true);
    for (final entity in from.listSync(recursive: true, followLinks: false)) {
      if (entity is Link) {
        throw const FormatException('source tree contains a link');
      }
      final target = p.join(to.path, p.relative(entity.path, from: from.path));
      if (entity is Directory) {
        Directory(target).createSync(recursive: true);
      } else if (entity is File) {
        await (beforeCopy ?? debugBeforeCopy)?.call(phase, entity);
        File(target).parent.createSync(recursive: true);
        final bytes = await entity.readAsBytes();
        await File(target).writeAsBytes(bytes, flush: true);
        final written = await File(target).readAsBytes();
        if (bytes.length != written.length ||
            List.generate(
              bytes.length,
              (i) => bytes[i] == written[i],
            ).contains(false)) {
          throw const FormatException('source backup verification failed');
        }
      }
    }
  }

  Future<void> replace(
    Directory incoming, {
    required void Function() requireCurrent,
    required Future<void> Function() reload,
    required void Function() denyRuntime,
  }) async {
    if (directory.existsSync()) {
      throw StateError('An interrupted source import requires recovery first.');
    }
    directory.createSync(recursive: true);
    final hadRoot = sourceRoot.existsSync();
    var replacing = false;
    var safeToClean = false;
    try {
      _record('backing-up', hadRoot);
      if (hadRoot) await _copy(sourceRoot, backup, 'backup');
      _record('backup-ready', hadRoot);
      requireCurrent();
      // Persist intent before the first destructive operation.
      _record('replacing', hadRoot);
      replacing = true;
      denyRuntime();
      if (sourceRoot.existsSync()) sourceRoot.deleteSync(recursive: true);
      await _copy(incoming, sourceRoot, 'replace');
      requireCurrent();
      _record('replaced', hadRoot);
      await reload();
      requireCurrent();
      _record('verified', hadRoot);
      safeToClean = true;
    } catch (_) {
      if (replacing) {
        denyRuntime();
        // The lock still belongs to this import. A waiting mode request may
        // revoke execution, but cannot have selected another tree yet.
        await _restore(hadRoot);
        _record('restored', hadRoot);
      }
      safeToClean = true;
      rethrow;
    } finally {
      if (safeToClean && directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
    }
  }

  Future<void> _restore(bool hadRoot) async {
    if (hadRoot && !backup.existsSync()) {
      throw StateError('Source import backup is missing.');
    }
    if (sourceRoot.existsSync()) sourceRoot.deleteSync(recursive: true);
    if (hadRoot) await _copy(backup, sourceRoot, 'restore');
  }

  Future<void> recover() async {
    if (!directory.existsSync()) return;
    if (!journal.existsSync()) {
      throw StateError('Source import recovery journal is missing.');
    }
    final state = jsonDecode(journal.readAsStringSync()) as Map;
    final phase = state['phase'];
    if (phase == 'replacing' || phase == 'replaced') {
      await _restore(state['hadRoot'] == true);
    } else if (![
      'backing-up',
      'backup-ready',
      'verified',
      'restored',
    ].contains(phase)) {
      throw StateError('Source import recovery journal is invalid.');
    }
    directory.deleteSync(recursive: true);
  }
}
