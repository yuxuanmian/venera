part of 'settings_page.dart';

/// Settings for the Venera Server used on the next application start.
///
/// This page intentionally only validates the Authority endpoint.  It never
/// downloads a Catalog and never replaces the Runtime used by the current
/// session.
class ServerSettings extends StatefulWidget {
  const ServerSettings({super.key, this.client});

  @visibleForTesting
  final CatalogHttpClient? client;

  @override
  State<ServerSettings> createState() => _ServerSettingsState();
}

class _ServerSettingsState extends State<ServerSettings> {
  late final TextEditingController _controller;
  bool _busy = false;
  String? _error;
  String? _success;
  DateTime? _checkedAt;

  CatalogHttpClient get _client => widget.client ?? CatalogHttpClient();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: _savedUrl);
    final state = _readCatalogState();
    _checkedAt = state?.lastAuthority?.checkedAt;
  }

  String get _savedUrl {
    final value = appdata.settings['serverUrl'];
    if (value is String && value.trim().isNotEmpty) return value.trim();
    // This fallback only helps a pre-Catalog installation migrate its visible
    // value. It is not used as an authentication or tracking setting.
    final old = appdata.settings['cloudTrackingServerUrl'];
    return old is String ? old.trim() : '';
  }

  AppCatalogState? _readCatalogState() {
    try {
      return appdata.readCatalogState();
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _verifyAndSave() async {
    if (_busy) return;
    final before = _savedUrl;
    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });
    try {
      final base = CatalogServerUrl.parse(_controller.text);
      await _client.getAuthority(base.normalized);

      // Keep the old value in memory until persistence succeeds. A failed
      // replace therefore cannot make the current session point at a value
      // that was never saved.
      appdata.settings['serverUrl'] = base.normalized;
      try {
        await appdata.saveData(false);
      } catch (_) {
        appdata.settings['serverUrl'] = before;
        rethrow;
      }
      if (!mounted) return;
      setState(() {
        _controller.text = base.normalized;
        _checkedAt = DateTime.now();
        _success = '地址验证成功，将在下次启动时应用'.tl;
      });
    } on Object catch (error, stack) {
      Log.error('Server settings', error, stack);
      if (!mounted) return;
      setState(() {
        _error = _serverError(error);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _serverError(Object error) {
    if (error is CatalogHttpException) return error.message;
    return 'Server 地址验证失败：$error';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text('Venera Server'.tl)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const Key('server-url-field'),
            controller: _controller,
            enabled: !_busy,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: 'Server 地址'.tl,
              hintText: '例如 https://server.example/'.tl,
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('verify-server-button'),
            onPressed: _busy ? null : _verifyAndSave,
            child: Text(_busy ? '正在验证…'.tl : '验证并保存'.tl),
          ),
          if (_success != null) ...[
            const SizedBox(height: 12),
            Text(_success!, style: TextStyle(color: Colors.green.shade700)),
          ],
          const SizedBox(height: 20),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('最近验证'.tl),
            subtitle: Text(
              _checkedAt == null
                  ? '尚未验证'.tl
                  : '${_checkedAt!.toLocal()}\n${_savedUrl.isEmpty ? '未配置'.tl : _savedUrl}',
            ),
          ),
          Text('保存只影响下次启动；当前漫画源、Runtime 和阅读会话不会切换。'.tl),
        ],
      ),
    );
  }
}
