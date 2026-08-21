import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/services/sync_contract.dart';
import 'package:realmwise/services/sync_coordinator.dart';
import 'package:realmwise/services/sync_metadata.dart';

void main() {
  test('rebinds active runtime after remote catalog replacement', () async {
    final storage = _MemoryMetadataStorage();
    final coordinator = SyncCoordinator(metadataStorage: storage);
    final provider = _Provider();
    final session = const SyncAuthSession(
      accountId: 'account',
      displayName: 'Account',
    );
    final target = const SyncRemoteTarget(id: 'target', name: 'Bundle');
    coordinator.provider = provider;
    coordinator.session = session;
    coordinator.target = target;
    coordinator.metadata = const SyncMetadata(
      catalogIdentity: 'catalog',
      provider: 'fake',
      accountId: 'account',
      accountDisplayName: 'Account',
      remoteTargetId: 'target',
      remoteTargetName: 'Bundle',
      state: SyncState.ready,
      automaticSyncEnabled: true,
      deviceId: 'device',
      deviceName: 'Phone',
      leaseToken: 'lease',
    );

    final snapshot = coordinator.captureRuntime();
    coordinator.resetRuntime();
    final rebound = await coordinator.rebindAfterCatalogRestore(
      snapshot,
      catalogIdentity: 'catalog',
      remote: const SyncRemoteMetadata(
        revision: SyncRevision('7'),
        contentHash: 'remote-hash',
      ),
      localFingerprint: 'remote-fingerprint',
    );

    expect(rebound?.catalogIdentity, 'catalog');
    expect(rebound?.revision, '7');
    expect(rebound?.contentHash, 'remote-hash');
    expect(rebound?.lastSuccessfulLocalFingerprint, 'remote-fingerprint');
    expect(rebound?.automaticSyncEnabled, isFalse);
    expect(rebound?.leaseToken, isNull);
    expect(coordinator.isConnected, isTrue);
    expect(await storage.read('catalog'), same(rebound));
  });

  test(
    'rebinds an active runtime when the restored catalog identity changes',
    () async {
      final coordinator = SyncCoordinator(
        metadataStorage: _MemoryMetadataStorage(),
      );
      final provider = _Provider();
      coordinator.provider = provider;
      coordinator.session = const SyncAuthSession(accountId: 'account');
      coordinator.target = const SyncRemoteTarget(id: 'target', name: 'Bundle');
      coordinator.metadata = const SyncMetadata(
        catalogIdentity: 'original',
        provider: 'fake',
        accountId: 'account',
        remoteTargetId: 'target',
      );

      final snapshot = coordinator.captureRuntime();
      coordinator.resetRuntime();
      final rebound = await coordinator.rebindAfterCatalogRestore(
        snapshot,
        catalogIdentity: 'manual-import',
        remote: const SyncRemoteMetadata(
          revision: SyncRevision('7'),
          contentHash: 'remote-hash',
        ),
        localFingerprint: 'remote-fingerprint',
      );

      expect(rebound?.catalogIdentity, 'manual-import');
      expect(coordinator.isConnected, isTrue);
    },
  );

  test(
    'rejects a captured runtime whose provider/account/target do not match',
    () async {
      final coordinator = SyncCoordinator(
        metadataStorage: _MemoryMetadataStorage(),
      );
      coordinator.provider = _Provider();
      coordinator.session = const SyncAuthSession(accountId: 'account');
      coordinator.target = const SyncRemoteTarget(id: 'target', name: 'Bundle');
      coordinator.metadata = const SyncMetadata(
        catalogIdentity: 'original',
        provider: 'other-provider',
        accountId: 'other-account',
        remoteTargetId: 'other-target',
      );
      final snapshot = coordinator.captureRuntime();
      coordinator.resetRuntime();
      final rebound = await coordinator.rebindAfterCatalogRestore(
        snapshot,
        catalogIdentity: 'restored',
        remote: const SyncRemoteMetadata(
          revision: SyncRevision('7'),
          contentHash: 'remote-hash',
        ),
        localFingerprint: 'remote-fingerprint',
      );
      expect(rebound, isNull);
      expect(coordinator.isConnected, isFalse);
    },
  );

  test('does not rebind without an active runtime snapshot', () async {
    final coordinator = SyncCoordinator(
      metadataStorage: _MemoryMetadataStorage(),
    );
    final rebound = await coordinator.rebindAfterCatalogRestore(
      null,
      catalogIdentity: 'catalog',
      remote: const SyncRemoteMetadata(
        revision: SyncRevision('7'),
        contentHash: 'remote-hash',
      ),
      localFingerprint: 'remote-fingerprint',
    );

    expect(rebound, isNull);
    expect(coordinator.metadata, isNull);
    expect(coordinator.isConnected, isFalse);
  });
}

class _MemoryMetadataStorage implements SyncMetadataStorage {
  final Map<String, SyncMetadata> values = <String, SyncMetadata>{};
  @override
  Future<SyncMetadata?> read(String catalogIdentity) async =>
      values[catalogIdentity];
  @override
  Future<void> write(SyncMetadata metadata) async =>
      values[metadata.catalogIdentity] = metadata;
  @override
  Future<void> remove(String catalogIdentity) async =>
      values.remove(catalogIdentity);
}

class _Provider implements SyncProvider {
  @override
  String get provider => 'fake';
  @override
  Future<SyncAuthSession> authenticate() async =>
      const SyncAuthSession(accountId: 'account');
  @override
  Future<List<SyncRemoteTarget>> listRemoteTargets(
    SyncAuthSession session,
  ) async => const [];
  @override
  Future<SyncRemoteMetadata?> metadata(
    SyncAuthSession session,
    SyncRemoteTarget target,
  ) async => null;
  @override
  Future<SyncUploadResult> upload(
    SyncAuthSession session,
    SyncRemoteTarget target,
    Uint8List payload, {
    SyncPrecondition? precondition,
  }) => throw UnimplementedError();
  @override
  Future<SyncDownloadResult> download(
    SyncAuthSession session,
    SyncRemoteTarget target, {
    SyncPrecondition? precondition,
  }) => throw UnimplementedError();
}
