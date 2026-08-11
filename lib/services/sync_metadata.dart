import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'secure_storage_service.dart';

enum SyncState {
  notConnected,
  connectedUnconfigured,
  ready,
  syncing,
  needsDecision,
  error,
}

String syncCredentialKey({
  required String catalogIdentity,
  required String provider,
  required String accountId,
}) {
  String encode(String value) => base64UrlEncode(
    Uint8List.fromList(utf8.encode(value)),
  ).replaceAll('=', '');
  return 'cloud_sync_token:v1:${encode(provider)}:${encode(accountId)}:${encode(catalogIdentity)}';
}

/// Persist only a stable, non-sensitive error code; exception text is never stored.
String sanitizeSyncError(Object error) => 'sync_error';

class SyncMetadata {
  const SyncMetadata({
    required this.catalogIdentity,
    this.provider,
    this.accountId,
    this.accountDisplayName,
    this.remoteTargetId,
    this.remoteTargetName,
    this.revision,
    this.contentHash,
    this.createdAt,
    this.updatedAt,
    this.state = SyncState.notConnected,
    this.error,
  });

  final String catalogIdentity;
  final String? provider,
      accountId,
      accountDisplayName,
      remoteTargetId,
      remoteTargetName,
      revision,
      contentHash;
  final DateTime? createdAt, updatedAt;
  final SyncState state;
  final String? error;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'catalogIdentity': catalogIdentity,
    'provider': provider,
    'accountId': accountId,
    'accountDisplayName': accountDisplayName,
    'remoteTargetId': remoteTargetId,
    'remoteTargetName': remoteTargetName,
    'revision': revision,
    'contentHash': contentHash,
    'createdAt': createdAt?.toIso8601String(),
    'updatedAt': updatedAt?.toIso8601String(),
    'state': state.name,
    'error': error == null ? null : sanitizeSyncError(error!),
  };

  factory SyncMetadata.fromJson(Map<String, Object?> json) => SyncMetadata(
    catalogIdentity: json['catalogIdentity'] as String? ?? '',
    provider: json['provider'] as String?,
    accountId: json['accountId'] as String?,
    accountDisplayName: json['accountDisplayName'] as String?,
    remoteTargetId: json['remoteTargetId'] as String?,
    remoteTargetName: json['remoteTargetName'] as String?,
    revision: json['revision'] as String?,
    contentHash: json['contentHash'] as String?,
    createdAt: _date(json['createdAt']),
    updatedAt: _date(json['updatedAt']),
    state: SyncState.values.firstWhere(
      (s) => s.name == json['state'],
      orElse: () => SyncState.notConnected,
    ),
    error: json['error'] == null ? null : sanitizeSyncError(json['error']!),
  );

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
  String encode() => jsonEncode(toJson());
  factory SyncMetadata.decode(String value, {String? fallbackCatalogIdentity}) {
    SyncMetadata fallback() =>
        SyncMetadata(catalogIdentity: fallbackCatalogIdentity ?? '');
    try {
      final root = jsonDecode(value);
      if (root is! Map || root['schemaVersion'] != 1) {
        return fallback();
      }
      return SyncMetadata.fromJson(root.cast<String, Object?>());
    } on Object {
      return fallback();
    }
  }
}

abstract interface class SyncMetadataStorage {
  Future<SyncMetadata?> read(String catalogIdentity);
  Future<void> write(SyncMetadata metadata);
  Future<void> remove(String catalogIdentity);
}

class SharedPreferencesSyncMetadataStorage implements SyncMetadataStorage {
  SharedPreferencesSyncMetadataStorage(this.preferences);
  final SharedPreferences preferences;
  String _key(String identity) => 'cloud_sync_metadata:$identity';
  @override
  Future<SyncMetadata?> read(String identity) async {
    final value = preferences.getString(_key(identity));
    return value == null
        ? null
        : SyncMetadata.decode(value, fallbackCatalogIdentity: identity);
  }

  @override
  Future<void> write(SyncMetadata metadata) async =>
      preferences.setString(_key(metadata.catalogIdentity), metadata.encode());
  @override
  Future<void> remove(String identity) async =>
      preferences.remove(_key(identity));
}

class SyncStateMachine {
  SyncState _state;
  String? _error;
  SyncStateMachine([SyncState initial = SyncState.notConnected])
    : _state = initial;
  SyncState get state => _state;
  String? get error => _error;
  void connected({bool configured = false}) => _setConnected(configured);

  void _setConnected(bool configured) {
    if (_state != SyncState.notConnected && _state != SyncState.error) {
      throw StateError('Already connected.');
    }
    _error = null;
    _state = configured ? SyncState.ready : SyncState.connectedUnconfigured;
  }

  void configure() {
    if (_state != SyncState.connectedUnconfigured) {
      throw StateError('Sync is not awaiting configuration.');
    }
    _error = null;
    _state = SyncState.ready;
  }

  void startSync() {
    if (_state != SyncState.ready) throw StateError('Sync is not ready.');
    _state = SyncState.syncing;
  }

  void finishSync() {
    if (_state != SyncState.syncing) throw StateError('Sync is not running.');
    _error = null;
    _state = SyncState.ready;
  }

  void needsDecision() {
    if (_state != SyncState.syncing && _state != SyncState.ready) {
      throw StateError('Sync decision is unavailable.');
    }
    _state = SyncState.needsDecision;
  }

  void fail(Object exception) {
    _error = sanitizeSyncError(exception);
    _state = SyncState.error;
  }

  void disconnect() {
    _error = null;
    _state = SyncState.notConnected;
  }
}

/// Marker used by providers to make it explicit that tokens are isolated.
abstract interface class SyncTokenStore implements TokenStorage {}
