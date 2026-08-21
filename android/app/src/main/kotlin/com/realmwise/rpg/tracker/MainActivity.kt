package com.realmwise.rpg.tracker

import android.app.Activity
import android.content.Intent
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.auth.api.identity.AuthorizationClient
import com.google.android.gms.auth.api.identity.ClearTokenRequest
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.Scope
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private lateinit var authorizationClient: AuthorizationClient
    private var pendingResult: MethodChannel.Result? = null
    private var dropboxResult: MethodChannel.Result? = null
    private var oneDriveResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        authorizationClient = Identity.getAuthorizationClient(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "clear_token") {
                    val token = call.argument<String>("token")
                    if (token.isNullOrEmpty()) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    authorizationClient.clearToken(
                        ClearTokenRequest.builder().setToken(token).build()
                    ).addOnSuccessListener { result.success(null) }
                        .addOnFailureListener {
                            result.error("clear_token_failed", safeMessage(it), null)
                        }
                    return@setMethodCallHandler
                }
                if (call.method != "authorize") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (pendingResult != null) {
                    result.error("authorization_in_progress", "Google authorization is already in progress", null)
                    return@setMethodCallHandler
                }
                pendingResult = result
                val request = AuthorizationRequest.builder()
                    .setRequestedScopes(listOf(
                        Scope(DRIVE_APPDATA_SCOPE),
                        Scope("openid"),
                        Scope("email")
                    ))
                    .build()
                authorizationClient.authorize(request)
                    .addOnSuccessListener { authorizationResult ->
                        if (authorizationResult.hasResolution()) {
                            try {
                                startIntentSenderForResult(
                                    authorizationResult.pendingIntent!!.intentSender,
                                    REQUEST_CODE, null, 0, 0, 0, null
                                )
                            } catch (error: Exception) {
                                pendingResult = null
                                result.error("authorization_failed", safeMessage(error), null)
                            }
                        } else {
                            pendingResult = null
                            result.success(tokenMap(authorizationResult))
                        }
                    }
                    .addOnFailureListener { throwable ->
                        pendingResult = null
                        result.error("authorization_failed", safeMessage(throwable), null)
                    }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DROPBOX_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "cancel_callback") {
                    val callback = dropboxResult
                    dropboxResult = null
                    callback?.error("authorization_cancelled", "Dropbox authorization was cancelled", null)
                    result.success(null)
                    return@setMethodCallHandler
                }
                if (call.method != "wait_for_callback") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val redirect = call.argument<String>("redirect_uri")
                if (redirect.isNullOrBlank()) {
                    result.error("invalid_redirect_uri", "Dropbox redirect URI is required", null)
                    return@setMethodCallHandler
                }
                val expected = android.net.Uri.parse(redirect)
                if (expected.scheme != "com.realmwise.rpg.tracker" ||
                    expected.host != "oauth2redirect" || expected.path != "/dropbox") {
                    result.error("invalid_redirect_uri", "Unsupported Dropbox redirect URI", null)
                    return@setMethodCallHandler
                }
                if (dropboxResult != null) {
                    result.error("callback_in_progress", "Dropbox authorization is already in progress", null)
                    return@setMethodCallHandler
                }
                // Never retain a callback received before Dart starts this
                // authorization attempt: its PKCE verifier/state no longer
                // exists and must not be consumed by a later attempt.
                dropboxResult = result
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ONEDRIVE_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "cancel_callback") {
                    val callback = oneDriveResult
                    oneDriveResult = null
                    callback?.error("authorization_cancelled", "OneDrive authorization was cancelled", null)
                    result.success(null)
                    return@setMethodCallHandler
                }
                if (call.method != "wait_for_callback") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val redirect = call.argument<String>("redirect_uri")
                if (redirect != ONEDRIVE_REDIRECT_URI) {
                    result.error("invalid_redirect_uri", "Unsupported OneDrive redirect URI", null)
                    return@setMethodCallHandler
                }
                if (oneDriveResult != null) {
                    result.error("callback_in_progress", "OneDrive authorization is already in progress", null)
                    return@setMethodCallHandler
                }
                oneDriveResult = result
            }
        deliverOAuthIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        deliverOAuthIntent(intent)
    }

    private fun deliverOAuthIntent(incoming: Intent?) {
        if (incoming?.action != Intent.ACTION_VIEW) return
        val uri = incoming.data ?: return
        val raw = uri.toString()
        // The Dart side performs state/code validation. Native only accepts the
        // exact registered callback shapes and never logs query values.
        if (uri.scheme == "com.realmwise.rpg.tracker" &&
            uri.host == "oauth2redirect" && uri.path == "/dropbox") {
            val callback = dropboxResult
            if (callback != null) {
                dropboxResult = null
                callback.success(raw)
            }
        } else if (uri.scheme == "msauth" && uri.host == "com.realmwise.rpg.tracker" &&
            (uri.path == "/hu33S0PdJMD/BlOPVgFheEvptH8=" ||
                uri.encodedPath == "/hu33S0PdJMD%2FBlOPVgFheEvptH8%3D")) {
            val callback = oneDriveResult
            if (callback != null) {
                oneDriveResult = null
                callback.success(raw)
            }
        }
    }

    @Deprecated("Activity result API required by Google AuthorizationClient")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_CODE) return
        val callback = pendingResult ?: return
        pendingResult = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            callback.error("authorization_cancelled", "Google authorization was cancelled", null)
            return
        }
        try {
            callback.success(tokenMap(authorizationClient.getAuthorizationResultFromIntent(data)))
        } catch (error: Exception) {
            callback.error("authorization_failed", safeMessage(error), null)
        }
    }

    private fun tokenMap(result: com.google.android.gms.auth.api.identity.AuthorizationResult): Map<String, Any?> {
        val account = result.toGoogleSignInAccount()
        // AuthorizationClient intentionally exposes no expiry field; GIS
        // access tokens are normally valid for one hour. Dart re-authorizes
        // interactively when this conservative timestamp is reached.
        // AuthorizationResult does not expose expiry; reacquire frequently.
        val expiresAt = System.currentTimeMillis() + 5 * 60_000L
        val email = account?.email
        val stableId = account?.id
        return mapOf(
            "access_token" to result.accessToken,
            "expires_at_epoch_ms" to expiresAt,
            "account_id" to (stableId ?: email ?: "google-drive"),
            "account_name" to email,
        )
    }

    private fun safeMessage(error: Throwable): String = error.message ?: "Google authorization failed"

    companion object {
        private const val CHANNEL = "realmwise/google_drive"
        private const val DROPBOX_CHANNEL = "realmwise/dropbox_oauth"
        private const val ONEDRIVE_CHANNEL = "realmwise/onedrive_oauth"
        private const val ONEDRIVE_REDIRECT_URI = "msauth://com.realmwise.rpg.tracker/hu33S0PdJMD%2FBlOPVgFheEvptH8%3D"
        private const val DRIVE_APPDATA_SCOPE = "https://www.googleapis.com/auth/drive.appdata"
        private const val REQUEST_CODE = 4207
    }
}
