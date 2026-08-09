import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/services/sync_metadata.dart';

void main() {
  test('metadata serializes without credentials and round trips', () {
    final metadata = SyncMetadata(
      catalogIdentity: 'catalog-a',
      provider: 'drive',
      accountId: 'user@example.com',
      remoteTargetId: 'folder',
      revision: 'r1',
      contentHash: 'h',
      state: SyncState.ready,
      error: 'safe error',
      createdAt: DateTime.utc(2025),
      updatedAt: DateTime.utc(2025, 1, 2),
    );
    final encoded = metadata.encode();
    expect(encoded, isNot(contains('token')));
    expect(SyncMetadata.decode(encoded).toJson(), metadata.toJson());
  });

  test('credential names are isolated by catalog, provider, and account', () {
    final a = syncCredentialKey(
      catalogIdentity: 'a',
      provider: 'p',
      accountId: 'x',
    );
    expect(
      a,
      isNot(
        syncCredentialKey(catalogIdentity: 'b', provider: 'p', accountId: 'x'),
      ),
    );
    expect(a, isNot(contains('secret')));
    expect(
      syncCredentialKey(catalogIdentity: 'a:b', provider: 'p', accountId: 'x'),
      isNot(
        syncCredentialKey(
          catalogIdentity: 'a',
          provider: 'p',
          accountId: 'x:b',
        ),
      ),
    );
    expect(
      syncCredentialKey(
        catalogIdentity: ' café ',
        provider: 'p',
        accountId: 'x',
      ),
      isNot(
        syncCredentialKey(
          catalogIdentity: 'café',
          provider: 'p',
          accountId: 'x',
        ),
      ),
    );
  });

  test('state machine covers sync transitions', () {
    final machine = SyncStateMachine();
    expect(machine.state, SyncState.notConnected);
    machine.connected();
    expect(machine.state, SyncState.connectedUnconfigured);
    machine.configure();
    machine.startSync();
    expect(machine.state, SyncState.syncing);
    machine.finishSync();
    machine.needsDecision();
    expect(machine.state, SyncState.needsDecision);
    expect(() => machine.startSync(), throwsStateError);
    machine.disconnect();
    machine.connected();
    machine.fail(Exception('Bearer abc'));
    expect(machine.state, SyncState.error);
    expect(machine.error, 'sync_error');
    machine.connected(configured: true);
    expect(machine.state, SyncState.ready);
    expect(machine.error, isNull);
  });

  test('errors redact bearer and credential query values', () {
    final result = sanitizeSyncError(
      Exception('Bearer abc123 https://x.test/?access_token=secret'),
    );
    expect(result, 'sync_error');
  });

  test('invalid metadata is safely defaulted and schema-versioned', () {
    expect(
      SyncMetadata.decode(
        '{bad json',
        fallbackCatalogIdentity: 'catalog-a',
      ).catalogIdentity,
      'catalog-a',
    );
    expect(SyncMetadata.decode('{}').state, SyncState.notConnected);
    expect(
      SyncMetadata.decode(
        '{"schemaVersion":99}',
        fallbackCatalogIdentity: 'catalog-a',
      ).catalogIdentity,
      'catalog-a',
    );
  });
}
