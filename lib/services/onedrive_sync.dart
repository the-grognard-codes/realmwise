import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'secure_storage_service.dart';
import 'sync_contract.dart';
import 'sync_debug.dart';

abstract interface class OneDriveOAuthBrowser {
  Future<void> open(Uri uri);
}

abstract interface class OneDriveOAuthCallback {
  Future<Uri> waitForCallback();
}

abstract interface class OneDriveOAuthCallbackCancellation {
  Future<void> cancel();
}

class OneDriveAuthException implements Exception {
  OneDriveAuthException(this.message);
  final String message;
  @override
  String toString() => 'OneDriveAuthException: $message';
}

class OneDriveException implements Exception {
  OneDriveException(
    this.message, {
    this.statusCode,
    this.operation,
    this.grantedScopes,
    this.graphErrorCode,
  });
  final String message;
  final int? statusCode;
  final String? operation;
  final List<String>? grantedScopes;
  final String? graphErrorCode;
  @override
  String toString() {
    final details = <String>[
      if (operation != null) 'operation=$operation',
      if (statusCode != null) 'status=$statusCode',
      if (grantedScopes != null && grantedScopes!.isNotEmpty)
        'scopes=${grantedScopes!.join(" ")}',
      if (graphErrorCode != null) 'code=$graphErrorCode',
    ];
    return details.isEmpty
        ? 'OneDriveException: $message'
        : 'OneDriveException(${details.join(", ")}): $message';
  }
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

String? _safeOAuthErrorCode(String body) {
  try {
    final decoded = jsonDecode(body);
    final error = decoded is Map ? decoded['error'] : null;
    return error is String &&
            error.length <= 64 &&
            RegExp(r'^[a-z_]+$').hasMatch(error)
        ? error
        : null;
  } catch (_) {
    return null;
  }
}

String? _safeGraphErrorCode(String body) {
  try {
    final decoded = jsonDecode(body);
    final error = decoded is Map ? decoded['error'] : null;
    final code = error is Map && error['code'] is String
        ? (error['code'] as String).trim()
        : '';
    if (code.isEmpty ||
        code.length > 64 ||
        !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(code))
      return null;
    return code;
  } catch (_) {
    return null;
  }
}

// Microsoft Graph does not support sha256Hash for drive items.  Its documented,
// cross-OneDrive content identity is quickXorHash (a 160-bit, base64 value).
// This implements Microsoft's published QuickXor algorithm for an in-memory
// bundle payload.
String _quickXorHash(Uint8List bytes) {
  const width = 160;
  const shift = 11;
  const mask64 = 0xffffffffffffffff;
  const mask32 = 0xffffffff;
  final data = List<int>.filled(3, 0);
  var vectorIndex = 0;
  var vectorOffset = 0;
  final iterations = min(bytes.length, width);

  for (var i = 0; i < iterations; i++) {
    final lastCell = vectorIndex == data.length - 1;
    final bits = lastCell ? 32 : 64;
    var value = 0;
    for (var j = i; j < bytes.length; j += width) {
      value ^= bytes[j];
    }
    if (vectorOffset <= bits - 8) {
      final mask = lastCell ? mask32 : mask64;
      data[vectorIndex] = (data[vectorIndex] ^ (value << vectorOffset)) & mask;
    } else {
      final low = bits - vectorOffset;
      final nextIndex = lastCell ? 0 : vectorIndex + 1;
      final currentMask = lastCell ? mask32 : mask64;
      final nextMask = nextIndex == data.length - 1 ? mask32 : mask64;
      data[vectorIndex] =
          (data[vectorIndex] ^ (value << vectorOffset)) & currentMask;
      data[nextIndex] = (data[nextIndex] ^ (value >> low)) & nextMask;
    }
    vectorOffset += shift;
    while (vectorOffset >= bits) {
      vectorIndex = lastCell ? 0 : vectorIndex + 1;
      vectorOffset -= bits;
    }
  }

  final output = Uint8List(20);
  for (var cell = 0; cell < data.length; cell++) {
    final cellBytes = cell == data.length - 1 ? 4 : 8;
    for (var byte = 0; byte < cellBytes; byte++) {
      output[cell * 8 + byte] = (data[cell] >> (byte * 8)) & 0xff;
    }
  }
  var length = bytes.length;
  for (var byte = 0; byte < 8; byte++) {
    output[12 + byte] ^= length & 0xff;
    length >>= 8;
  }
  return base64.encode(output);
}

Never _fail(http.Response r, String op) {
  final graphErrorCode = _safeGraphErrorCode(r.body);
  SyncDebug.trace('provider.graph.error', {
    'operation': op,
    'status': r.statusCode,
    'code': ?graphErrorCode,
  });
  if (r.statusCode == 401)
    throw OneDriveAuthException('Authentication expired or revoked');
  if (r.statusCode == 403)
    throw OneDriveException(
      '$op: permission denied or quota exceeded',
      statusCode: r.statusCode,
      operation: op,
    );
  if (r.statusCode == 404)
    throw OneDriveException(
      'Remote target not found',
      statusCode: r.statusCode,
      operation: op,
    );
  if (r.statusCode == 412)
    throw OneDriveException(
      'Remote precondition failed',
      statusCode: r.statusCode,
      operation: op,
    );
  if (r.statusCode == 503)
    throw OneDriveException(
      'OneDrive is preparing storage; retry shortly',
      statusCode: r.statusCode,
      operation: op,
    );
  if (r.statusCode == 429)
    throw OneDriveException(
      'OneDrive request throttled or quota exceeded; retry shortly',
      statusCode: r.statusCode,
      operation: op,
    );
  if (r.statusCode == 504)
    throw OneDriveException(
      'OneDrive request timed out; retry shortly',
      statusCode: r.statusCode,
      operation: op,
    );
  throw OneDriveException(
    op,
    statusCode: r.statusCode,
    operation: op,
    graphErrorCode: graphErrorCode,
  );
}

List<String> _scopeNames(Object? value) {
  if (value is String) {
    return value
        .split(RegExp(r'\s+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }
  if (value is List) {
    return value
        .whereType<String>()
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }
  return const [];
}

void _requireAppFolderScope(Iterable<String> scopes) {
  final granted = scopes.toSet();
  final appFolderPresent = granted.contains('Files.ReadWrite.AppFolder');
  SyncDebug.trace('provider.oauth.scopes', {
    'filesReadWriteAppFolder': appFolderPresent,
    'scopeCount': granted.length,
  });
  if (!appFolderPresent) {
    throw OneDriveAuthException(
      'Microsoft consent did not grant Files.ReadWrite.AppFolder; revoke Realmwise consent and reconnect',
    );
  }
}

class OneDriveOAuthAuthenticator implements SyncAuthenticator {
  OneDriveOAuthAuthenticator({
    required this.clientId,
    required this.redirectUri,
    required this.browser,
    required this.callback,
    required this.tokenStore,
    this.tenant = 'common',
    this.callbackTimeout = const Duration(minutes: 5),
    http.Client? httpClient,
    this._delay,
    this.maxTransientRetries = 3,
  }) : _http = httpClient ?? http.Client();
  final String clientId, tenant;
  final Uri redirectUri;
  final OneDriveOAuthBrowser browser;
  final OneDriveOAuthCallback callback;
  final OneDriveTokenStore tokenStore;
  final Duration callbackTimeout;
  final http.Client _http;
  final Future<void> Function(Duration)? _delay;
  final int maxTransientRetries;
  String get _key => 'onedrive_oauth:$clientId';

  Future<http.Response> _retryGraph(
    Future<http.Response> Function() request,
  ) async {
    var attempt = 0;
    while (true) {
      final response = await request();
      if (![429, 503, 504].contains(response.statusCode) ||
          attempt >= maxTransientRetries)
        return response;
      final retryAfter = int.tryParse(response.headers['retry-after'] ?? '');
      final wait = Duration(
        seconds: (retryAfter ?? (1 << attempt)).clamp(1, 30).toInt(),
      );
      SyncDebug.trace('provider.graph.retry', {
        'attempt': attempt + 1,
        'backoffMs': wait.inMilliseconds,
        'status': response.statusCode,
      });
      if (_delay != null) {
        await _delay(wait);
      } else {
        await Future<void>.delayed(wait);
      }
      attempt++;
    }
  }

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
    Future<Uri>? callbackFuture;
    late final Uri u;
    try {
      // Attach a drain handler immediately. If opening the browser fails, the
      // native/localhost callback future may later complete with cancellation;
      // that secondary error must not become an uncaught async exception.
      callbackFuture = callback.waitForCallback();
      unawaited(callbackFuture.then<void>((_) {}, onError: (_, _) {}));
      await browser.open(auth);
      u = await callbackFuture.timeout(
        callbackTimeout,
        onTimeout: () => throw OneDriveAuthException(
          'Timed out waiting for OneDrive OAuth callback',
        ),
      );
    } catch (_) {
      final cancellable = callback;
      if (cancellable is OneDriveOAuthCallbackCancellation) {
        try {
          await (cancellable as OneDriveOAuthCallbackCancellation).cancel();
        } catch (_) {}
      }
      rethrow;
    }
    if (u.queryParameters['state'] != state)
      throw OneDriveAuthException('Invalid OAuth state');
    if (u.queryParameters['error'] != null) {
      final error = u.queryParameters['error'];
      SyncDebug.trace('provider.oauth.error', {
        'phase': 'authorization',
        'code': ?error,
      });
      throw OneDriveAuthException(_safe(error, 'authorization'));
    }
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
      final e = _safeOAuthErrorCode(r.body);
      SyncDebug.trace('provider.oauth.error', {
        'phase': 'tokenExchange',
        'status': r.statusCode,
        'code': ?e,
      });
      throw OneDriveAuthException(_safe(e, 'token exchange'));
    }
    final j = jsonDecode(r.body) as Map;
    final access = j['access_token'] as String?;
    if (access == null) throw OneDriveAuthException('Missing access token');
    final scopes = _scopeNames(j['scope']);
    _requireAppFolderScope(scopes);
    final t = <String, Object?>{
      'access_token': access,
      'refresh_token': j['refresh_token'],
      'expires_at': DateTime.now()
          .add(Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 3600))
          .toIso8601String(),
      'account_id': 'onedrive',
      'scopes': scopes,
    };
    final me = await _retryGraph(
      () => _http.get(
        Uri.parse('https://graph.microsoft.com/v1.0/me'),
        headers: {'Authorization': 'Bearer $access'},
      ),
    );
    if (me.statusCode != 200) {
      if (me.statusCode == 503)
        throw OneDriveAuthException(
          'OneDrive is preparing storage; retry shortly',
        );
      if (me.statusCode == 429)
        throw OneDriveAuthException(
          'OneDrive request throttled; retry shortly',
        );
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

class OneDriveProvider implements SyncProvider, SyncLeaseProvider {
  OneDriveProvider({
    required this.authenticator,
    required this.tokenStore,
    http.Client? httpClient,
    this.delay,
    this.maxTransientRetries = 3,
  }) : _http = httpClient ?? http.Client();
  final OneDriveOAuthAuthenticator authenticator;
  final OneDriveTokenStore tokenStore;
  final http.Client _http;
  final Future<void> Function(Duration)? delay;
  final int maxTransientRetries;
  final Map<String, String> _tags = {};
  // The app-root ID is account-specific.  Keep it for the lifetime of this
  // provider so lease operations do not repeatedly resolve the special folder,
  // but never share it across signed-in accounts.
  final Map<String, String> _appRootIds = {};

  Future<Map<String, String>> _authHeaders(SyncAuthSession s) async => {
    'Authorization': 'Bearer ${await _access(s)}',
  };

  Future<http.Response> _retryTransient(
    Future<http.Response> Function() request,
  ) async {
    var attempt = 0;
    while (true) {
      final response = await request();
      if (![429, 503, 504].contains(response.statusCode) ||
          attempt >= maxTransientRetries)
        return response;
      final retryAfter = int.tryParse(response.headers['retry-after'] ?? '');
      final seconds = retryAfter ?? (1 << attempt);
      final wait = Duration(seconds: seconds.clamp(1, 30).toInt());
      SyncDebug.trace('provider.graph.retry', {
        'attempt': attempt + 1,
        'backoffMs': wait.inMilliseconds,
        'status': response.statusCode,
      });
      if (delay != null) {
        await delay!(wait);
      } else {
        await Future<void>.delayed(wait);
      }
      attempt++;
    }
  }

  Future<void> _waitForConsistency(int attempt) async {
    final wait = Duration(seconds: (1 << attempt).clamp(1, 30).toInt());
    SyncDebug.trace('provider.download.retry', {
      'attempt': attempt + 1,
      'backoffMs': wait.inMilliseconds,
    });
    if (delay != null) {
      await delay!(wait);
    } else {
      await Future<void>.delayed(wait);
    }
  }

  @override
  String get provider => 'onedrive';
  String _leasePath(String c) =>
      'Realmwise/Realmwise.lease.${sha256.convert(utf8.encode(c)).toString()}.json';
  Future<String> _appRootId(SyncAuthSession s) async {
    final cached = _appRootIds[s.accountId];
    if (cached != null) return cached;
    final root = await _root(s);
    final id = root['id']!;
    _appRootIds[s.accountId] = id;
    return id;
  }

  Uri _leaseItemUri(String rootId, String catalogIdentity) => Uri.parse(
    'https://graph.microsoft.com/v1.0/me/drive/items/$rootId:/${_leasePath(catalogIdentity)}',
  );

  Uri _leaseContentUri(String rootId, String catalogIdentity) =>
      Uri.parse('${_leaseItemUri(rootId, catalogIdentity)}:/content');

  Future<Map?> _leaseResource(SyncAuthSession s, String c) async {
    final rootId = await _appRootId(s);
    final r = await _retryTransient(
      () async =>
          _http.get(_leaseItemUri(rootId, c), headers: await _authHeaders(s)),
    );
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) _fail(r, 'OneDrive lease metadata failed');
    return jsonDecode(r.body) as Map;
  }

  Future<SyncLease?> _cloudLease(SyncAuthSession s, String c) async {
    final m = await _leaseResource(s, c);
    if (m == null) return null;
    final d = await _retryTransient(
      () async => _http.get(Uri.parse('${m['@microsoft.graph.downloadUrl']}')),
    );
    if (d.statusCode != 200)
      throw OneDriveException('OneDrive lease download failed');
    final x = jsonDecode(d.body) as Map;
    return SyncLease(
      catalogIdentity: c,
      ownerDeviceId: x['ownerDeviceId'] as String,
      ownerDeviceName: x['ownerDeviceName'] as String,
      generation: x['generation'] as String,
      token: x['token'] as String,
      issuedAt: DateTime.parse(x['issuedAt'] as String),
      expiresAt: DateTime.parse(x['expiresAt'] as String),
      lastRenewedAt: DateTime.parse(x['lastRenewedAt'] as String),
      remoteRevision: m['eTag'] is String && (m['eTag'] as String).isNotEmpty
          ? SyncRevision(m['eTag'] as String)
          : null,
    );
  }

  @override
  Future<SyncLease?> readLease(
    SyncAuthSession s,
    SyncRemoteTarget t,
    String c,
  ) => _cloudLease(s, c);
  Future<SyncLease> _writeLease(
    SyncAuthSession s,
    SyncLease l,
    String? etag,
  ) async {
    final h = {
      'Authorization': 'Bearer ${await _access(s)}',
      'Content-Type': 'application/json',
      'If-Match': ?etag,
      if (etag == null) 'If-None-Match': '*',
    };
    final rootId = await _appRootId(s);
    final r = await _http.put(
      _leaseContentUri(rootId, l.catalogIdentity),
      headers: h,
      body: jsonEncode({
        'catalogIdentity': l.catalogIdentity,
        'ownerDeviceId': l.ownerDeviceId,
        'ownerDeviceName': l.ownerDeviceName,
        'generation': l.generation,
        'token': l.token,
        'issuedAt': l.issuedAt.toIso8601String(),
        'expiresAt': l.expiresAt.toIso8601String(),
        'lastRenewedAt': l.lastRenewedAt.toIso8601String(),
      }),
    );
    if (r.statusCode == 412) throw const SyncLeaseLostException();
    if (r.statusCode != 200 && r.statusCode != 201)
      _fail(r, 'OneDrive lease write failed');
    return l;
  }

  @override
  Future<SyncLease> acquireLease(
    SyncAuthSession s,
    SyncRemoteTarget t,
    String c, {
    required String deviceId,
    required String deviceName,
    required Duration duration,
    bool takeover = false,
  }) async {
    final o = await _cloudLease(s, c), n = DateTime.now().toUtc();
    if (!takeover && o != null && o.isValidAt(n) && o.ownerDeviceId != deviceId)
      throw SyncLeaseContendedException(o);
    final l = SyncLease(
      catalogIdentity: c,
      ownerDeviceId: deviceId,
      ownerDeviceName: deviceName,
      generation: ((int.tryParse(o?.generation ?? '') ?? 0) + 1).toString(),
      token: '${deviceId}_${n.microsecondsSinceEpoch}',
      issuedAt: n,
      expiresAt: n.add(duration),
      lastRenewedAt: n,
    );
    return _writeLease(s, l, o?.remoteRevision?.value);
  }

  @override
  Future<SyncLease> renewLease(
    SyncAuthSession s,
    SyncRemoteTarget t,
    String c, {
    required String deviceId,
    required String token,
    required Duration duration,
  }) async {
    final o = await _cloudLease(s, c), n = DateTime.now().toUtc();
    if (o == null ||
        o.ownerDeviceId != deviceId ||
        o.token != token ||
        !o.isValidAt(n) ||
        o.remoteRevision?.value.isNotEmpty != true)
      throw const SyncLeaseLostException();
    final l = SyncLease(
      catalogIdentity: c,
      ownerDeviceId: o.ownerDeviceId,
      ownerDeviceName: o.ownerDeviceName,
      generation: o.generation,
      token: o.token,
      issuedAt: o.issuedAt,
      expiresAt: n.add(duration),
      lastRenewedAt: n,
    );
    return _writeLease(s, l, o.remoteRevision?.value);
  }

  @override
  Future<void> releaseLease(
    SyncAuthSession s,
    SyncRemoteTarget t,
    String c, {
    required String deviceId,
    required String token,
  }) async {
    final o = await _cloudLease(s, c);
    if (o == null || o.ownerDeviceId != deviceId || o.token != token) return;
    final etag = o.remoteRevision?.value;
    if (etag == null || etag.isEmpty) throw const SyncLeaseLostException();
    final rootId = await _appRootId(s);
    final r = await _http.delete(
      _leaseItemUri(rootId, c),
      headers: {
        'Authorization': 'Bearer ${await _access(s)}',
        'If-Match': etag,
      },
    );
    if (r.statusCode == 412) throw const SyncLeaseLostException();
    if (r.statusCode != 204 && r.statusCode != 404)
      _fail(r, 'OneDrive lease release failed');
  }

  Future<void> clearCredentials() => tokenStore.delete(authenticator._key);
  Future<SyncAuthSession?> restoreSession() async {
    final t = await tokenStore.read(authenticator._key);
    if (t['access_token'] == null && t['refresh_token'] == null) return null;
    return SyncAuthSession(accountId: t['account_id'] as String? ?? 'onedrive');
  }

  @override
  Future<SyncAuthSession> authenticate() => authenticator.authenticate();

  Future<void> cancelPendingAuthentication() async {
    final cancellable = authenticator.callback;
    if (cancellable is OneDriveOAuthCallbackCancellation) {
      try {
        await (cancellable as OneDriveOAuthCallbackCancellation).cancel();
      } catch (_) {
        // Cancellation must not mask the connection operation's result.
      }
    }
  }

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
            e.isAfter(DateTime.now().add(const Duration(minutes: 1))))) {
      _requireAppFolderScope(_scopeNames(t['scopes']));
      return a;
    }
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
    final refreshedScopes = _scopeNames(j['scope']);
    if (refreshedScopes.isNotEmpty) {
      t['scopes'] = refreshedScopes;
    }
    _requireAppFolderScope(_scopeNames(t['scopes']));
    t['access_token'] = j['access_token'];
    if (j['refresh_token'] is String) t['refresh_token'] = j['refresh_token'];
    t['expires_at'] = DateTime.now()
        .add(Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 3600))
        .toIso8601String();
    await tokenStore.write(k, t);
    return j['access_token'] as String;
  }

  Future<Map<String, String>> _root(SyncAuthSession s) async {
    Future<http.Response> readRoot() => _retryTransient(
      () async => _http.get(
        Uri.parse('https://graph.microsoft.com/v1.0/me/drive/special/approot'),
        headers: await _authHeaders(s),
      ),
    );

    var r = await readRoot();
    if (r.statusCode == 404) {
      // A content write through the special-folder namespace is the documented
      // first-use operation for Files.ReadWrite.AppFolder. Unlike the generic
      // /children folder endpoint, it does not require Files.ReadWrite.
      const markerName = '.realmwise-approot-initialize';
      final bootstrap = await _retryTransient(
        () async => _http.put(
          Uri.parse(
            'https://graph.microsoft.com/v1.0/me/drive/special/approot/children/$markerName/content',
          ),
          headers: {
            ...(await _authHeaders(s)),
            'Content-Type': 'application/octet-stream',
          },
          body: Uint8List(0),
        ),
      );
      if (bootstrap.statusCode ~/ 100 != 2) {
        _fail(bootstrap, 'OneDrive app root bootstrap write failed');
      }

      // Materialization can still be briefly asynchronous on personal drives.
      for (var attempt = 0; attempt < 3; attempt++) {
        r = await readRoot();
        if (r.statusCode != 404) break;
        if (attempt < 2) await _waitForConsistency(attempt);
      }

      if (r.statusCode == 200) {
        // Do not leave an implementation marker in the user's app folder.
        // Cleanup is best effort: a successful root lookup is sufficient to
        // continue, and a later retry can remove a stale zero-byte marker.
        final root = jsonDecode(r.body) as Map;
        final rootId = root['id'] as String;
        await _retryTransient(
          () async => _http.delete(
            Uri.parse(
              'https://graph.microsoft.com/v1.0/me/drive/items/$rootId:/$markerName',
            ),
            headers: await _authHeaders(s),
          ),
        );
      }
    }
    if (r.statusCode != 200) _fail(r, 'OneDrive app root lookup failed');
    final j = jsonDecode(r.body) as Map;
    return {'id': j['id'] as String};
  }

  Future<SyncRemoteTarget> ensureBundleTarget(SyncAuthSession s) async {
    final root = await _root(s);
    final baseHeaders = {'Authorization': 'Bearer ${await _access(s)}'};
    final listing = await _retryTransient(
      () async => _http.get(
        Uri.parse(
          'https://graph.microsoft.com/v1.0/me/drive/items/${root['id']}/children',
        ),
        headers: baseHeaders,
      ),
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
      final created = await _retryTransient(
        () async => _http.post(
          Uri.parse(
            'https://graph.microsoft.com/v1.0/me/drive/items/${root['id']}/children',
          ),
          headers: {...baseHeaders, 'Content-Type': 'application/json'},
          body: jsonEncode({'name': 'Realmwise', 'folder': {}}),
        ),
      );
      if (created.statusCode ~/ 100 != 2)
        _fail(created, 'OneDrive folder creation failed');
      folder = jsonDecode(created.body) as Map;
    }
    final existing = await _listChildren(s, folder['id'] as String);
    if (existing.isNotEmpty) return existing.first;
    // Graph creates folders via /children; create the initially empty bundle
    // through the file-content endpoint, which returns its driveItem.
    final r = await _retryTransient(
      () async => _http.put(
        Uri.parse(
          'https://graph.microsoft.com/v1.0/me/drive/items/${folder['id']}:/${Uri.encodeComponent('Realmwise.realmwise')}:/content',
        ),
        headers: {
          ...(await _authHeaders(s)),
          'Content-Type': 'application/octet-stream',
        },
        body: Uint8List(0),
      ),
    );
    if (r.statusCode ~/ 100 != 2) _fail(r, 'OneDrive bundle creation failed');
    final j = jsonDecode(r.body) as Map;
    return SyncRemoteTarget(id: j['id'] as String, name: j['name'] as String);
  }

  Future<List<SyncRemoteTarget>> _listChildren(
    SyncAuthSession s,
    String id,
  ) async {
    final r = await _retryTransient(
      () async => _http.get(
        Uri.parse(
          'https://graph.microsoft.com/v1.0/me/drive/items/$id/children',
        ),
        headers: await _authHeaders(s),
      ),
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
    final r = await _retryTransient(
      () async => _http.get(
        Uri.parse(
          'https://graph.microsoft.com/v1.0/me/drive/items/${root['id']}/children',
        ),
        headers: await _authHeaders(s),
      ),
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
    final r = await _retryTransient(
      () async => _http.get(
        Uri.parse('https://graph.microsoft.com/v1.0/me/drive/items/${t.id}'),
        headers: {'Authorization': 'Bearer ${await _access(s)}'},
      ),
    );
    if (r.statusCode == 404) {
      SyncDebug.trace('provider.metadata', {'status': 404});
      _tags.remove(t.id);
      return null;
    }
    if (r.statusCode != 200) {
      SyncDebug.trace('provider.metadata.error', {'status': r.statusCode});
      _fail(r, 'OneDrive metadata failed');
    }
    final j = jsonDecode(r.body) as Map;
    final tag = (j['eTag'] ?? r.headers['etag']) as String? ?? '';
    _tags[t.id] = tag;
    final h = (j['file'] as Map?)?['hashes'];
    final metadata = SyncRemoteMetadata(
      revision: SyncRevision(tag),
      contentHash: (h is Map ? h['quickXorHash'] : null) as String? ?? '',
      updatedAt: DateTime.tryParse(j['lastModifiedDateTime'] ?? ''),
    );
    SyncDebug.trace('provider.metadata', {
      'status': r.statusCode,
      'revision': SyncDebug.hashPrefix(metadata.revision.value),
      'etagPresent': tag.isNotEmpty,
    });
    return metadata;
  }

  @override
  Future<SyncUploadResult> upload(
    SyncAuthSession s,
    SyncRemoteTarget t,
    Uint8List payload, {
    SyncPrecondition? precondition,
  }) async {
    final hash = sha256.convert(payload).toString();
    SyncDebug.trace('provider.upload.start', {
      'revision': precondition?.revision == null
          ? 'none'
          : SyncDebug.hashPrefix(precondition!.revision!.value),
      'hash': SyncDebug.hashPrefix(hash),
      'precondition': precondition != null,
    });
    final old = await metadata(s, t);
    if (precondition != null &&
        old != null &&
        ((precondition.revision != null &&
                precondition.revision!.value != old.revision.value) ||
            (precondition.contentHash != null &&
                precondition.contentHash != old.contentHash))) {
      SyncDebug.trace('provider.upload.conflict', {'reason': 'precondition'});
      throw SyncConflictException(old);
    }
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
      SyncDebug.trace('provider.upload.412', {'status': 412});
    if (r.statusCode == 412)
      throw SyncConflictException(
        old ??
            SyncRemoteMetadata(
              revision: const SyncRevision(''),
              contentHash: '',
            ),
      );
    if (r.statusCode ~/ 100 != 2) _fail(r, 'OneDrive upload failed');
    SyncDebug.trace('provider.upload.content', {
      'status': r.statusCode,
      'etagPresent': r.headers['etag'] != null,
    });
    final m = await metadata(s, t);
    return SyncUploadResult(
      metadata:
          m ??
          SyncRemoteMetadata(
            revision: const SyncRevision(''),
            contentHash: _quickXorHash(payload),
          ),
    );
  }

  @override
  Future<SyncDownloadResult> download(
    SyncAuthSession s,
    SyncRemoteTarget t, {
    SyncPrecondition? precondition,
  }) async {
    Uint8List? unsettledPayload;
    SyncRevision? unsettledRevision;
    var hashlessWaits = 0;
    var hashlessConfirmationPending = false;
    for (var attempt = 0; ; attempt++) {
      final m = await metadata(s, t);
      if (m == null) throw OneDriveException('Remote target missing');
      final expectedHash = precondition?.contentHash;
      if (precondition?.revision != null &&
          precondition!.revision!.value != m.revision.value) {
        throw SyncConflictException(m);
      }
      if (expectedHash != null &&
          expectedHash.isNotEmpty &&
          expectedHash != m.contentHash) {
        throw SyncConflictException(m);
      }
      final r = await _retryTransient(
        () async => _http.get(
          Uri.parse(
            'https://graph.microsoft.com/v1.0/me/drive/items/${t.id}/content',
          ),
          headers: {'Authorization': 'Bearer ${await _access(s)}'},
        ),
      );
      if (r.statusCode != 200) _fail(r, 'OneDrive download failed');
      final b = Uint8List.fromList(r.bodyBytes);
      final latest = await metadata(s, t);
      if (latest == null) throw OneDriveException('Remote target missing');
      final hash = _quickXorHash(b);
      if (precondition?.revision != null &&
          precondition!.revision!.value != latest.revision.value) {
        throw SyncConflictException(latest);
      }
      if (expectedHash != null &&
          expectedHash.isNotEmpty &&
          expectedHash != latest.contentHash) {
        throw SyncConflictException(latest);
      }
      final hashesAvailable =
          m.contentHash.isNotEmpty && latest.contentHash.isNotEmpty;
      final coherent =
          latest.revision == m.revision &&
          hashesAvailable &&
          hash == m.contentHash &&
          hash == latest.contentHash;
      if (coherent) return SyncDownloadResult(payload: b, metadata: latest);
      // Some OneDrive responses omit the identity hash briefly after a write.
      // Give metadata/content a bounded settling window before accepting a
      // stable-revision payload whose hash cannot be checked.
      if (!hashesAvailable && latest.revision == m.revision) {
        final stableRead =
            unsettledPayload != null &&
            unsettledRevision == latest.revision &&
            _sameBytes(unsettledPayload, b);
        if (hashlessConfirmationPending && !stableRead) {
          throw OneDriveException('Unable to verify downloaded content');
        }
        if (stableRead && hashlessWaits >= maxTransientRetries) {
          return SyncDownloadResult(payload: b, metadata: latest);
        }
        unsettledPayload = Uint8List.fromList(b);
        unsettledRevision = latest.revision;
        if (hashlessWaits < maxTransientRetries) {
          await _waitForConsistency(hashlessWaits);
          hashlessWaits++;
        } else {
          hashlessConfirmationPending = true;
        }
        continue;
      }
      unsettledPayload = null;
      unsettledRevision = null;
      hashlessWaits = 0;
      hashlessConfirmationPending = false;
      if (attempt >= maxTransientRetries) {
        throw OneDriveException('Content changed while downloading');
      }
      await _waitForConsistency(attempt);
    }
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
