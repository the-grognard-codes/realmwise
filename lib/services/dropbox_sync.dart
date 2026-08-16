import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'sync_contract.dart';
import 'sync_debug.dart';
import 'secure_storage_service.dart';

abstract interface class DropboxOAuthBrowser {
  Future<void> open(Uri uri);
}

abstract interface class DropboxOAuthCallback {
  Future<Uri> waitForCallback();
}

class DropboxAuthException implements Exception {
  DropboxAuthException(this.message);
  final String message;
  @override
  String toString() => 'DropboxAuthException: $message';
}

class DropboxException implements Exception {
  DropboxException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'DropboxException($statusCode): $message';
}

class DropboxTokenStore {
  DropboxTokenStore(this.storage);
  final TokenStorage storage;
  Future<Map<String, Object?>> read(String k) async {
    final v = await storage.read(k);
    if (v == null) return {};
    try {
      return (jsonDecode(v) as Map).cast<String, Object?>();
    } catch (_) {
      return {};
    }
  }

  Future<void> write(String k, Map<String, Object?> v) =>
      storage.write(k, jsonEncode(v));
  Future<void> delete(String k) => storage.delete(k);
}

class DropboxOAuthAuthenticator implements SyncAuthenticator {
  DropboxOAuthAuthenticator({
    required this.clientId,
    required this.redirectUri,
    required this.browser,
    required this.callback,
    required this.tokenStore,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();
  final String clientId;
  final Uri redirectUri;
  final DropboxOAuthBrowser browser;
  final DropboxOAuthCallback callback;
  final DropboxTokenStore tokenStore;
  final http.Client _http;
  String get _key => 'dropbox_oauth:$clientId';
  @override
  Future<SyncAuthSession> authenticate() async {
    final verifier = _rand(64);
    final challenge = base64Url
        .encode(sha256.convert(utf8.encode(verifier)).bytes)
        .replaceAll('=', '');
    final state = _rand(24);
    final auth = Uri.https('www.dropbox.com', '/oauth2/authorize', {
      'client_id': clientId,
      'response_type': 'code',
      'redirect_uri': redirectUri.toString(),
      'token_access_type': 'offline',
      'state': state,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
    });
    final f = callback.waitForCallback();
    await browser.open(auth);
    final u = await f;
    if (u.path != redirectUri.path)
      throw DropboxAuthException('Invalid OAuth callback');
    if (u.queryParameters['state'] != state)
      throw DropboxAuthException('Invalid OAuth state');
    if (u.queryParameters['error'] != null)
      throw DropboxAuthException('OAuth authorization failed');
    final code = u.queryParameters['code'];
    if (code == null) throw DropboxAuthException('Missing authorization code');
    final r = await _http.post(
      Uri.https('api.dropboxapi.com', '/oauth2/token'),
      body: {
        'code': code,
        'grant_type': 'authorization_code',
        'client_id': clientId,
        'redirect_uri': redirectUri.toString(),
        'code_verifier': verifier,
      },
    );
    if (r.statusCode ~/ 100 != 2)
      throw DropboxAuthException('OAuth token exchange failed');
    final j = jsonDecode(r.body) as Map;
    final access = j['access_token'] as String?;
    if (access == null) throw DropboxAuthException('Missing access token');
    final t = <String, Object?>{
      'access_token': access,
      'refresh_token': j['refresh_token'],
      'expires_at': DateTime.now()
          .add(Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 14400))
          .toIso8601String(),
    };
    final a = await _http.post(
      Uri.https('api.dropboxapi.com', '/2/users/get_current_account'),
      headers: {'Authorization': 'Bearer $access'},
    );
    if (a.statusCode != 200)
      throw DropboxAuthException('Unable to verify Dropbox account');
    final p = jsonDecode(a.body) as Map;
    t['account_id'] = p['account_id'];
    t['account_name'] = ((p['name'] as Map?)?['display_name']);
    await tokenStore.write(_key, t);
    return SyncAuthSession(
      accountId: t['account_id'] as String,
      displayName: t['account_name'] as String?,
    );
  }

  static String _rand(int n) {
    final r = Random.secure();
    const c = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    return List.generate(n, (_) => c[r.nextInt(c.length)]).join();
  }
}

class DropboxProvider implements SyncProvider {
  DropboxProvider({
    required this.authenticator,
    required this.tokenStore,
    http.Client? httpClient,
    this._delay,
    this.maxTransientRetries = 3,
  }) : _http = httpClient ?? http.Client();
  final DropboxOAuthAuthenticator authenticator;
  final DropboxTokenStore tokenStore;
  final http.Client _http;
  final Future<void> Function(Duration)? _delay;
  final int maxTransientRetries;
  static const _contentHashBlockSize = 4 * 1024 * 1024;

  static String _dropboxContentHash(Uint8List bytes) {
    final blockHashes = <int>[];
    for (
      var offset = 0;
      offset < bytes.length;
      offset += _contentHashBlockSize
    ) {
      final end = min(offset + _contentHashBlockSize, bytes.length);
      blockHashes.addAll(sha256.convert(bytes.sublist(offset, end)).bytes);
    }
    return sha256.convert(Uint8List.fromList(blockHashes)).toString();
  }

  @override
  String get provider => 'dropbox';
  Future<void> clearCredentials() => tokenStore.delete(authenticator._key);
  Future<SyncAuthSession?> restoreSession() async {
    final t = await tokenStore.read(authenticator._key);
    final id = t['account_id'] as String?;
    return id == null
        ? null
        : SyncAuthSession(
            accountId: id,
            displayName: t['account_name'] as String?,
          );
  }

  Future<String> _access(SyncAuthSession s) async {
    final k = authenticator._key, t = await tokenStore.read(k);
    if (t['account_id'] != null && t['account_id'] != s.accountId)
      throw DropboxAuthException(
        'Connected account changed; reconnect Dropbox',
      );
    final a = t['access_token'] as String?;
    final e = DateTime.tryParse(t['expires_at'] as String? ?? '');
    if (a != null &&
        (e == null ||
            e.isAfter(DateTime.now().add(const Duration(minutes: 1)))))
      return a;
    final ref = t['refresh_token'] as String?;
    if (ref == null) throw DropboxAuthException('Not authenticated');
    final r = await _http.post(
      Uri.https('api.dropboxapi.com', '/oauth2/token'),
      body: {
        'refresh_token': ref,
        'grant_type': 'refresh_token',
        'client_id': authenticator.clientId,
      },
    );
    if (r.statusCode ~/ 100 != 2)
      throw DropboxAuthException('OAuth token refresh failed');
    final j = jsonDecode(r.body) as Map;
    t['access_token'] = j['access_token'];
    t['expires_at'] = DateTime.now()
        .add(Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 14400))
        .toIso8601String();
    await tokenStore.write(k, t);
    return j['access_token'] as String;
  }

  Future<http.Response> _retry(Future<http.Response> Function() request) async {
    for (var attempt = 0; ; attempt++) {
      final r = await request();
      final transient =
          r.statusCode == 429 || (r.statusCode >= 500 && r.statusCode < 600);
      if (!transient || attempt >= maxTransientRetries) return r;
      final seconds =
          (int.tryParse(r.headers['retry-after'] ?? '') ?? (1 << attempt))
              .clamp(1, 30);
      SyncDebug.trace('provider.dropbox.retry', {
        'attempt': attempt + 1,
        'status': r.statusCode,
      });
      if (_delay != null)
        await _delay(Duration(seconds: seconds));
      else
        await Future<void>.delayed(Duration(seconds: seconds));
    }
  }

  Future<http.Response> _call(
    String path,
    SyncAuthSession s, {
    String method = 'POST',
    Object? body,
    bool content = false,
  }) async {
    final h = {
      'Authorization': 'Bearer ${await _access(s)}',
      'Content-Type': content ? 'application/octet-stream' : 'application/json',
    };
    final u = Uri.https('api.dropboxapi.com', path);
    return _retry(
      () => method == 'POST'
          ? _http.post(
              u,
              headers: h,
              body: body is String
                  ? body
                  : body == null
                  ? null
                  : jsonEncode(body),
            )
          : _http.get(u, headers: h),
    );
  }

  Never _fail(http.Response r, String op) {
    if (r.statusCode == 401)
      throw DropboxAuthException('Authentication expired or revoked');
    if (r.statusCode == 409)
      throw DropboxException(
        'Remote precondition failed',
        statusCode: r.statusCode,
      );
    if (r.statusCode == 429)
      throw DropboxException(
        'Dropbox request throttled; retry shortly',
        statusCode: r.statusCode,
      );
    throw DropboxException(op, statusCode: r.statusCode);
  }

  @override
  Future<SyncAuthSession> authenticate() => authenticator.authenticate();
  @override
  Future<List<SyncRemoteTarget>> listRemoteTargets(SyncAuthSession s) async {
    final r = await _call('/2/files/list_folder', s, body: {'path': ''});
    if (r.statusCode != 200) _fail(r, 'Dropbox list failed');
    final e = ((jsonDecode(r.body) as Map)['entries'] as List? ?? const []);
    return e
        .whereType<Map>()
        .where((x) => x['.tag'] == 'file' && x['name'] == 'Realmwise.realmwise')
        .map(
          (x) => SyncRemoteTarget(
            id: x['id'] as String,
            name: x['name'] as String,
          ),
        )
        .toList();
  }

  Future<SyncRemoteTarget> ensureBundleTarget(SyncAuthSession s) async {
    final x = await listRemoteTargets(s);
    if (x.isNotEmpty) return x.first;
    final r = await _http.post(
      Uri.https('content.dropboxapi.com', '/2/files/upload'),
      headers: {
        'Authorization': 'Bearer ${await _access(s)}',
        'Content-Type': 'application/octet-stream',
        'Dropbox-API-Arg': jsonEncode({
          'path': '/Realmwise.realmwise',
          'mode': {'.tag': 'add'},
        }),
      },
      body: Uint8List(0),
    );
    if (r.statusCode ~/ 100 != 2) _fail(r, 'Dropbox bundle creation failed');
    final j = jsonDecode(r.body) as Map;
    return SyncRemoteTarget(id: j['id'] as String, name: j['name'] as String);
  }

  @override
  Future<SyncRemoteMetadata?> metadata(
    SyncAuthSession s,
    SyncRemoteTarget t,
  ) async {
    final r = await _call('/2/files/get_metadata', s, body: {'path': t.id});
    if (r.statusCode == 409 || r.statusCode == 404) return null;
    if (r.statusCode != 200) _fail(r, 'Dropbox metadata failed');
    final j = jsonDecode(r.body) as Map;
    final rev = j['rev'] as String? ?? '';
    final h = j['content_hash'] as String? ?? '';
    SyncDebug.trace('provider.metadata', {
      'revision': SyncDebug.hashPrefix(rev),
    });
    return SyncRemoteMetadata(
      revision: SyncRevision(rev),
      contentHash: h,
      updatedAt: DateTime.tryParse(j['server_modified'] ?? ''),
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
        old == null &&
        (precondition.revision != null ||
            (precondition.contentHash?.isNotEmpty ?? false)))
      throw SyncConflictException(
        const SyncRemoteMetadata(revision: SyncRevision(''), contentHash: ''),
      );
    if (precondition != null &&
        old != null &&
        ((precondition.revision != null &&
                precondition.revision!.value != old.revision.value) ||
            (precondition.contentHash != null &&
                precondition.contentHash!.isNotEmpty &&
                precondition.contentHash != old.contentHash)))
      throw SyncConflictException(old);
    if (old != null && (old.revision.value.isEmpty || old.contentHash.isEmpty))
      throw DropboxException('Remote target has incomplete metadata');
    final mode = old == null
        ? {'.tag': 'add'}
        : {'.tag': 'update', 'update': old.revision.value};
    final expectedHash = _dropboxContentHash(payload);
    final r = await _http.post(
      Uri.https('content.dropboxapi.com', '/2/files/upload'),
      headers: {
        'Authorization': 'Bearer ${await _access(s)}',
        'Content-Type': 'application/octet-stream',
        'Dropbox-API-Arg': jsonEncode({
          'path': '/Realmwise.realmwise',
          'mode': mode,
        }),
      },
      body: payload,
    );
    if (r.statusCode == 429 || (r.statusCode >= 500 && r.statusCode < 600)) {
      // Upload is a mutation: never blindly replay an ambiguous response.
      final reconciled = await metadata(s, t);
      if (reconciled != null && reconciled.contentHash == expectedHash)
        return SyncUploadResult(metadata: reconciled);
    }
    if (r.statusCode == 409)
      throw SyncConflictException(
        old ??
            const SyncRemoteMetadata(
              revision: SyncRevision(''),
              contentHash: '',
            ),
      );
    if (r.statusCode ~/ 100 != 2) _fail(r, 'Dropbox upload failed');
    final after = await metadata(s, t);
    if (after == null ||
        after.revision.value.isEmpty ||
        after.contentHash.isEmpty)
      throw DropboxException('Dropbox upload returned incomplete metadata');
    final j = jsonDecode(r.body) as Map;
    final returnedRev = j['rev'] as String? ?? '';
    final returnedHash = j['content_hash'] as String? ?? '';
    if (returnedRev.isNotEmpty && returnedRev != after.revision.value)
      throw DropboxException('Dropbox upload metadata changed unexpectedly');
    if (returnedHash.isNotEmpty && returnedHash != after.contentHash)
      throw DropboxException('Dropbox upload hash changed unexpectedly');
    if (after.contentHash != expectedHash)
      throw DropboxException('Dropbox upload content hash mismatch');
    return SyncUploadResult(metadata: after);
  }

  @override
  Future<SyncDownloadResult> download(
    SyncAuthSession s,
    SyncRemoteTarget t, {
    SyncPrecondition? precondition,
  }) async {
    for (var attempt = 0; ; attempt++) {
      final before = await metadata(s, t);
      if (before == null) throw DropboxException('Remote target missing');
      if (before.revision.value.isEmpty || before.contentHash.isEmpty)
        throw DropboxException('Remote target has incomplete metadata');
      if (precondition?.revision != null &&
          precondition!.revision!.value != before.revision.value)
        throw SyncConflictException(before);
      final contentHash = precondition?.contentHash;
      if (contentHash != null &&
          contentHash.isNotEmpty &&
          contentHash != before.contentHash)
        throw SyncConflictException(before);
      final r = await _retry(
        () async => _http.post(
          Uri.https('content.dropboxapi.com', '/2/files/download'),
          headers: {
            'Authorization': 'Bearer ${await _access(s)}',
            'Dropbox-API-Arg': jsonEncode({'path': t.id}),
          },
        ),
      );
      if (r.statusCode != 200) _fail(r, 'Dropbox download failed');
      final resultHeader = r.headers['dropbox-api-result'];
      String? responseRev;
      String? responseHash;
      try {
        final h = resultHeader == null ? null : jsonDecode(resultHeader) as Map;
        responseRev = h?['rev'] as String?;
        responseHash = h?['content_hash'] as String?;
      } catch (_) {}
      final b = Uint8List.fromList(r.bodyBytes);
      final after = await metadata(s, t);
      if (after == null) throw DropboxException('Remote target missing');
      final coherent =
          before.revision == after.revision &&
          before.contentHash == after.contentHash &&
          responseRev != null &&
          responseRev.isNotEmpty &&
          responseHash != null &&
          responseHash.isNotEmpty &&
          responseRev == after.revision.value &&
          responseHash == after.contentHash &&
          responseHash == _dropboxContentHash(b);
      if (coherent) return SyncDownloadResult(payload: b, metadata: after);
      if (attempt >= maxTransientRetries)
        throw DropboxException('Dropbox content changed while downloading');
      final wait = Duration(seconds: (1 << attempt).clamp(1, 30));
      if (_delay != null)
        await _delay(wait);
      else
        await Future<void>.delayed(wait);
    }
  }
}
