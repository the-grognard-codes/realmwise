import 'dart:typed_data';

import 'sync_contract.dart';
import 'sync_metadata.dart';
import 'sync_debug.dart';

enum SyncOutcome { uploaded, alreadySynced }

/// Small provider-neutral orchestration layer used by the settings UI.
class SyncCoordinator {
  SyncCoordinator({required this.metadataStorage});

  final SyncMetadataStorage metadataStorage;
  SyncProvider? provider;
  SyncAuthSession? session;
  SyncRemoteTarget? target;
  SyncMetadata? metadata;
  SyncOutcome lastOutcome = SyncOutcome.uploaded;

  bool get isConnected => provider != null && session != null;

  Future<void> configureTarget(SyncRemoteTarget selected) async {
    final current = metadata;
    if (current == null) throw StateError('Connect a provider first.');
    target = selected;
    final sameTarget = current.remoteTargetId == selected.id;
    metadata = SyncMetadata(
      catalogIdentity: current.catalogIdentity,
      provider: current.provider,
      accountId: current.accountId,
      accountDisplayName: current.accountDisplayName,
      remoteTargetId: selected.id,
      remoteTargetName: selected.name,
      revision: sameTarget ? current.revision : null,
      contentHash: sameTarget ? current.contentHash : null,
      lastSuccessfulLocalFingerprint: sameTarget
          ? current.lastSuccessfulLocalFingerprint
          : null,
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
    final sameAccount =
        saved.provider == value.provider &&
        saved.accountId == restored.accountId;
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
      revision: sameAccount ? saved.revision : null,
      contentHash: sameAccount ? saved.contentHash : null,
      lastSuccessfulLocalFingerprint: sameAccount
          ? saved.lastSuccessfulLocalFingerprint
          : null,
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
      final sameTuple =
          previous != null &&
          previous.provider == value.provider &&
          previous.accountId == authenticated.accountId &&
          previous.remoteTargetId == target?.id;
      metadata = SyncMetadata(
        catalogIdentity: catalogIdentity,
        provider: value.provider,
        accountId: authenticated.accountId,
        accountDisplayName: authenticated.displayName,
        remoteTargetId: target?.id,
        remoteTargetName: target?.name,
        revision: sameTuple ? previous.revision : null,
        contentHash: sameTuple ? previous.contentHash : null,
        lastSuccessfulLocalFingerprint: sameTuple
            ? previous.lastSuccessfulLocalFingerprint
            : null,
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

  Future<SyncMetadata> sync(
    Uint8List payload, {
    String? localFingerprint,
  }) async {
    final p = provider, s = session, t = target, current = metadata;
    if (p == null || s == null || t == null || current == null) {
      throw StateError('Connect Google Drive before syncing.');
    }
    SyncDebug.trace('coordinator.sync.start', {
      'hasFingerprint': localFingerprint != null,
      'hasRevision': current.revision != null,
    });
    if (localFingerprint != null &&
        current.state == SyncState.ready &&
        current.provider == p.provider &&
        current.accountId == s.accountId &&
        current.remoteTargetId == t.id &&
        current.lastSuccessfulLocalFingerprint == localFingerprint &&
        current.revision != null &&
        current.contentHash != null) {
      try {
        final remote = await p.metadata(s, t);
        if (remote != null && remote.contentHash == current.contentHash) {
          // Drive can advance a file revision for its own metadata processing
          // after a successful Realmwise upload.  Its Realmwise-managed
          // payload hash is the authoritative indication that the portable
          // bundle itself is unchanged, so reconcile that benign revision
          // churn before reporting a no-op sync.
          if (remote.revision.value != current.revision) {
            metadata = SyncMetadata(
              catalogIdentity: current.catalogIdentity,
              provider: current.provider,
              accountId: current.accountId,
              accountDisplayName: current.accountDisplayName,
              remoteTargetId: current.remoteTargetId,
              remoteTargetName: current.remoteTargetName,
              revision: remote.revision.value,
              contentHash: remote.contentHash,
              lastSuccessfulLocalFingerprint:
                  current.lastSuccessfulLocalFingerprint,
              createdAt: current.createdAt,
              updatedAt: DateTime.now().toUtc(),
              state: SyncState.ready,
            );
            await metadataStorage.write(metadata!);
            SyncDebug.trace('coordinator.sync.noop_reconciled_revision', {
              'revision': remote.revision.value,
            });
          }
          lastOutcome = SyncOutcome.alreadySynced;
          SyncDebug.trace('coordinator.sync.noop', {'decision': true});
          return metadata!;
        }
      } catch (_) {
        SyncDebug.trace('coordinator.sync.remote_check_error');
        // Metadata lookup failure must not suppress an upload attempt.
      }
    }
    late final SyncUploadResult result;
    try {
      result = await p.upload(
        s,
        t,
        payload,
        precondition: current.revision == null
            ? null
            : SyncPrecondition(
                revision: SyncRevision(current.revision!),
                contentHash: current.contentHash,
              ),
      );
    } catch (error) {
      SyncDebug.trace('coordinator.sync.upload_error', {
        'type': error.runtimeType.toString(),
      });
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
      lastSuccessfulLocalFingerprint: localFingerprint,
      createdAt: current.createdAt,
      updatedAt: DateTime.now().toUtc(),
      state: SyncState.ready,
    );
    await metadataStorage.write(metadata!);
    lastOutcome = SyncOutcome.uploaded;
    SyncDebug.trace('coordinator.sync.uploaded', {
      'revision': result.metadata.revision.value,
    });
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

  Future<void> commitDownload(
    SyncRemoteMetadata remote, {
    String? localFingerprint,
  }) async {
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
      lastSuccessfulLocalFingerprint: localFingerprint,
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
