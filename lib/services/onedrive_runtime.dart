import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'onedrive_sync.dart';
import 'secure_storage_service.dart';
import 'google_drive_runtime.dart';

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
  bool _cancelled = false;

  @override
  Future<Uri> waitForCallback() async {
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

OneDriveProvider? createConfiguredOneDriveProvider([
  AndroidOAuthConfiguration? androidConfiguration,
]) {
  final android = Platform.isAndroid && androidConfiguration != null;
  final effectiveId = android
      ? androidConfiguration.microsoftOnedriveClientId
      : (kReleaseMode
            ? '1b24f572-c129-4e3c-9afa-d51781afe96c'
            : 'f689c4d7-5fc4-4a50-aee5-da175b97e113');
  if (effectiveId.isEmpty) return null;
  final configured = android
      ? androidConfiguration.microsoftOnedriveRedirectUri
      : '';
  final uri = Uri.tryParse(
    configured.isEmpty && !Platform.isAndroid
        ? 'http://127.0.0.1:8765/oauth2callback'
        : configured,
  );
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  final store = OneDriveTokenStore(SecureStorageService());
  return OneDriveProvider(
    authenticator: OneDriveOAuthAuthenticator(
      clientId: effectiveId,
      // Both Realmwise registrations accept personal Microsoft accounts only.
      // Keeping the desktop authority aligned with Android also ensures the
      // authorization and refresh requests target the same account system.
      tenant: android && androidConfiguration.microsoftOnedriveTenant.isNotEmpty
          ? androidConfiguration.microsoftOnedriveTenant
          : 'consumers',
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
  return 'configured';
}

void logOneDriveConfiguration() {
  if (kDebugMode) debugPrint('OneDrive: ${oneDriveConfigurationState()}');
}
