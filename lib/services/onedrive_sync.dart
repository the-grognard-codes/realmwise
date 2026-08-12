import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'secure_storage_service.dart';
import 'sync_contract.dart';

abstract interface class OneDriveOAuthBrowser {
  Future<void> open(Uri uri);
}

abstract interface class OneDriveOAuthCallback {
  Future<Uri> waitForCallback();
}

class OneDriveAuthException implements Exception {
  OneDriveAuthException(this.message);
  final String message;
  @override
  String toString() => 'OneDriveAuthException: $message';
}

class OneDriveException implements Exception {
  OneDriveException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'OneDriveException($statusCode): $message';
}

class OneDriveTokenStore {
  OneDriveTokenStore(this.storage);
  final TokenStorage storage;
  Future<Map<String, Object?>> read(String k) async {
    final r = await storage.read(k);
    if (r == null) return {};
    try {
      return (jsonDecode(r) as Map).cast<String, Object?>();
    } catch (_) {
      return {};
    }
  }

  Future<void> write(String k, Map<String, Object?> v) =>
      storage.write(k, jsonEncode(v));
  Future<void> delete(String k) => storage.delete(k);
}

String _safe(String? e, String op) {
  const a = {
    'invalid_grant',
    'invalid_client',
    'access_denied',
    'unauthorized_client',
  };
  return e != null && a.contains(e)
      ? 'OAuth $op failed ($e)'
      : 'OAuth $op failed';
}

Never _fail(http.Response r, String op) {
  if (r.statusCode == 401)
    throw OneDriveAuthException('Authentication expired or revoked');
  if (r.statusCode == 403)
    throw OneDriveException(
      'Permission denied or quota exceeded',
      statusCode: r.statusCode,
    );
  if (r.statusCode == 404)
    throw OneDriveException(
      'Remote target not found',
      statusCode: r.statusCode,
    );
  if (r.statusCode == 412)
    throw OneDriveException(
      'Remote precondition failed',
      statusCode: r.statusCode,
    );
  throw OneDriveException(op, statusCode: r.statusCode);
}

class OneDriveOAuthAuthenticator implements SyncAuthenticator {
  OneDriveOAuthAuthenticator({
    required this.clientId,
    required this.redirectUri,
    required this.browser,
    required this.callback,
    required this.tokenStore,
    this.tenant = 'common',
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();
  final String clientId, tenant;
  final Uri redirectUri;
  final OneDriveOAuthBrowser browser;
  final OneDriveOAuthCallback callback;
  final OneDriveTokenStore tokenStore;
  final http.Client _http;
  String get _key => 'onedrive_oauth:$clientId';
  @override
  Future<SyncAuthSession> authenticate() async {
    final v = _random(64), state = _random(24);
    final ch = base64Url
        .encode(sha256.convert(utf8.encode(v)).bytes)
        .replaceAll('=', '');
    final authority = tenant.trim().isEmpty ? 'common' : tenant.trim();
    final auth = Uri.https(
      'login.microsoftonline.com',
      '/$authority/oauth2/v2.0/authorize',
      {
        'client_id': clientId,
        'response_type': 'code',
        'redirect_uri': redirectUri.toString(),
        'response_mode': 'query',
        // User.Read is only used to bind persisted sync state to the signed-in
        // account; file access remains restricted to this app's folder.
        'scope': 'openid offline_access User.Read Files.ReadWrite.AppFolder',
        'state': state,
        'code_challenge': ch,
        'code_challenge_method': 'S256',
      },
    );
    final f = callback.waitForCallback();
    await browser.open(auth);
    final u = await f;
    if (u.queryParameters['state'] != state)
      throw OneDriveAuthException('Invalid OAuth state');
    if (u.queryParameters['error'] != null)
      throw OneDriveAuthException(
        _safe(u.queryParameters['error'], 'authorization'),
      );
    final code = u.queryParameters['code'];
    if (code == null) throw OneDriveAuthException('Missing authorization code');
    final r = await _http.post(
      Uri.https('login.microsoftonline.com', '/$authority/oauth2/v2.0/token'),
      body: {
        'client_id': clientId,
        'grant_type': 'authorization_code',
        'redirect_uri': redirectUri.toString(),
        'code': code,
        'code_verifier': v,
        'scope': 'openid offline_access User.Read Files.ReadWrite.AppFolder',
      },
    );
    if (r.statusCode ~/ 100 != 2) {
      String? e;
      try {
        e = (jsonDecode(r.body) as Map)['error'] as String?;
      } catch (_) {}
      throw OneDriveAuthException(_safe(e, 'token exchange'));
    }
    final j = jsonDecode(r.body) as Map;
    final access = j['access_token'] as String?;
    if (access == null) throw OneDriveAuthException('Missing access token');
    final t = <String, Object?>{
      'access_token': access,
      'refresh_token': j['refresh_token'],
      'expires_at': DateTime.now()
          .add(Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 3600))
          .toIso8601String(),
      'account_id': 'onedrive',
    };
    final me = await _http.get(
      Uri.parse('https://graph.microsoft.com/v1.0/me'),
      headers: {'Authorization': 'Bearer $access'},
    );
    if (me.statusCode != 200) {
      throw OneDriveAuthException('Unable to verify Microsoft account');
    }
    final profile = jsonDecode(me.body) as Map;
    final id = (profile['id'] as String?)?.trim();
    if (id == null || id.isEmpty) {
      throw OneDriveAuthException('Microsoft account identity is unavailable');
    }
    final label =
        (profile['userPrincipalName'] as String?)?.trim() ??
        (profile['displayName'] as String?)?.trim();
    t['account_id'] = id;
    if (label != null && label.isNotEmpty) t['account_name'] = label;
    await tokenStore.write(_key, t);
    return SyncAuthSession(
      accountId: t['account_id'] as String? ?? 'onedrive',
      displayName: t['account_name'] as String?,
    );
  }

  static String _random(int n) {
    final r = Random.secure();
    const c =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~';
    return List.generate(n, (_) => c[r.nextInt(c.length)]).join();
  }
}

class OneDriveProvider implements SyncProvider {
  OneDriveProvider({
    required this.authenticator,
    required this.tokenStore,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();
  final OneDriveOAuthAuthenticator authenticator;
  final OneDriveTokenStore tokenStore;
  final http.Client _http;
  final Map<String, String> _tags = {};
  @override
  String get provider => 'onedrive';
  Future<void> clearCredentials() => tokenStore.delete(authenticator._key);
  Future<SyncAuthSession?> restoreSession() async {
    final t = await tokenStore.read(authenticator._key);
    if (t['access_token'] == null && t['refresh_token'] == null) return null;
    return SyncAuthSession(accountId: t['account_id'] as String? ?? 'onedrive');
  }

  @override
  Future<SyncAuthSession> authenticate() => authenticator.authenticate();
  Future<String> _access(SyncAuthSession s) async {
    final k = authenticator._key, t = await tokenStore.read(k);
    final storedAccount = t['account_id'] as String?;
    if (storedAccount != null &&
        storedAccount.isNotEmpty &&
        s.accountId != storedAccount) {
      throw OneDriveAuthException(
        'Connected account changed; reconnect OneDrive',
      );
    }
    final a = t['access_token'] as String?;
    final e = DateTime.tryParse(t['expires_at'] as String? ?? '');
    if (a != null &&
        (e == null ||
            e.isAfter(DateTime.now().add(const Duration(minutes: 1)))))
      return a;
    final ref = t['refresh_token'] as String?;
    if (ref == null) throw OneDriveAuthException('Not authenticated');
    final authority = authenticator.tenant.trim().isEmpty
        ? 'common'
        : authenticator.tenant.trim();
    final r = await _http.post(
      Uri.https('login.microsoftonline.com', '/$authority/oauth2/v2.0/token'),
      body: {
        'client_id': authenticator.clientId,
        'grant_type': 'refresh_token',
        'refresh_token': ref,
        'scope': 'openid offline_access User.Read Files.ReadWrite.AppFolder',
      },
    );
    if (r.statusCode ~/ 100 != 2)
      throw OneDriveAuthException('OAuth token refresh failed');
    final j = jsonDecode(r.body) as Map;
    t['access_token'] = j['access_token'];
    if (j['refresh_token'] is String) t['refresh_token'] = j['refresh_token'];
    t['expires_at'] = DateTime.now()
        .add(Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 3600))
        .toIso8601String();
    await tokenStore.write(k, t);
    return j['access_token'] as String;
  }

  Future<Map<String, String>> _root(SyncAuthSession s) async {
    final r = await _http.get(
      Uri.parse('https://graph.microsoft.com/v1.0/me/drive/special/approot'),
      headers: {'Authorization': 'Bearer ${await _access(s)}'},
    );
    if (r.statusCode != 200) _fail(r, 'OneDrive app root lookup failed');
    final j = jsonDecode(r.body) as Map;
    return {'id': j['id'] as String};
  }

  Future<SyncRemoteTarget> ensureBundleTarget(SyncAuthSession s) async {
    final root = await _root(s);
    final baseHeaders = {'Authorization': 'Bearer ${await _access(s)}'};
    final listing = await _http.get(
      Uri.parse(
        'https://graph.microsoft.com/v1.0/me/drive/items/${root['id']}/children',
      ),
      headers: baseHeaders,
    );
    if (listing.statusCode != 200)
      _fail(listing, 'OneDrive folder lookup failed');
    final values =
        ((jsonDecode(listing.body) as Map)['value'] as List? ?? const []);
    Map folder = values.whereType<Map>().firstWhere(
      (x) => x['name'] == 'Realmwise' && x['folder'] != null,
      orElse: () => {},
    );
    if (folder.isEmpty) {
      final created = await _http.post(
        Uri.parse(
          'https://graph.microsoft.com/v1.0/me/drive/items/${root['id']}/children',
        ),
        headers: {...baseHeaders, 'Content-Type': 'application/json'},
        body: jsonEncode({'name': 'Realmwise', 'folder': {}}),
      );
      if (created.statusCode ~/ 100 != 2)
        _fail(created, 'OneDrive folder creation failed');
      folder = jsonDecode(created.body) as Map;
    }
    final existing = await _listChildren(s, folder['id'] as String);
    if (existing.isNotEmpty) return existing.first;
    // Graph creates folders via /children; create the initially empty bundle
    // through the file-content endpoint, which returns its driveItem.
    final r = await _http.put(
      Uri.parse(
        'https://graph.microsoft.com/v1.0/me/drive/items/${folder['id']}:/${Uri.encodeComponent('Realmwise.realmwise')}:/content',
      ),
      headers: {
        'Authorization': 'Bearer ${await _access(s)}',
        'Content-Type': 'application/octet-stream',
      },
      body: Uint8List(0),
    );
    if (r.statusCode ~/ 100 != 2) _fail(r, 'OneDrive bundle creation failed');
    final j = jsonDecode(r.body) as Map;
    return SyncRemoteTarget(id: j['id'] as String, name: j['name'] as String);
  }

  Future<List<SyncRemoteTarget>> _listChildren(
    SyncAuthSession s,
    String id,
  ) async {
    final r = await _http.get(
      Uri.parse('https://graph.microsoft.com/v1.0/me/drive/items/$id/children'),
      headers: {'Authorization': 'Bearer ${await _access(s)}'},
    );
    if (r.statusCode != 200) _fail(r, 'OneDrive list failed');
    final a = ((jsonDecode(r.body) as Map)['value'] as List? ?? const []);
    return a
        .whereType<Map>()
        .where((x) => x['name'] == 'Realmwise.realmwise')
        .map(
          (x) => SyncRemoteTarget(
            id: x['id'] as String,
            name: x['name'] as String,
          ),
        )
        .toList();
  }

  @override
  Future<List<SyncRemoteTarget>> listRemoteTargets(SyncAuthSession s) async {
    final root = await _root(s);
    final r = await _http.get(
      Uri.parse(
        'https://graph.microsoft.com/v1.0/me/drive/items/${root['id']}/children',
      ),
      headers: {'Authorization': 'Bearer ${await _access(s)}'},
    );
    if (r.statusCode != 200) _fail(r, 'OneDrive list failed');
    final a = ((jsonDecode(r.body) as Map)['value'] as List? ?? const []);
    final folder = a.whereType<Map>().firstWhere(
      (x) => x['name'] == 'Realmwise' && x['folder'] != null,
      orElse: () => {},
    );
    if (folder.isEmpty) return const [];
    final nested = await _listChildren(s, folder['id'] as String);
    return nested.where((x) => x.name == 'Realmwise.realmwise').toList();
  }

  @override
  Future<SyncRemoteMetadata?> metadata(
    SyncAuthSession s,
    SyncRemoteTarget t,
  ) async {
    final r = await _http.get(
      Uri.parse('https://graph.microsoft.com/v1.0/me/drive/items/${t.id}'),
      headers: {'Authorization': 'Bearer ${await _access(s)}'},
    );
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) _fail(r, 'OneDrive metadata failed');
    final j = jsonDecode(r.body) as Map;
    final tag = (j['eTag'] ?? r.headers['etag']) as String? ?? '';
    _tags[t.id] = tag;
    final h = (j['file'] as Map?)?['hashes'];
    return SyncRemoteMetadata(
      revision: SyncRevision(tag),
      contentHash: (h is Map ? h['sha256Hash'] : null) as String? ?? '',
      updatedAt: DateTime.tryParse(j['lastModifiedDateTime'] ?? ''),
    );
  }

  @override
  Future<SyncUploadResult> upload(
    SyncAuthSession s,
    SyncRemoteTarget t,
    Uint8List payload, {
    SyncPrecondition? precondition,
  }) async {
    final old = await metadata(s, t);
    if (precondition != null &&
        old != null &&
        ((precondition.revision != null &&
                precondition.revision!.value != old.revision.value) ||
            (precondition.contentHash != null &&
                precondition.contentHash != old.contentHash)))
      throw SyncConflictException(old);
    final r = await _http.put(
      Uri.parse(
        'https://graph.microsoft.com/v1.0/me/drive/items/${t.id}/content',
      ),
      headers: {
        'Authorization': 'Bearer ${await _access(s)}',
        'Content-Type': 'application/octet-stream',
        if (_tags[t.id] != null) 'If-Match': _tags[t.id]!,
      },
      body: payload,
    );
    if (r.statusCode == 412)
      throw SyncConflictException(
        old ??
            SyncRemoteMetadata(
              revision: const SyncRevision(''),
              contentHash: '',
            ),
      );
    if (r.statusCode ~/ 100 != 2) _fail(r, 'OneDrive upload failed');
    final m = await metadata(s, t);
    return SyncUploadResult(
      metadata:
          m ??
          SyncRemoteMetadata(
            revision: const SyncRevision(''),
            contentHash: sha256.convert(payload).toString(),
          ),
    );
  }

  @override
  Future<SyncDownloadResult> download(
    SyncAuthSession s,
    SyncRemoteTarget t, {
    SyncPrecondition? precondition,
  }) async {
    final m = await metadata(s, t);
    if (m == null) throw OneDriveException('Remote target missing');
    if (precondition?.revision != null &&
        precondition!.revision!.value != m.revision.value)
      throw SyncConflictException(m);
    final r = await _http.get(
      Uri.parse(
        'https://graph.microsoft.com/v1.0/me/drive/items/${t.id}/content',
      ),
      headers: {'Authorization': 'Bearer ${await _access(s)}'},
    );
    if (r.statusCode != 200) _fail(r, 'OneDrive download failed');
    final b = Uint8List.fromList(r.bodyBytes);
    if (m.contentHash.isNotEmpty &&
        sha256.convert(b).toString() != m.contentHash)
      throw OneDriveException('Content hash mismatch');
    return SyncDownloadResult(payload: b, metadata: m);
  }
}
