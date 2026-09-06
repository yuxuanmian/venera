import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/proxy.dart';

/// Holds the shared rhttp client used by [RHttpAdapter].
///
/// Creating an [rhttp.RhttpClient] is an expensive operation: it owns a
/// connection pool and other resources on the Rust side, and reusing it keeps
/// TCP/TLS connections alive across requests. Before this manager existed,
/// every request created a throwaway client, so each image download had to
/// establish a fresh connection and TLS handshake.
///
/// The client's settings (proxy, DNS overrides, TLS flags) are fixed at
/// creation time, so the manager rebuilds the client whenever the settings it
/// depends on change. The old client is not disposed on rebuild: in-flight
/// requests still use it, and rhttp frees it once it is garbage collected.
class SharedRhttpClientManager {
  SharedRhttpClientManager._();

  static final SharedRhttpClientManager instance = SharedRhttpClientManager._();

  rhttp.RhttpClient? _client;

  // Catalog requests share proxy, DNS and TLS settings with normal traffic,
  // but use a separate client because redirect policy is client-scoped in
  // rhttp. Keeping it cached avoids rebuilding native clients per source
  // file while leaving ordinary requests unchanged.
  rhttp.RhttpClient? _catalogClient;

  /// Fingerprint of the settings the current [_client] was created with.
  Object? _fingerprint;
  Object? _catalogFingerprint;

  /// Coalesces concurrent rebuilds so racing requests create only one client.
  Future<void>? _rebuilding;
  Future<void>? _catalogRebuilding;

  /// Returns the shared client, creating or rebuilding it when the settings
  /// it depends on have changed.
  Future<rhttp.RhttpClient> getClient() async {
    final fingerprint = await _computeFingerprint();
    final client = _client;
    if (client != null && fingerprint == _fingerprint) {
      return client;
    }
    final rebuilding = _rebuilding ??= _rebuild(fingerprint);
    await rebuilding;
    if (fingerprint != _fingerprint) {
      // The settings changed again while we were rebuilding; try once more
      // so this caller does not get a client with stale settings.
      return getClient();
    }
    return _client!;
  }

  /// Returns a client with the application's current proxy/DNS/TLS policy
  /// and an explicit no-redirect policy for immutable Catalog resources.
  Future<rhttp.RhttpClient> getCatalogClient() async {
    final fingerprint = await _computeFingerprint();
    final client = _catalogClient;
    if (client != null && fingerprint == _catalogFingerprint) {
      return client;
    }
    final rebuilding = _catalogRebuilding ??= _rebuildCatalog(fingerprint);
    await rebuilding;
    if (fingerprint != _catalogFingerprint) return getCatalogClient();
    return _catalogClient!;
  }

  Future<void> _rebuild(Object fingerprint) async {
    try {
      final client = await rhttp.RhttpClient.create(
        settings: await _buildSettings(),
      );
      _client = client;
      _fingerprint = fingerprint;
    } finally {
      _rebuilding = null;
    }
  }

  Future<void> _rebuildCatalog(Object fingerprint) async {
    try {
      _catalogClient = await rhttp.RhttpClient.create(
        settings: await _buildSettings(catalogNoRedirect: true),
      );
      _catalogFingerprint = fingerprint;
    } finally {
      _catalogRebuilding = null;
    }
  }

  Future<Object> _computeFingerprint() async {
    final proxy = await getProxy();
    return (
      proxy,
      appdata.settings['enableDnsOverrides'] == true,
      appdata.settings['dnsOverrides']?.toString() ?? '',
      appdata.settings['sni'],
      appdata.settings['ignoreBadCertificate'],
    );
  }

  Future<rhttp.ClientSettings> _buildSettings({
    bool catalogNoRedirect = false,
  }) async {
    var proxy = await getProxy();
    return rhttp.ClientSettings(
      proxySettings: proxy == null
          ? const rhttp.ProxySettings.noProxy()
          : rhttp.ProxySettings.proxy(proxy),
      redirectSettings: catalogNoRedirect
          ? const rhttp.RedirectSettings.none()
          : const rhttp.RedirectSettings.limited(5),
      timeoutSettings: const rhttp.TimeoutSettings(
        connectTimeout: Duration(seconds: 15),
        keepAliveTimeout: Duration(seconds: 60),
        keepAlivePing: Duration(seconds: 30),
      ),
      throwOnStatusCode: false,
      dnsSettings: rhttp.DnsSettings.static(overrides: _getOverrides()),
      tlsSettings: rhttp.TlsSettings(
        sni: appdata.settings['sni'] != false,
        verifyCertificates: appdata.settings['ignoreBadCertificate'] != true,
      ),
    );
  }

  static Map<String, List<String>> _getOverrides() {
    if (!appdata.settings['enableDnsOverrides'] == true) {
      return {};
    }
    var config = appdata.settings["dnsOverrides"];
    var result = <String, List<String>>{};
    if (config is Map) {
      for (var entry in config.entries) {
        if (entry.key is String && entry.value is String) {
          result[entry.key] = [entry.value];
        }
      }
    }
    return result;
  }
}
