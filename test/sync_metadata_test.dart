import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/services/sync_metadata.dart';
import 'dart:typed_data';
import 'package:realmwise/services/sync_contract.dart';
import 'package:realmwise/services/sync_coordinator.dart';

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

  test('metadata persists image policy and retention decision', () {
    final value = SyncMetadata(
      catalogIdentity: 'c',
      includePersonalImages: true,
      retainedRevisionCount: 5,
    );
    final restored = SyncMetadata.decode(value.encode());
    expect(restored.includePersonalImages, isTrue);
    expect(restored.retainedRevisionCount, 5);
  });

  test('sync states have understandable status labels', () {
    expect(SyncState.notConnected.label, 'Not connected');
    expect(SyncState.ready.label, contains('last sync succeeded'));
    expect(SyncState.needsDecision.label, contains('Conflict'));
    expect(SyncState.error.label, 'Sync error');
  });

  test('coordinator prevents concurrent syncs for one catalog', () async {
    final provider = _RetentionProvider()..holdUpload = true;
    final coordinator = SyncCoordinator(metadataStorage: _MemorySyncStorage());
    await coordinator.connect(provider, 'catalog');
    coordinator.metadata = const SyncMetadata(
      catalogIdentity: 'catalog',
      provider: 'fake',
      accountId: 'a',
      remoteTargetId: 'target',
      revision: 'old',
      contentHash: 'old',
      lastSuccessfulLocalFingerprint: 'old',
      state: SyncState.ready,
    );
    final first = coordinator.sync(
      Uint8List.fromList([1]),
      localFingerprint: 'new',
    );
    await provider.uploadStarted.future;
    await expectLater(
      coordinator.sync(Uint8List.fromList([1]), localFingerprint: 'newer'),
      throwsA(isA<SyncBusyException>()),
    );
    provider.releaseUpload.complete();
    await first;
  });

  test('cancellation before upload leaves metadata unchanged', () async {
    final provider = _RetentionProvider();
    final coordinator = SyncCoordinator(metadataStorage: _MemorySyncStorage());
    await coordinator.connect(provider, 'catalog');
    coordinator.metadata = const SyncMetadata(
      catalogIdentity: 'catalog',
      provider: 'fake',
      accountId: 'a',
      remoteTargetId: 'target',
      revision: 'old',
      contentHash: 'old',
      lastSuccessfulLocalFingerprint: 'old',
      state: SyncState.ready,
    );
    await expectLater(
      coordinator.sync(
        Uint8List.fromList([1]),
        localFingerprint: 'new',
        onProgress: (_) => coordinator.cancel(),
      ),
      throwsA(isA<SyncCancelledException>()),
    );
    expect(provider.uploads, 0);
    expect(coordinator.metadata?.revision, 'old');
  });

  test('cancellation after upload still commits successful revision', () async {
    final provider = _RetentionProvider()..holdUpload = true;
    final coordinator = SyncCoordinator(metadataStorage: _MemorySyncStorage());
    await coordinator.connect(provider, 'catalog');
    coordinator.metadata = const SyncMetadata(
      catalogIdentity: 'catalog',
      provider: 'fake',
      accountId: 'a',
      remoteTargetId: 'target',
      revision: 'old',
      contentHash: 'old',
      lastSuccessfulLocalFingerprint: 'old',
      state: SyncState.ready,
    );
    final pending = coordinator.sync(
      Uint8List.fromList([1]),
      localFingerprint: 'new',
    );
    await provider.uploadStarted.future;
    coordinator.cancel();
    provider.releaseUpload.complete();
    final result = await pending;
    expect(result.revision, 'new');
    expect(coordinator.metadata?.lastSuccessfulLocalFingerprint, 'new');
  });

  test('retention capability receives configured revision limit', () async {
    final provider = _RetentionProvider();
    final coordinator = SyncCoordinator(metadataStorage: _MemorySyncStorage());
    await coordinator.connect(provider, 'catalog');
    coordinator.metadata = const SyncMetadata(
      catalogIdentity: 'catalog',
      provider: 'fake',
      accountId: 'a',
      remoteTargetId: 'target',
      revision: 'old',
      contentHash: 'old',
      lastSuccessfulLocalFingerprint: 'old',
      state: SyncState.ready,
      retainedRevisionCount: 2,
    );
    await coordinator.sync(Uint8List.fromList([1]), localFingerprint: 'new');
    expect(provider.retentionKeep, 2);
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

  test('sync classification compares saved local and remote pair', () async {
    final storage = _MemorySyncStorage();
    final coordinator = SyncCoordinator(metadataStorage: storage);
    final provider = _PolicyProvider();
    await coordinator.connect(provider, 'catalog');
    coordinator.metadata = SyncMetadata(
      catalogIdentity: 'catalog',
      provider: 'fake',
      accountId: 'a',
      remoteTargetId: 'target',
      revision: 'r1',
      contentHash: 'h1',
      lastSuccessfulLocalFingerprint: 'l1',
      state: SyncState.ready,
    );
    expect(
      (await coordinator.classify('l1')).classification,
      SyncClassification.noChanges,
    );
    provider.remote = const SyncRemoteMetadata(
      revision: SyncRevision('r2'),
      contentHash: 'h2',
    );
    expect(
      (await coordinator.classify('l1')).classification,
      SyncClassification.remoteOnly,
    );
    provider.remote = const SyncRemoteMetadata(
      revision: SyncRevision('r1'),
      contentHash: 'h1',
    );
    expect(
      (await coordinator.classify('l2')).classification,
      SyncClassification.localOnly,
    );
    provider.remote = const SyncRemoteMetadata(
      revision: SyncRevision('r2'),
      contentHash: 'h2',
    );
    expect(
      (await coordinator.classify('l2')).classification,
      SyncClassification.divergent,
    );
  });

  test(
    'same content hash with advanced revision is unchanged and reconciles metadata',
    () async {
      final storage = _MemorySyncStorage();
      final coordinator = SyncCoordinator(metadataStorage: storage);
      final provider = _PolicyProvider()
        ..remote = const SyncRemoteMetadata(
          revision: SyncRevision('r2'),
          contentHash: 'h1',
        );
      await coordinator.connect(provider, 'catalog');
      coordinator.metadata = SyncMetadata(
        catalogIdentity: 'catalog',
        provider: 'fake',
        accountId: 'a',
        remoteTargetId: 'target',
        revision: 'r1',
        contentHash: 'h1',
        lastSuccessfulLocalFingerprint: 'l1',
        state: SyncState.ready,
      );

      final result = await coordinator.classify('l1');

      expect(result.classification, SyncClassification.noChanges);
      expect(result.remote?.revision.value, 'r2');
      expect(coordinator.metadata?.revision, 'r2');
      expect((await storage.read('catalog'))?.revision, 'r2');
    },
  );

  test('empty hashes never make a changed remote look unchanged', () async {
    final coordinator = SyncCoordinator(metadataStorage: _MemorySyncStorage());
    final provider = _PolicyProvider()
      ..remote = const SyncRemoteMetadata(
        revision: SyncRevision('r2'),
        contentHash: '',
      );
    await coordinator.connect(provider, 'catalog');
    coordinator.metadata = SyncMetadata(
      catalogIdentity: 'catalog',
      provider: 'fake',
      accountId: 'a',
      remoteTargetId: 'target',
      revision: 'r1',
      contentHash: '',
      lastSuccessfulLocalFingerprint: 'l1',
      state: SyncState.ready,
    );

    expect(
      (await coordinator.classify('l1')).classification,
      SyncClassification.remoteOnly,
    );
  });

  test('empty saved hash does not take the sync no-op fast path', () async {
    final coordinator = SyncCoordinator(metadataStorage: _MemorySyncStorage());
    final provider = _PolicyProvider()
      ..remote = const SyncRemoteMetadata(
        revision: SyncRevision('r1'),
        contentHash: '',
      );
    await coordinator.connect(provider, 'catalog');
    coordinator.metadata = SyncMetadata(
      catalogIdentity: 'catalog',
      provider: 'fake',
      accountId: 'a',
      remoteTargetId: 'target',
      revision: 'r1',
      contentHash: '',
      lastSuccessfulLocalFingerprint: 'l1',
      state: SyncState.ready,
    );

    await coordinator.sync(Uint8List.fromList([1]), localFingerprint: 'l1');

    expect(provider.uploads, 1);
  });

  test(
    'metadata lookup failure is unknown and preserves known pair on upload error',
    () async {
      final storage = _MemorySyncStorage();
      final coordinator = SyncCoordinator(metadataStorage: storage);
      final provider = _PolicyProvider()..metadataFails = true;
      await coordinator.connect(provider, 'catalog');
      expect(
        (await coordinator.classify('l1')).classification,
        SyncClassification.unknownError,
      );
      provider.metadataFails = false;
      provider.uploadFails = true;
      coordinator.metadata = SyncMetadata(
        catalogIdentity: 'catalog',
        provider: 'fake',
        accountId: 'a',
        remoteTargetId: 'target',
        revision: 'r1',
        contentHash: 'h1',
        lastSuccessfulLocalFingerprint: 'l1',
        state: SyncState.ready,
      );
      await expectLater(
        coordinator.sync(Uint8List.fromList([1]), localFingerprint: 'l2'),
        throwsA(isA<Object>()),
      );
      expect(coordinator.metadata?.lastSuccessfulLocalFingerprint, 'l1');
      expect(coordinator.metadata?.revision, 'r1');
    },
  );

  test('stale remote rejects explicit replacement before backup', () async {
    final coordinator = SyncCoordinator(metadataStorage: _MemorySyncStorage());
    final provider = _PolicyProvider();
    await coordinator.connect(provider, 'catalog');
    coordinator.metadata = SyncMetadata(
      catalogIdentity: 'catalog',
      provider: 'fake',
      accountId: 'a',
      remoteTargetId: 'target',
      revision: 'r1',
      contentHash: 'h1',
      lastSuccessfulLocalFingerprint: 'l1',
      state: SyncState.ready,
    );
    var backup = false;
    provider.remote = const SyncRemoteMetadata(
      revision: SyncRevision('r2'),
      contentHash: 'h2',
    );
    await expectLater(
      coordinator.resolveConflict(
        SyncConflictChoice.uploadReplaceRemote,
        currentLocalFingerprint: 'l2',
        expectedLocalFingerprint: 'l2',
        observedRemote: const SyncRemoteMetadata(
          revision: SyncRevision('r1'),
          contentHash: 'h1',
        ),
        payload: Uint8List.fromList([1]),
        payloadFingerprint: 'l2',
        backup: () async => backup = true,
      ),
      throwsA(isA<SyncConflictException>()),
    );
    expect(backup, isFalse);
  });

  test('conflict cancellation does not transfer or backup', () async {
    final coordinator = SyncCoordinator(metadataStorage: _MemorySyncStorage());
    final provider = _PolicyProvider();
    await coordinator.connect(provider, 'catalog');
    var backedUp = false;
    expect(
      await coordinator.resolveConflict(
        SyncConflictChoice.cancel,
        currentLocalFingerprint: 'l2',
        observedRemote: provider.remote,
        backup: () async => backedUp = true,
      ),
      isNull,
    );
    expect(backedUp, isFalse);
    expect(provider.uploads, 0);
  });
}

class _MemorySyncStorage implements SyncMetadataStorage {
  SyncMetadata? value;
  @override
  Future<SyncMetadata?> read(String _) async => value;
  @override
  Future<void> write(SyncMetadata metadata) async => value = metadata;
  @override
  Future<void> remove(String _) async => value = null;
}

class _PolicyProvider implements SyncProvider {
  SyncRemoteMetadata remote = const SyncRemoteMetadata(
    revision: SyncRevision('r1'),
    contentHash: 'h1',
  );
  int uploads = 0;
  bool metadataFails = false;
  bool uploadFails = false;
  @override
  String get provider => 'fake';
  @override
  Future<SyncAuthSession> authenticate() async =>
      const SyncAuthSession(accountId: 'a');
  @override
  Future<List<SyncRemoteTarget>> listRemoteTargets(SyncAuthSession _) async =>
      const [SyncRemoteTarget(id: 'target', name: 'Target')];
  @override
  Future<SyncRemoteMetadata?> metadata(
    SyncAuthSession _,
    SyncRemoteTarget _,
  ) async {
    if (metadataFails) throw StateError('metadata unavailable');
    return remote;
  }

  @override
  Future<SyncUploadResult> upload(
    SyncAuthSession _,
    SyncRemoteTarget _,
    Uint8List _, {
    SyncPrecondition? precondition,
  }) async {
    if (uploadFails) throw StateError('upload interrupted');
    uploads++;
    return SyncUploadResult(metadata: remote);
  }

  @override
  Future<SyncDownloadResult> download(
    SyncAuthSession _,
    SyncRemoteTarget _, {
    SyncPrecondition? precondition,
  }) async =>
      SyncDownloadResult(payload: Uint8List.fromList([1]), metadata: remote);
}

class _RetentionProvider extends _PolicyProvider
    implements SyncRetentionProvider {
  final uploadStarted = Completer<void>();
  final releaseUpload = Completer<void>();
  bool holdUpload = false;
  int? retentionKeep;

  @override
  Future<SyncUploadResult> upload(
    SyncAuthSession session,
    SyncRemoteTarget target,
    Uint8List payload, {
    SyncPrecondition? precondition,
  }) async {
    uploads++;
    uploadStarted.complete();
    if (holdUpload) await releaseUpload.future;
    remote = const SyncRemoteMetadata(
      revision: SyncRevision('new'),
      contentHash: 'new-hash',
    );
    return SyncUploadResult(metadata: remote);
  }

  @override
  Future<void> retainRevisions(
    SyncAuthSession session,
    SyncRemoteTarget target, {
    int keep = 3,
  }) async {
    retentionKeep = keep;
  }
}
