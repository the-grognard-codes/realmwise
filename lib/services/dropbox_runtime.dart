import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dropbox_sync.dart';
import 'secure_storage_service.dart';
import 'google_drive_runtime.dart';

class UrlLauncherDropboxBrowser implements DropboxOAuthBrowser {
  @override
  Future<void> open(Uri uri) async {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication))
      throw DropboxAuthException('Unable to open browser');
  }
}

class DropboxLocalhostCallback
    implements DropboxOAuthCallback, DropboxOAuthCallbackCancellation {
  DropboxLocalhostCallback(this.redirectUri);
  final Uri redirectUri;
  HttpServer? _server;
  bool _cancelled = false;

  @override
  Future<Uri> waitForCallback() async {
    // Cancellation belongs to one authorization attempt. The provider can be
    // reused for a later connection attempt after a timeout or browser error.
    _cancelled = false;
    if (_cancelled) throw DropboxAuthException('OAuth callback cancelled');
    final s = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      redirectUri.port,
    );
    _server = s;
    // Cancellation can race with bind(). Close the listener before waiting.
    if (_cancelled) {
      await s.close(force: true);
      _server = null;
      throw DropboxAuthException('OAuth callback cancelled');
    }
    try {
      final q = await s.first;
      final u = q.uri;
      q.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write('<html><body>You may close this window.</body></html>');
      await q.response.close();
      return u;
    } finally {
      _server = null;
      await s.close(force: true);
    }
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    final s = _server;
    _server = null;
    if (s != null) await s.close(force: true);
  }
}

class AndroidDropboxCallback
    implements DropboxOAuthCallback, DropboxOAuthCallbackCancellation {
  AndroidDropboxCallback(this.redirectUri);
  final Uri redirectUri;
  static const _channel = MethodChannel('realmwise/dropbox_oauth');
  bool _cancelled = false;

  @override
  Future<Uri> waitForCallback() async {
    _cancelled = false;
    if (_cancelled) throw DropboxAuthException('OAuth callback cancelled');
    final raw = await _channel.invokeMethod<String>('wait_for_callback', {
      'redirect_uri': redirectUri.toString(),
    });
    if (_cancelled) throw DropboxAuthException('OAuth callback cancelled');
    final value = Uri.tryParse(raw ?? '');
    if (value == null) throw DropboxAuthException('Invalid OAuth callback');
    return value;
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
    try {
      await _channel.invokeMethod<void>('cancel_callback');
    } catch (_) {
      // Cancellation must not mask the original authentication failure.
    }
  }
}

DropboxProvider? createConfiguredDropboxProvider([
  AndroidOAuthConfiguration? androidConfiguration,
]) {
  final android = Platform.isAndroid && androidConfiguration != null;
  final effectiveId = android
      ? androidConfiguration.dropboxClientId
      : (kReleaseMode ? 'pujnhj60xv194u6' : 'qiiuadba0azgtr7');
  if (effectiveId.isEmpty) return null;
  final configured = android ? androidConfiguration.dropboxRedirectUri : '';
  final uri = Uri.tryParse(
    configured.isEmpty && Platform.isAndroid
        ? 'com.realmwise.rpg.tracker://oauth2redirect/dropbox'
        : (configured.isEmpty
              ? 'http://127.0.0.1:8766/oauth2callback'
              : configured),
  );
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  final store = DropboxTokenStore(SecureStorageService());
  return DropboxProvider(
    authenticator: DropboxOAuthAuthenticator(
      clientId: effectiveId,
      redirectUri: uri,
      browser: UrlLauncherDropboxBrowser(),
      callback: Platform.isAndroid
          ? AndroidDropboxCallback(uri)
          : DropboxLocalhostCallback(uri),
      tokenStore: store,
    ),
    tokenStore: store,
  );
}

String dropboxConfigurationState() {
  return 'configured';
}

void logDropboxConfiguration() {
  if (kDebugMode) debugPrint('Dropbox: ${dropboxConfigurationState()}');
}
