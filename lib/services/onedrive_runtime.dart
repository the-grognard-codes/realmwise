import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'onedrive_sync.dart';
import 'secure_storage_service.dart';

class UrlLauncherOneDriveBrowser implements OneDriveOAuthBrowser {
  @override
  Future<void> open(Uri uri) async {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication))
      throw OneDriveAuthException('Unable to open browser');
  }
}

class OneDriveLocalhostCallback
    implements OneDriveOAuthCallback, OneDriveOAuthCallbackCancellation {
  OneDriveLocalhostCallback(this.redirectUri);
  final Uri redirectUri;
  HttpServer? _server;
  bool _cancelled = false;
  @override
  Future<Uri> waitForCallback() async {
    _cancelled = false;
    final s = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      redirectUri.port,
    );
    _server = s;
    try {
      if (_cancelled) throw OneDriveAuthException('OAuth callback cancelled');
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
    final server = _server;
    _server = null;
    if (server != null) await server.close(force: true);
  }
}

class AndroidOneDriveCallback
    implements OneDriveOAuthCallback, OneDriveOAuthCallbackCancellation {
  AndroidOneDriveCallback(this.redirectUri);
  final Uri redirectUri;
  static const _channel = MethodChannel('realmwise/onedrive_oauth');
  static const _registeredRedirect =
      'msauth://com.realmwise.rpg.tracker/hu33S0PdJMD%2FBlOPVgFheEvptH8%3D';
  bool _cancelled = false;

  @override
  Future<Uri> waitForCallback() async {
    if (redirectUri.toString() != _registeredRedirect) {
      throw OneDriveAuthException('Unsupported OneDrive redirect URI');
    }
    _cancelled = false;
    final raw = await _channel.invokeMethod<String>('wait_for_callback', {
      'redirect_uri': redirectUri.toString(),
    });
    if (_cancelled) throw OneDriveAuthException('OAuth callback cancelled');
    final value = Uri.tryParse(raw ?? '');
    if (value == null) throw OneDriveAuthException('Invalid OAuth callback');
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

const _androidOneDriveRedirect =
    'msauth://com.realmwise.rpg.tracker/hu33S0PdJMD%2FBlOPVgFheEvptH8%3D';

OneDriveProvider? createConfiguredOneDriveProvider() {
  const id = String.fromEnvironment('MICROSOFT_ONEDRIVE_CLIENT_ID');
  if (id.trim().isEmpty) return null;
  const tenant = String.fromEnvironment('MICROSOFT_ONEDRIVE_TENANT');
  const raw = String.fromEnvironment('MICROSOFT_ONEDRIVE_REDIRECT_URI');
  final configured = raw.trim();
  if (Platform.isAndroid && configured != _androidOneDriveRedirect) return null;
  final uri = Uri.tryParse(
    configured.isEmpty && !Platform.isAndroid
        ? 'http://127.0.0.1:8765/oauth2callback'
        : configured,
  );
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  final store = OneDriveTokenStore(SecureStorageService());
  return OneDriveProvider(
    authenticator: OneDriveOAuthAuthenticator(
      clientId: id.trim(),
      tenant: tenant.trim().isEmpty ? 'common' : tenant.trim(),
      redirectUri: uri,
      browser: UrlLauncherOneDriveBrowser(),
      callback: Platform.isAndroid
          ? AndroidOneDriveCallback(uri)
          : OneDriveLocalhostCallback(uri),
      tokenStore: store,
    ),
    tokenStore: store,
  );
}

String oneDriveConfigurationState() {
  const id = String.fromEnvironment('MICROSOFT_ONEDRIVE_CLIENT_ID');
  const redirect = String.fromEnvironment('MICROSOFT_ONEDRIVE_REDIRECT_URI');
  return id.trim().isEmpty
      ? 'missing MICROSOFT_ONEDRIVE_CLIENT_ID'
      : Platform.isAndroid && redirect.trim() != _androidOneDriveRedirect
          ? 'invalid MICROSOFT_ONEDRIVE_REDIRECT_URI'
      : 'configured';
}

void logOneDriveConfiguration() {
  if (kDebugMode) debugPrint('OneDrive: ${oneDriveConfigurationState()}');
}
