import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'models.dart';

class CatalogStorageException implements Exception {
  const CatalogStorageException(this.code, this.message, [this.cause]);

  final String code;
  final String message;
  final Object? cause;

  @override
  String toString() =>
      cause == null ? '$code: $message' : '$code: $message: $cause';
}

class CatalogCandidate {
  CatalogCandidate({
    required this.pointer,
    required this.directory,
    required this.indexBytes,
    required this.index,
    required this.manifest,
  });

  final CatalogPointer pointer;
  final Directory directory;
  final List<int> indexBytes;
  final CatalogIndex index;
  final CatalogSnapshotManifest manifest;

  bool _closed = false;

  bool get isClosed => _closed;

  CatalogSnapshot get snapshot => CatalogSnapshot(
    manifest: manifest,
    indexBytes: indexBytes,
    index: index,
    rootPath: directory.path,
  );

  Future<void> discard() async {
    if (_closed) return;
    _closed = true;
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

/// Filesystem-only Catalog storage. App state remains in appdata; this class
/// owns immutable snapshots and never chooses an active pointer.
class CatalogStore {
  CatalogStore(this.root);

  final Directory root;

  Directory snapshotDirectory(CatalogPointer pointer) => Directory(
    p.join(
      root.path,
      'snapshots',
      _namespace(pointer.catalogId),
      pointer.revision,
    ),
  );

  Directory candidateDirectory(String attemptId) {
    if (!_safeSegment(attemptId)) {
      throw const CatalogStorageException(
        'invalid_attempt',
        'invalid candidate id',
      );
    }
    return Directory(p.join(root.path, 'candidates', attemptId));
  }

  Future<CatalogSnapshot?> readSnapshot(CatalogPointer pointer) async {
    try {
      pointer.validate();
      final directory = snapshotDirectory(pointer);
      if (!await _isSafeDirectory(directory)) return null;
      return await _readVerifiedDirectory(directory, pointer);
    } on CatalogStorageException {
      rethrow;
    } on CatalogFormatException catch (error) {
      throw CatalogStorageException(
        'invalid_snapshot',
        'snapshot manifest is invalid',
        error,
      );
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2) return null;
      throw CatalogStorageException(
        'snapshot_read_failed',
        'cannot read snapshot',
        error,
      );
    }
  }

  Future<CatalogCandidate> createCandidate({
    required CatalogPointer pointer,
    required List<int> indexBytes,
    required CatalogIndex index,
    String? attemptId,
  }) async {
    pointer.validate();
    if (indexBytes.length > catalogMaxIndexBytes) {
      throw const CatalogStorageException(
        'index_too_large',
        'index exceeds maximum size',
      );
    }
    final id = attemptId ?? const Uuid().v4();
    final directory = candidateDirectory(id);
    if (await directory.exists()) {
      throw const CatalogStorageException(
        'candidate_exists',
        'candidate directory already exists',
      );
    }
    await Directory(p.join(root.path, 'candidates')).create(recursive: true);
    await directory.create(recursive: true);
    final sourceDirectory = Directory(p.join(directory.path, 'sources'));
    await sourceDirectory.create();
    final manifest = CatalogSnapshotManifest(
      pointer: pointer,
      indexSha256: sha256Hex(indexBytes),
      files: const [],
    );
    return CatalogCandidate(
      pointer: pointer,
      directory: directory,
      indexBytes: List.unmodifiable(indexBytes),
      index: index,
      manifest: manifest,
    );
  }

  Future<void> writeCandidateSource(
    CatalogCandidate candidate,
    CatalogSourceEntry entry,
    List<int> bytes,
  ) async {
    _requireOpen(candidate);
    entry.validate();
    if (bytes.length > catalogMaxSourceBytes) {
      throw const CatalogStorageException(
        'source_too_large',
        'source exceeds maximum size',
      );
    }
    if (candidate.index.find(entry.key)?.fileName != entry.fileName) {
      throw const CatalogStorageException(
        'source_not_declared',
        'source is not declared by index',
      );
    }
    final path = p.join(candidate.directory.path, 'sources', entry.fileName);
    await _writeExclusive(File(path), bytes);
  }

  Future<CatalogCandidate> finalizeCandidate(CatalogCandidate candidate) async {
    _requireOpen(candidate);
    final files = <CatalogSnapshotFile>[];
    var total = 0;
    for (final entry in candidate.index.entries) {
      final file = File(
        p.join(candidate.directory.path, 'sources', entry.fileName),
      );
      if (!await _isRegularFile(file)) {
        throw CatalogStorageException(
          'candidate_incomplete',
          'missing source ${entry.fileName}',
        );
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > catalogMaxSourceBytes) {
        throw CatalogStorageException(
          'source_too_large',
          'source exceeds maximum size: ${entry.fileName}',
        );
      }
      total += bytes.length;
      if (total > catalogMaxTotalSourceBytes) {
        throw const CatalogStorageException(
          'sources_too_large',
          'sources exceed maximum total size',
        );
      }
      files.add(
        CatalogSnapshotFile(
          sourceKey: entry.key,
          fileName: entry.fileName,
          size: bytes.length,
          sha256: sha256Hex(bytes),
        ),
      );
    }
    final manifest = CatalogSnapshotManifest(
      pointer: candidate.pointer,
      indexSha256: sha256Hex(candidate.indexBytes),
      files: files,
    );
    await _writeExclusive(
      File(p.join(candidate.directory.path, 'index.json')),
      candidate.indexBytes,
    );
    await _writeExclusive(
      File(p.join(candidate.directory.path, 'snapshot.json')),
      utf8.encode(jsonEncode(manifest.toJson())),
    );
    return CatalogCandidate(
      pointer: candidate.pointer,
      directory: candidate.directory,
      indexBytes: candidate.indexBytes,
      index: candidate.index,
      manifest: manifest,
    );
  }

  /// Promotes a complete candidate into the immutable revision directory.
  /// The old directory is never removed as part of this operation.
  Future<CatalogSnapshot> promoteCandidate(
    CatalogCandidate candidate, {
    bool replaceInvalid = false,
  }) async {
    _requireOpen(candidate);
    final verified = await _readVerifiedDirectory(
      candidate.directory,
      candidate.pointer,
    );
    final finalDirectory = snapshotDirectory(candidate.pointer);
    await Directory(
      p.join(root.path, 'snapshots', _namespace(candidate.pointer.catalogId)),
    ).create(recursive: true);
    if (await finalDirectory.exists()) {
      CatalogSnapshot? existing;
      try {
        existing = await readSnapshot(candidate.pointer);
      } on CatalogStorageException {
        if (!replaceInvalid) rethrow;
      }
      if (existing != null) {
        await candidate.discard();
        return existing;
      }
      if (!replaceInvalid) {
        throw const CatalogStorageException(
          'snapshot_conflict',
          'existing snapshot is invalid',
        );
      }
      final backup = Directory(
        '${finalDirectory.path}.invalid-${const Uuid().v4()}',
      );
      await finalDirectory.rename(backup.path);
      try {
        await candidate.directory.rename(finalDirectory.path);
        candidate._closed = true;
      } catch (error) {
        if (await backup.exists() && !await finalDirectory.exists()) {
          await backup.rename(finalDirectory.path);
        }
        throw CatalogStorageException(
          'snapshot_replace_failed',
          'cannot replace invalid snapshot',
          error,
        );
      }
      await backup.delete(recursive: true);
      return CatalogSnapshot(
        manifest: verified.manifest,
        indexBytes: verified.indexBytes,
        index: verified.index,
        rootPath: finalDirectory.path,
      );
    }
    await candidate.directory.rename(finalDirectory.path);
    candidate._closed = true;
    return CatalogSnapshot(
      manifest: verified.manifest,
      indexBytes: verified.indexBytes,
      index: verified.index,
      rootPath: p.join(finalDirectory.path),
    );
  }

  Future<CatalogSnapshot> _readVerifiedDirectory(
    Directory directory,
    CatalogPointer expected,
  ) async {
    if (!await _isSafeDirectory(directory)) {
      throw const CatalogStorageException(
        'invalid_snapshot',
        'snapshot path is unsafe',
      );
    }
    final indexFile = File(p.join(directory.path, 'index.json'));
    final manifestFile = File(p.join(directory.path, 'snapshot.json'));
    if (!await _isRegularFile(indexFile) ||
        !await _isRegularFile(manifestFile)) {
      throw const CatalogStorageException(
        'snapshot_incomplete',
        'snapshot metadata is incomplete',
      );
    }
    final indexBytes = await indexFile.readAsBytes();
    final manifestJson = jsonDecode(await manifestFile.readAsString());
    if (manifestJson is! Map) {
      throw const CatalogStorageException(
        'invalid_snapshot',
        'snapshot manifest must be an object',
      );
    }
    final manifest = CatalogSnapshotManifest.fromJson(
      Map<String, dynamic>.from(manifestJson),
    );
    if (!manifest.pointer.sameIdentity(expected) ||
        manifest.pointer != expected) {
      throw const CatalogStorageException(
        'snapshot_identity_mismatch',
        'snapshot pointer mismatch',
      );
    }
    if (sha256Hex(indexBytes) != manifest.indexSha256) {
      throw const CatalogStorageException(
        'snapshot_digest_mismatch',
        'index digest mismatch',
      );
    }
    final index = CatalogIndex.fromBytes(indexBytes);
    if (manifest.files.length != index.entries.length) {
      throw const CatalogStorageException(
        'snapshot_file_set_mismatch',
        'snapshot file set mismatch',
      );
    }
    final byKey = {for (final file in manifest.files) file.sourceKey: file};
    var total = 0;
    for (final entry in index.entries) {
      final record = byKey[entry.key];
      if (record == null || record.fileName != entry.fileName) {
        throw const CatalogStorageException(
          'snapshot_file_set_mismatch',
          'manifest does not match index',
        );
      }
      final file = File(p.join(directory.path, 'sources', record.fileName));
      if (!await _isRegularFile(file)) {
        throw CatalogStorageException(
          'snapshot_missing_file',
          'missing ${record.fileName}',
        );
      }
      final bytes = await file.readAsBytes();
      total += bytes.length;
      if (bytes.length != record.size || sha256Hex(bytes) != record.sha256) {
        throw CatalogStorageException(
          'snapshot_digest_mismatch',
          'source digest mismatch: ${record.fileName}',
        );
      }
      if (bytes.length > catalogMaxSourceBytes ||
          total > catalogMaxTotalSourceBytes) {
        throw const CatalogStorageException(
          'sources_too_large',
          'sources exceed maximum size',
        );
      }
    }
    if (byKey.length != index.entries.length) {
      throw const CatalogStorageException(
        'snapshot_file_set_mismatch',
        'manifest contains extra files',
      );
    }
    return CatalogSnapshot(
      manifest: manifest,
      indexBytes: List.unmodifiable(indexBytes),
      index: index,
      rootPath: directory.path,
    );
  }

  Future<void> _writeExclusive(File file, List<int> bytes) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp-${const Uuid().v4()}');
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(file.path);
    } catch (error) {
      if (await temp.exists()) await temp.delete();
      throw CatalogStorageException(
        'write_failed',
        'cannot write ${file.path}',
        error,
      );
    }
  }

  Future<bool> _isSafeDirectory(Directory directory) async {
    final rootPath = p.normalize(p.absolute(root.path));
    final directoryPath = p.normalize(p.absolute(directory.path));
    if (!p.isWithin(rootPath, directoryPath) && directoryPath != rootPath)
      return false;
    if (!await directory.exists()) return false;
    return (await FileSystemEntity.type(directory.path, followLinks: false)) ==
        FileSystemEntityType.directory;
  }

  Future<bool> _isRegularFile(File file) async =>
      await file.exists() &&
      await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.file;

  String _namespace(String catalogId) => sha256Hex(utf8.encode(catalogId));

  void _requireOpen(CatalogCandidate candidate) {
    if (candidate.isClosed) {
      throw const CatalogStorageException(
        'candidate_closed',
        'candidate is already closed',
      );
    }
  }

  bool _safeSegment(String value) =>
      value.isNotEmpty &&
      RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(value) &&
      value != '.' &&
      value != '..';
}
