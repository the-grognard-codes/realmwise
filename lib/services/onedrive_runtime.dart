import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
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

class OneDriveLocalhostCallback implements OneDriveOAuthCallback {
  OneDriveLocalhostCallback(this.redirectUri);
  final Uri redirectUri;
  @override
  Future<Uri> waitForCallback() async {
    final s = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      redirectUri.port,
    );
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
      await s.close(force: true);
    }
  }
}

OneDriveProvider? createConfiguredOneDriveProvider() {
  const id = String.fromEnvironment('MICROSOFT_ONEDRIVE_CLIENT_ID');
  if (id.trim().isEmpty) return null;
  const tenant = String.fromEnvironment('MICROSOFT_ONEDRIVE_TENANT');
  const raw = String.fromEnvironment('MICROSOFT_ONEDRIVE_REDIRECT_URI');
  final uri = Uri.tryParse(
    raw.trim().isEmpty ? 'http://127.0.0.1:8765/oauth2callback' : raw,
  );
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
  final store = OneDriveTokenStore(SecureStorageService());
  return OneDriveProvider(
    authenticator: OneDriveOAuthAuthenticator(
      clientId: id.trim(),
      tenant: tenant.trim().isEmpty ? 'common' : tenant.trim(),
      redirectUri: uri,
      browser: UrlLauncherOneDriveBrowser(),
      callback: OneDriveLocalhostCallback(uri),
      tokenStore: store,
    ),
    tokenStore: store,
  );
}

String oneDriveConfigurationState() {
  const id = String.fromEnvironment('MICROSOFT_ONEDRIVE_CLIENT_ID');
  return id.trim().isEmpty
      ? 'missing MICROSOFT_ONEDRIVE_CLIENT_ID'
      : 'configured';
}

void logOneDriveConfiguration() {
  if (kDebugMode) debugPrint('OneDrive: ${oneDriveConfigurationState()}');
}
