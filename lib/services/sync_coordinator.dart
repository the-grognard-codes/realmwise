import 'dart:typed_data';

import 'sync_contract.dart';
import 'sync_metadata.dart';

/// Small provider-neutral orchestration layer used by the settings UI.
class SyncCoordinator {
  SyncCoordinator({required this.metadataStorage});

  final SyncMetadataStorage metadataStorage;
  SyncProvider? provider;
  SyncAuthSession? session;
  SyncRemoteTarget? target;
  SyncMetadata? metadata;

  bool get isConnected => provider != null && session != null;

  Future<void> configureTarget(SyncRemoteTarget selected) async {
    final current = metadata;
    if (current == null) throw StateError('Connect a provider first.');
    target = selected;
    metadata = SyncMetadata(
      catalogIdentity: current.catalogIdentity,
      provider: current.provider,
      accountId: current.accountId,
      accountDisplayName: current.accountDisplayName,
      remoteTargetId: selected.id,
      remoteTargetName: selected.name,
      revision: current.revision,
      contentHash: current.contentHash,
      createdAt: current.createdAt,
      updatedAt: DateTime.now().toUtc(),
      state: SyncState.ready,
    );
    await metadataStorage.write(metadata!);
  }

  Future<void> restore(
    SyncProvider value,
    SyncAuthSession restored,
    SyncMetadata saved,
  ) async {
    final targets = await value.listRemoteTargets(restored);
    provider = value;
    session = restored;
    target = targets
        .where((item) => item.id == saved.remoteTargetId)
        .firstOrNull;
    metadata = SyncMetadata(
      catalogIdentity: saved.catalogIdentity,
      provider: saved.provider,
      accountId: saved.accountId,
      accountDisplayName: restored.displayName ?? saved.accountDisplayName,
      remoteTargetId: saved.remoteTargetId,
      remoteTargetName: saved.remoteTargetName,
      revision: saved.revision,
      contentHash: saved.contentHash,
      createdAt: saved.createdAt,
      updatedAt: DateTime.now().toUtc(),
      state: target == null ? SyncState.connectedUnconfigured : SyncState.ready,
      error: saved.error,
    );
    await metadataStorage.write(metadata!);
  }

  Future<SyncMetadata> connect(
    SyncProvider value,
    String catalogIdentity,
  ) async {
    provider = value;
    try {
      final authenticated = await value.authenticate();
      final targets = await value.listRemoteTargets(authenticated);
      final previous = await metadataStorage.read(catalogIdentity);
      session = authenticated;
      target =
          targets
              .where((item) => item.id == previous?.remoteTargetId)
              .firstOrNull ??
          (targets.isEmpty ? null : targets.first);
      metadata = SyncMetadata(
        catalogIdentity: catalogIdentity,
        provider: value.provider,
        accountId: authenticated.accountId,
        accountDisplayName: authenticated.displayName,
        remoteTargetId: target?.id,
        remoteTargetName: target?.name,
        state: target == null
            ? SyncState.connectedUnconfigured
            : SyncState.ready,
        createdAt: previous?.createdAt ?? DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );
      await metadataStorage.write(metadata!);
      return metadata!;
    } catch (error) {
      final previous = await metadataStorage.read(catalogIdentity);
      metadata = SyncMetadata(
        catalogIdentity: catalogIdentity,
        provider: value.provider,
        accountId: previous?.accountId,
        accountDisplayName: previous?.accountDisplayName,
        remoteTargetId: previous?.remoteTargetId,
        remoteTargetName: previous?.remoteTargetName,
        createdAt: previous?.createdAt ?? DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
        state: SyncState.error,
        error: sanitizeSyncError(error),
      );
      await metadataStorage.write(metadata!);
      provider = null;
      session = null;
      rethrow;
    }
  }

  /// Rolls back a partially completed connection (for example, target setup)
  /// and leaves a recoverable, sanitized error state persisted for the UI.
  Future<void> failConnection(Object error) async {
    final current = metadata;
    if (current != null) {
      metadata = SyncMetadata(
        catalogIdentity: current.catalogIdentity,
        provider: current.provider,
        accountId: current.accountId,
        accountDisplayName: current.accountDisplayName,
        remoteTargetId: current.remoteTargetId,
        remoteTargetName: current.remoteTargetName,
        createdAt: current.createdAt,
        updatedAt: DateTime.now().toUtc(),
        state: SyncState.error,
        error: sanitizeSyncError(error),
      );
      await metadataStorage.write(metadata!);
    }
    provider = null;
    session = null;
    target = null;
  }

  Future<SyncMetadata> sync(Uint8List payload) async {
    final p = provider, s = session, t = target, current = metadata;
    if (p == null || s == null || t == null || current == null) {
      throw StateError('Connect Google Drive before syncing.');
    }
    late final SyncUploadResult result;
    try {
      result = await p.upload(
        s,
        t,
        payload,
        precondition: current.revision == null
            ? null
            : SyncPrecondition(revision: SyncRevision(current.revision!)),
      );
    } catch (error) {
      metadata = SyncMetadata(
        catalogIdentity: current.catalogIdentity,
        provider: current.provider,
        accountId: current.accountId,
        accountDisplayName: current.accountDisplayName,
        remoteTargetId: current.remoteTargetId,
        remoteTargetName: current.remoteTargetName,
        revision: current.revision,
        contentHash: current.contentHash,
        createdAt: current.createdAt,
        updatedAt: DateTime.now().toUtc(),
        state: SyncState.error,
        error: sanitizeSyncError(error),
      );
      await metadataStorage.write(metadata!);
      rethrow;
    }
    metadata = SyncMetadata(
      catalogIdentity: current.catalogIdentity,
      provider: current.provider,
      accountId: current.accountId,
      accountDisplayName: current.accountDisplayName,
      remoteTargetId: t.id,
      remoteTargetName: t.name,
      revision: result.metadata.revision.value,
      contentHash: result.metadata.contentHash,
      createdAt: current.createdAt,
      updatedAt: DateTime.now().toUtc(),
      state: SyncState.ready,
    );
    await metadataStorage.write(metadata!);
    return metadata!;
  }

  Future<SyncDownloadResult> download() async {
    final p = provider, s = session, t = target, current = metadata;
    if (p == null || s == null || t == null || current == null) {
      throw StateError('Connect Google Drive before restoring.');
    }
    try {
      final result = await p.download(
        s,
        t,
        precondition: current.revision == null
            ? null
            : SyncPrecondition(revision: SyncRevision(current.revision!)),
      );
      metadata = SyncMetadata(
        catalogIdentity: current.catalogIdentity,
        provider: current.provider,
        accountId: current.accountId,
        accountDisplayName: current.accountDisplayName,
        remoteTargetId: t.id,
        remoteTargetName: t.name,
        revision: result.metadata.revision.value,
        contentHash: result.metadata.contentHash,
        createdAt: current.createdAt,
        updatedAt: DateTime.now().toUtc(),
        state: SyncState.ready,
      );
      return result;
    } catch (error) {
      metadata = SyncMetadata(
        catalogIdentity: current.catalogIdentity,
        provider: current.provider,
        accountId: current.accountId,
        accountDisplayName: current.accountDisplayName,
        remoteTargetId: current.remoteTargetId,
        remoteTargetName: current.remoteTargetName,
        revision: current.revision,
        contentHash: current.contentHash,
        createdAt: current.createdAt,
        updatedAt: DateTime.now().toUtc(),
        state: SyncState.error,
        error: sanitizeSyncError(error),
      );
      await metadataStorage.write(metadata!);
      rethrow;
    }
  }

  Future<void> commitDownload(SyncRemoteMetadata remote) async {
    final current = metadata;
    if (current == null) return;
    metadata = SyncMetadata(
      catalogIdentity: current.catalogIdentity,
      provider: current.provider,
      accountId: current.accountId,
      accountDisplayName: current.accountDisplayName,
      remoteTargetId: current.remoteTargetId,
      remoteTargetName: current.remoteTargetName,
      revision: remote.revision.value,
      contentHash: remote.contentHash,
      createdAt: current.createdAt,
      updatedAt: DateTime.now().toUtc(),
      state: SyncState.ready,
    );
    await metadataStorage.write(metadata!);
  }

  Future<void> disconnect() async {
    final identity = metadata?.catalogIdentity;
    provider = null;
    session = null;
    target = null;
    metadata = null;
    if (identity != null) await metadataStorage.remove(identity);
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
