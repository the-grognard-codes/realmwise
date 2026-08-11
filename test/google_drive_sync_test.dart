import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:realmwise/services/google_drive_sync.dart';
import 'package:realmwise/services/secure_storage_service.dart';
import 'package:realmwise/services/sync_contract.dart';

class MemTokens implements TokenStorage {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class B implements OAuthBrowser {
  Uri? opened;
  @override
  Future<void> open(Uri uri) async => opened = uri;
}

class C implements OAuthCallback {
  C(this.uri);
  final Uri uri;
  @override
  Future<Uri> waitForCallback() async => uri;
}

class DynamicCallback implements OAuthCallback {
  DynamicCallback(this.browser);
  final B browser;
  @override
  Future<Uri> waitForCallback() async {
    while (browser.opened == null) {
      await Future<void>.delayed(Duration.zero);
    }
    final state = browser.opened!.queryParameters['state'];
    return Uri.parse(
      'http://localhost/cb?state=$state&code=authorization-code',
    );
  }
}

class DynamicErrorCallback implements OAuthCallback {
  DynamicErrorCallback(this.browser);
  final B browser;
  @override
  Future<Uri> waitForCallback() async {
    while (browser.opened == null) {
      await Future<void>.delayed(Duration.zero);
    }
    final state = browser.opened!.queryParameters['state'];
    return Uri.parse(
      'http://localhost/cb?state=$state&error=secret-client-token',
    );
  }
}

void main() {
  test(
    'token exchange errors expose Google diagnostics without secrets',
    () async {
      final browser = B();
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'error': 'invalid_grant',
            'error_description':
                'submitted-code client-secret access-token refresh-token',
            'access_token': 'must-not-appear',
          }),
          400,
        ),
      );
      final auth = GoogleDriveOAuthAuthenticator(
        clientId: 'id',
        redirectUri: Uri.parse('http://localhost/cb'),
        browser: browser,
        callback: DynamicCallback(browser),
        tokenStore: GoogleDriveTokenStore(MemTokens()),
        httpClient: client,
      );
      final error = await captureError(auth.authenticate());
      expect(error, isA<GoogleDriveAuthException>());
      expect(error.toString(), contains('invalid_grant'));
      expect(error.toString(), isNot(contains('submitted-code')));
      expect(error.toString(), isNot(contains('client-secret')));
      expect(error.toString(), isNot(contains('access-token')));
      expect(error.toString(), isNot(contains('refresh-token')));
      expect(error.toString(), isNot(contains('must-not-appear')));
      expect(error.toString(), isNot(contains('authorization-code')));
    },
  );

  test('callback OAuth errors are allowlisted and safe', () async {
    final browser = B();
    final auth = GoogleDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost/cb'),
      browser: browser,
      callback: DynamicErrorCallback(browser),
      tokenStore: GoogleDriveTokenStore(MemTokens()),
    );
    final error = await captureError(auth.authenticate());
    expect(
      error.toString(),
      'GoogleDriveAuthException: OAuth authorization failed',
    );
    expect(error.toString(), isNot(contains('secret-client-token')));
  });

  test('oauth success stores token and PKCE', () async {
    final b = B();
    final tokens = MemTokens();
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'access_token': 'a',
          'refresh_token': 'r',
          'expires_in': 3600,
        }),
        200,
      ),
    );
    final auth = GoogleDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost/cb'),
      browser: b,
      callback: C(Uri.parse('http://localhost/cb?state=bad')),
      tokenStore: GoogleDriveTokenStore(tokens),
      httpClient: client,
    );
    expect(auth.authenticate(), throwsA(isA<GoogleDriveAuthException>()));
  });
  test('uses appdata OAuth scope', () async {
    final b = B();
    final tokens = MemTokens();
    final auth = GoogleDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost/cb'),
      browser: b,
      callback: C(Uri.parse('http://localhost/cb?state=bad')),
      tokenStore: GoogleDriveTokenStore(tokens),
    );
    await expectLater(
      auth.authenticate(),
      throwsA(isA<GoogleDriveAuthException>()),
    );
    expect(
      b.opened!.queryParameters['scope'],
      'https://www.googleapis.com/auth/drive.appdata',
    );
  });
  test('refreshes expired token', () async {
    final tokens = MemTokens();
    final key = 'google_drive_oauth:id';
    await tokens.write(
      key,
      jsonEncode({'refresh_token': 'r', 'expires_at': '2000-01-01T00:00:00Z'}),
    );
    final client = MockClient((request) async {
      if (request.url.host == 'oauth2.googleapis.com')
        return http.Response(
          jsonEncode({'access_token': 'new', 'expires_in': 3600}),
          200,
        );
      return http.Response(jsonEncode({'files': []}), 200);
    });
    final auth = GoogleDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost'),
      browser: B(),
      callback: C(Uri.parse('http://localhost')),
      tokenStore: GoogleDriveTokenStore(tokens),
      httpClient: client,
    );
    final p = GoogleDriveProvider(
      authenticator: auth,
      tokenStore: GoogleDriveTokenStore(tokens),
      httpClient: client,
    );
    await p.listRemoteTargets(const SyncAuthSession(accountId: 'x'));
    expect(jsonDecode((await tokens.read(key))!)['access_token'], 'new');
  });
  test('appDataFolder target lookup errors are typed', () async {
    final tokens = MemTokens();
    await tokens.write(
      'google_drive_oauth:id',
      jsonEncode({'access_token': 'a', 'expires_at': '2999-01-01T00:00:00Z'}),
    );
    final client = MockClient((request) async => http.Response('', 403));
    final auth = GoogleDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost'),
      browser: B(),
      callback: C(Uri.parse('http://localhost')),
      tokenStore: GoogleDriveTokenStore(tokens),
      httpClient: client,
    );
    final p = GoogleDriveProvider(
      authenticator: auth,
      tokenStore: GoogleDriveTokenStore(tokens),
      httpClient: client,
    );
    expect(
      p.ensureBundleTarget(const SyncAuthSession(accountId: 'x')),
      throwsA(isA<GoogleDriveException>()),
    );
  });
  test('uses hidden appDataFolder without creating a visible folder', () async {
    final tokens = MemTokens();
    await tokens.write(
      'google_drive_oauth:id',
      jsonEncode({'access_token': 'a', 'expires_at': '2999-01-01T00:00:00Z'}),
    );
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      if (request.method == 'GET')
        return http.Response(jsonEncode({'files': []}), 200);
      return http.Response(
        jsonEncode({'id': 'bundle', 'name': 'Realmwise.realmwise'}),
        200,
      );
    });
    final auth = GoogleDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost'),
      browser: B(),
      callback: C(Uri.parse('http://localhost')),
      tokenStore: GoogleDriveTokenStore(tokens),
      httpClient: client,
    );
    final p = GoogleDriveProvider(
      authenticator: auth,
      tokenStore: GoogleDriveTokenStore(tokens),
      httpClient: client,
    );
    await p.ensureBundleTarget(const SyncAuthSession(accountId: 'x'));
    expect(requests, hasLength(2));
    expect(requests.first.url.queryParameters['spaces'], 'appDataFolder');
    expect(
      requests.first.url.queryParameters['q'],
      contains("'appDataFolder' in parents"),
    );
    expect(requests[1].url.queryParameters, isEmpty);
    expect(jsonDecode(requests[1].body)['parents'], ['appDataFolder']);
  });
  test('quota and revoked errors are typed', () async {
    for (final code in [401, 429]) {
      final t = MemTokens();
      await t.write(
        'google_drive_oauth:id',
        jsonEncode({'access_token': 'a', 'expires_at': '2999-01-01T00:00:00Z'}),
      );
      final c = MockClient((_) async => http.Response('', code));
      final a = GoogleDriveOAuthAuthenticator(
        clientId: 'id',
        redirectUri: Uri.parse('http://localhost'),
        browser: B(),
        callback: C(Uri.parse('http://localhost')),
        tokenStore: GoogleDriveTokenStore(t),
        httpClient: c,
      );
      final p = GoogleDriveProvider(
        authenticator: a,
        tokenStore: GoogleDriveTokenStore(t),
        httpClient: c,
      );
      expect(
        p.listRemoteTargets(const SyncAuthSession(accountId: 'x')),
        throwsA(isA<Exception>()),
      );
    }
  });
  test('network failures surface', () async {
    final t = MemTokens();
    await t.write(
      'google_drive_oauth:id',
      jsonEncode({'access_token': 'a', 'expires_at': '2999-01-01T00:00:00Z'}),
    );
    final c = MockClient((_) async => throw http.ClientException('offline'));
    final a = GoogleDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost'),
      browser: B(),
      callback: C(Uri.parse('http://localhost')),
      tokenStore: GoogleDriveTokenStore(t),
      httpClient: c,
    );
    final p = GoogleDriveProvider(
      authenticator: a,
      tokenStore: GoogleDriveTokenStore(t),
      httpClient: c,
    );
    expect(
      p.listRemoteTargets(const SyncAuthSession(accountId: 'x')),
      throwsA(isA<Exception>()),
    );
  });
  test('upload and download bundle', () async {
    final t = MemTokens();
    await t.write(
      'google_drive_oauth:id',
      jsonEncode({'access_token': 'a', 'expires_at': '2999-01-01T00:00:00Z'}),
    );
    var n = 0;
    final bytes = Uint8List.fromList([1, 2, 3]);
    final hash = sha256.convert(bytes).toString();
    final c = MockClient((r) async {
      n++;
      if (r.url.queryParameters['alt'] == 'media')
        return http.Response.bytes(bytes, 200);
      if (r.method == 'PATCH') return http.Response('{}', 200);
      return http.Response(
        jsonEncode({
          'version': '2',
          'description': hash,
          'modifiedTime': '2026-01-01T00:00:00Z',
        }),
        200,
      );
    });
    final a = GoogleDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost'),
      browser: B(),
      callback: C(Uri.parse('http://localhost')),
      tokenStore: GoogleDriveTokenStore(t),
      httpClient: c,
    );
    final p = GoogleDriveProvider(
      authenticator: a,
      tokenStore: GoogleDriveTokenStore(t),
      httpClient: c,
    );
    final s = const SyncAuthSession(accountId: 'x');
    final target = const SyncRemoteTarget(id: 'f', name: 'f');
    expect((await p.upload(s, target, bytes)).metadata.contentHash, hash);
    expect((await p.download(s, target)).payload, bytes);
    expect(n, greaterThan(2));
  });
  test('upload returns final revision usable for immediate download', () async {
    final t = MemTokens();
    await t.write(
      'google_drive_oauth:id',
      jsonEncode({'access_token': 'a', 'expires_at': '2999-01-01T00:00:00Z'}),
    );
    final bytes = Uint8List.fromList([4, 5, 6]);
    final hash = sha256.convert(bytes).toString();
    var metadataReads = 0;
    final c = MockClient((r) async {
      if (r.url.queryParameters['alt'] == 'media') {
        return http.Response.bytes(bytes, 200);
      }
      if (r.method == 'PATCH' &&
          r.url.host == 'www.googleapis.com' &&
          r.url.path.startsWith('/upload/')) {
        return http.Response(jsonEncode({'version': '2'}), 200);
      }
      if (r.method == 'PATCH') {
        // Drive's properties response contains the post-write revision.
        return http.Response(
          jsonEncode({
            'version': '3',
            'modifiedTime': '2026-01-01T00:00:00Z',
            'appProperties': {'realmwiseSha256': hash},
          }),
          200,
        );
      }
      metadataReads++;
      return http.Response(
        jsonEncode({
          'version': metadataReads == 1 ? '2' : '3',
          'appProperties': {'realmwiseSha256': hash},
        }),
        200,
      );
    });
    final auth = GoogleDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost'),
      browser: B(),
      callback: C(Uri.parse('http://localhost')),
      tokenStore: GoogleDriveTokenStore(t),
      httpClient: c,
    );
    final provider = GoogleDriveProvider(
      authenticator: auth,
      tokenStore: GoogleDriveTokenStore(t),
      httpClient: c,
    );
    const session = SyncAuthSession(accountId: 'x');
    const target = SyncRemoteTarget(id: 'f', name: 'f');
    final uploaded = await provider.upload(session, target, bytes);
    expect(uploaded.metadata.revision, const SyncRevision('3'));
    expect(
      (await provider.download(
        session,
        target,
        precondition: SyncPrecondition(revision: uploaded.metadata.revision),
      )).payload,
      bytes,
    );
  });
  test('download retries stale revision metadata before conflicting', () async {
    final t = MemTokens();
    await t.write(
      'google_drive_oauth:id',
      jsonEncode({'access_token': 'a', 'expires_at': '2999-01-01T00:00:00Z'}),
    );
    final bytes = Uint8List.fromList([7]);
    var reads = 0;
    final client = MockClient((r) async {
      if (r.url.queryParameters['alt'] == 'media')
        return http.Response.bytes(bytes, 200);
      reads++;
      return http.Response(
        jsonEncode({'version': reads == 1 ? '2' : '3'}),
        200,
      );
    });
    final auth = GoogleDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost'),
      browser: B(),
      callback: C(Uri.parse('http://localhost')),
      tokenStore: GoogleDriveTokenStore(t),
      httpClient: client,
    );
    final provider = GoogleDriveProvider(
      authenticator: auth,
      tokenStore: GoogleDriveTokenStore(t),
      httpClient: client,
    );
    final result = await provider.download(
      const SyncAuthSession(accountId: 'x'),
      const SyncRemoteTarget(id: 'f', name: 'f'),
      precondition: const SyncPrecondition(revision: SyncRevision('3')),
    );
    expect(result.payload, bytes);
    expect(reads, 2);
  });

  test('download conflicts after bounded stale revision retries', () async {
    final t = MemTokens();
    await t.write(
      'google_drive_oauth:id',
      jsonEncode({'access_token': 'a', 'expires_at': '2999-01-01T00:00:00Z'}),
    );
    var reads = 0;
    final client = MockClient((_) async {
      reads++;
      return http.Response(jsonEncode({'version': '2'}), 200);
    });
    final auth = GoogleDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost'),
      browser: B(),
      callback: C(Uri.parse('http://localhost')),
      tokenStore: GoogleDriveTokenStore(t),
      httpClient: client,
    );
    final provider = GoogleDriveProvider(
      authenticator: auth,
      tokenStore: GoogleDriveTokenStore(t),
      httpClient: client,
    );
    await expectLater(
      provider.download(
        const SyncAuthSession(accountId: 'x'),
        const SyncRemoteTarget(id: 'f', name: 'f'),
        precondition: const SyncPrecondition(revision: SyncRevision('3')),
      ),
      throwsA(isA<SyncConflictException>()),
    );
    expect(reads, 4);
  });

  test('download rejects newer remote revision without retrying', () async {
    final t = MemTokens();
    await t.write(
      'google_drive_oauth:id',
      jsonEncode({'access_token': 'a', 'expires_at': '2999-01-01T00:00:00Z'}),
    );
    var reads = 0;
    final client = MockClient((_) async {
      reads++;
      return http.Response(jsonEncode({'version': '4'}), 200);
    });
    final auth = GoogleDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost'),
      browser: B(),
      callback: C(Uri.parse('http://localhost')),
      tokenStore: GoogleDriveTokenStore(t),
      httpClient: client,
    );
    final provider = GoogleDriveProvider(
      authenticator: auth,
      tokenStore: GoogleDriveTokenStore(t),
      httpClient: client,
    );
    await expectLater(
      provider.download(
        const SyncAuthSession(accountId: 'x'),
        const SyncRemoteTarget(id: 'f', name: 'f'),
        precondition: const SyncPrecondition(revision: SyncRevision('3')),
      ),
      throwsA(isA<SyncConflictException>()),
    );
    expect(reads, 1);
  });

  test('download integrity mismatch and revision conflict', () async {
    final t = MemTokens();
    await t.write(
      'google_drive_oauth:id',
      jsonEncode({'access_token': 'a', 'expires_at': '2999-01-01T00:00:00Z'}),
    );
    final c = MockClient((r) async {
      if (r.url.queryParameters['alt'] == 'media')
        return http.Response.bytes([9], 200);
      return http.Response(
        jsonEncode({'version': '9', 'description': 'bad'}),
        200,
      );
    });
    final a = GoogleDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost'),
      browser: B(),
      callback: C(Uri.parse('http://localhost')),
      tokenStore: GoogleDriveTokenStore(t),
      httpClient: c,
    );
    final p = GoogleDriveProvider(
      authenticator: a,
      tokenStore: GoogleDriveTokenStore(t),
      httpClient: c,
    );
    final s = const SyncAuthSession(accountId: 'x');
    final target = const SyncRemoteTarget(id: 'f', name: 'f');
    expect(p.download(s, target), throwsA(isA<Exception>()));
    expect(
      p.upload(
        s,
        target,
        Uint8List.fromList([1]),
        precondition: const SyncPrecondition(revision: SyncRevision('1')),
      ),
      throwsA(isA<SyncConflictException>()),
    );
  });
}

Future<Object> captureError(Future<Object> future) async {
  try {
    await future;
    throw StateError('expected an error');
  } catch (error) {
    return error;
  }
}
