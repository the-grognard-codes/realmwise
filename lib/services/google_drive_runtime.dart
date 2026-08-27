import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';

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

class AndroidGoogleDriveAuthorizationBridge
    implements AndroidGoogleDriveAuthorization {
  const AndroidGoogleDriveAuthorizationBridge();
  static const _channel = MethodChannel('realmwise/google_drive');

  @override
  Future<Map<String, Object?>> authorize({required String clientId}) async {
    final value = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'authorize',
      <String, Object?>{'client_id': clientId},
    );
    if (value == null) {
      throw GoogleDriveAuthException('Google authorization returned no result');
    }
    return value.map((key, value) => MapEntry('$key', value));
  }

  @override
  Future<void> cancelAuthorization() async {
    try {
      await _channel.invokeMethod<void>('cancel_authorize');
    } catch (_) {
      // Cancellation must not mask the connection operation's result.
    }
  }

  @override
  Future<void> clearToken(String token) async {
    await _channel.invokeMethod<void>('clear_token', <String, Object?>{
      'token': token,
    });
  }
}

class AndroidOAuthConfiguration {
  const AndroidOAuthConfiguration({
    required this.googleDriveEnabled,
    required this.googleDriveTokenNamespace,
    required this.microsoftOnedriveClientId,
    required this.microsoftOnedriveTenant,
    required this.microsoftOnedriveRedirectUri,
    required this.dropboxClientId,
    required this.dropboxRedirectUri,
  });

  final bool googleDriveEnabled;
  final String googleDriveTokenNamespace;
  final String microsoftOnedriveClientId;
  final String microsoftOnedriveTenant;
  final String microsoftOnedriveRedirectUri;
  final String dropboxClientId;
  final String dropboxRedirectUri;
}

/// Loads configuration selected by the Android Gradle build type.
Future<AndroidOAuthConfiguration?> loadAndroidOAuthConfiguration() async {
  if (!Platform.isAndroid) return null;
  try {
    final raw = await const MethodChannel(
      'realmwise/oauth_configuration',
    ).invokeMethod<Map<dynamic, dynamic>>('get_configuration');
    if (raw == null) return null;
    String value(String key) => '${raw[key] ?? ''}'.trim();
    return AndroidOAuthConfiguration(
      googleDriveEnabled: raw['google_drive_enabled'] == true,
      googleDriveTokenNamespace: value('google_drive_token_namespace'),
      microsoftOnedriveClientId: value('microsoft_onedrive_client_id'),
      microsoftOnedriveTenant: value('microsoft_onedrive_tenant'),
      microsoftOnedriveRedirectUri: value('microsoft_onedrive_redirect_uri'),
      dropboxClientId: value('dropbox_client_id'),
      dropboxRedirectUri: value('dropbox_redirect_uri'),
    );
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

GoogleDriveProvider? createConfiguredGoogleDriveProvider([
  AndroidOAuthConfiguration? androidConfiguration,
]) {
  final android = Platform.isAndroid && androidConfiguration != null;
  if (android && !androidConfiguration.googleDriveEnabled) return null;
  // Android native Google authorization identifies the app from its package
  // and signing certificate. This stable build-scoped value only namespaces
  // the secure token-store entry; it is not a credential.
  final effectiveClientId = android
      ? (androidConfiguration.googleDriveTokenNamespace.isEmpty
            ? 'android-google-drive'
            : androidConfiguration.googleDriveTokenNamespace)
      : (kReleaseMode
            ? '792779271616-6cqvr19p36fh397tulce2t17euaiejur.apps.googleusercontent.com'
            : '792779271616-rhlm36vsff8jirqroqsr1ue3lvf7t2ld.apps.googleusercontent.com');
  // Google currently requires the installed-app client secret for desktop
  // authorization-code exchanges even when PKCE is used. Installed-app
  // secrets are not confidential: they ship with the native client itself.
  const configuredSecret = kReleaseMode
      ? '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'
      : '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';
  const configuredRedirect = '';
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
      clientId: effectiveClientId,
      clientSecret: configuredSecret.trim().isEmpty
          ? null
          : configuredSecret.trim(),
      redirectUri: redirect,
      browser: UrlLauncherOAuthBrowser(),
      callback: LocalhostOAuthCallback(redirect),
      androidAuthorization: Platform.isAndroid
          ? const AndroidGoogleDriveAuthorizationBridge()
          : null,
      tokenStore: storage,
    ),
    tokenStore: storage,
  );
}

String googleDriveConfigurationState() {
  return 'configured';
}

void logGoogleDriveConfiguration() {
  if (kDebugMode)
    debugPrint('Google Drive: ${googleDriveConfigurationState()}');
}
