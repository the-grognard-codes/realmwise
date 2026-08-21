import 'dart:typed_data';

import 'sync_contract.dart';
import 'sync_metadata.dart';
import 'sync_debug.dart';

enum SyncOutcome { uploaded, alreadySynced }

/// Captures an authenticated runtime connection while the active catalog is
/// temporarily closed for a bundle replacement. Credentials are never
/// serialized into this value or into catalog metadata.
class SyncRuntimeSnapshot {
  const SyncRuntimeSnapshot({
    required this.provider,
    required this.session,
    required this.target,
    required this.metadata,
  });

  final SyncProvider provider;
  final SyncAuthSession session;
  final SyncRemoteTarget target;
  final SyncMetadata metadata;
}

/// Small provider-neutral orchestration layer used by the settings UI.
class SyncCoordinator {
  SyncCoordinator({required this.metadataStorage});

  final SyncMetadataStorage metadataStorage;
  SyncProvider? provider;
  SyncAuthSession? session;
  SyncRemoteTarget? target;
  SyncMetadata? metadata;
  SyncOutcome lastOutcome = SyncOutcome.uploaded;
  final Set<String> _activeCatalogs = <String>{};
  SyncCancellationToken? activeCancellation;
  SyncProgress? progress;
  bool get isSyncing => _activeCatalogs.contains(metadata?.catalogIdentity);

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    final identity = metadata?.catalogIdentity;
    if (identity == null)
      throw StateError('Connect a provider before syncing.');
    if (!_activeCatalogs.add(identity)) throw const SyncBusyException();
    final token = SyncCancellationToken();
    activeCancellation = token;
    try {
      return await action();
    } finally {
      _activeCatalogs.remove(identity);
      if (identical(activeCancellation, token)) activeCancellation = null;
      progress = null;
    }
  }

  void cancel() => activeCancellation?.cancel();

  bool get isConnected => provider != null && session != null;

  /// Captures the currently authenticated connection for a controlled
  /// catalog replacement. Ordinary/manual imports should not call this.
  SyncRuntimeSnapshot? captureRuntime() {
    final p = provider, s = session, t = target, current = metadata;
    if (p == null || s == null || t == null || current == null) return null;
    return SyncRuntimeSnapshot(
      provider: p,
      session: s,
      target: t,
      metadata: current,
    );
  }

  /// Rebinds a previously active connection after replacing the catalog with
  /// its just-downloaded remote bundle. A catalog identity mismatch leaves
  /// the coordinator disconnected, preventing credentials from being
  /// resurrected for an arbitrary/manual import.
  Future<SyncMetadata?> rebindAfterCatalogRestore(
    SyncRuntimeSnapshot? snapshot, {
    required String catalogIdentity,
    required SyncRemoteMetadata remote,
    required String? localFingerprint,
  }) async {
    if (snapshot == null ||
        snapshot.provider.provider != snapshot.metadata.provider ||
        snapshot.session.accountId != snapshot.metadata.accountId ||
        snapshot.target.id != snapshot.metadata.remoteTargetId) {
      return null;
    }
    provider = snapshot.provider;
    session = snapshot.session;
    target = snapshot.target;
    final current = snapshot.metadata;
    metadata = SyncMetadata(
      catalogIdentity: catalogIdentity,
      provider: snapshot.provider.provider,
      accountId: snapshot.session.accountId,
      accountDisplayName:
          snapshot.session.displayName ?? current.accountDisplayName,
      remoteTargetId: snapshot.target.id,
      remoteTargetName: snapshot.target.name,
      revision: remote.revision.value,
      contentHash: remote.contentHash,
      lastSuccessfulLocalFingerprint: localFingerprint,
      createdAt: current.createdAt,
      updatedAt: DateTime.now().toUtc(),
      state: SyncState.ready,
      includePersonalImages: current.includePersonalImages,
      retainedRevisionCount: current.retainedRevisionCount,
    );
    await metadataStorage.write(metadata!);
    return metadata;
  }

  /// Compares both sides with the last committed pair.  A metadata lookup
  /// failure is deliberately distinguishable from an empty remote file.
  Future<SyncClassificationResult> classify(
    String? currentLocalFingerprint,
  ) async {
    final p = provider, s = session, t = target, saved = metadata;
    if (p == null || s == null || t == null || saved == null) {
      return const SyncClassificationResult(SyncClassification.unknownError);
    }
    try {
      if (currentLocalFingerprint == null) {
        return const SyncClassificationResult(SyncClassification.unknownError);
      }
      final remote = await p.metadata(s, t);
      if (remote == null) {
        return const SyncClassificationResult(SyncClassification.unknownError);
      }
      final localChanged =
          currentLocalFingerprint != saved.lastSuccessfulLocalFingerprint;
      // A provider revision can advance while the Realmwise payload remains
      // unchanged.  The non-null content hash is the authoritative payload
      // identity in that case; reconcile the benign revision churn so the
      // next classification compares against the current remote revision.
      final sameContent =
          saved.contentHash != null &&
          saved.contentHash!.isNotEmpty &&
          remote.contentHash.isNotEmpty &&
          remote.contentHash == saved.contentHash;
      if (sameContent && remote.revision.value != saved.revision) {
        metadata = SyncMetadata(
          catalogIdentity: saved.catalogIdentity,
          provider: saved.provider,
          accountId: saved.accountId,
          accountDisplayName: saved.accountDisplayName,
          remoteTargetId: saved.remoteTargetId,
          remoteTargetName: saved.remoteTargetName,
          revision: remote.revision.value,
          contentHash: remote.contentHash,
          lastSuccessfulLocalFingerprint: saved.lastSuccessfulLocalFingerprint,
          createdAt: saved.createdAt,
          updatedAt: DateTime.now().toUtc(),
          state: saved.state,
          error: saved.error,
        );
        await metadataStorage.write(metadata!);
      }
      final remoteChanged =
          !sameContent &&
          (saved.revision == null ||
              saved.contentHash == null ||
              saved.contentHash!.isEmpty ||
              remote.contentHash.isEmpty ||
              remote.revision.value != saved.revision ||
              remote.contentHash != saved.contentHash);
      final kind = switch ((localChanged, remoteChanged)) {
        (false, false) => SyncClassification.noChanges,
        (true, false) => SyncClassification.localOnly,
        (false, true) => SyncClassification.remoteOnly,
        (true, true) => SyncClassification.divergent,
      };
      return SyncClassificationResult(kind, remote: remote);
    } on Object catch (error) {
      return SyncClassificationResult(
        SyncClassification.unknownError,
        error: error,
      );
    }
  }

  /// Applies an explicit conflict choice. [backup] must create a recoverable
  /// local snapshot before either replacement; it is awaited before transfer.
  Future<SyncDownloadResult?> resolveConflict(
    SyncConflictChoice choice, {
    required String currentLocalFingerprint,
    String? expectedLocalFingerprint,
    required SyncRemoteMetadata observedRemote,
    Uint8List? payload,
    String? payloadFingerprint,
    Future<void> Function()? backup,
  }) async {
    if (choice == SyncConflictChoice.cancel) return null;
    final p = provider, s = session, t = target, saved = metadata;
    if (p == null || s == null || t == null || saved == null) {
      throw StateError('Connect a provider before resolving sync conflict.');
    }
    // The local side must still be the side the user saw when choosing.
    if (expectedLocalFingerprint != null &&
        currentLocalFingerprint != expectedLocalFingerprint) {
      throw StateError('The local catalog changed; review the conflict again.');
    }
    final latest = await p.metadata(s, t);
    if (latest == null ||
        latest.revision != observedRemote.revision ||
        latest.contentHash != observedRemote.contentHash) {
      throw SyncConflictException(latest ?? observedRemote);
    }
    if (backup != null) await backup();
    if (choice == SyncConflictChoice.downloadReplaceLocal) {
      return download(expectedRemote: observedRemote);
    }
    if (payload == null || payloadFingerprint == null) {
      throw ArgumentError(
        'Upload replacement requires payload and fingerprint.',
      );
    }
    await sync(
      payload,
      localFingerprint: payloadFingerprint,
      expectedRemote: observedRemote,
    );
    return null;
  }

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
      includePersonalImages: current.includePersonalImages,
      retainedRevisionCount: current.retainedRevisionCount,
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
    SyncRemoteMetadata? expectedRemote,
    SyncProgressCallback? onProgress,
  }) => _exclusive(
    () => _syncInternal(
      payload,
      localFingerprint: localFingerprint,
      expectedRemote: expectedRemote,
      onProgress: onProgress,
    ),
  );

  Future<SyncMetadata> _syncInternal(
    Uint8List payload, {
    String? localFingerprint,
    SyncRemoteMetadata? expectedRemote,
    SyncProgressCallback? onProgress,
  }) async {
    final p = provider, s = session, t = target, current = metadata;
    if (p == null || s == null || t == null || current == null) {
      throw StateError('Connect Google Drive before syncing.');
    }
    SyncDebug.trace('coordinator.sync.start', {
      'hasFingerprint': localFingerprint != null,
      'hasRevision': current.revision != null,
    });
    progress = const SyncProgress(
      completed: 0,
      total: 1,
      phase: 'Preparing bundle',
    );
    onProgress?.call(progress!);
    if (localFingerprint != null &&
        current.state == SyncState.ready &&
        current.provider == p.provider &&
        current.accountId == s.accountId &&
        current.remoteTargetId == t.id &&
        current.lastSuccessfulLocalFingerprint == localFingerprint &&
        current.revision != null &&
        current.contentHash != null &&
        current.contentHash!.isNotEmpty) {
      try {
        final remote = await p.metadata(s, t);
        if (remote != null &&
            remote.contentHash.isNotEmpty &&
            remote.contentHash == current.contentHash) {
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
      activeCancellation?.throwIfCancelled();
      progress = const SyncProgress(
        completed: 0,
        total: 1,
        phase: 'Uploading bundle',
      );
      onProgress?.call(progress!);
      result = await p.upload(
        s,
        t,
        payload,
        precondition: expectedRemote != null
            ? SyncPrecondition(
                revision: expectedRemote.revision,
                contentHash: expectedRemote.contentHash,
              )
            : current.revision == null
            ? null
            : SyncPrecondition(
                revision: SyncRevision(current.revision!),
                contentHash: current.contentHash,
              ),
      );
      progress = const SyncProgress(completed: 1, total: 1, phase: 'Complete');
      onProgress?.call(progress!);
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
        lastSuccessfulLocalFingerprint: current.lastSuccessfulLocalFingerprint,
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
      includePersonalImages: current.includePersonalImages,
      retainedRevisionCount: current.retainedRevisionCount,
    );
    await metadataStorage.write(metadata!);
    if (p case final SyncRetentionProvider retention) {
      try {
        await retention.retainRevisions(
          s,
          t,
          keep: current.retainedRevisionCount,
        );
      } catch (_) {
        // Retention is best effort and must not turn a successful upload into
        // a failed sync on providers without revision deletion support.
      }
    }
    lastOutcome = SyncOutcome.uploaded;
    SyncDebug.trace('coordinator.sync.uploaded', {
      'revision': result.metadata.revision.value,
    });
    return metadata!;
  }

  Future<SyncDownloadResult> download({
    SyncRemoteMetadata? expectedRemote,
  }) async {
    final p = provider, s = session, t = target, current = metadata;
    if (p == null || s == null || t == null || current == null) {
      throw StateError('Connect Google Drive before restoring.');
    }
    try {
      final result = await p.download(
        s,
        t,
        precondition: expectedRemote != null
            ? SyncPrecondition(
                revision: expectedRemote.revision,
                contentHash: expectedRemote.contentHash,
              )
            : current.revision == null
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
        includePersonalImages: current.includePersonalImages,
        retainedRevisionCount: current.retainedRevisionCount,
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
        lastSuccessfulLocalFingerprint: current.lastSuccessfulLocalFingerprint,
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
      includePersonalImages: current.includePersonalImages,
      retainedRevisionCount: current.retainedRevisionCount,
    );
    await metadataStorage.write(metadata!);
  }

  /// Enables the foreground automatic-backup path and acquires the cloud
  /// fencing lease. Providers which do not implement leases fail closed.
  Future<SyncLease> enableAutomaticSync({
    required String deviceId,
    required String deviceName,
    Duration leaseDuration = const Duration(minutes: 10),
  }) async {
    final p = provider, s = session, t = target, current = metadata;
    if (p is! SyncLeaseProvider || s == null || t == null || current == null) {
      throw StateError('This provider does not support automatic sync leases.');
    }
    final leases = p as SyncLeaseProvider;
    final existing = await leases.readLease(s, t, current.catalogIdentity);
    if (existing != null &&
        existing.isValidAt(DateTime.now().toUtc()) &&
        existing.ownerDeviceId != deviceId) {
      throw SyncLeaseContendedException(existing);
    }
    final lease = await leases.acquireLease(
      s,
      t,
      current.catalogIdentity,
      deviceId: deviceId,
      deviceName: deviceName,
      duration: leaseDuration,
    );
    metadata = current.copyWith(
      automaticSyncEnabled: true,
      deviceId: deviceId,
      deviceName: deviceName,
      ownershipGeneration: lease.generation,
      leaseToken: lease.token,
      leaseExpiresAt: lease.expiresAt,
      lastLeaseRenewedAt: lease.lastRenewedAt,
      automaticSchedulerState: 'ready',
    );
    await metadataStorage.write(metadata!);
    return lease;
  }

  Future<SyncLease> takeOverAutomaticSync({
    required String deviceId,
    required String deviceName,
    required bool confirmed,
    Duration leaseDuration = const Duration(minutes: 10),
  }) async {
    if (!confirmed)
      throw StateError('Takeover requires explicit confirmation.');
    final p = provider, s = session, t = target, current = metadata;
    if (p is! SyncLeaseProvider || s == null || t == null || current == null) {
      throw StateError('This provider does not support automatic sync leases.');
    }
    final leases = p as SyncLeaseProvider;
    // The provider must re-read and conditionally fence the prior generation.
    final lease = await leases.acquireLease(
      s,
      t,
      current.catalogIdentity,
      deviceId: deviceId,
      deviceName: deviceName,
      duration: leaseDuration,
      takeover: true,
    );
    metadata = current.copyWith(
      automaticSyncEnabled: true,
      deviceId: deviceId,
      deviceName: deviceName,
      ownershipGeneration: lease.generation,
      leaseToken: lease.token,
      leaseExpiresAt: lease.expiresAt,
      lastLeaseRenewedAt: lease.lastRenewedAt,
      automaticSchedulerState: 'needs_remote_validation',
    );
    await metadataStorage.write(metadata!);
    return lease;
  }

  Future<void> disableAutomaticSync() async {
    final p = provider, s = session, t = target, current = metadata;
    if (p is SyncLeaseProvider &&
        s != null &&
        t != null &&
        current != null &&
        current.deviceId != null &&
        current.leaseToken != null) {
      try {
        await (p as SyncLeaseProvider).releaseLease(
          s,
          t,
          current.catalogIdentity,
          deviceId: current.deviceId!,
          token: current.leaseToken!,
        );
      } catch (_) {
        // Local disable must never be blocked by an offline provider.
      }
    }
    if (current != null) {
      metadata = current.copyWith(
        automaticSyncEnabled: false,
        automaticSchedulerState: 'disabled',
        clearLease: true,
      );
      await metadataStorage.write(metadata!);
    }
  }

  Future<SyncLease?> refreshAutomaticLease({
    Duration leaseDuration = const Duration(minutes: 10),
  }) async {
    final p = provider, s = session, t = target, current = metadata;
    if (p is! SyncLeaseProvider ||
        s == null ||
        t == null ||
        current == null ||
        !current.automaticSyncEnabled ||
        current.deviceId == null ||
        current.leaseToken == null)
      return null;
    final leases = p as SyncLeaseProvider;
    final remote = await leases.readLease(s, t, current.catalogIdentity);
    if (remote == null ||
        remote.ownerDeviceId != current.deviceId ||
        remote.token != current.leaseToken ||
        !remote.isValidAt(DateTime.now().toUtc())) {
      metadata = current.copyWith(
        automaticSyncEnabled: false,
        automaticSchedulerState: 'lease_lost',
        clearLease: true,
      );
      await metadataStorage.write(metadata!);
      return null;
    }
    final lease = await leases.renewLease(
      s,
      t,
      current.catalogIdentity,
      deviceId: current.deviceId!,
      token: current.leaseToken!,
      duration: leaseDuration,
    );
    metadata = current.copyWith(
      ownershipGeneration: lease.generation,
      leaseExpiresAt: lease.expiresAt,
      lastLeaseRenewedAt: lease.lastRenewedAt,
      automaticSchedulerState: 'ready',
    );
    await metadataStorage.write(metadata!);
    return lease;
  }

  /// Automatic uploads are fenced immediately before transfer.  Callers still
  /// provide the already-created, SQLite-consistent bundle snapshot.
  Future<SyncMetadata> automaticUpload(
    Uint8List payload, {
    String? localFingerprint,
    SyncProgressCallback? onProgress,
  }) => _exclusive(() async {
    final current = metadata;
    if (current == null || !current.automaticSyncEnabled) {
      throw const SyncLeaseLostException();
    }
    if (current.automaticSchedulerState == 'needs_remote_validation') {
      if (localFingerprint == null)
        throw SyncConflictException(
          SyncRemoteMetadata(revision: SyncRevision(''), contentHash: ''),
        );
      final check = await classify(localFingerprint);
      if (check.classification == SyncClassification.divergent ||
          check.classification == SyncClassification.unknownError) {
        metadata = current.copyWith(automaticSchedulerState: 'conflict');
        await metadataStorage.write(metadata!);
        throw SyncConflictException(
          check.remote ??
              const SyncRemoteMetadata(
                revision: SyncRevision(''),
                contentHash: '',
              ),
        );
      }
      metadata = current.copyWith(automaticSchedulerState: 'ready');
      await metadataStorage.write(metadata!);
    }
    final lease = await refreshAutomaticLease();
    if (lease == null) throw const SyncLeaseLostException();
    metadata = metadata!.copyWith(
      lastAutomaticAttemptAt: DateTime.now().toUtc(),
      automaticSchedulerState: 'syncing',
    );
    await metadataStorage.write(metadata!);
    try {
      final result = await _syncInternal(
        payload,
        localFingerprint: localFingerprint,
        onProgress: onProgress,
      );
      metadata = metadata!.copyWith(
        lastAutomaticSuccessAt: DateTime.now().toUtc(),
        automaticSchedulerState: 'ready',
      );
      await metadataStorage.write(metadata!);
      return result;
    } on Object {
      metadata = metadata!.copyWith(automaticSchedulerState: 'error');
      await metadataStorage.write(metadata!);
      rethrow;
    }
  });

  Future<void> disconnect() async {
    final identity = metadata?.catalogIdentity;
    provider = null;
    session = null;
    target = null;
    metadata = null;
    if (identity != null) await metadataStorage.remove(identity);
  }

  /// Clears the live connection when changing catalogs without deleting the
  /// previous catalog's persisted sync setup or provider credentials.
  void resetRuntime() {
    provider = null;
    session = null;
    target = null;
    metadata = null;
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
