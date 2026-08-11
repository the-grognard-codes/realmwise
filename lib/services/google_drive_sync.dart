import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'secure_storage_service.dart';
import 'sync_contract.dart';

abstract interface class OAuthBrowser {
  Future<void> open(Uri uri);
}

abstract interface class OAuthCallback {
  Future<Uri> waitForCallback();
}

class GoogleDriveAuthException implements Exception {
  GoogleDriveAuthException(this.message);
  final String message;
  @override
  String toString() => 'GoogleDriveAuthException: $message';
}

class SyncConflictException implements Exception {
  SyncConflictException(this.remote);
  final SyncRemoteMetadata remote;
  @override
  String toString() => 'SyncConflictException';
}

class GoogleDriveException implements Exception {
  GoogleDriveException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'GoogleDriveException($statusCode): $message';
}

Never _driveFailure(http.Response response, String operation) {
  final message = switch (response.statusCode) {
    401 => 'Authentication expired',
    403 => 'Permission denied or quota exceeded',
    429 => 'Rate limited; retry later',
    _ => operation,
  };
  throw GoogleDriveException(message, statusCode: response.statusCode);
}

String _safeOAuthError(String? error, String operation) {
  const allowed = {
    'invalid_grant',
    'invalid_client',
    'unauthorized_client',
    'access_denied',
  };
  final code = error?.trim();
  return code != null && allowed.contains(code)
      ? 'OAuth $operation failed ($code)'
      : 'OAuth $operation failed';
}

Never _tokenFailure(http.Response response, String operation) {
  String? error;
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map) {
      final rawError = decoded['error'];
      if (rawError is String && rawError.trim().isNotEmpty) {
        error = rawError.trim();
      }
    }
  } catch (_) {
    // Fall through to a generic, safe message for non-JSON responses.
  }
  throw GoogleDriveAuthException(_safeOAuthError(error, operation));
}

class GoogleDriveTokenStore {
  GoogleDriveTokenStore(this.storage);
  final TokenStorage storage;
  Future<Map<String, Object?>> read(String key) async {
    final raw = await storage.read(key);
    if (raw == null) return <String, Object?>{};
    try {
      return (jsonDecode(raw) as Map).cast<String, Object?>();
    } catch (_) {
      return <String, Object?>{};
    }
  }

  Future<void> write(String key, Map<String, Object?> value) =>
      storage.write(key, jsonEncode(value));
  Future<void> delete(String key) => storage.delete(key);
}

class GoogleDriveOAuthAuthenticator implements SyncAuthenticator {
  GoogleDriveOAuthAuthenticator({
    required this.clientId,
    required this.redirectUri,
    required this.browser,
    required this.callback,
    required this.tokenStore,
    this.clientSecret,
    this.scopes = const ['https://www.googleapis.com/auth/drive.appdata'],
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();
  final String clientId;
  final String? clientSecret;
  final Uri redirectUri;
  final OAuthBrowser browser;
  final OAuthCallback callback;
  final GoogleDriveTokenStore tokenStore;
  final List<String> scopes;
  final http.Client _http;
  String get _key => 'google_drive_oauth:$clientId';

  @override
  Future<SyncAuthSession> authenticate() async {
    final verifier = _random(64);
    final challenge = base64Url
        .encode(sha256.convert(utf8.encode(verifier)).bytes)
        .replaceAll('=', '');
    final state = _random(24);
    final auth = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': clientId,
      'redirect_uri': redirectUri.toString(),
      'response_type': 'code',
      'scope': scopes.join(' '),
      'access_type': 'offline',
      'prompt': 'consent',
      'state': state,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
    });
    final callbackFuture = callback.waitForCallback();
    await browser.open(auth);
    final result = await callbackFuture;
    if (result.queryParameters['state'] != state)
      throw GoogleDriveAuthException('Invalid OAuth state');
    final error = result.queryParameters['error'];
    if (error != null)
      throw GoogleDriveAuthException(_safeOAuthError(error, 'authorization'));
    final code = result.queryParameters['code'];
    if (code == null)
      throw GoogleDriveAuthException('Missing authorization code');
    final response = await _http.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      body: {
        'code': code,
        'client_id': clientId,
        'redirect_uri': redirectUri.toString(),
        'grant_type': 'authorization_code',
        'code_verifier': verifier,
        if (clientSecret != null) 'client_secret': clientSecret!,
      },
    );
    if (response.statusCode ~/ 100 != 2)
      _tokenFailure(response, 'token exchange');
    final json = jsonDecode(response.body) as Map;
    final access = json['access_token'] as String?;
    if (access == null) throw GoogleDriveAuthException('Missing access token');
    await tokenStore.write(_key, {
      'access_token': access,
      'refresh_token': json['refresh_token'],
      'expires_at': DateTime.now()
          .add(Duration(seconds: (json['expires_in'] as num?)?.toInt() ?? 3600))
          .toIso8601String(),
      'account_id': 'google-drive',
    });
    return const SyncAuthSession(accountId: 'google-drive');
  }

  static String _random(int n) {
    final r = Random.secure();
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~';
    return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
  }
}

class GoogleDriveProvider implements SyncProvider {
  GoogleDriveProvider({
    required this.authenticator,
    required this.tokenStore,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();
  final GoogleDriveOAuthAuthenticator authenticator;
  final GoogleDriveTokenStore tokenStore;
  final http.Client _http;
  final Map<String, String> _etags = {};
  @override
  String get provider => 'google_drive';
  Future<void> clearCredentials() => tokenStore.delete(authenticator._key);
  Future<SyncAuthSession?> restoreSession() async {
    final token = await tokenStore.read(authenticator._key);
    final access = token['access_token'] as String?;
    if (access == null && token['refresh_token'] == null) return null;
    return const SyncAuthSession(accountId: 'google-drive');
  }

  @override
  Future<SyncAuthSession> authenticate() => authenticator.authenticate();
  Future<String> _access(SyncAuthSession session) async {
    final key = authenticator._key;
    final t = await tokenStore.read(key);
    final access = t['access_token'] as String?;
    final expiry = DateTime.tryParse(t['expires_at'] as String? ?? '');
    if (access != null &&
        (expiry == null ||
            expiry.isAfter(DateTime.now().add(const Duration(minutes: 1)))))
      return access;
    final refresh = t['refresh_token'] as String?;
    if (refresh == null) throw GoogleDriveAuthException('Not authenticated');
    final r = await _http.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      body: {
        'client_id': authenticator.clientId,
        'grant_type': 'refresh_token',
        'refresh_token': refresh,
        if (authenticator.clientSecret != null)
          'client_secret': authenticator.clientSecret!,
      },
    );
    if (r.statusCode ~/ 100 != 2) _tokenFailure(r, 'token refresh');
    final j = jsonDecode(r.body) as Map;
    t['access_token'] = j['access_token'];
    t['expires_at'] = DateTime.now()
        .add(Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 3600))
        .toIso8601String();
    await tokenStore.write(key, t.cast<String, Object?>());
    return j['access_token'] as String;
  }

  Future<String> ensureRealmwiseFolder(SyncAuthSession s) async {
    // appDataFolder is a hidden, provider-managed folder; it must not be
    // created or surfaced as a user-visible Realmwise directory.
    return 'appDataFolder';
  }

  Future<SyncRemoteTarget> ensureBundleTarget(SyncAuthSession s) async {
    final folder = await ensureRealmwiseFolder(s);
    final auth = {'Authorization': 'Bearer ${await _access(s)}'};
    final q = Uri.encodeQueryComponent(
      "name = 'Realmwise.realmwise' and '$folder' in parents and trashed = false",
    );
    final found = await _http.get(
      Uri.parse(
        'https://www.googleapis.com/drive/v3/files?q=$q&spaces=appDataFolder&fields=files(id,name)',
      ),
      headers: auth,
    );
    if (found.statusCode != 200)
      _driveFailure(found, 'Drive bundle lookup failed');
    final files = (jsonDecode(found.body)['files'] as List? ?? []);
    if (files.isNotEmpty)
      return SyncRemoteTarget(
        id: files.first['id'] as String,
        name: files.first['name'] as String,
      );
    final created = await _http.post(
      Uri.parse('https://www.googleapis.com/drive/v3/files'),
      headers: {...auth, 'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': 'Realmwise.realmwise',
        'parents': [folder],
        'mimeType': 'application/zip',
      }),
    );
    if (created.statusCode ~/ 100 != 2)
      _driveFailure(created, 'Drive bundle creation failed');
    final j = jsonDecode(created.body);
    return SyncRemoteTarget(id: j['id'] as String, name: j['name'] as String);
  }

  @override
  Future<List<SyncRemoteTarget>> listRemoteTargets(SyncAuthSession s) async {
    final r = await _http.get(
      Uri.parse(
        "https://www.googleapis.com/drive/v3/files?q=name%3D%27Realmwise.realmwise%27+and+%27appDataFolder%27+in+parents+and+trashed%3Dfalse&spaces=appDataFolder&fields=files(id,name)",
      ),
      headers: {'Authorization': 'Bearer ${await _access(s)}'},
    );
    if (r.statusCode != 200) throw Exception('Drive list failed');
    final files = (jsonDecode(r.body)['files'] as List? ?? []);
    return files
        .map(
          (f) => SyncRemoteTarget(
            id: f['id'] as String,
            name: f['name'] as String,
          ),
        )
        .toList();
  }

  @override
  Future<SyncRemoteMetadata?> metadata(
    SyncAuthSession s,
    SyncRemoteTarget t,
  ) async {
    final r = await _http.get(
      Uri.parse(
        'https://www.googleapis.com/drive/v3/files/${t.id}?fields=md5Checksum,version,modifiedTime,description,appProperties',
      ),
      headers: {'Authorization': 'Bearer ${await _access(s)}'},
    );
    if (r.statusCode == 404) return null;
    if (r.statusCode != 200) throw Exception('Drive metadata failed');
    final j = jsonDecode(r.body);
    final etag = r.headers['etag'];
    if (etag != null) {
      _etags[t.id] = etag;
    } else if (j['etag'] is String) {
      _etags[t.id] = j['etag'] as String;
    }
    return SyncRemoteMetadata(
      revision: SyncRevision('${j['version']}'),
      contentHash:
          ((j['appProperties'] as Map?)?['realmwiseSha256'] as String?) ??
          (j['description'] as String?) ??
          (j['md5Checksum'] as String? ?? ''),
      updatedAt: DateTime.tryParse(j['modifiedTime'] ?? ''),
    );
  }

  @override
  Future<SyncUploadResult> upload(
    SyncAuthSession s,
    SyncRemoteTarget t,
    Uint8List payload, {
    SyncPrecondition? precondition,
  }) async {
    final hash = sha256.convert(payload).toString();
    final old = await metadata(s, t);
    if (precondition != null &&
        old != null &&
        ((precondition.revision != null &&
                precondition.revision!.value != old.revision.value) ||
            (precondition.contentHash != null &&
                precondition.contentHash != old.contentHash)))
      throw SyncConflictException(old);
    final r = await _http.patch(
      Uri.parse(
        'https://www.googleapis.com/upload/drive/v3/files/${t.id}?uploadType=media',
      ),
      headers: {
        'Authorization': 'Bearer ${await _access(s)}',
        if (_etags[t.id] != null) 'If-Match': _etags[t.id]!,
        'Content-Type': 'application/octet-stream',
        'X-Upload-Content-Type': 'application/zip',
        'X-Upload-Content-Length': '${payload.length}',
      },
      body: payload,
    );
    if (r.statusCode == 412 && old != null) throw SyncConflictException(old);
    if (r.statusCode ~/ 100 != 2) throw Exception('Drive upload failed');
    final properties = await _http.patch(
      Uri.parse(
        'https://www.googleapis.com/drive/v3/files/${t.id}'
        '?fields=version,md5Checksum,modifiedTime,description,appProperties',
      ),
      headers: {
        'Authorization': 'Bearer ${await _access(s)}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'appProperties': {'realmwiseSha256': hash},
      }),
    );
    if (properties.statusCode == 412 && old != null) {
      throw SyncConflictException(old);
    }
    if (properties.statusCode ~/ 100 != 2) {
      throw Exception('Drive metadata update failed');
    }

    // The metadata update is a second Drive write and therefore advances the
    // file version. Prefer the resource returned by that write when available
    // so callers can immediately use the returned revision as a precondition;
    // an eventually-consistent metadata GET may still expose the prior version.
    SyncRemoteMetadata? returned;
    try {
      final j = jsonDecode(properties.body);
      if (j is Map && j['version'] != null) {
        returned = SyncRemoteMetadata(
          revision: SyncRevision('${j['version']}'),
          contentHash:
              ((j['appProperties'] as Map?)?['realmwiseSha256'] as String?) ??
              hash,
          updatedAt: DateTime.tryParse(j['modifiedTime'] ?? ''),
        );
      }
    } catch (_) {
      // Fall back to a metadata read for clients/mocks with an empty response.
    }
    final fetched = await metadata(s, t);
    final m = returned ?? fetched;
    return SyncUploadResult(
      metadata:
          m ??
          SyncRemoteMetadata(
            revision: const SyncRevision('0'),
            contentHash: hash,
          ),
    );
  }

  @override
  Future<SyncDownloadResult> download(
    SyncAuthSession s,
    SyncRemoteTarget t, {
    SyncPrecondition? precondition,
  }) async {
    final initial = await metadata(s, t);
    if (initial == null) throw Exception('Remote target missing');
    var m = initial;
    if (precondition != null && precondition.revision != null) {
      // Drive metadata can briefly lag the just-completed upload. Re-read a
      // small bounded number of times before treating a revision mismatch as
      // a real conflict; no delay keeps this deterministic for callers/tests.
      final expectedRevision = precondition.revision!.value;
      final expectedNumber = int.tryParse(expectedRevision);
      final expected = expectedNumber ?? -1;
      var canRetry = expectedNumber != null;
      final observedNumber = int.tryParse(m.revision.value);
      if (observedNumber == null || observedNumber > expected) {
        canRetry = false;
      }
      for (
        var attempt = 0;
        canRetry && attempt < 3 && expectedRevision != m.revision.value;
        attempt++
      ) {
        final refreshed = await metadata(s, t);
        if (refreshed == null) break;
        m = refreshed;
        final refreshedNumber = int.tryParse(m.revision.value);
        if (refreshedNumber == null || refreshedNumber > expected) {
          canRetry = false;
        }
      }
      if (expectedRevision != m.revision.value) {
        throw SyncConflictException(m);
      }
    }
    final r = await _http.get(
      Uri.parse('https://www.googleapis.com/drive/v3/files/${t.id}?alt=media'),
      headers: {'Authorization': 'Bearer ${await _access(s)}'},
    );
    if (r.statusCode != 200) throw Exception('Drive download failed');
    final bytes = Uint8List.fromList(r.bodyBytes);
    if (sha256.convert(bytes).toString() != m.contentHash &&
        m.contentHash.isNotEmpty)
      throw Exception('Content hash mismatch');
    return SyncDownloadResult(payload: bytes, metadata: m);
  }
}
