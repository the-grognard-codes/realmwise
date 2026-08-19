import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:realmwise/services/google_drive_sync.dart';
import 'package:realmwise/services/secure_storage_service.dart';
import 'package:realmwise/services/sync_contract.dart';
import 'package:realmwise/services/sync_coordinator.dart';
import 'package:realmwise/services/sync_metadata.dart';

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

class MemSyncMetadata implements SyncMetadataStorage {
  SyncMetadata? value;
  @override
  Future<SyncMetadata?> read(String _) async => value;
  @override
  Future<void> write(SyncMetadata metadata) async => value = metadata;
  @override
  Future<void> remove(String _) async => value = null;
}

class FailingProvider implements SyncProvider {
  @override
  String get provider => 'test';
  @override
  Future<SyncAuthSession> authenticate() async => throw Exception('offline');
  @override
  Future<List<SyncRemoteTarget>> listRemoteTargets(SyncAuthSession _) async =>
      const [];
  @override
  Future<SyncRemoteMetadata?> metadata(
    SyncAuthSession _,
    SyncRemoteTarget __,
  ) async => null;
  @override
  Future<SyncUploadResult> upload(
    SyncAuthSession _,
    SyncRemoteTarget __,
    Uint8List ___, {
    SyncPrecondition? precondition,
  }) async => throw UnimplementedError();
  @override
  Future<SyncDownloadResult> download(
    SyncAuthSession _,
    SyncRemoteTarget __, {
    SyncPrecondition? precondition,
  }) async => throw UnimplementedError();
}

class EmptyProvider extends FailingProvider {
  @override
  Future<SyncAuthSession> authenticate() async =>
      const SyncAuthSession(accountId: 'account');
}

class TargetProvider extends FailingProvider {
  int uploads = 0;
  SyncRemoteMetadata? remoteMetadata;
  SyncPrecondition? lastPrecondition;
  String providerName = 'test';
  String accountId = 'account';

  @override
  String get provider => providerName;

  @override
  Future<SyncAuthSession> authenticate() async =>
      SyncAuthSession(accountId: accountId);

  @override
  Future<List<SyncRemoteTarget>> listRemoteTargets(SyncAuthSession _) async =>
      const [
        SyncRemoteTarget(id: 'target-a', name: 'A'),
        SyncRemoteTarget(id: 'target-b', name: 'B'),
      ];

  @override
  Future<SyncUploadResult> upload(
    SyncAuthSession _,
    SyncRemoteTarget __,
    Uint8List ___, {
    SyncPrecondition? precondition,
  }) async {
    uploads++;
    lastPrecondition = precondition;
    return const SyncUploadResult(
      metadata: SyncRemoteMetadata(
        revision: SyncRevision('2'),
        contentHash: 'remote-hash',
      ),
    );
  }

  @override
  Future<SyncRemoteMetadata?> metadata(
    SyncAuthSession _,
    SyncRemoteTarget __,
  ) async => remoteMetadata;
}

void main() {
  test(
    'failed connect persists recoverable error and clears live connection',
    () async {
      final storage = MemSyncMetadata();
      final coordinator = SyncCoordinator(metadataStorage: storage);
      await expectLater(
        coordinator.connect(FailingProvider(), 'catalog'),
        throwsException,
      );
      expect(coordinator.provider, isNull);
      expect(coordinator.session, isNull);
      expect(coordinator.metadata?.state, SyncState.error);
      expect(storage.value?.error, 'sync_error');
    },
  );

  test('target setup failure rollback clears connected session', () async {
    final storage = MemSyncMetadata();
    final coordinator = SyncCoordinator(metadataStorage: storage);
    await coordinator.connect(EmptyProvider(), 'catalog');
    expect(coordinator.isConnected, isTrue);
    await coordinator.failConnection(Exception('target setup failed'));
    expect(coordinator.isConnected, isFalse);
    expect(coordinator.target, isNull);
    expect(storage.value?.state, SyncState.error);
    expect(storage.value?.error, 'sync_error');
  });

  test(
    'runtime reset unlocks provider selection without deleting metadata',
    () async {
      final storage = MemSyncMetadata();
      final coordinator = SyncCoordinator(metadataStorage: storage);
      await coordinator.connect(TargetProvider(), 'catalog');
      final persisted = storage.value;
      expect(coordinator.isConnected, isTrue);

      coordinator.resetRuntime();

      expect(coordinator.isConnected, isFalse);
      expect(coordinator.metadata, isNull);
      expect(storage.value, same(persisted));
    },
  );

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

  test('oauth fetches and persists Drive account profile', () async {
    final browser = B();
    final tokens = MemTokens();
    final client = MockClient((request) async {
      if (request.url.host == 'oauth2.googleapis.com') {
        return http.Response(
          jsonEncode({
            'access_token': 'a',
            'refresh_token': 'r',
            'expires_in': 3600,
          }),
          200,
        );
      }
      expect(request.url.path, '/drive/v3/about');
      expect(
        request.url.queryParameters['fields'],
        'user(displayName,emailAddress)',
      );
      return http.Response(
        jsonEncode({
          'user': {
            'displayName': 'Ada Lovelace',
            'emailAddress': 'ada@example.com',
          },
        }),
        200,
      );
    });
    final auth = GoogleDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost/cb'),
      browser: browser,
      callback: DynamicCallback(browser),
      tokenStore: GoogleDriveTokenStore(tokens),
      httpClient: client,
    );
    final session = await auth.authenticate();
    expect(session.accountId, 'ada@example.com');
    expect(session.displayName, 'ada@example.com');
    final restored = await GoogleDriveProvider(
      authenticator: auth,
      tokenStore: GoogleDriveTokenStore(tokens),
      httpClient: client,
    ).restoreSession();
    expect(restored?.accountId, 'ada@example.com');
    expect(restored?.displayName, 'ada@example.com');
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
      await expectLater(
        p.listRemoteTargets(const SyncAuthSession(accountId: 'x')),
        throwsA(
          isA<GoogleDriveException>().having(
            (e) => e.statusCode,
            'statusCode',
            code,
          ),
        ),
      );
    }
  });
  test('malformed list response is a safe typed error', () async {
    final t = MemTokens();
    await t.write(
      'google_drive_oauth:id',
      jsonEncode({'access_token': 'a', 'expires_at': '2999-01-01T00:00:00Z'}),
    );
    final c = MockClient((_) async => http.Response('{}', 200));
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
    await expectLater(
      p.listRemoteTargets(const SyncAuthSession(accountId: 'x')),
      throwsA(isA<GoogleDriveException>()),
    );
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
  test('upload retries stale revision/hash then succeeds', () async {
    final t = MemTokens();
    await t.write(
      'google_drive_oauth:id',
      jsonEncode({'access_token': 'a', 'expires_at': '2999-01-01T00:00:00Z'}),
    );
    final payload = Uint8List.fromList([1]);
    final hash = sha256.convert(payload).toString();
    var reads = 0;
    var patches = 0;
    final delays = <Duration>[];
    final client = MockClient((r) async {
      if (r.method == 'PATCH') {
        patches++;
        return http.Response(jsonEncode({'version': '4'}), 200);
      }
      reads++;
      final expected = reads > 1;
      return http.Response(
        jsonEncode({
          'version': expected ? '3' : '2',
          'appProperties': {'realmwiseSha256': expected ? hash : 'stale'},
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
      httpClient: client,
    );
    final p = GoogleDriveProvider(
      authenticator: auth,
      tokenStore: GoogleDriveTokenStore(t),
      httpClient: client,
      delay: (duration) async => delays.add(duration),
    );
    await p.upload(
      const SyncAuthSession(accountId: 'x'),
      const SyncRemoteTarget(id: 'f', name: 'f'),
      payload,
      precondition: SyncPrecondition(
        revision: const SyncRevision('3'),
        contentHash: hash,
      ),
    );
    expect(patches, greaterThan(0));
    expect(delays, [const Duration(milliseconds: 100)]);
  });

  test(
    'switching target clears local fingerprint and prevents no-op sync',
    () async {
      final storage = MemSyncMetadata();
      final provider = TargetProvider();
      final coordinator = SyncCoordinator(metadataStorage: storage);
      await coordinator.connect(provider, 'catalog');
      await coordinator.sync(Uint8List.fromList([1]), localFingerprint: 'same');
      expect(coordinator.metadata?.lastSuccessfulLocalFingerprint, 'same');

      await coordinator.configureTarget(
        const SyncRemoteTarget(id: 'target-b', name: 'B'),
      );
      expect(coordinator.metadata?.lastSuccessfulLocalFingerprint, isNull);
      await coordinator.sync(Uint8List.fromList([1]), localFingerprint: 'same');
      expect(provider.uploads, 2);
    },
  );

  test(
    'matching local fingerprint with divergent remote metadata uploads',
    () async {
      final storage = MemSyncMetadata();
      final provider = TargetProvider()
        ..remoteMetadata = const SyncRemoteMetadata(
          revision: SyncRevision('99'),
          contentHash: 'different-hash',
        );
      final coordinator = SyncCoordinator(metadataStorage: storage);
      await coordinator.connect(provider, 'catalog');
      await coordinator.sync(Uint8List.fromList([1]), localFingerprint: 'same');
      expect(coordinator.metadata?.lastSuccessfulLocalFingerprint, 'same');

      provider.remoteMetadata = const SyncRemoteMetadata(
        revision: SyncRevision('3'),
        contentHash: 'different-hash',
      );
      await coordinator.sync(Uint8List.fromList([1]), localFingerprint: 'same');

      expect(coordinator.lastOutcome, SyncOutcome.uploaded);
      expect(provider.uploads, 2);
      expect(provider.lastPrecondition?.revision, const SyncRevision('2'));
      expect(provider.lastPrecondition?.contentHash, 'remote-hash');
    },
  );

  test(
    'matching tuple and remote metadata skips upload as already synced',
    () async {
      final storage = MemSyncMetadata();
      final provider = TargetProvider()
        ..remoteMetadata = const SyncRemoteMetadata(
          revision: SyncRevision('2'),
          contentHash: 'remote-hash',
        );
      final coordinator = SyncCoordinator(metadataStorage: storage);
      await coordinator.connect(provider, 'catalog');
      await coordinator.sync(Uint8List.fromList([1]), localFingerprint: 'same');
      final uploads = provider.uploads;

      await coordinator.sync(Uint8List.fromList([1]), localFingerprint: 'same');

      expect(coordinator.lastOutcome, SyncOutcome.alreadySynced);
      expect(provider.uploads, uploads);
    },
  );

  test(
    'matching remote hash reconciles Drive revision without uploading',
    () async {
      final storage = MemSyncMetadata();
      final provider = TargetProvider()
        ..remoteMetadata = const SyncRemoteMetadata(
          revision: SyncRevision('21'),
          contentHash: 'remote-hash',
        );
      final coordinator = SyncCoordinator(metadataStorage: storage);
      await coordinator.connect(provider, 'catalog');
      await coordinator.sync(Uint8List.fromList([1]), localFingerprint: 'same');
      final uploads = provider.uploads;

      provider.remoteMetadata = const SyncRemoteMetadata(
        revision: SyncRevision('22'),
        contentHash: 'remote-hash',
      );
      await coordinator.sync(Uint8List.fromList([1]), localFingerprint: 'same');

      expect(coordinator.lastOutcome, SyncOutcome.alreadySynced);
      expect(provider.uploads, uploads);
      expect(coordinator.metadata?.revision, '22');
      expect(storage.value?.revision, '22');
    },
  );

  test('legacy metadata without local fingerprint uploads', () async {
    final storage = MemSyncMetadata()
      ..value = const SyncMetadata(
        catalogIdentity: 'catalog',
        provider: 'test',
        accountId: 'account',
        remoteTargetId: 'target-a',
        remoteTargetName: 'A',
        revision: '2',
        contentHash: 'remote-hash',
        state: SyncState.ready,
      );
    final provider = TargetProvider()
      ..remoteMetadata = const SyncRemoteMetadata(
        revision: SyncRevision('2'),
        contentHash: 'remote-hash',
      );
    final coordinator = SyncCoordinator(metadataStorage: storage);
    await coordinator.connect(provider, 'catalog');
    await coordinator.sync(Uint8List.fromList([1]), localFingerprint: 'same');

    expect(coordinator.lastOutcome, SyncOutcome.uploaded);
    expect(provider.uploads, 1);
  });

  test('provider or account metadata mismatch prevents no-op', () async {
    for (final mismatch in ['provider', 'account']) {
      final storage = MemSyncMetadata()
        ..value = const SyncMetadata(
          catalogIdentity: 'catalog',
          provider: 'test',
          accountId: 'account',
          remoteTargetId: 'target-a',
          remoteTargetName: 'A',
          revision: '2',
          contentHash: 'remote-hash',
          lastSuccessfulLocalFingerprint: 'same',
          state: SyncState.ready,
        );
      final provider = TargetProvider()
        ..remoteMetadata = const SyncRemoteMetadata(
          revision: SyncRevision('2'),
          contentHash: 'remote-hash',
        );
      if (mismatch == 'provider') {
        provider.providerName = 'other';
      } else {
        provider.accountId = 'other-account';
      }
      final coordinator = SyncCoordinator(metadataStorage: storage);
      await coordinator.connect(provider, 'catalog');
      await coordinator.sync(Uint8List.fromList([1]), localFingerprint: 'same');
      expect(provider.uploads, 1, reason: mismatch);
    }
  });

  test(
    'commitDownload with null fingerprint clears prior fingerprint',
    () async {
      final storage = MemSyncMetadata();
      final coordinator = SyncCoordinator(metadataStorage: storage);
      await coordinator.connect(TargetProvider(), 'catalog');
      await coordinator.sync(
        Uint8List.fromList([1]),
        localFingerprint: 'prior',
      );

      await coordinator.commitDownload(
        const SyncRemoteMetadata(
          revision: SyncRevision('3'),
          contentHash: 'downloaded',
        ),
      );
      expect(coordinator.metadata?.lastSuccessfulLocalFingerprint, isNull);
    },
  );

  test(
    'upload retries media PATCH after stale ETag when metadata still matches',
    () async {
      final t = MemTokens();
      await t.write(
        'google_drive_oauth:id',
        jsonEncode({'access_token': 'a', 'expires_at': '2999-01-01T00:00:00Z'}),
      );
      final payload = Uint8List.fromList([2]);
      final hash = sha256.convert(payload).toString();
      var metadataReads = 0;
      var mediaPatches = 0;
      final client = MockClient((r) async {
        if (r.url.queryParameters['uploadType'] == 'media') {
          mediaPatches++;
          if (mediaPatches == 1) return http.Response('{}', 412);
          return http.Response('{}', 200, headers: {'etag': 'etag-new'});
        }
        if (r.method == 'PATCH')
          return http.Response(jsonEncode({'version': '3'}), 200);
        metadataReads++;
        return http.Response(
          jsonEncode({
            'version': '2',
            'appProperties': {'realmwiseSha256': hash},
          }),
          200,
          headers: {'etag': metadataReads == 1 ? 'etag-old' : 'etag-new'},
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
      final p = GoogleDriveProvider(
        authenticator: auth,
        tokenStore: GoogleDriveTokenStore(t),
        httpClient: client,
      );
      await p.upload(
        const SyncAuthSession(accountId: 'x'),
        const SyncRemoteTarget(id: 'f', name: 'f'),
        payload,
        precondition: SyncPrecondition(
          revision: const SyncRevision('2'),
          contentHash: hash,
        ),
      );
      expect(mediaPatches, 2);
    },
  );

  test('upload conflicts on media 412 without logical precondition', () async {
    final t = MemTokens();
    await t.write(
      'google_drive_oauth:id',
      jsonEncode({'access_token': 'a', 'expires_at': '2999-01-01T00:00:00Z'}),
    );
    var mediaPatches = 0;
    final client = MockClient((r) async {
      if (r.url.queryParameters['uploadType'] == 'media') {
        mediaPatches++;
        return http.Response('{}', 412);
      }
      return http.Response(
        jsonEncode({
          'version': '1',
          'appProperties': {'realmwiseSha256': 'old'},
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
      httpClient: client,
    );
    final p = GoogleDriveProvider(
      authenticator: auth,
      tokenStore: GoogleDriveTokenStore(t),
      httpClient: client,
    );
    await expectLater(
      p.upload(
        const SyncAuthSession(accountId: 'x'),
        const SyncRemoteTarget(id: 'f', name: 'f'),
        Uint8List.fromList([2]),
      ),
      throwsA(isA<SyncConflictException>()),
    );
    expect(mediaPatches, 1);
  });

  test(
    'upload does not retry media PATCH after 412 when metadata diverged',
    () async {
      final t = MemTokens();
      await t.write(
        'google_drive_oauth:id',
        jsonEncode({'access_token': 'a', 'expires_at': '2999-01-01T00:00:00Z'}),
      );
      var mediaPatches = 0;
      var metadataReads = 0;
      final client = MockClient((r) async {
        if (r.url.queryParameters['uploadType'] == 'media') {
          mediaPatches++;
          return http.Response('{}', 412);
        }
        if (r.method == 'PATCH') return http.Response('{}', 200);
        metadataReads++;
        return http.Response(
          jsonEncode({
            'version': metadataReads == 1 ? '2' : '3',
            'appProperties': {
              'realmwiseSha256': metadataReads == 1 ? 'expected' : 'newer',
            },
          }),
          200,
          headers: {'etag': 'etag'},
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
      final p = GoogleDriveProvider(
        authenticator: auth,
        tokenStore: GoogleDriveTokenStore(t),
        httpClient: client,
      );
      await expectLater(
        p.upload(
          const SyncAuthSession(accountId: 'x'),
          const SyncRemoteTarget(id: 'f', name: 'f'),
          Uint8List.fromList([2]),
          precondition: const SyncPrecondition(
            revision: SyncRevision('2'),
            contentHash: 'expected',
          ),
        ),
        throwsA(isA<SyncConflictException>()),
      );
      expect(mediaPatches, 1);
    },
  );

  test(
    'repeated upload refreshes stale ETag cached from prior properties write',
    () async {
      final t = MemTokens();
      await t.write(
        'google_drive_oauth:id',
        jsonEncode({'access_token': 'a', 'expires_at': '2999-01-01T00:00:00Z'}),
      );
      final payload = Uint8List.fromList([3]);
      final hash = sha256.convert(payload).toString();
      var metadataReads = 0;
      var mediaPatches = 0;
      var propertiesPatches = 0;
      final client = MockClient((r) async {
        if (r.url.queryParameters['uploadType'] == 'media') {
          mediaPatches++;
          if (mediaPatches == 2) return http.Response('{}', 412);
          return http.Response('{}', 200);
        }
        if (r.method == 'PATCH') {
          propertiesPatches++;
          return http.Response(
            jsonEncode({'version': propertiesPatches == 1 ? '2' : '3'}),
            200,
            headers: {'etag': 'etag-cached'},
          );
        }
        metadataReads++;
        final refreshed = metadataReads == 4;
        return http.Response(
          jsonEncode({
            'version': metadataReads == 1 ? '1' : '2',
            'appProperties': {'realmwiseSha256': hash},
          }),
          200,
          headers: refreshed ? {'etag': 'etag-fresh'} : {},
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
      final p = GoogleDriveProvider(
        authenticator: auth,
        tokenStore: GoogleDriveTokenStore(t),
        httpClient: client,
      );
      const session = SyncAuthSession(accountId: 'x');
      const target = SyncRemoteTarget(id: 'f', name: 'f');
      await p.upload(session, target, payload);
      await p.upload(
        session,
        target,
        payload,
        precondition: SyncPrecondition(
          revision: const SyncRevision('2'),
          contentHash: hash,
        ),
      );
      expect(mediaPatches, 3);
    },
  );

  test('upload conflicts on refreshed divergent hash without PATCH', () async {
    final t = MemTokens();
    await t.write(
      'google_drive_oauth:id',
      jsonEncode({'access_token': 'a', 'expires_at': '2999-01-01T00:00:00Z'}),
    );
    var patches = 0;
    var reads = 0;
    final client = MockClient((r) async {
      if (r.method == 'PATCH') {
        patches++;
        return http.Response('{}', 200);
      }
      reads++;
      return http.Response(
        jsonEncode({
          'version': reads == 1 ? '2' : '3',
          'appProperties': {'realmwiseSha256': reads == 1 ? 'stale' : 'other'},
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
      httpClient: client,
    );
    final p = GoogleDriveProvider(
      authenticator: auth,
      tokenStore: GoogleDriveTokenStore(t),
      httpClient: client,
    );
    await expectLater(
      p.upload(
        const SyncAuthSession(accountId: 'x'),
        const SyncRemoteTarget(id: 'f', name: 'f'),
        Uint8List.fromList([1]),
        precondition: const SyncPrecondition(
          revision: SyncRevision('3'),
          contentHash: 'expected',
        ),
      ),
      throwsA(isA<SyncConflictException>()),
    );
    expect(reads, 2);
    expect(patches, 0);
  });

  test(
    'upload rejects newer revision immediately without retry or PATCH',
    () async {
      final t = MemTokens();
      await t.write(
        'google_drive_oauth:id',
        jsonEncode({'access_token': 'a', 'expires_at': '2999-01-01T00:00:00Z'}),
      );
      var reads = 0;
      var patches = 0;
      final client = MockClient((r) async {
        if (r.method == 'PATCH') {
          patches++;
          return http.Response('{}', 200);
        }
        reads++;
        return http.Response(
          jsonEncode({
            'version': '4',
            'appProperties': {'realmwiseSha256': 'other'},
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
        httpClient: client,
      );
      final p = GoogleDriveProvider(
        authenticator: auth,
        tokenStore: GoogleDriveTokenStore(t),
        httpClient: client,
      );
      await expectLater(
        p.upload(
          const SyncAuthSession(accountId: 'x'),
          const SyncRemoteTarget(id: 'f', name: 'f'),
          Uint8List.fromList([1]),
          precondition: const SyncPrecondition(
            revision: SyncRevision('3'),
            contentHash: 'expected',
          ),
        ),
        throwsA(isA<SyncConflictException>()),
      );
      expect(reads, 1);
      expect(patches, 0);
    },
  );

  test(
    'upload nonnumeric revision mismatch conflicts without retry or PATCH',
    () async {
      final t = MemTokens();
      await t.write(
        'google_drive_oauth:id',
        jsonEncode({'access_token': 'a', 'expires_at': '2999-01-01T00:00:00Z'}),
      );
      var reads = 0;
      var patches = 0;
      final client = MockClient((r) async {
        if (r.method == 'PATCH') {
          patches++;
          return http.Response('{}', 200);
        }
        reads++;
        return http.Response(
          jsonEncode({
            'version': 'abc',
            'appProperties': {'realmwiseSha256': 'h'},
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
        httpClient: client,
      );
      final p = GoogleDriveProvider(
        authenticator: auth,
        tokenStore: GoogleDriveTokenStore(t),
        httpClient: client,
      );
      await expectLater(
        p.upload(
          const SyncAuthSession(accountId: 'x'),
          const SyncRemoteTarget(id: 'f', name: 'f'),
          Uint8List.fromList([1]),
          precondition: const SyncPrecondition(revision: SyncRevision('3')),
        ),
        throwsA(isA<SyncConflictException>()),
      );
      expect(reads, 1);
      expect(patches, 0);
    },
  );

  test('download retries stale revision metadata before conflicting', () async {
    final t = MemTokens();
    await t.write(
      'google_drive_oauth:id',
      jsonEncode({'access_token': 'a', 'expires_at': '2999-01-01T00:00:00Z'}),
    );
    final bytes = Uint8List.fromList([7]);
    var reads = 0;
    final delays = <Duration>[];
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
      delay: (duration) async => delays.add(duration),
    );
    final result = await provider.download(
      const SyncAuthSession(accountId: 'x'),
      const SyncRemoteTarget(id: 'f', name: 'f'),
      precondition: const SyncPrecondition(revision: SyncRevision('3')),
    );
    expect(result.payload, bytes);
    expect(reads, 8);
    expect(delays, [
      const Duration(milliseconds: 100),
      const Duration(milliseconds: 100),
      const Duration(milliseconds: 100),
      const Duration(milliseconds: 200),
      const Duration(milliseconds: 200),
      const Duration(milliseconds: 400),
    ]);
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

  test(
    'download rejects matching revision with divergent content hash',
    () async {
      final t = MemTokens();
      await t.write(
        'google_drive_oauth:id',
        jsonEncode({'access_token': 'a', 'expires_at': '2999-01-01T00:00:00Z'}),
      );
      var mediaReads = 0;
      final client = MockClient((r) async {
        if (r.url.queryParameters['alt'] == 'media') {
          mediaReads++;
          return http.Response.bytes([1], 200);
        }
        return http.Response(
          jsonEncode({
            'version': '3',
            'appProperties': {'realmwiseSha256': 'remote-sha'},
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
          precondition: const SyncPrecondition(
            revision: SyncRevision('3'),
            contentHash: 'expected-sha',
          ),
        ),
        throwsA(isA<SyncConflictException>()),
      );
      expect(mediaReads, 0);
    },
  );

  test('metadata does not treat Drive MD5 as Realmwise SHA-256', () async {
    final t = MemTokens();
    await t.write(
      'google_drive_oauth:id',
      jsonEncode({'access_token': 'a', 'expires_at': '2999-01-01T00:00:00Z'}),
    );
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({'version': '3', 'md5Checksum': 'md5-value'}),
        200,
      ),
    );
    final auth = GoogleDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost'),
      browser: B(),
      callback: C(Uri.parse('http://localhost')),
      tokenStore: GoogleDriveTokenStore(t),
      httpClient: client,
    );
    final metadata =
        await GoogleDriveProvider(
          authenticator: auth,
          tokenStore: GoogleDriveTokenStore(t),
          httpClient: client,
        ).metadata(
          const SyncAuthSession(accountId: 'x'),
          const SyncRemoteTarget(id: 'f', name: 'f'),
        );
    expect(metadata?.contentHash, isEmpty);
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
