import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:realmwise/services/onedrive_sync.dart';
import 'package:realmwise/services/secure_storage_service.dart';
import 'package:realmwise/services/sync_contract.dart';

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
