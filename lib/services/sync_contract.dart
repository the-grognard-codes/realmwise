import 'dart:typed_data';

/// Comparison of the last known good local/remote pair with the current pair.
enum SyncClassification {
  noChanges,
  localOnly,
  remoteOnly,
  divergent,
  unknownError,
}

/// Explicit conflict choices.  A replacement is never implicit.
enum SyncConflictChoice { downloadReplaceLocal, uploadReplaceRemote, cancel }

/// Cancellation and progress are deliberately provider-neutral so the UI can
/// stop a manual transfer without ever mutating the active catalog halfway
/// through a bundle operation.
class SyncCancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
  void throwIfCancelled() {
    if (_cancelled) throw const SyncCancelledException();
  }
}

class SyncCancelledException implements Exception {
  const SyncCancelledException();
  @override
  String toString() => 'Sync was cancelled.';
}

class SyncBusyException implements Exception {
  const SyncBusyException();
  @override
  String toString() => 'A sync is already running for this catalog.';
}

typedef SyncProgressCallback = void Function(SyncProgress progress);

class SyncProgress {
  const SyncProgress({
    required this.completed,
    required this.total,
    this.phase = 'syncing',
  });
  final int completed;
  final int total;
  final String phase;
  double get fraction => total <= 0 ? 0 : (completed / total).clamp(0, 1);
}

class SyncClassificationResult {
  const SyncClassificationResult(
    this.classification, {
    this.remote,
    this.error,
  });
  final SyncClassification classification;
  final SyncRemoteMetadata? remote;
  final Object? error;
}

class SyncDecisionRequired implements Exception {
  const SyncDecisionRequired(this.result, {this.localFingerprint});
  final SyncClassificationResult result;
  final String? localFingerprint;
  @override
  String toString() => 'Sync decision required: ${result.classification.name}';
}

/// Provider-neutral authentication/session contract. Implementations must keep
/// credentials in [TokenStorage], never in these value objects.
abstract interface class SyncAuthenticator {
  Future<SyncAuthSession> authenticate();
}

abstract interface class SyncTargetSelector {
  Future<List<SyncRemoteTarget>> listRemoteTargets(SyncAuthSession session);
}

abstract interface class SyncMetadataLookup {
  Future<SyncRemoteMetadata?> metadata(
    SyncAuthSession session,
    SyncRemoteTarget target,
  );
}

abstract interface class SyncTransfer {
  Future<SyncUploadResult> upload(
    SyncAuthSession session,
    SyncRemoteTarget target,
    Uint8List payload, {
    SyncPrecondition? precondition,
  });
  Future<SyncDownloadResult> download(
    SyncAuthSession session,
    SyncRemoteTarget target, {
    SyncPrecondition? precondition,
  });
}

abstract interface class SyncProvider
    implements
        SyncAuthenticator,
        SyncTargetSelector,
        SyncMetadataLookup,
        SyncTransfer {
  String get provider;
}

/// A provider-side, advisory fencing lease.  Implementations store this as a
/// separate object from the catalog bundle and must use the provider's
/// conditional revision/ETag writes for every mutation.
abstract interface class SyncLeaseProvider {
  Future<SyncLease?> readLease(
    SyncAuthSession session,
    SyncRemoteTarget target,
    String catalogIdentity,
  );

  Future<SyncLease> acquireLease(
    SyncAuthSession session,
    SyncRemoteTarget target,
    String catalogIdentity, {
    required String deviceId,
    required String deviceName,
    required Duration duration,
    bool takeover = false,
  });

  Future<SyncLease> renewLease(
    SyncAuthSession session,
    SyncRemoteTarget target,
    String catalogIdentity, {
    required String deviceId,
    required String token,
    required Duration duration,
  });

  Future<void> releaseLease(
    SyncAuthSession session,
    SyncRemoteTarget target,
    String catalogIdentity, {
    required String deviceId,
    required String token,
  });
}

class SyncLease {
  const SyncLease({
    required this.catalogIdentity,
    required this.ownerDeviceId,
    required this.ownerDeviceName,
    required this.generation,
    required this.token,
    required this.issuedAt,
    required this.expiresAt,
    required this.lastRenewedAt,
    this.remoteRevision,
  });
  final String catalogIdentity, ownerDeviceId, ownerDeviceName, generation, token;
  final DateTime issuedAt, expiresAt, lastRenewedAt;
  final SyncRevision? remoteRevision;
  bool isValidAt(DateTime now) => expiresAt.isAfter(now);
}

class SyncLeaseContendedException implements Exception {
  const SyncLeaseContendedException(this.lease);
  final SyncLease lease;
  @override
  String toString() => 'Automatic sync is owned by another device.';
}

class SyncLeaseLostException implements Exception {
  const SyncLeaseLostException();
  @override
  String toString() => 'Automatic sync ownership was lost.';
}

/// Optional provider capability. Providers that cannot enumerate/delete old
/// revisions simply omit this interface; the current bundle is always kept.
abstract interface class SyncRetentionProvider {
  Future<void> retainRevisions(
    SyncAuthSession session,
    SyncRemoteTarget target, {
    int keep = 3,
  });
}

class SyncConflictException implements Exception {
  SyncConflictException(this.remote);
  final SyncRemoteMetadata remote;
}

class SyncAuthSession {
  const SyncAuthSession({required this.accountId, this.displayName});
  final String accountId;
  final String? displayName;
}

class SyncRemoteTarget {
  const SyncRemoteTarget({required this.id, required this.name});
  final String id;
  final String name;
}

class SyncRevision {
  const SyncRevision(this.value);
  final String value;
  @override
  String toString() => value;
  @override
  bool operator ==(Object other) =>
      other is SyncRevision && other.value == value;
  @override
  int get hashCode => value.hashCode;
}

class SyncPrecondition {
  const SyncPrecondition({this.revision, this.contentHash});
  final SyncRevision? revision;
  final String? contentHash;
}

class SyncRemoteMetadata {
  const SyncRemoteMetadata({
    required this.revision,
    required this.contentHash,
    this.updatedAt,
  });
  final SyncRevision revision;
  final String contentHash;
  final DateTime? updatedAt;
}

class SyncUploadResult {
  const SyncUploadResult({required this.metadata});
  final SyncRemoteMetadata metadata;
}

class SyncDownloadResult {
  const SyncDownloadResult({required this.payload, required this.metadata});
  final Uint8List payload;
  final SyncRemoteMetadata metadata;
}
