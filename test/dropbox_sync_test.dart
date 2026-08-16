import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:realmwise/services/dropbox_sync.dart';
import 'package:realmwise/services/secure_storage_service.dart';
import 'package:realmwise/services/sync_contract.dart';

class _Store implements TokenStorage {
  final m = <String, String>{};
  Future<String?> read(String k) async => m[k];
  Future<void> write(String k, String v) async {
    m[k] = v;
  }

  Future<void> delete(String k) async {
    m.remove(k);
  }
}

class _Browser implements DropboxOAuthBrowser {
  Uri? opened;
  Future<void> open(Uri u) async {
    opened = u;
  }
}

class _Callback implements DropboxOAuthCallback {
  _Callback(this.uri);
  final Uri uri;
  Future<Uri> waitForCallback() async => uri;
}

String _dropboxHash(Uint8List bytes) =>
    sha256.convert(sha256.convert(bytes).bytes).toString();

void main() {
  test('token store round trip and provider id', () async {
    final s = _Store();
    final t = DropboxTokenStore(s);
    await t.write('k', {'access_token': 'x'});
    expect((await t.read('k'))['access_token'], 'x');
    final a = DropboxOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost/cb'),
      browser: _Browser(),
      callback: _Callback(Uri.parse('http://localhost/cb?error=access_denied')),
      tokenStore: t,
    );
    expect(
      DropboxProvider(authenticator: a, tokenStore: t).provider,
      'dropbox',
    );
  });
  test('refreshes OAuth token', () async {
    final s = _Store();
    final t = DropboxTokenStore(s);
    await t.write('dropbox_oauth:id', {
      'refresh_token': 'r',
      'account_id': 'acct',
      'expires_at': DateTime.now()
          .subtract(const Duration(days: 1))
          .toIso8601String(),
    });
    final c = MockClient(
      (r) async => r.url.path.endsWith('token')
          ? http.Response('{"access_token":"new","expires_in":3600}', 200)
          : http.Response('{"rev":"rev1","content_hash":"hash"}', 200),
    );
    final a = DropboxOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost/cb'),
      browser: _Browser(),
      callback: _Callback(Uri.parse('http://localhost/cb')),
      tokenStore: t,
      httpClient: c,
    );
    final p = DropboxProvider(authenticator: a, tokenStore: t, httpClient: c);
    expect(
      await p.metadata(
        const SyncAuthSession(accountId: 'acct'),
        const SyncRemoteTarget(id: 'id', name: 'x'),
      ),
      isNotNull,
    );
    expect((await t.read('dropbox_oauth:id'))['access_token'], 'new');
  });
  test('revision precondition conflict', () async {
    final s = _Store();
    final t = DropboxTokenStore(s);
    await t.write('dropbox_oauth:id', {
      'access_token': 'a',
      'account_id': 'acct',
      'expires_at': DateTime.now()
          .add(const Duration(hours: 1))
          .toIso8601String(),
    });
    final c = MockClient((r) async {
      if (r.url.path.endsWith('get_metadata'))
        return http.Response('{"rev":"rev2","content_hash":""}', 200);
      return http.Response('', 500);
    });
    final a = DropboxOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost/cb'),
      browser: _Browser(),
      callback: _Callback(Uri.parse('http://localhost/cb')),
      tokenStore: t,
      httpClient: c,
    );
    final p = DropboxProvider(authenticator: a, tokenStore: t, httpClient: c);
    expect(
      () => p.upload(
        const SyncAuthSession(accountId: 'acct'),
        const SyncRemoteTarget(id: 'id', name: 'x'),
        Uint8List.fromList([1]),
        precondition: const SyncPrecondition(revision: SyncRevision('rev1')),
      ),
      throwsA(isA<SyncConflictException>()),
    );
  });
  test('content hash precondition conflict is enforced', () async {
    final s = _Store();
    final t = DropboxTokenStore(s);
    await t.write('dropbox_oauth:id', {
      'access_token': 'a',
      'account_id': 'acct',
      'expires_at': DateTime.now()
          .add(const Duration(hours: 1))
          .toIso8601String(),
    });
    final c = MockClient(
      (r) async =>
          http.Response('{"rev":"rev2","content_hash":"remote-hash"}', 200),
    );
    final a = DropboxOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost/cb'),
      browser: _Browser(),
      callback: _Callback(Uri.parse('http://localhost/cb')),
      tokenStore: t,
      httpClient: c,
    );
    final p = DropboxProvider(authenticator: a, tokenStore: t, httpClient: c);
    expect(
      () => p.upload(
        const SyncAuthSession(accountId: 'acct'),
        const SyncRemoteTarget(id: 'id', name: 'x'),
        Uint8List.fromList([1]),
        precondition: const SyncPrecondition(contentHash: 'local-hash'),
      ),
      throwsA(isA<SyncConflictException>()),
    );
  });
  test('download fails closed when Dropbox content is not coherent', () async {
    final s = _Store();
    final t = DropboxTokenStore(s);
    await t.write('dropbox_oauth:id', {
      'access_token': 'a',
      'account_id': 'acct',
      'expires_at': DateTime.now()
          .add(const Duration(hours: 1))
          .toIso8601String(),
    });
    var metadataCalls = 0;
    final c = MockClient((r) async {
      if (r.url.path.endsWith('get_metadata')) {
        metadataCalls++;
        final rev = metadataCalls.isEven ? 'rev2' : 'rev1';
        return http.Response('{"rev":"$rev","content_hash":"hash"}', 200);
      }
      return http.Response(
        'bytes',
        200,
        headers: {'dropbox-api-result': '{"rev":"rev1"}'},
      );
    });
    final a = DropboxOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost/cb'),
      browser: _Browser(),
      callback: _Callback(Uri.parse('http://localhost/cb')),
      tokenStore: t,
      httpClient: c,
    );
    final p = DropboxProvider(
      authenticator: a,
      tokenStore: t,
      httpClient: c,
      maxTransientRetries: 1,
      delay: (_) => Future.value(),
    );
    expect(
      () => p.download(
        const SyncAuthSession(accountId: 'acct'),
        const SyncRemoteTarget(id: 'id', name: 'x'),
      ),
      throwsA(isA<DropboxException>()),
    );
  });
  test('ambiguous upload error is reconciled without replay', () async {
    final s = _Store();
    final t = DropboxTokenStore(s);
    await t.write('dropbox_oauth:id', {
      'access_token': 'a',
      'account_id': 'acct',
      'expires_at': DateTime.now()
          .add(const Duration(hours: 1))
          .toIso8601String(),
    });
    var uploads = 0;
    var metadataCalls = 0;
    final hash = _dropboxHash(Uint8List.fromList([1]));
    final c = MockClient((r) async {
      if (r.url.path.endsWith('get_metadata')) {
        metadataCalls++;
        return http.Response(
          metadataCalls == 1
              ? '{"rev":"old","content_hash":"old"}'
              : '{"rev":"new","content_hash":"$hash"}',
          200,
        );
      }
      if (r.url.path.endsWith('/upload')) {
        uploads++;
        return http.Response('', 500);
      }
      return http.Response('', 500);
    });
    final a = DropboxOAuthAuthenticator(
      clientId: 'id',
      redirectUri: Uri.parse('http://localhost/cb'),
      browser: _Browser(),
      callback: _Callback(Uri.parse('http://localhost/cb')),
      tokenStore: t,
      httpClient: c,
    );
    final p = DropboxProvider(authenticator: a, tokenStore: t, httpClient: c);
    final result = await p.upload(
      const SyncAuthSession(accountId: 'acct'),
      const SyncRemoteTarget(id: 'id', name: 'x'),
      Uint8List.fromList([1]),
    );
    expect(result.metadata.revision.value, 'new');
    expect(uploads, 1);
  });
}
