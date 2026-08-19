import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:realmwise/services/onedrive_sync.dart';
import 'package:realmwise/services/onedrive_runtime.dart';
import 'package:realmwise/services/secure_storage_service.dart';
import 'package:realmwise/services/sync_contract.dart';
import 'package:realmwise/services/sync_debug.dart';

class _Store implements TokenStorage {
  final m = <String, String>{};
  @override
  Future<String?> read(String key) async => m[key];
  @override
  Future<void> write(String key, String value) async => m[key] = value;
  @override
  Future<void> delete(String key) async => m.remove(key);
}

void main() {
  test('Android callback rejects an unregistered redirect before channel use', () async {
    final callback = AndroidOneDriveCallback(
      Uri.parse('msauth://com.realmwise.rpg.tracker/wrong'),
    );
    expect(
      callback.waitForCallback(),
      throwsA(isA<OneDriveAuthException>()),
    );
  });

  test('Android callback returns the native callback URI', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final channel = const MethodChannel('realmwise/onedrive_oauth');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'wait_for_callback');
      expect(
        call.arguments['redirect_uri'],
        'msauth://com.realmwise.rpg.tracker/hu33S0PdJMD%2FBlOPVgFheEvptH8%3D',
      );
      return 'msauth://com.realmwise.rpg.tracker/hu33S0PdJMD%2FBlOPVgFheEvptH8%3D?code=c&state=s';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final value = await AndroidOneDriveCallback(
      Uri.parse(
        'msauth://com.realmwise.rpg.tracker/hu33S0PdJMD%2FBlOPVgFheEvptH8%3D',
      ),
    ).waitForCallback();
    expect(value.queryParameters['code'], 'c');
  });

  test('token store round trips values', () async {
    final s = _Store();
    final t = OneDriveTokenStore(s);
    await t.write('k', {'access_token': 'x'});
    expect((await t.read('k'))['access_token'], 'x');
  });
  test('provider exposes onedrive identifier', () {
    final s = _Store();
    final a = OneDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost/cb'),
      browser: _Browser(),
      callback: _Callback(),
      tokenStore: OneDriveTokenStore(s),
    );
    final p = OneDriveProvider(
      authenticator: a,
      tokenStore: OneDriveTokenStore(s),
    );
    expect(p.provider, 'onedrive');
  });
  test('OAuth denial is surfaced safely', () async {
    final store = _Store();
    final auth = OneDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost/cb'),
      browser: _Browser(),
      callback: _DeniedCallback(),
      tokenStore: OneDriveTokenStore(store),
      httpClient: MockClient((_) async => http.Response('{}', 400)),
    );
    expect(() => auth.authenticate(), throwsA(isA<OneDriveAuthException>()));
  });
  test('metadata maps eTag revision and hash', () async {
    final store = _Store();
    await store.write('onedrive_oauth:id', '{"access_token":"a"}');
    final auth = OneDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost/cb'),
      browser: _Browser(),
      callback: _Callback(),
      tokenStore: OneDriveTokenStore(store),
    );
    final p = OneDriveProvider(
      authenticator: auth,
      tokenStore: OneDriveTokenStore(store),
      httpClient: MockClient(
        (r) async => http.Response(
          '{"eTag":"tag","file":{"hashes":{"sha256Hash":"h"}},"lastModifiedDateTime":"2024-01-01T00:00:00Z"}',
          200,
        ),
      ),
    );
    final m = await p.metadata(
      const SyncAuthSession(accountId: 'x'),
      const SyncRemoteTarget(id: '1', name: 'Realmwise.realmwise'),
    );
    expect(m!.revision.value, 'tag');
    expect(m.contentHash, 'h');
  });
  test('debug metadata tracing is redacted and records safe taxonomy', () async {
    final store = _Store();
    await store.write('onedrive_oauth:id', '{"access_token":"secret-token"}');
    final logs = <String>[];
    SyncDebug.logger = logs.add;
    try {
      final p = OneDriveProvider(
        authenticator: OneDriveOAuthAuthenticator(
          clientId: 'id',
          redirectUri: Uri.parse('http://localhost/cb'),
          browser: _Browser(),
          callback: _Callback(),
          tokenStore: OneDriveTokenStore(store),
        ),
        tokenStore: OneDriveTokenStore(store),
        httpClient: MockClient(
          (_) async => http.Response(
            '{"eTag":"very-long-etag-secret","file":{"hashes":{"sha256Hash":"hash"}}}',
            200,
          ),
        ),
      );
      await p.metadata(
        const SyncAuthSession(accountId: 'x'),
        const SyncRemoteTarget(id: 'item-id', name: 'Realmwise.realmwise'),
      );
      expect(logs.single, contains('provider.metadata'));
      expect(logs.single, contains('etagPresent=true'));
      expect(logs.single, isNot(contains('very-long-etag-secret')));
      expect(logs.single, isNot(contains('secret-token')));
    } finally {
      SyncDebug.logger = null;
    }
  });
  test('OAuth binds the session to the verified Microsoft account', () async {
    final store = _Store();
    final browser = _CapturingBrowser();
    final auth = OneDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost/cb'),
      browser: browser,
      callback: _DynamicCallback(browser),
      tokenStore: OneDriveTokenStore(store),
      httpClient: MockClient(
        (request) async => request.method == 'POST'
            ? http.Response(
                '{"access_token":"token","refresh_token":"refresh"}',
                200,
              )
            : http.Response(
                '{"id":"account-1","userPrincipalName":"a@example.com"}',
                200,
              ),
      ),
    );
    final session = await auth.authenticate();
    expect(session.accountId, 'account-1');
    expect(session.displayName, 'a@example.com');
    expect(browser.uri!.queryParameters['scope'], contains('User.Read'));
  });
  test('OAuth preserves encoded Android redirect in authorize and token requests', () async {
    final store = _Store();
    final browser = _CapturingBrowser();
    final requests = <http.Request>[];
    final redirect = Uri.parse(
      'msauth://com.realmwise.rpg.tracker/hu33S0PdJMD%2FBlOPVgFheEvptH8%3D',
    );
    final auth = OneDriveOAuthAuthenticator(
      clientId: 'id', redirectUri: redirect, browser: browser,
      callback: _DynamicCallback(browser), tokenStore: OneDriveTokenStore(store),
      httpClient: MockClient((request) async {
        requests.add(request);
        return request.method == 'POST'
            ? http.Response('{"access_token":"token"}', 200)
            : http.Response('{"id":"account-1"}', 200);
      }),
    );
    await auth.authenticate();
    expect(browser.uri!.queryParameters['redirect_uri'], redirect.toString());
    expect(requests.first.body, contains('redirect_uri=msauth%3A%2F%2Fcom.realmwise.rpg.tracker%2Fhu33S0PdJMD%252FBlOPVgFheEvptH8%253D'));
  });

  test('OAuth callback timeout cancels native wait and can be retried', () async {
    final callback = _CancellableCallback();
    final auth = OneDriveOAuthAuthenticator(
      clientId: 'id', redirectUri: Uri.parse('http://localhost/cb'),
      browser: _Browser(), callback: callback, tokenStore: OneDriveTokenStore(_Store()),
      callbackTimeout: const Duration(milliseconds: 1),
    );
    await expectLater(auth.authenticate(), throwsA(isA<OneDriveAuthException>()));
    expect(callback.cancelCount, 1);
    callback.value = Uri.parse('http://localhost/cb?code=x');
    // A subsequent attempt gets a clean callback lifecycle; token exchange
    // details are outside this callback-specific regression test.
    expect(callback.waitForCallback(), completion(isA<Uri>()));
  });

  test('browser failure drains callback and next authentication can retry', () async {
    final callback = _ReusableCallback();
    final failing = OneDriveOAuthAuthenticator(
      clientId: 'id', redirectUri: Uri.parse('http://localhost/cb'),
      browser: _ThrowingBrowser(), callback: callback,
      tokenStore: OneDriveTokenStore(_Store()),
    );
    await expectLater(failing.authenticate(), throwsA(isA<StateError>()));
    expect(callback.cancelCount, 1);

    final retry = OneDriveOAuthAuthenticator(
      clientId: 'id', redirectUri: Uri.parse('http://localhost/cb'),
      browser: _CompletingBrowser(callback), callback: callback,
      tokenStore: OneDriveTokenStore(_Store()),
      httpClient: MockClient((request) async => request.method == 'POST'
          ? http.Response('{"access_token":"token"}', 200)
          : http.Response('{"id":"account-1"}', 200)),
    );
    expect((await retry.authenticate()).accountId, 'account-1');
  });

  test('OAuth account verification retries Graph 503', () async {
    final store = _Store();
    final browser = _CapturingBrowser();
    var meCalls = 0;
    final auth = OneDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost/cb'),
      browser: browser,
      callback: _DynamicCallback(browser),
      tokenStore: OneDriveTokenStore(store),
      delay: (_) async {},
      httpClient: MockClient((request) async {
        if (request.method == 'POST') {
          return http.Response('{"access_token":"token"}', 200);
        }
        meCalls++;
        return meCalls == 1
            ? http.Response('', 503)
            : http.Response('{"id":"account-1"}', 200);
      }),
    );
    final session = await auth.authenticate();
    expect(session.accountId, 'account-1');
    expect(meCalls, 2);
  });
  test(
    'creates Realmwise folder and empty bundle with Graph content API',
    () async {
      final store = _Store();
      await store.write(
        'onedrive_oauth:id',
        '{"access_token":"a","account_id":"x"}',
      );
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/approot'))
          return http.Response('{"id":"root"}', 200);
        if (request.method == 'GET' &&
            request.url.path.endsWith('/root/children'))
          return http.Response('{"value":[]}', 200);
        if (request.method == 'POST')
          return http.Response(
            '{"id":"folder","name":"Realmwise","folder":{}}',
            201,
          );
        if (request.method == 'GET') return http.Response('{"value":[]}', 200);
        return http.Response(
          '{"id":"bundle","name":"Realmwise.realmwise"}',
          201,
        );
      });
      final provider = OneDriveProvider(
        authenticator: OneDriveOAuthAuthenticator(
          clientId: 'id',
          redirectUri: Uri.parse('http://localhost/cb'),
          browser: _Browser(),
          callback: _Callback(),
          tokenStore: OneDriveTokenStore(store),
        ),
        tokenStore: OneDriveTokenStore(store),
        httpClient: client,
      );
      final target = await provider.ensureBundleTarget(
        const SyncAuthSession(accountId: 'x'),
      );
      expect(target.id, 'bundle');
      expect(requests.last.method, 'PUT');
      expect(requests.last.url.path, contains('Realmwise.realmwise'));
    },
  );
  test('retries transient Graph 503 and succeeds', () async {
    final store = _Store();
    await store.write(
      'onedrive_oauth:id',
      '{"access_token":"a","account_id":"x"}',
    );
    var rootCalls = 0;
    final waits = <Duration>[];
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/approot')) {
        rootCalls++;
        if (rootCalls == 1)
          return http.Response('', 503, headers: {'retry-after': '1'});
        return http.Response('{"id":"root"}', 200);
      }
      return http.Response('{"value":[]}', 200);
    });
    final auth = OneDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost/cb'),
      browser: _Browser(),
      callback: _Callback(),
      tokenStore: OneDriveTokenStore(store),
    );
    final p = OneDriveProvider(
      authenticator: auth,
      tokenStore: OneDriveTokenStore(store),
      httpClient: client,
      delay: (d) async => waits.add(d),
    );
    await p.listRemoteTargets(const SyncAuthSession(accountId: 'x'));
    expect(rootCalls, 2);
    expect(waits.single, const Duration(seconds: 1));
  });

  test('exhausted Graph 503 is actionable and preserves status', () async {
    final store = _Store();
    await store.write(
      'onedrive_oauth:id',
      '{"access_token":"a","account_id":"x"}',
    );
    final auth = OneDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost/cb'),
      browser: _Browser(),
      callback: _Callback(),
      tokenStore: OneDriveTokenStore(store),
    );
    final p = OneDriveProvider(
      authenticator: auth,
      tokenStore: OneDriveTokenStore(store),
      httpClient: MockClient((_) async => http.Response('', 503)),
      delay: (_) async {},
      maxTransientRetries: 2,
    );
    await expectLater(
      p.listRemoteTargets(const SyncAuthSession(accountId: 'x')),
      throwsA(
        isA<OneDriveException>()
            .having((e) => e.statusCode, 'status', 503)
            .having((e) => e.message, 'message', contains('preparing storage')),
      ),
    );
  });
  test('upload maps Graph 412 to the shared conflict exception', () async {
    final store = _Store();
    await store.write(
      'onedrive_oauth:id',
      '{"access_token":"a","account_id":"x"}',
    );
    final client = MockClient(
      (request) async => request.method == 'GET'
          ? http.Response(
              '{"eTag":"tag","file":{"hashes":{"sha256Hash":"h"}}}',
              200,
            )
          : http.Response('', 412),
    );
    final provider = OneDriveProvider(
      authenticator: OneDriveOAuthAuthenticator(
        clientId: 'id',
        redirectUri: Uri.parse('http://localhost/cb'),
        browser: _Browser(),
        callback: _Callback(),
        tokenStore: OneDriveTokenStore(store),
      ),
      tokenStore: OneDriveTokenStore(store),
      httpClient: client,
    );
    expect(
      provider.upload(
        const SyncAuthSession(accountId: 'x'),
        const SyncRemoteTarget(id: '1', name: 'b'),
        Uint8List.fromList([1]),
      ),
      throwsA(isA<SyncConflictException>()),
    );
  });
  test('download retries an incoherent read-after-write window', () async {
    final store = _Store();
    await store.write(
      'onedrive_oauth:id',
      '{"access_token":"a","account_id":"x"}',
    );
    final payload = Uint8List.fromList([1, 2, 3]);
    final hash = sha256.convert(payload).toString();
    var metadataCalls = 0;
    final waits = <Duration>[];
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/content')) {
        return http.Response.bytes(payload, 200);
      }
      metadataCalls++;
      final tag = metadataCalls == 1 ? 'tag-1' : 'tag-2';
      return http.Response(
        '{"eTag":"$tag","file":{"hashes":{"sha256Hash":"$hash"}}}',
        200,
      );
    });
    final provider = OneDriveProvider(
      authenticator: OneDriveOAuthAuthenticator(
        clientId: 'id',
        redirectUri: Uri.parse('http://localhost/cb'),
        browser: _Browser(),
        callback: _Callback(),
        tokenStore: OneDriveTokenStore(store),
      ),
      tokenStore: OneDriveTokenStore(store),
      httpClient: client,
      delay: (d) async => waits.add(d),
    );
    final result = await provider.download(
      const SyncAuthSession(accountId: 'x'),
      const SyncRemoteTarget(id: '1', name: 'b'),
    );
    expect(result.payload, payload);
    expect(result.metadata.revision.value, 'tag-2');
    expect(metadataCalls, 4);
    expect(waits, [const Duration(seconds: 1)]);
  });
  test('download rejects a precondition content hash conflict', () async {
    final store = _Store();
    await store.write(
      'onedrive_oauth:id',
      '{"access_token":"a","account_id":"x"}',
    );
    var contentCalls = 0;
    final provider = OneDriveProvider(
      authenticator: OneDriveOAuthAuthenticator(
        clientId: 'id',
        redirectUri: Uri.parse('http://localhost/cb'),
        browser: _Browser(),
        callback: _Callback(),
        tokenStore: OneDriveTokenStore(store),
      ),
      tokenStore: OneDriveTokenStore(store),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/content')) {
          contentCalls++;
          return http.Response.bytes([1], 200);
        }
        return http.Response(
          '{"eTag":"tag","file":{"hashes":{"sha256Hash":"remote"}}}',
          200,
        );
      }),
    );

    await expectLater(
      provider.download(
        const SyncAuthSession(accountId: 'x'),
        const SyncRemoteTarget(id: '1', name: 'b'),
        precondition: const SyncPrecondition(
          revision: SyncRevision('tag'),
          contentHash: 'expected',
        ),
      ),
      throwsA(isA<SyncConflictException>()),
    );
    expect(contentCalls, 0);
  });

  test('download requires stable bytes without an identity hash', () async {
    final store = _Store();
    await store.write(
      'onedrive_oauth:id',
      '{"access_token":"a","account_id":"x"}',
    );
    final stalePayload = Uint8List.fromList([1, 2]);
    final currentPayload = Uint8List.fromList([4, 5]);
    var metadataCalls = 0;
    var contentCalls = 0;
    final waits = <Duration>[];
    final provider = OneDriveProvider(
      authenticator: OneDriveOAuthAuthenticator(
        clientId: 'id',
        redirectUri: Uri.parse('http://localhost/cb'),
        browser: _Browser(),
        callback: _Callback(),
        tokenStore: OneDriveTokenStore(store),
      ),
      tokenStore: OneDriveTokenStore(store),
      maxTransientRetries: 2,
      delay: (d) async => waits.add(d),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/content')) {
          contentCalls++;
          return http.Response.bytes(
            contentCalls <= 2 ? stalePayload : currentPayload,
            200,
          );
        }
        metadataCalls++;
        return http.Response('{"eTag":"tag"}', 200);
      }),
    );

    final result = await provider.download(
      const SyncAuthSession(accountId: 'x'),
      const SyncRemoteTarget(id: '1', name: 'b'),
    );

    expect(result.payload, currentPayload);
    expect(contentCalls, 4);
    expect(metadataCalls, 8);
    expect(waits, [const Duration(seconds: 1), const Duration(seconds: 2)]);
  });
  test('hashless download fails after one bounded confirmation', () async {
    final store = _Store();
    await store.write(
      'onedrive_oauth:id',
      '{"access_token":"a","account_id":"x"}',
    );
    var contentCalls = 0;
    final waits = <Duration>[];
    final provider = OneDriveProvider(
      authenticator: OneDriveOAuthAuthenticator(
        clientId: 'id',
        redirectUri: Uri.parse('http://localhost/cb'),
        browser: _Browser(),
        callback: _Callback(),
        tokenStore: OneDriveTokenStore(store),
      ),
      tokenStore: OneDriveTokenStore(store),
      maxTransientRetries: 1,
      delay: (d) async => waits.add(d),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/content')) {
          contentCalls++;
          return http.Response.bytes([contentCalls.isEven ? 2 : 1], 200);
        }
        return http.Response('{"eTag":"tag"}', 200);
      }),
    );

    await expectLater(
      provider.download(
        const SyncAuthSession(accountId: 'x'),
        const SyncRemoteTarget(id: '1', name: 'b'),
      ),
      throwsA(
        isA<OneDriveException>().having(
          (e) => e.message,
          'message',
          'Unable to verify downloaded content',
        ),
      ),
    );
    expect(contentCalls, 3);
    expect(waits, [const Duration(seconds: 1)]);
  });
  test('account mismatch is rejected', () async {
    final store = _Store();
    await store.write(
      'onedrive_oauth:id',
      '{"access_token":"a","account_id":"alice"}',
    );
    final auth = OneDriveOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost/cb'),
      browser: _Browser(),
      callback: _Callback(),
      tokenStore: OneDriveTokenStore(store),
    );
    final p = OneDriveProvider(
      authenticator: auth,
      tokenStore: OneDriveTokenStore(store),
      httpClient: MockClient((_) async => http.Response('{}', 200)),
    );
    expect(
      () => p.metadata(
        const SyncAuthSession(accountId: 'bob'),
        const SyncRemoteTarget(id: '1', name: 'x'),
      ),
      throwsA(isA<OneDriveAuthException>()),
    );
  });
}

class _Browser implements OneDriveOAuthBrowser {
  @override
  Future<void> open(Uri uri) async {}
}

class _CapturingBrowser implements OneDriveOAuthBrowser {
  Uri? uri;
  @override
  Future<void> open(Uri value) async => uri = value;
}

class _DynamicCallback implements OneDriveOAuthCallback {
  _DynamicCallback(this.browser);
  final _CapturingBrowser browser;
  @override
  Future<Uri> waitForCallback() async {
    while (browser.uri == null) {
      await Future<void>.delayed(Duration.zero);
    }
    return Uri.parse(
      'http://localhost/cb?state=${browser.uri!.queryParameters['state']}&code=code',
    );
  }
}

class _Callback implements OneDriveOAuthCallback {
  @override
  Future<Uri> waitForCallback() async =>
      Uri.parse('http://localhost/cb?state=x');
}

class _DeniedCallback implements OneDriveOAuthCallback {
  @override
  Future<Uri> waitForCallback() async =>
      Uri.parse('http://localhost/cb?state=bad&error=access_denied');
}

class _CancellableCallback
    implements OneDriveOAuthCallback, OneDriveOAuthCallbackCancellation {
  int cancelCount = 0;
  Uri? value;
  @override
  Future<Uri> waitForCallback() async {
    while (value == null) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    return value!;
  }

  @override
  Future<void> cancel() async => cancelCount++;
}

class _ThrowingBrowser implements OneDriveOAuthBrowser {
  @override
  Future<void> open(Uri uri) => Future<void>.error(StateError('browser unavailable'));
}

class _CompletingBrowser implements OneDriveOAuthBrowser {
  _CompletingBrowser(this.callback);
  final _ReusableCallback callback;
  @override
  Future<void> open(Uri uri) async => callback.complete(Uri.parse(
    'http://localhost/cb?state=${uri.queryParameters['state']}&code=code',
  ));
}

class _ReusableCallback
    implements OneDriveOAuthCallback, OneDriveOAuthCallbackCancellation {
  Completer<Uri>? _pending;
  int cancelCount = 0;
  @override
  Future<Uri> waitForCallback() {
    _pending = Completer<Uri>();
    return _pending!.future;
  }
  void complete(Uri value) => _pending?.complete(value);
  @override
  Future<void> cancel() async {
    cancelCount++;
    final pending = _pending;
    _pending = null;
    pending?.completeError(OneDriveAuthException('cancelled'));
  }
}
