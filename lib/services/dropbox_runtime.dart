import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dropbox_sync.dart';
import 'secure_storage_service.dart';

class UrlLauncherDropboxBrowser implements DropboxOAuthBrowser { @override Future<void> open(Uri uri) async { if(!await launchUrl(uri,mode:LaunchMode.externalApplication)) throw DropboxAuthException('Unable to open browser'); } }
class DropboxLocalhostCallback implements DropboxOAuthCallback { DropboxLocalhostCallback(this.redirectUri); final Uri redirectUri; @override Future<Uri> waitForCallback() async { final s=await HttpServer.bind(InternetAddress.loopbackIPv4,redirectUri.port); try { final q=await s.first; final u=q.uri; q.response..statusCode=200..headers.contentType=ContentType.html..write('<html><body>You may close this window.</body></html>'); await q.response.close(); return u; } finally { await s.close(force:true); } } }
DropboxProvider? createConfiguredDropboxProvider() { const id=String.fromEnvironment('DROPBOX_CLIENT_ID'); if(id.trim().isEmpty)return null; const raw=String.fromEnvironment('DROPBOX_REDIRECT_URI'); final uri=Uri.tryParse(raw.trim().isEmpty?'http://127.0.0.1:8766/oauth2callback':raw); if(uri==null||!uri.hasScheme||uri.host.isEmpty)return null; final store=DropboxTokenStore(SecureStorageService()); return DropboxProvider(authenticator:DropboxOAuthAuthenticator(clientId:id.trim(),redirectUri:uri,browser:UrlLauncherDropboxBrowser(),callback:DropboxLocalhostCallback(uri),tokenStore:store),tokenStore:store); }
String dropboxConfigurationState(){const id=String.fromEnvironment('DROPBOX_CLIENT_ID'); return id.trim().isEmpty?'missing DROPBOX_CLIENT_ID':'configured';}
void logDropboxConfiguration(){if(kDebugMode)debugPrint('Dropbox: ${dropboxConfigurationState()}');}
