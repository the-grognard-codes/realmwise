import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/catalog_bundle_service.dart';
import '../services/catalog_recovery.dart';
import '../services/dropbox_sync.dart';
import '../services/google_drive_sync.dart';
import '../services/onedrive_sync.dart';
import '../services/sync_contract.dart';
import '../services/sync_coordinator.dart';
import '../services/sync_debug.dart';

enum SyncChoice { download, upload, retry, cancel }

enum SyncFailureCategory { network, auth, conflictChanged, storage, unknown }

sealed class SyncResult {
  const SyncResult();
}

final class SyncUploaded extends SyncResult {
  const SyncUploaded(this.providerName);
  final String providerName;
}

final class SyncAlreadyInSync extends SyncResult {
  const SyncAlreadyInSync();
}

final class SyncDownloaded extends SyncResult {
  const SyncDownloaded({this.needsRecoveryReview = false});
  final bool needsRecoveryReview;
}

final class SyncCancelled extends SyncResult {
  const SyncCancelled();
}

final class SyncBusy extends SyncResult {
  const SyncBusy();
}

final class SyncFailed extends SyncResult {
  const SyncFailed(this.category, this.message);

  factory SyncFailed.fromError(Object error) {
    final status = switch (error) {
      GoogleDriveException(:final statusCode) ||
      OneDriveException(:final statusCode) ||
      DropboxException(:final statusCode) => statusCode,
      _ => null,
    };
    return switch (error) {
      SyncConflictException() => changed,
      SyncBusyException() => busy,
      SyncLeaseLostException() => const SyncFailed(
        SyncFailureCategory.conflictChanged,
        'Automatic sync ownership was lost.',
      ),
      SyncLeaseContendedException() => const SyncFailed(
        SyncFailureCategory.conflictChanged,
        'Automatic sync is owned by another device.',
      ),
      GoogleDriveAuthException() ||
      OneDriveAuthException() ||
      DropboxAuthException() => const SyncFailed(
        SyncFailureCategory.auth,
        'Cloud sign-in failed. Reconnect your provider and try again.',
      ),
      SocketException() ||
      TimeoutException() ||
      http.ClientException() => const SyncFailed(
        SyncFailureCategory.network,
        'Could not reach cloud storage. Check your connection and retry.',
      ),
      FileSystemException() || FormatException() => const SyncFailed(
        SyncFailureCategory.storage,
        'Could not read or save the catalog bundle.',
      ),
      _ when status == 401 || status == 403 => const SyncFailed(
        SyncFailureCategory.auth,
        'Cloud access failed. Check your provider connection and permissions.',
      ),
      _ when status == 408 || status == 429 || (status ?? 0) >= 500 =>
        const SyncFailed(
          SyncFailureCategory.network,
          'Cloud storage is temporarily unavailable. Try again.',
        ),
      _ => const SyncFailed(
        SyncFailureCategory.unknown,
        'Could not complete sync. Try again.',
      ),
    };
  }

  static const changed = SyncFailed(
    SyncFailureCategory.conflictChanged,
    'The catalog or cloud connection changed. Start sync again to review it.',
  );
  static const busy = SyncFailed(
    SyncFailureCategory.unknown,
    'A sync is already running for this catalog.',
  );
  static const recoveryReview = SyncFailed(
    SyncFailureCategory.storage,
    'Review and acknowledge the active catalog before syncing, or restore a protected snapshot.',
  );

  final SyncFailureCategory category;
  final String message;
}

sealed class SyncDecision extends SyncResult {
  const SyncDecision(
    this.classification,
    this.remoteRevision,
    this.localFingerprint,
  );
  final SyncClassification classification;
  final SyncRevision? remoteRevision;
  final String localFingerprint;
  Set<SyncChoice> get choices;
}

final class RemoteNewerDecision extends SyncDecision {
  const RemoteNewerDecision(SyncRevision revision, String fingerprint)
    : super(SyncClassification.remoteOnly, revision, fingerprint);

  @override
  Set<SyncChoice> get choices => const {SyncChoice.download, SyncChoice.cancel};
}

final class CatalogsDivergedDecision extends SyncDecision {
  const CatalogsDivergedDecision(
    super.classification,
    SyncRevision super.remoteRevision,
    super.localFingerprint,
  );

  @override
  Set<SyncChoice> get choices => const {
    SyncChoice.download,
    SyncChoice.upload,
    SyncChoice.cancel,
  };
}

final class DownloadCatalogDecision extends SyncDecision {
  const DownloadCatalogDecision(SyncRevision revision, String fingerprint)
    : super(SyncClassification.noChanges, revision, fingerprint);

  @override
  Set<SyncChoice> get choices => const {SyncChoice.download, SyncChoice.cancel};
}

final class StatusUnknownDecision extends SyncDecision {
  const StatusUnknownDecision(String fingerprint)
    : super(SyncClassification.unknownError, null, fingerprint);

  @override
  Set<SyncChoice> get choices => const {SyncChoice.retry, SyncChoice.cancel};
}

final class SyncChangedDecision extends SyncDecision {
  const SyncChangedDecision(
    super.classification,
    super.remoteRevision,
    super.localFingerprint,
  );

  @override
  Set<SyncChoice> get choices => const {SyncChoice.retry, SyncChoice.cancel};
}

enum _SyncAction { sync, download }

typedef _Observation = ({
  SyncRuntimeSnapshot runtime,
  int catalogGeneration,
  String fingerprint,
  SyncClassificationResult status,
});

typedef _PendingDecision = ({
  SyncDecision request,
  _SyncAction action,
  _Observation observed,
  Uint8List? uploadPayload,
});

/// Owns a manual sync from its first observation to a terminal outcome. The
/// shared operation runner is released while the user considers a decision.
class SyncSession {
  SyncSession({
    required this.coordinator,
    required this.recovery,
    required this.exportBundle,
    required this.localFingerprint,
    required this.catalogGeneration,
    required this.registeredProvider,
    required this.imageRootPath,
    required this.bundles,
    this.runOperation,
    this.onProgress,
    this.onReplacement,
    this.temporaryDirectory = getTemporaryDirectory,
  });

  final SyncCoordinator Function() coordinator;
  final CatalogRecovery Function() recovery;
  final Future<void> Function(String) exportBundle;
  final Future<String> Function() localFingerprint;
  final int Function() catalogGeneration;
  final SyncProvider? Function(String) registeredProvider;
  final String? Function() imageRootPath;
  final CatalogBundleService bundles;
  final Future<SyncResult> Function(Future<SyncResult> Function())?
  runOperation;
  final SyncProgressCallback? onProgress;
  final void Function()? onReplacement;
  final Future<Directory> Function() temporaryDirectory;

  SyncCancellationToken? _cancellation;
  _PendingDecision? _pending;

  void cancel() => _cancellation?.cancel();

  void invalidateDecision() => _pending = null;

  Future<SyncResult> sync() => _run((token) => _start(_SyncAction.sync, token));

  Future<SyncResult> download() =>
      _run((token) => _start(_SyncAction.download, token));

  Future<SyncResult> answer(SyncDecision request, SyncChoice choice) {
    final pending = _pending;
    if (pending == null || !identical(request, pending.request)) {
      return Future.value(SyncFailed.changed);
    }
    if (choice == SyncChoice.cancel) {
      _pending = null;
      return Future.value(const SyncCancelled());
    }
    if (!request.choices.contains(choice))
      return Future.value(SyncFailed.changed);
    return _run((token) async {
      if (!identical(_pending, pending)) return SyncFailed.changed;
      _pending = null;
      if (!_sameConnection(pending.observed)) return SyncFailed.changed;
      if (choice == SyncChoice.retry) return _start(pending.action, token);
      if (choice == SyncChoice.upload && recovery().warning != null) {
        return SyncFailed.recoveryReview;
      }

      final fingerprint = await localFingerprint();
      token.throwIfCancelled();
      final now = await _observe(pending.observed.runtime, fingerprint, token);
      if (_changed(pending.observed, now)) {
        return _refresh(pending.action, now, token);
      }
      try {
        if (choice == SyncChoice.download) {
          return await _download(pending.action, now, token);
        }
        return await _replaceRemote(
          pending.action,
          now,
          pending.uploadPayload!,
          token,
        );
      } on SyncConflictException {
        return _refresh(
          pending.action,
          await _observe(now.runtime, await localFingerprint(), token),
          token,
        );
      }
    });
  }

  Future<SyncResult> _run(
    Future<SyncResult> Function(SyncCancellationToken) operation,
  ) async {
    if (_cancellation != null) return const SyncBusy();
    final token = SyncCancellationToken();
    _cancellation = token;
    try {
      Future<SyncResult> run() {
        token.throwIfCancelled();
        return operation(token);
      }

      return await (runOperation?.call(run) ?? run());
    } on SyncBusyException {
      return const SyncBusy();
    } on SyncCancelledException {
      return const SyncCancelled();
    } catch (error) {
      return SyncFailed.fromError(error);
    } finally {
      _cancellation = null;
    }
  }

  Future<SyncResult> _start(
    _SyncAction action,
    SyncCancellationToken token,
  ) async {
    _pending = null;
    if (action == _SyncAction.sync && recovery().warning != null) {
      return SyncFailed.recoveryReview;
    }
    final runtime = coordinator().captureRuntime();
    if (runtime == null) {
      return const SyncFailed(
        SyncFailureCategory.auth,
        'Connect a cloud provider and choose a sync target first.',
      );
    }
    return _withLocalBundle((bundle, fingerprint) async {
      token.throwIfCancelled();
      final observed = await _observe(runtime, fingerprint, token);
      if (action == _SyncAction.sync) {
        switch (observed.status.classification) {
          case SyncClassification.noChanges:
            return const SyncAlreadyInSync();
          case SyncClassification.localOnly:
            try {
              return await _upload(observed, await bundle.readAsBytes(), token);
            } on SyncConflictException {
              return _refresh(
                action,
                await _observe(runtime, await localFingerprint(), token),
                token,
              );
            }
          case SyncClassification.remoteOnly:
          case SyncClassification.divergent:
          case SyncClassification.unknownError:
            break;
        }
      }
      return _decision(action, observed, bundle);
    });
  }

  Future<_Observation> _observe(
    SyncRuntimeSnapshot runtime,
    String fingerprint,
    SyncCancellationToken token,
  ) async {
    final generation = catalogGeneration();
    final status = await coordinator().classify(fingerprint);
    token.throwIfCancelled();
    return (
      runtime: runtime,
      catalogGeneration: generation,
      fingerprint: fingerprint,
      status: status,
    );
  }

  bool _sameConnection(_Observation observed) {
    final current = coordinator().captureRuntime();
    return current != null &&
        catalogGeneration() == observed.catalogGeneration &&
        identical(current.provider, observed.runtime.provider) &&
        identical(current.session, observed.runtime.session) &&
        current.target.id == observed.runtime.target.id &&
        current.metadata.catalogIdentity ==
            observed.runtime.metadata.catalogIdentity;
  }

  bool _changed(_Observation previous, _Observation current) =>
      current.fingerprint != previous.fingerprint ||
      current.status.classification != previous.status.classification ||
      current.status.remote?.revision != previous.status.remote?.revision ||
      current.status.remote?.contentHash != previous.status.remote?.contentHash;

  Future<SyncResult> _refresh(
    _SyncAction action,
    _Observation observed,
    SyncCancellationToken token,
  ) {
    final kind = observed.status.classification;
    if (kind == SyncClassification.divergent ||
        (action == _SyncAction.download &&
            kind == SyncClassification.localOnly)) {
      // A fresh replacement choice needs the bytes for its own observation.
      return _withLocalBundle((bundle, fingerprint) async {
        final current = await _observe(observed.runtime, fingerprint, token);
        return _decision(action, current, bundle);
      });
    }
    return _decision(action, observed, null);
  }

  Future<SyncResult> _decision(
    _SyncAction action,
    _Observation observed,
    File? bundle,
  ) async {
    final (:fingerprint, :status, runtime: _, catalogGeneration: _) = observed;
    final revision = status.remote?.revision;
    final kind = status.classification;
    final request = switch (kind) {
      SyncClassification.remoteOnly => RemoteNewerDecision(
        revision!,
        fingerprint,
      ),
      SyncClassification.divergent => CatalogsDivergedDecision(
        kind,
        revision!,
        fingerprint,
      ),
      SyncClassification.localOnly when action == _SyncAction.download =>
        CatalogsDivergedDecision(kind, revision!, fingerprint),
      SyncClassification.noChanges when action == _SyncAction.download =>
        DownloadCatalogDecision(revision!, fingerprint),
      SyncClassification.unknownError => StatusUnknownDecision(fingerprint),
      SyncClassification.localOnly || SyncClassification.noChanges =>
        SyncChangedDecision(kind, revision, fingerprint),
    };
    final uploadPayload = request.choices.contains(SyncChoice.upload)
        ? await bundle!.readAsBytes()
        : null;
    _pending = (
      request: request,
      action: action,
      observed: observed,
      uploadPayload: uploadPayload,
    );
    return request;
  }

  Future<SyncUploaded> _upload(
    _Observation observed,
    Uint8List payload,
    SyncCancellationToken token,
  ) async {
    token.throwIfCancelled();
    await coordinator().sync(
      payload,
      localFingerprint: observed.fingerprint,
      expectedRemote: observed.status.remote!,
      cancellation: token,
      onProgress: onProgress,
    );
    return SyncUploaded(observed.runtime.provider.displayName);
  }

  Future<SyncResult> _replaceRemote(
    _SyncAction action,
    _Observation observed,
    Uint8List payload,
    SyncCancellationToken token,
  ) async {
    final remote = await coordinator().download(
      expectedRemote: observed.status.remote!,
      recordResult: false,
    );
    token.throwIfCancelled();
    // Preserve the observed remote bundle and a local snapshot before overwrite.
    await recovery().snapshot(
      SnapshotKind.preRemoteOverwrite,
      bundleBytes: remote.payload,
    );
    await recovery().snapshot(SnapshotKind.preConflict);
    final current = await localFingerprint();
    token.throwIfCancelled();
    if (current != observed.fingerprint) {
      return _refresh(
        action,
        await _observe(observed.runtime, current, token),
        token,
      );
    }
    return _upload(observed, payload, token);
  }

  Future<SyncResult> _download(
    _SyncAction action,
    _Observation observed,
    SyncCancellationToken token,
  ) async {
    final temp = await _createScratch();
    try {
      final file = File(p.join(temp.path, 'remote.realmwise'));
      final (result, manifest) = await _readRemote(
        file,
        observed.status.remote!,
        token,
      );
      // The provider download is conditional. Confirm its revision again
      // before the local swap, after staging the downloaded bundle.
      final replacement = await recovery().replaceCatalog(
        file.path,
        bundle: true,
        snapshotKind: SnapshotKind.preDownload,
        imageRootPath: imageRootPath(),
        beforeReplacement: () async {
          token.throwIfCancelled();
          final latest = await _observe(
            observed.runtime,
            observed.fingerprint,
            token,
          );
          final current = await localFingerprint();
          token.throwIfCancelled();
          if (current != observed.fingerprint) {
            throw _SyncObservationChanged(
              await _observe(observed.runtime, current, token),
            );
          }
          if (_changed(observed, latest)) throw _SyncObservationChanged(latest);
        },
      );
      try {
        if (!replacement.needsAcknowledgement) {
          await _rebind(observed.runtime, manifest, result.metadata);
        }
      } finally {
        onReplacement?.call();
      }
      return SyncDownloaded(
        needsRecoveryReview: replacement.needsAcknowledgement,
      );
    } on _SyncObservationChanged catch (error) {
      return _refresh(action, error.observed, token);
    } finally {
      await temp.delete(recursive: true);
    }
  }

  Future<(SyncDownloadResult, BundleManifest)> _readRemote(
    File file,
    SyncRemoteMetadata expected,
    SyncCancellationToken token,
  ) async {
    // OneDrive can return an older, incomplete file immediately after the
    // manifest is created or replaced. Keep this finite so a permanently
    // malformed bundle still fails promptly, while allowing propagation to
    // settle over several seconds.
    const maxBundleReadRetries = 5;
    const initialBundleReadRetryDelay = Duration(milliseconds: 500);
    for (var attempt = 0; ; attempt++) {
      token.throwIfCancelled();
      final result = await coordinator().download(
        expectedRemote: expected,
        recordResult: false,
      );
      token.throwIfCancelled();
      try {
        await file.writeAsBytes(result.payload, flush: true);
        return (result, await bundles.validateBundle(file.path));
      } on FormatException {
        if (attempt == maxBundleReadRetries - 1) rethrow;
        await Future<void>.delayed(
          initialBundleReadRetryDelay * (1 << attempt),
        );
      }
    }
  }

  Future<void> _rebind(
    SyncRuntimeSnapshot runtime,
    BundleManifest manifest,
    SyncRemoteMetadata remote,
  ) async {
    final sync = coordinator();
    if (!identical(
      registeredProvider(runtime.provider.provider),
      runtime.provider,
    )) {
      SyncDebug.trace('restore.rebind.error', const {
        'status': 'provider_mismatch',
      });
      sync.resetRuntime();
      return;
    }
    try {
      final rebound = await sync.rebindAfterCatalogRestore(
        runtime,
        catalogIdentity: manifest.catalogIdentity,
        remote: remote,
        localFingerprint: manifest.contentFingerprint,
      );
      if (rebound == null) {
        SyncDebug.trace('restore.rebind.error', const {'status': 'rejected'});
        sync.resetRuntime();
      }
    } catch (_) {
      // Never fall back to credentials or metadata from the replacement catalog.
      SyncDebug.trace('restore.rebind.error', const {'status': 'failed'});
      sync.resetRuntime();
      rethrow;
    }
  }

  /// Automatic uploads already run inside the controller's operation queue.
  Future<void> automaticUpload(
    SyncCancellationToken token, {
    required void Function() beforeTransfer,
    required void Function(SyncCancellationToken?) onTransfer,
  }) => _withLocalBundle((file, fingerprint) async {
    final payload = await file.readAsBytes();
    token.throwIfCancelled();
    beforeTransfer();
    final upload = coordinator().automaticUpload(
      payload,
      localFingerprint: fingerprint,
    );
    onTransfer(coordinator().activeCancellation);
    await upload;
  });

  Future<SyncClassificationResult> validateAutomaticRemote() =>
      _withLocalBundle((_, fingerprint) => coordinator().classify(fingerprint));

  Future<T> _withLocalBundle<T>(Future<T> Function(File, String) action) async {
    final temp = await _createScratch();
    try {
      final file = File(p.join(temp.path, 'local.realmwise'));
      await exportBundle(file.path);
      final manifest = await bundles.validateBundle(file.path);
      final fingerprint = manifest.contentFingerprint;
      if (fingerprint == null)
        throw const FormatException('Missing local fingerprint.');
      return await action(file, fingerprint);
    } finally {
      await temp.delete(recursive: true);
    }
  }

  Future<Directory> _createScratch() async =>
      (await temporaryDirectory()).createTemp('realmwise-sync-');
}

class _SyncObservationChanged implements Exception {
  const _SyncObservationChanged(this.observed);

  final _Observation observed;
}
