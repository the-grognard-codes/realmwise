import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'secure_storage_service.dart';
import 'sync_contract.dart';
import 'sync_debug.dart';

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
    final token = <String, Object?>{
      'access_token': access,
      'refresh_token': json['refresh_token'],
      'expires_at': DateTime.now()
          .add(Duration(seconds: (json['expires_in'] as num?)?.toInt() ?? 3600))
          .toIso8601String(),
      'account_id': 'google-drive',
    };
    // Best-effort profile lookup using the existing appdata scope. Failure
    // must not prevent connecting; no token details are persisted or exposed.
    try {
      final profile = await _http.get(
        Uri.parse(
          'https://www.googleapis.com/drive/v3/about?fields=user(displayName,emailAddress)',
        ),
        headers: {'Authorization': 'Bearer $access'},
      );
      if (profile.statusCode == 200) {
        final user = (jsonDecode(profile.body) as Map?)?['user'];
        if (user is Map) {
          final email = user['emailAddress'] as String?;
          final name = user['displayName'] as String?;
          if (email != null && email.trim().isNotEmpty)
            token['account_id'] = email.trim();
          // Use the stable email address as the account label when available;
          // displayName is only a fallback for profiles without an email.
          final label = email != null && email.trim().isNotEmpty
              ? email.trim()
              : name?.trim();
          if (label != null && label.isNotEmpty) token['account_name'] = label;
        }
      }
    } catch (_) {}
    await tokenStore.write(_key, token);
    return SyncAuthSession(
      accountId: token['account_id'] as String,
      displayName: token['account_name'] as String?,
    );
  }

  static String _random(int n) {
    final r = Random.secure();
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~';
    return List.generate(n, (_) => chars[r.nextInt(chars.length)]).join();
  }
}

class GoogleDriveProvider implements SyncProvider, SyncLeaseProvider {
  GoogleDriveProvider({
    required this.authenticator,
    required this.tokenStore,
    http.Client? httpClient,
    Future<void> Function(Duration duration)? delay,
  }) : _http = httpClient ?? http.Client(),
       _delay = delay ?? Future<void>.delayed;
  final GoogleDriveOAuthAuthenticator authenticator;
  final GoogleDriveTokenStore tokenStore;
  final http.Client _http;
  final Future<void> Function(Duration duration) _delay;
  final Map<String, String> _etags = {};
  @override
  String get provider => 'google_drive';

  Future<String?> _leaseFile(SyncAuthSession s, String c) async {
    final q=Uri.encodeQueryComponent("name = 'Realmwise.lease.${sha256.convert(utf8.encode(c)).toString()}' and 'appDataFolder' in parents and trashed = false");
    final r=await _http.get(Uri.parse('https://www.googleapis.com/drive/v3/files?q=$q&spaces=appDataFolder&fields=files(id)'),headers:{'Authorization':'Bearer ${await _access(s)}'});
    if(r.statusCode!=200)return null; final a=(jsonDecode(r.body)['files'] as List? ?? const []); return a.isEmpty?null:a.first['id'] as String;
  }
  Future<SyncLease?> _cloudLease(SyncAuthSession s,String c) async { final id=await _leaseFile(s,c); if(id==null)return null; final r=await _http.get(Uri.parse('https://www.googleapis.com/drive/v3/files/$id?fields=description,version'),headers:{'Authorization':'Bearer ${await _access(s)}'}); if(r.statusCode!=200)return null; final j=jsonDecode(r.body) as Map; final etag=r.headers['etag']; if(etag==null||etag.isEmpty)return null; _etags[id]=etag; final x=jsonDecode(j['description'] as String) as Map; return SyncLease(catalogIdentity:c,ownerDeviceId:x['ownerDeviceId'] as String,ownerDeviceName:x['ownerDeviceName'] as String,generation:x['generation'] as String,token:x['token'] as String,issuedAt:DateTime.parse(x['issuedAt'] as String),expiresAt:DateTime.parse(x['expiresAt'] as String),lastRenewedAt:DateTime.parse(x['lastRenewedAt'] as String),remoteRevision:SyncRevision(etag)); }
  @override Future<SyncLease?> readLease(SyncAuthSession s, SyncRemoteTarget t, String c) => _cloudLease(s,c);
  Future<void> _writeCloudLease(SyncAuthSession s, SyncLease l, String? id, String? revision) async { final body=jsonEncode({'catalogIdentity':l.catalogIdentity,'ownerDeviceId':l.ownerDeviceId,'ownerDeviceName':l.ownerDeviceName,'generation':l.generation,'token':l.token,'issuedAt':l.issuedAt.toIso8601String(),'expiresAt':l.expiresAt.toIso8601String(),'lastRenewedAt':l.lastRenewedAt.toIso8601String()}); final h={'Authorization':'Bearer ${await _access(s)}','Content-Type':'application/json',if(revision!=null)'If-Match':revision}; final r=id==null?await _http.post(Uri.parse('https://www.googleapis.com/drive/v3/files'),headers:h,body:jsonEncode({'name':'Realmwise.lease.${sha256.convert(utf8.encode(l.catalogIdentity))}','parents':['appDataFolder'],'mimeType':'application/octet-stream','description':body})):await _http.patch(Uri.parse('https://www.googleapis.com/drive/v3/files/$id'),headers:h,body:jsonEncode({'description':body})); if(r.statusCode==412)throw const SyncLeaseLostException(); if(r.statusCode~/100!=2)throw Exception('Drive lease write failed'); }
  @override Future<SyncLease> acquireLease(SyncAuthSession s, SyncRemoteTarget t, String c, {required String deviceId, required String deviceName, required Duration duration, bool takeover = false}) async {
    final o=await _cloudLease(s,c), n=DateTime.now().toUtc(); if(!takeover&&o!=null&&o.isValidAt(n)&&o.ownerDeviceId!=deviceId)throw SyncLeaseContendedException(o); final l=SyncLease(catalogIdentity:c,ownerDeviceId:deviceId,ownerDeviceName:deviceName,generation:((int.tryParse(o?.generation??'')??0)+1).toString(),token:'${deviceId}_${n.microsecondsSinceEpoch}',issuedAt:n,expiresAt:n.add(duration),lastRenewedAt:n); await _writeCloudLease(s,l,await _leaseFile(s,c),o?.remoteRevision?.value); return l;
  }
  @override
  Future<SyncLease> renewLease(SyncAuthSession s, SyncRemoteTarget t, String c, {required String deviceId, required String token, required Duration duration}) async {
    final old = await _cloudLease(s,c), now = DateTime.now().toUtc();
    if (old == null || old.ownerDeviceId != deviceId || old.token != token || !old.isValidAt(now)) throw const SyncLeaseLostException();
    final lease = SyncLease(catalogIdentity:c, ownerDeviceId:old.ownerDeviceId, ownerDeviceName:old.ownerDeviceName, generation:old.generation, token:old.token, issuedAt:old.issuedAt, expiresAt:now.add(duration), lastRenewedAt:now);
    await _writeCloudLease(s,lease,await _leaseFile(s,c),old.remoteRevision?.value); return lease;
  }
  @override
  Future<void> releaseLease(SyncAuthSession s, SyncRemoteTarget t, String c, {required String deviceId, required String token}) async {
    final old = await _cloudLease(s,c);
    if (old == null || old.ownerDeviceId != deviceId || old.token != token) return;
    final r=await _http.delete(Uri.parse('https://www.googleapis.com/drive/v3/files/${await _leaseFile(s,c)}'),headers:{'Authorization':'Bearer ${await _access(s)}','If-Match':old.remoteRevision?.value ?? ''});
    if (r.statusCode != 204 && r.statusCode != 200 && r.statusCode != 404) throw Exception('Drive lease release failed');
  }
  Future<void> clearCredentials() => tokenStore.delete(authenticator._key);
  Future<SyncAuthSession?> restoreSession() async {
    final token = await tokenStore.read(authenticator._key);
    final access = token['access_token'] as String?;
    if (access == null && token['refresh_token'] == null) return null;
    return SyncAuthSession(
      accountId: token['account_id'] as String? ?? 'google-drive',
      displayName: token['account_name'] as String?,
    );
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
    if (r.statusCode == 404) {
      SyncDebug.trace('provider.metadata', {'status': 404});
      _etags.remove(t.id);
      return null;
    }
    if (r.statusCode != 200) {
      SyncDebug.trace('provider.metadata.error', {'status': r.statusCode});
      throw Exception('Drive metadata failed');
    }
    final j = jsonDecode(r.body);
    final etag = r.headers['etag'];
    SyncDebug.trace('provider.metadata', {
      'status': r.statusCode,
      'revision': '${j['version']}',
      'etagPresent': etag != null || j['etag'] is String,
    });
    if (etag != null) {
      _etags[t.id] = etag;
    } else if (j['etag'] is String) {
      _etags[t.id] = j['etag'] as String;
    } else {
      _etags.remove(t.id);
    }
    return SyncRemoteMetadata(
      revision: SyncRevision('${j['version']}'),
      contentHash:
          ((j['appProperties'] as Map?)?['realmwiseSha256'] as String?) ??
          (j['description'] as String?) ??
          // Drive's md5Checksum is a different digest algorithm from the
          // SHA-256 identity used by Realmwise.  Do not expose it as the
          // Realmwise content hash: doing so makes an unchanged payload look
          // divergent during precondition and download validation.
          '',
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
    SyncDebug.trace('provider.upload.start', {
      'revision': precondition?.revision?.value ?? 'none',
      'hash': SyncDebug.hashPrefix(hash),
    });
    var old = await metadata(s, t);
    if (precondition != null && old != null) {
      final expectedRevision = precondition.revision?.value;
      final expectedNumber = expectedRevision == null
          ? null
          : int.tryParse(expectedRevision);
      var revisionMismatch =
          expectedRevision != null && expectedRevision != old.revision.value;
      var hashMismatch =
          precondition.contentHash != null &&
          precondition.contentHash != old.contentHash;
      // A Drive file version can advance for metadata-only processing after
      // Realmwise uploaded the same bundle.  A matching Realmwise SHA-256
      // proves the portable payload has not diverged, so adopt the newer
      // revision for this upload rather than reporting a false conflict.
      if (revisionMismatch &&
          !hashMismatch &&
          precondition.contentHash != null) {
        SyncDebug.trace('provider.upload.revision_reconciled', {
          'revision': old.revision.value,
          'hash': SyncDebug.hashPrefix(old.contentHash),
        });
        revisionMismatch = false;
      }
      var canRetry = revisionMismatch && expectedNumber != null;
      final observedNumber = int.tryParse(old.revision.value);
      final expected = expectedNumber;
      if (observedNumber == null ||
          (expected != null && observedNumber > expected)) {
        canRetry = false;
      }
      for (
        var attempt = 0;
        canRetry && revisionMismatch && attempt < 3;
        attempt++
      ) {
        SyncDebug.trace('provider.upload.retry', {
          'attempt': attempt + 1,
          'backoffMs': 100 * (1 << attempt),
        });
        await _delay(Duration(milliseconds: 100 * (1 << attempt)));
        final refreshed = await metadata(s, t);
        if (refreshed == null) break;
        old = refreshed;
        revisionMismatch = expectedRevision != refreshed.revision.value;
        hashMismatch =
            precondition.contentHash != null &&
            precondition.contentHash != refreshed.contentHash;
        if (revisionMismatch &&
            !hashMismatch &&
            precondition.contentHash != null) {
          SyncDebug.trace('provider.upload.revision_reconciled', {
            'revision': refreshed.revision.value,
            'hash': SyncDebug.hashPrefix(refreshed.contentHash),
          });
          revisionMismatch = false;
        }
        final refreshedNumber = int.tryParse(refreshed.revision.value);
        if (refreshedNumber == null ||
            (expected != null && refreshedNumber > expected)) {
          canRetry = false;
        }
      }
      if (hashMismatch || revisionMismatch) {
        SyncDebug.trace('provider.upload.conflict', {
          'revisionMismatch': revisionMismatch,
          'hashMismatch': hashMismatch,
        });
        throw SyncConflictException(old!);
      }
    }
    Future<http.Response> mediaPatch() async => _http.patch(
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
    var r = await mediaPatch();
    SyncDebug.trace('provider.upload.media', {
      'status': r.statusCode,
      'etagPresent': r.headers['etag'] != null,
    });
    if (r.statusCode == 412) {
      // A cached ETag may be stale even when the logical precondition still
      // holds (for example after an earlier successful sync). Refresh
      // metadata/ETag and retry exactly once; never overwrite a divergent
      // remote revision or hash.
      if (precondition == null) throw SyncConflictException(old!);
      final refreshed = await metadata(s, t);
      final matches =
          refreshed != null &&
          ((precondition.contentHash != null &&
                  precondition.contentHash == refreshed.contentHash) ||
              (precondition.contentHash == null &&
                  (precondition.revision == null ||
                      precondition.revision == refreshed.revision)));
      if (!matches) throw SyncConflictException(refreshed ?? old!);
      SyncDebug.trace('provider.upload.412.retry', {'status': 412});
      old = refreshed;
      r = await mediaPatch();
      if (r.statusCode == 412) throw SyncConflictException(refreshed);
    }
    if (r.statusCode ~/ 100 != 2) throw Exception('Drive upload failed');
    final mediaEtag = r.headers['etag'];
    if (mediaEtag != null) _etags[t.id] = mediaEtag;
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
    SyncDebug.trace('provider.upload.properties', {
      'status': properties.statusCode,
      'etagPresent': properties.headers['etag'] != null,
    });
    if (properties.statusCode == 412 && old != null) {
      throw SyncConflictException(old);
    }
    if (properties.statusCode ~/ 100 != 2) {
      throw Exception('Drive metadata update failed');
    }
    final propertiesEtag = properties.headers['etag'];
    if (propertiesEtag != null) _etags[t.id] = propertiesEtag;

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
    final expectedHash = precondition?.contentHash;
    if (expectedHash != null && expectedHash.isNotEmpty) {
      // appProperties can briefly lag the file revision.  Never restore
      // bytes without confirming the expected Realmwise identity.
      for (var attempt = 0;
          attempt < 3 && m.contentHash.isEmpty;
          attempt++) {
        await _delay(Duration(milliseconds: 100 * (1 << attempt)));
        final refreshed = await metadata(s, t);
        if (refreshed == null) break;
        m = refreshed;
      }
      if (m.contentHash.isEmpty) {
        throw SyncConflictException(m);
      }
    }
    if (expectedHash != null &&
        expectedHash.isNotEmpty &&
        m.contentHash.isNotEmpty &&
        expectedHash != m.contentHash) {
      // A matching revision is not sufficient when the caller supplied a
      // content identity. Reject the remote before downloading its bytes.
      throw SyncConflictException(m);
    }
    if (precondition != null && precondition.revision != null) {
      // Drive metadata can briefly lag the just-completed upload. Re-read a
      // small bounded number of times before treating a revision mismatch as
      // a real conflict; bounded backoff avoids racing eventual consistency.
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
        await _delay(Duration(milliseconds: 100 * (1 << attempt)));
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
    Future<Uint8List> fetchBytes() async {
      final r = await _http.get(
        Uri.parse('https://www.googleapis.com/drive/v3/files/${t.id}?alt=media'),
        headers: {'Authorization': 'Bearer ${await _access(s)}'},
      );
      if (r.statusCode != 200) throw Exception('Drive download failed');
      return Uint8List.fromList(r.bodyBytes);
    }

    var bytes = await fetchBytes();
    if (expectedHash == null || expectedHash.isEmpty) {
      // Without a Realmwise hash, require a full confirmation window: each
      // media response is bracketed by metadata reads, and both consecutive
      // byte responses and revisions must agree before accepting the bundle.
      var confirmed = false;
      for (var attempt = 0; attempt < 3 && !confirmed; attempt++) {
        await _delay(Duration(milliseconds: 100 * (1 << attempt)));
        final after = await metadata(s, t);
        if (after == null) throw Exception('Remote target missing');
        if (precondition?.revision != null &&
            after.revision != precondition!.revision) {
          throw SyncConflictException(after);
        }
        if (after.revision != m.revision) {
          m = after;
          if (attempt == 2) throw SyncConflictException(m);
          await _delay(Duration(milliseconds: 100 * (1 << attempt)));
          bytes = await fetchBytes();
          continue;
        }
        final confirmationBytes = await fetchBytes();
        final confirmation = await metadata(s, t);
        if (confirmation == null) throw Exception('Remote target missing');
        if (precondition?.revision != null &&
            confirmation.revision != precondition!.revision) {
          throw SyncConflictException(confirmation);
        }
        final bytesMatch = bytes.length == confirmationBytes.length &&
            bytes.asMap().keys.every((i) => bytes[i] == confirmationBytes[i]);
        // Do not accept an early stable pair: the complete bounded backoff
        // window must elapse before the final consecutive confirmation.
        if (attempt == 2 && confirmation.revision == m.revision && bytesMatch) {
          confirmed = true;
        } else {
          m = confirmation;
          if (attempt == 2) throw SyncConflictException(m);
          await _delay(Duration(milliseconds: 100 * (1 << attempt)));
          bytes = confirmationBytes;
        }
      }
      if (!confirmed) throw SyncConflictException(m);
    }
    if (sha256.convert(bytes).toString() != m.contentHash &&
        m.contentHash.isNotEmpty)
      throw Exception('Content hash mismatch');
    return SyncDownloadResult(payload: bytes, metadata: m);
  }
}
