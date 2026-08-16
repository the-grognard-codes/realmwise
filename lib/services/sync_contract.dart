import 'dart:typed_data';

/// Comparison of the last known good local/remote pair with the current pair.
enum SyncClassification { noChanges, localOnly, remoteOnly, divergent, unknownError }

/// Explicit conflict choices.  A replacement is never implicit.
enum SyncConflictChoice { downloadReplaceLocal, uploadReplaceRemote, cancel }

class SyncClassificationResult {
  const SyncClassificationResult(this.classification, {this.remote, this.error});
  final SyncClassification classification;
  final SyncRemoteMetadata? remote;
  final Object? error;
}

class SyncDecisionRequired implements Exception {
  const SyncDecisionRequired(this.result, {this.localFingerprint});
  final SyncClassificationResult result;
  final String? localFingerprint;
  @override String toString() => 'Sync decision required: ${result.classification.name}';
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
