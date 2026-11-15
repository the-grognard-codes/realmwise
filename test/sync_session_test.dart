import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:realmwise/data/database_service.dart';
import 'package:realmwise/services/catalog_bundle_service.dart';
import 'package:realmwise/services/catalog_recovery.dart';
import 'package:realmwise/services/dropbox_sync.dart';
import 'package:realmwise/services/sync_contract.dart';
import 'package:realmwise/services/sync_coordinator.dart';
import 'package:realmwise/services/sync_metadata.dart';
import 'package:realmwise/sync/sync_session.dart';

void main() {
  late Directory directory;
  late _Provider provider;
  late SyncCoordinator coordinator;
  late _Recovery recovery;
  late SyncSession session;
  late String fingerprint;
  late List<String> events;
  late int exports, generation;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sync_session_test_');
    events = [];
    exports = 0;
    generation = 0;
    fingerprint = 'baseline';
    provider = _Provider(events);
    coordinator = SyncCoordinator(metadataStorage: _MetadataStorage());
    await coordinator.connect(provider, 'catalog');
    coordinator.metadata = coordinator.metadata!.copyWith(
      revision: _baseline.revision.value,
      contentHash: _baseline.contentHash,
      lastSuccessfulLocalFingerprint: fingerprint,
    );
    recovery = _Recovery(events);
    session = SyncSession(
      coordinator: () => coordinator,
      recovery: () => recovery,
      exportBundle: (path) async {
        exports++;
        await File(path).writeAsString(fingerprint);
      },
      localFingerprint: () async => fingerprint,
      catalogGeneration: () => generation,
      registeredProvider: (_) => provider,
      imageRootPath: () => null,
      bundles: _Bundles(),
      temporaryDirectory: () async => directory,
    );
  });

  tearDown(() => directory.delete(recursive: true));

  test('no changes returns already synced without a transfer', () async {
    expect(await session.sync(), isA<SyncAlreadyInSync>());
    expect(exports, 1);
    expect(provider.metadataReads, 1);
    expect(events, isEmpty);
  });

  test(
    'local-only changes upload using the observed remote revision',
    () async {
      fingerprint = 'local edit';
      expect(
        await session.sync(),
        isA<SyncUploaded>().having(
          (result) => result.providerName,
          'provider',
          'Test Cloud',
        ),
      );
      expect(provider.uploadCondition?.revision, _baseline.revision);
      expect(provider.uploadCondition?.contentHash, _baseline.contentHash);
      expect(provider.payload, 'local edit');
      expect(exports, 1);
      expect(events, ['upload']);
    },
  );

  test('first sync uploads to an empty provider placeholder', () async {
    coordinator.metadata = SyncMetadata(catalogIdentity: 'catalog');
    provider.remote = const SyncRemoteMetadata(
      revision: SyncRevision('empty'),
      contentHash: '',
      isEmpty: true,
    );
    expect(await session.sync(), isA<SyncUploaded>());
    expect(provider.uploadCondition?.revision, provider.remote!.revision);
    expect(events, ['upload']);
  });

  test(
    'remote-only changes offer download and snapshot before replacement',
    () async {
      provider.remote = _changed;
      final request = await session.sync() as RemoteNewerDecision;
      expect(request.classification, SyncClassification.remoteOnly);
      expect(request.remoteRevision, _changed.revision);
      expect(request.localFingerprint, fingerprint);
      expect(request.choices, {SyncChoice.download, SyncChoice.cancel});
      expect(
        await session.answer(request, SyncChoice.upload),
        isA<SyncFailed>(),
      );
      expect(
        await session.answer(request, SyncChoice.download),
        isA<SyncDownloaded>(),
      );
      expect(events, ['download', 'preDownload', 'replace']);
      expect(coordinator.metadata?.revision, _changed.revision.value);
      expect(
        coordinator.metadata?.lastSuccessfulLocalFingerprint,
        'remote catalog',
      );
      expect(exports, 1);
    },
  );

  test(
    'divergence preserves both snapshots before replacing the remote',
    () async {
      fingerprint = 'local edit';
      provider.remote = _changed;
      final request = await session.sync() as CatalogsDivergedDecision;
      expect(request.classification, SyncClassification.divergent);
      expect(request.choices, {
        SyncChoice.upload,
        SyncChoice.download,
        SyncChoice.cancel,
      });
      expect(
        await session.answer(request, SyncChoice.upload),
        isA<SyncUploaded>(),
      );
      expect(events, [
        'download',
        'preRemoteOverwrite',
        'preConflict',
        'upload',
      ]);
      expect(recovery.remoteSnapshot, 'remote catalog');
      expect(provider.payload, 'local edit');
      expect(exports, 1);
    },
  );

  test('divergence can also replace the local catalog', () async {
    fingerprint = 'local edit';
    provider.remote = _changed;
    final request = await session.sync() as CatalogsDivergedDecision;
    expect(
      await session.answer(request, SyncChoice.download),
      isA<SyncDownloaded>(),
    );
    expect(events, ['download', 'preDownload', 'replace']);
    expect(exports, 1);
  });

  test('download of an unchanged remote still requires confirmation', () async {
    final request = await session.download() as DownloadCatalogDecision;
    expect(events, isEmpty);
    expect(
      await session.answer(request, SyncChoice.download),
      isA<SyncDownloaded>(),
    );
    expect(events, ['download', 'preDownload', 'replace']);
  });

  test('download with unsynced local edits offers both choices', () async {
    fingerprint = 'local edit';
    final request = await session.download() as CatalogsDivergedDecision;
    expect(request.classification, SyncClassification.localOnly);
    expect(request.choices, {
      SyncChoice.download,
      SyncChoice.upload,
      SyncChoice.cancel,
    });
    expect(events, isEmpty);
  });

  test(
    'unknown status offers retry, then returns the current result',
    () async {
      provider.metadataError = DropboxAuthException('sensitive details');
      final request = await session.sync() as StatusUnknownDecision;
      expect(request.choices, {SyncChoice.retry, SyncChoice.cancel});
      expect(request.remoteRevision, isNull);
      expect(events, isEmpty);
      provider.metadataError = null;
      expect(
        await session.answer(request, SyncChoice.retry),
        isA<SyncAlreadyInSync>(),
      );
      expect(events, isEmpty);
    },
  );

  test('a local edit invalidates an outstanding remote-newer choice', () async {
    provider.remote = _changed;
    final original = await session.sync() as RemoteNewerDecision;
    fingerprint = 'local edit';
    final fresh = await session.answer(
      original,
      SyncChoice.download,
    ) as CatalogsDivergedDecision;
    expect(fresh.localFingerprint, 'local edit');
    expect(fresh.remoteRevision, original.remoteRevision);
    expect(events, isEmpty);
    expect(
      await session.answer(original, SyncChoice.download),
      isA<SyncFailed>(),
    );
  });

  test(
    'revision churn invalidates a choice even with the same remote hash',
    () async {
      provider.remote = _changed;
      final original = await session.sync() as RemoteNewerDecision;
      provider.remote = SyncRemoteMetadata(
        revision: const SyncRevision('newer'),
        contentHash: _changed.contentHash,
      );
      final fresh = await session.answer(
        original,
        SyncChoice.download,
      ) as RemoteNewerDecision;
      expect(fresh.remoteRevision, provider.remote!.revision);
      expect(events, isEmpty);
    },
  );

  test(
    'a fresh decision is required when the remote returns to baseline',
    () async {
      provider.remote = _changed;
      final original = await session.sync() as RemoteNewerDecision;
      provider.remote = _baseline;
      final fresh = await session.answer(
        original,
        SyncChoice.download,
      ) as SyncChangedDecision;
      expect(fresh.classification, SyncClassification.noChanges);
      expect(
        await session.answer(fresh, SyncChoice.retry),
        isA<SyncAlreadyInSync>(),
      );
      expect(events, isEmpty);
    },
  );

  test(
    'a local edit during download is checked before the catalog swap',
    () async {
      provider.remote = _changed;
      final request = await session.sync() as RemoteNewerDecision;
      provider.onDownload = () => fingerprint = 'local edit during download';
      expect(
        await session.answer(request, SyncChoice.download),
        isA<CatalogsDivergedDecision>(),
      );
      expect(events, ['download', 'preDownload']);
      expect(coordinator.metadata?.revision, _baseline.revision.value);
    },
  );

  test('a cloud precondition conflict refreshes the decision', () async {
    provider.remote = _changed;
    final request = await session.sync() as RemoteNewerDecision;
    provider.onDownload = () {
      provider.remote = const SyncRemoteMetadata(
        revision: SyncRevision('newer'),
        contentHash: 'newer hash',
      );
      throw SyncConflictException(provider.remote!);
    };
    final fresh = await session.answer(
      request,
      SyncChoice.download,
    ) as RemoteNewerDecision;
    expect(fresh.remoteRevision, provider.remote!.revision);
    expect(events, ['download']);
  });

  test('a newer cloud revision after transfer prevents a local swap', () async {
    provider.remote = _changed;
    final request = await session.sync() as RemoteNewerDecision;
    recovery.onSnapshot = () => provider.remote = const SyncRemoteMetadata(
      revision: SyncRevision('newer'),
      contentHash: 'newer hash',
    );
    final fresh = await session.answer(
      request,
      SyncChoice.download,
    ) as RemoteNewerDecision;
    expect(fresh.remoteRevision, provider.remote!.revision);
    expect(events, ['download', 'preDownload']);
    expect(coordinator.metadata?.revision, _baseline.revision.value);
  });

  test('a request cannot replace a reopened catalog', () async {
    provider.remote = _changed;
    final request = await session.sync() as RemoteNewerDecision;
    generation++;
    final result =
        await session.answer(request, SyncChoice.download) as SyncFailed;
    expect(result.category, SyncFailureCategory.conflictChanged);
    expect(events, isEmpty);
  });

  test('cancel dismisses a decision without touching either catalog', () async {
    provider.remote = _changed;
    final request = await session.sync() as RemoteNewerDecision;
    expect(
      await session.answer(request, SyncChoice.cancel),
      isA<SyncCancelled>(),
    );
    expect(
      await session.answer(request, SyncChoice.download),
      isA<SyncFailed>(),
    );
    expect(provider.metadataReads, 1);
    expect(events, isEmpty);
  });

  test('busy and in-flight cancellation return typed outcomes', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    provider.onMetadata = () async {
      entered.complete();
      await release.future;
    };
    final running = session.sync();
    await entered.future;
    expect(await session.download(), isA<SyncBusy>());
    session.cancel();
    release.complete();
    expect(await running, isA<SyncCancelled>());
    expect(events, isEmpty);
  });

  test('provider errors become safe categorized outcomes', () async {
    fingerprint = 'local edit';
    provider.onUpload = () => throw DropboxAuthException('secret token');
    final result = await session.sync() as SyncFailed;
    expect(result.category, SyncFailureCategory.auth);
    expect(result.message, isNot(contains('secret token')));
  });

  test('failed snapshots prevent the replacement', () async {
    fingerprint = 'local edit';
    provider.remote = _changed;
    recovery.failSnapshot = true;
    final request = await session.sync() as CatalogsDivergedDecision;
    final result =
        await session.answer(request, SyncChoice.upload) as SyncFailed;
    expect(result.category, SyncFailureCategory.storage);
    expect(events, ['download', 'preRemoteOverwrite']);
    expect(coordinator.metadata?.revision, _baseline.revision.value);
  });
}

const _baseline = SyncRemoteMetadata(
  revision: SyncRevision('baseline'),
  contentHash: 'baseline hash',
);
const _changed = SyncRemoteMetadata(
  revision: SyncRevision('changed'),
  contentHash: 'changed hash',
);

class _Provider implements NamedSyncProvider {
  _Provider(this.events);

  final List<String> events;
  SyncRemoteMetadata? remote = _baseline;
  SyncPrecondition? uploadCondition;
  String? payload;
  Object? metadataError;
  int metadataReads = 0;
  Future<void> Function()? onMetadata;
  void Function()? onDownload, onUpload;

  @override
  String get provider => 'test';

  @override
  String get displayName => 'Test Cloud';

  @override
  Future<SyncAuthSession> authenticate() async =>
      const SyncAuthSession(accountId: 'account');

  @override
  Future<List<SyncRemoteTarget>> listRemoteTargets(
    SyncAuthSession session,
  ) async => const [SyncRemoteTarget(id: 'target', name: 'Target')];

  @override
  Future<SyncRemoteMetadata?> metadata(
    SyncAuthSession session,
    SyncRemoteTarget target,
  ) async {
    metadataReads++;
    await onMetadata?.call();
    if (metadataError case final error?) throw error;
    return remote;
  }

  @override
  Future<SyncDownloadResult> download(
    SyncAuthSession session,
    SyncRemoteTarget target, {
    SyncPrecondition? precondition,
  }) async {
    events.add('download');
    expect(precondition?.revision, remote?.revision);
    expect(precondition?.contentHash, remote?.contentHash);
    onDownload?.call();
    return SyncDownloadResult(
      metadata: remote!,
      payload: Uint8List.fromList('remote catalog'.codeUnits),
    );
  }

  @override
  Future<SyncUploadResult> upload(
    SyncAuthSession session,
    SyncRemoteTarget target,
    Uint8List payload, {
    SyncPrecondition? precondition,
  }) async {
    events.add('upload');
    onUpload?.call();
    uploadCondition = precondition;
    this.payload = String.fromCharCodes(payload);
    return const SyncUploadResult(metadata: _changed);
  }
}

class _Recovery extends CatalogRecovery {
  _Recovery(this.events) : super(database: DatabaseService());

  final List<String> events;
  String? remoteSnapshot;
  bool failSnapshot = false;
  void Function()? onSnapshot;

  @override
  Future<RestorePoint> snapshot(
    SnapshotKind kind, {
    List<int>? bundleBytes,
  }) async {
    events.add(kind.name);
    onSnapshot?.call();
    if (failSnapshot) throw const FileSystemException('snapshot failure');
    if (bundleBytes != null) remoteSnapshot = String.fromCharCodes(bundleBytes);
    return RestorePoint(
      path: 'backup',
      kind: kind,
      format: RestorePointFormat.database,
      timestamp: DateTime.utc(2026),
    );
  }

  @override
  Future<CatalogReplacementResult> replaceCatalog(
    String sourcePath, {
    SnapshotKind snapshotKind = SnapshotKind.preImport,
    bool bundle = false,
    String? imageRootPath,
    Future<void> Function()? beforeReplacement,
  }) async {
    await snapshot(snapshotKind);
    await beforeReplacement?.call();
    events.add('replace');
    return const CatalogReplacementResult();
  }
}

class _Bundles extends CatalogBundleService {
  @override
  Future<BundleManifest> validateBundle(String bundlePath) async =>
      BundleManifest(
        formatVersion: 1,
        appVersion: '1.0.0',
        createdAt: '2026-01-01T00:00:00Z',
        catalogIdentity: 'catalog',
        databaseFilename: CatalogBundleService.databaseEntry,
        databaseSha256: 'hash',
        contentFingerprint: await File(bundlePath).readAsString(),
        assets: const [],
      );
}

class _MetadataStorage implements SyncMetadataStorage {
  final _values = <String, SyncMetadata>{};

  @override
  Future<SyncMetadata?> read(String catalogIdentity) async =>
      _values[catalogIdentity];

  @override
  Future<void> write(SyncMetadata metadata) async =>
      _values[metadata.catalogIdentity] = metadata;

  @override
  Future<void> remove(String catalogIdentity) async =>
      _values.remove(catalogIdentity);
}
