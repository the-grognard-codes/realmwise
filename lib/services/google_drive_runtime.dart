import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'google_drive_sync.dart';
import 'secure_storage_service.dart';

class UrlLauncherOAuthBrowser implements OAuthBrowser {
  @override
  Future<void> open(Uri uri) async {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw GoogleDriveAuthException('Unable to open browser');
    }
  }
}

class LocalhostOAuthCallback implements OAuthCallback {
  LocalhostOAuthCallback(this.redirectUri);
  final Uri redirectUri;
  HttpServer? _server;

  @override
  Future<Uri> waitForCallback() async {
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      redirectUri.port,
    );
    _server = server;
    try {
      final request = await server.first;
      final uri = request.uri;
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write('<html><body>You may close this window.</body></html>');
      await request.response.close();
      return uri;
    } finally {
      await server.close(force: true);
      _server = null;
    }
  }

  Future<void> close() async => _server?.close(force: true);
}

GoogleDriveProvider? createConfiguredGoogleDriveProvider() {
  const clientId = String.fromEnvironment('GOOGLE_DRIVE_CLIENT_ID');
  if (clientId.trim().isEmpty) return null;
  const configuredSecret = String.fromEnvironment('GOOGLE_DRIVE_CLIENT_SECRET');
  const configuredRedirect = String.fromEnvironment(
    'GOOGLE_DRIVE_REDIRECT_URI',
  );
  final redirect = Uri.tryParse(
    configuredRedirect.trim().isEmpty
        ? 'http://127.0.0.1:8765/oauth2callback'
        : configuredRedirect,
  );
  if (redirect == null || !redirect.hasScheme || redirect.host.isEmpty)
    return null;
  final storage = GoogleDriveTokenStore(SecureStorageService());
  return GoogleDriveProvider(
    authenticator: GoogleDriveOAuthAuthenticator(
      clientId: clientId.trim(),
      clientSecret: configuredSecret.trim().isEmpty
          ? null
          : configuredSecret.trim(),
      redirectUri: redirect,
      browser: UrlLauncherOAuthBrowser(),
      callback: LocalhostOAuthCallback(redirect),
      tokenStore: storage,
    ),
    tokenStore: storage,
  );
}

String googleDriveConfigurationState() {
  const clientId = String.fromEnvironment('GOOGLE_DRIVE_CLIENT_ID');
  const redirect = String.fromEnvironment('GOOGLE_DRIVE_REDIRECT_URI');
  if (clientId.trim().isEmpty) return 'missing GOOGLE_DRIVE_CLIENT_ID';
  if (redirect.trim().isNotEmpty && Uri.tryParse(redirect) == null) {
    return 'invalid GOOGLE_DRIVE_REDIRECT_URI';
  }
  return 'configured';
}

void logGoogleDriveConfiguration() {
  if (kDebugMode)
    debugPrint('Google Drive: ${googleDriveConfigurationState()}');
}
