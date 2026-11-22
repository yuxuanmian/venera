part of 'http_client.dart';

final _gitCommitSha = RegExp(r'^[0-9a-f]{40}$');
final _gitPacketLength = RegExp(r'^[0-9a-fA-F]{4}$');
const _maxGitPacketLength = 65520;

Future<CatalogPointer> _queryGitBranch(
  CatalogGitTransport transport,
  CatalogRepositorySource source,
  CatalogAttempt attempt,
) async {
  final repository = Uri.parse('${source.repositoryUrl}.git/');
  final ref = 'refs/heads/${source.branch}';
  Future<CatalogBytesResponse> request(Uri url, {Uint8List? body}) => transport
      .requestGit(
        url,
        timeout: _timeoutForAttempt(attempt, attempt.remaining),
        maxBytes: catalogMaxGitRefBytes,
        cancellation: attempt.cancellation,
        body: body,
      )
      .catchError((error) => throw _normalizeTransportError(error));

  try {
    final advertisement = await request(
      repository.resolve('info/refs?service=git-upload-pack'),
    );
    final capabilities = _gitResponseReader(advertisement, 'advertisement');
    // GitHub includes the smart HTTP service prelude before the v2 packets.
    var version = capabilities.read();
    if (version == '# service=git-upload-pack') {
      if (capabilities.read() != null) {
        throw const FormatException('Missing service flush');
      }
      version = capabilities.read();
    }
    if (version != 'version 2') {
      throw const FormatException('Git protocol v2 unavailable');
    }
    var supportsRefs = false;
    while (true) {
      final line = capabilities.read();
      if (line == null) break;
      if (line == 'ls-refs' || line.startsWith('ls-refs=')) supportsRefs = true;
      if (line.startsWith('object-format=') && line != 'object-format=sha1') {
        throw const FormatException('Unsupported Git object format');
      }
    }
    if (!supportsRefs || !capabilities.isDone) {
      throw const FormatException('Invalid ls-refs capabilities');
    }

    final reply = await request(
      repository.resolve('git-upload-pack'),
      body: _encodeLsRefs(ref),
    );
    final refs = _gitResponseReader(reply, 'result');
    String? revision;
    while (true) {
      final line = refs.read();
      if (line == null) break;
      final fields = line.split(' ');
      if (fields.length < 2 || !_gitCommitSha.hasMatch(fields[0])) {
        throw const FormatException('Invalid Git ref response');
      }
      if (fields[1] != ref) continue;
      if (revision != null) throw const FormatException('Duplicate Git ref');
      revision = fields[0];
    }
    if (!refs.isDone) throw const FormatException('Unexpected Git ref data');
    if (revision == null) {
      throw const CatalogHttpException('branch_not_found', '找不到配置仓库或分支');
    }
    return source.pointerForRevision(revision);
  } on FormatException {
    throw const CatalogHttpException('invalid_git_head_response', 'Git 分支响应无效');
  }
}

_GitPacketReader _gitResponseReader(
  CatalogBytesResponse response,
  String type,
) {
  if (response.statusCode != HttpStatus.ok) {
    throw CatalogHttpException(
      'git_head_query_failed',
      'Git 分支请求失败（HTTP ${response.statusCode}）',
    );
  }
  if (response.bytes.length > catalogMaxGitRefBytes) {
    throw const CatalogHttpException('response_too_large', 'Git 分支响应过大');
  }
  if (response.contentType?.split(';').first.trim() !=
      'application/x-git-upload-pack-$type') {
    throw const FormatException('Unexpected Git content type');
  }
  return _GitPacketReader(response.bytes);
}

Uint8List _encodeLsRefs(String ref) {
  List<int> packet(String line) {
    final bytes = utf8.encode('$line\n');
    final length = bytes.length + 4;
    if (length > _maxGitPacketLength) {
      throw const FormatException('Git packet exceeds maximum size');
    }
    return [...length.toRadixString(16).padLeft(4, '0').codeUnits, ...bytes];
  }

  return Uint8List.fromList([
    ...packet('command=ls-refs'),
    ...'0001'.codeUnits,
    ...packet('ref-prefix $ref'),
    ...'0000'.codeUnits,
  ]);
}

class _GitPacketReader {
  _GitPacketReader(this.bytes);

  final List<int> bytes;
  int _offset = 0;

  bool get isDone => _offset == bytes.length;

  String? read() {
    if (_offset + 4 > bytes.length) {
      throw const FormatException('Truncated Git packet');
    }
    final prefix = String.fromCharCodes(bytes, _offset, _offset + 4);
    if (!_gitPacketLength.hasMatch(prefix)) {
      throw const FormatException('Invalid packet length');
    }
    final length = int.parse(prefix, radix: 16);
    if (length == 0) {
      _offset += 4;
      return null;
    }
    final end = _offset + length;
    if (length < 4 || length > _maxGitPacketLength || end > bytes.length) {
      throw const FormatException('Invalid Git packet bounds');
    }
    final line = utf8.decode(bytes.sublist(_offset + 4, end));
    _offset = end;
    return line.endsWith('\n') ? line.substring(0, line.length - 1) : line;
  }
}
