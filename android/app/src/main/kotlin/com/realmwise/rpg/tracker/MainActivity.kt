package com.realmwise.rpg.tracker

import android.app.Activity
import android.content.Intent
import android.content.IntentSender
import android.net.Uri
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import android.util.Log
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.auth.api.identity.AuthorizationClient
import com.google.android.gms.auth.api.identity.ClearTokenRequest
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.CommonStatusCodes
import com.google.android.gms.common.api.Scope
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : FlutterActivity() {
    private lateinit var authorizationClient: AuthorizationClient
    private var pendingResult: MethodChannel.Result? = null
    private var googleAuthorizationGeneration = 0L
    // Resolution codes are never reused for this process. A canceled
    // operation can therefore be removed immediately; any late result has no
    // mapping and cannot be mistaken for a later authorization.
    private val googleResolutionOperations = mutableMapOf<Int, GoogleResolutionOperation>()
    private var nextGoogleResolutionRequestCode = GOOGLE_RESOLUTION_REQUEST_CODE_START
    private var googleAuthorizationCancelled = false
    private var dropboxResult: MethodChannel.Result? = null
    private var oneDriveResult: MethodChannel.Result? = null
    private var diagnosticResult: MethodChannel.Result? = null
    private val diagnosticScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val diagnosticIoInProgress = AtomicBoolean(false)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        authorizationClient = Identity.getAuthorizationClient(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "cancel_authorize") {
                    googleAuthorizationCancelled = true
                    val callback = pendingResult
                    pendingResult = null
                    googleAuthorizationGeneration++
                    if (callback != null) removeGoogleResolutions(callback)
                    callback?.error(
                        "authorization_cancelled",
                        "Google authorization was cancelled",
                        mapOf("phase" to "authorize", "errorClass" to "unknown"),
                    )
                    result.success(null)
                    return@setMethodCallHandler
                }
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
                googleAuthorizationCancelled = false
                val generation = ++googleAuthorizationGeneration
                val request = AuthorizationRequest.builder()
                    .setRequestedScopes(listOf(
                        Scope(DRIVE_APPDATA_SCOPE)
                    ))
                    .build()
                authorizationClient.authorize(request)
                    .addOnSuccessListener { authorizationResult ->
                        if (!isCurrentGoogleAuthorization(result, generation)) return@addOnSuccessListener
                        if (authorizationResult.hasResolution()) {
                            var resolutionRequestCode: Int? = null
                            try {
                                resolutionRequestCode = registerGoogleResolution(result, generation)
                                startIntentSenderForResult(
                                    authorizationResult.pendingIntent!!.intentSender,
                                    resolutionRequestCode!!, null, 0, 0, 0, null
                                )
                            } catch (error: Exception) {
                                resolutionRequestCode?.let { googleResolutionOperations.remove(it) }
                                if (!isCurrentGoogleAuthorization(result, generation)) return@addOnSuccessListener
                                pendingResult = null
                                Log.w(TAG, "Google authorization resolution failed: phase=launch_resolution status=unknown")
                                result.error("authorization_failed", authorizationErrorMessage(error), authorizationErrorDetails("launch_resolution", error))
                            }
                        } else {
                            if (!isCurrentGoogleAuthorization(result, generation)) return@addOnSuccessListener
                            pendingResult = null
                            Log.i(TAG, "Google authorization succeeded: phase=authorize status=0")
                            result.success(tokenMap(authorizationResult))
                        }
                    }
                    .addOnFailureListener { throwable ->
                        if (!isCurrentGoogleAuthorization(result, generation)) return@addOnFailureListener
                        pendingResult = null
                        Log.w(TAG, "Google authorization failed: ${authorizationLogSummary("authorize", throwable)}")
                        result.error("authorization_failed", authorizationErrorMessage(throwable), authorizationErrorDetails("authorize", throwable))
                    }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, OAUTH_CONFIG_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "get_configuration") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                result.success(mapOf(
                    "google_drive_enabled" to true,
                    "google_drive_token_namespace" to BuildConfig.GOOGLE_DRIVE_CLIENT_ID,
                    "microsoft_onedrive_client_id" to BuildConfig.MICROSOFT_ONEDRIVE_CLIENT_ID,
                    "microsoft_onedrive_tenant" to BuildConfig.MICROSOFT_ONEDRIVE_TENANT,
                    "microsoft_onedrive_redirect_uri" to BuildConfig.MICROSOFT_ONEDRIVE_REDIRECT_URI,
                    "dropbox_client_id" to BuildConfig.DROPBOX_CLIENT_ID,
                    "dropbox_redirect_uri" to DROPBOX_REDIRECT_URI,
                ))
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DIAGNOSTICS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "choose_destination" -> {
                        if (diagnosticResult != null) {
                            result.error("destination_in_progress", "A diagnostic export is already in progress", null)
                            return@setMethodCallHandler
                        }
                        diagnosticResult = result
                        val fileName = call.argument<String>("fileName") ?: "realmwise-diagnostics.zip"
                        val mimeType = call.argument<String>("mimeType") ?: "application/zip"
                        try {
                            startActivityForResult(
                                Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                    addCategory(Intent.CATEGORY_OPENABLE)
                                    type = mimeType
                                    putExtra(Intent.EXTRA_TITLE, fileName)
                                },
                                DIAGNOSTIC_CREATE_REQUEST_CODE,
                            )
                        } catch (error: Exception) {
                            diagnosticResult = null
                            result.error("destination_unavailable", error.message ?: "Could not open save dialog", null)
                        }
                    }
                    "copy_file_to_uri" -> {
                        val path = call.argument<String>("path")
                        val uriString = call.argument<String>("uri")
                        if (path.isNullOrBlank() || uriString.isNullOrBlank()) {
                            result.error("invalid_destination", "Diagnostic archive path and destination are required", null)
                            return@setMethodCallHandler
                        }
                        if (!diagnosticIoInProgress.compareAndSet(false, true)) {
                            result.error("copy_in_progress", "A diagnostic file operation is already in progress", null)
                            return@setMethodCallHandler
                        }
                        diagnosticScope.launch {
                            try {
                                val source = File(path)
                                if (!source.isFile) throw IllegalStateException("Diagnostic archive was not created")
                                val destination = Uri.parse(uriString)
                                val output = contentResolver.openOutputStream(destination, "w")
                                    ?: throw IllegalStateException("Could not open selected destination")
                                output.use { target -> source.inputStream().use { input -> input.copyTo(target) } }
                                withContext(Dispatchers.Main) { result.success(null) }
                            } catch (error: Exception) {
                                withContext(Dispatchers.Main) {
                                    result.error("copy_failed", error.message ?: "Could not save diagnostic archive", null)
                                }
                            } finally {
                                diagnosticIoInProgress.set(false)
                            }
                        }
                    }
                    "delete_uri" -> {
                        val uriString = call.argument<String>("uri")
                        if (uriString.isNullOrBlank()) {
                            result.error("invalid_destination", "Diagnostic destination is required", null)
                            return@setMethodCallHandler
                        }
                        if (!diagnosticIoInProgress.compareAndSet(false, true)) {
                            result.error("copy_in_progress", "A diagnostic file operation is already in progress", null)
                            return@setMethodCallHandler
                        }
                        diagnosticScope.launch {
                            try {
                                contentResolver.delete(Uri.parse(uriString), null, null)
                                withContext(Dispatchers.Main) { result.success(null) }
                            } catch (error: Exception) {
                                withContext(Dispatchers.Main) {
                                    result.error("delete_failed", error.message ?: "Could not remove diagnostic archive", null)
                                }
                            } finally {
                                diagnosticIoInProgress.set(false)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        deliverOAuthIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        deliverOAuthIntent(intent)
    }

    override fun onDestroy() {
        diagnosticScope.cancel()
        super.onDestroy()
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
            (uri.toString() == BuildConfig.MICROSOFT_ONEDRIVE_REDIRECT_URI ||
                uri.path == android.net.Uri.parse(BuildConfig.MICROSOFT_ONEDRIVE_REDIRECT_URI).path)) {
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
        if (requestCode == DIAGNOSTIC_CREATE_REQUEST_CODE) {
            val callback = diagnosticResult
            diagnosticResult = null
            if (callback != null) {
                if (resultCode == Activity.RESULT_OK && data?.data != null) {
                    callback.success(data.data.toString())
                } else {
                    callback.success(null)
                }
            }
            return
        }
        val operation = googleResolutionOperations.remove(requestCode) ?: return
        val callback = operation.callback
        if (!isCurrentGoogleAuthorization(callback, operation.generation)) return
        pendingResult = null
        if (data == null) {
            Log.w(TAG, "Google authorization cancelled: phase=activity_result status=0")
            callback.error("authorization_cancelled", "Google authorization was cancelled", mapOf("phase" to "activity_result"))
            return
        }
        try {
            callback.success(tokenMap(authorizationClient.getAuthorizationResultFromIntent(data)))
        } catch (error: Exception) {
            if (error is ApiException && error.statusCode == CommonStatusCodes.CANCELED) {
                Log.w(TAG, "Google authorization cancelled: ${authorizationLogSummary("get_authorization_result", error)}")
            callback.error("authorization_cancelled", "Google authorization was cancelled", authorizationErrorDetails("get_authorization_result", error))
        } else {
                Log.w(TAG, "Google authorization failed: ${authorizationLogSummary("get_authorization_result", error)}")
                callback.error("authorization_failed", authorizationErrorMessage(error), authorizationErrorDetails("get_authorization_result", error))
            }
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

    private fun authorizationErrorMessage(error: Throwable): String =
        if (error is ApiException) {
            "Google authorization failed (status code ${error.statusCode})"
        } else {
            "Google authorization failed"
        }

    // These details cross the MethodChannel and are persisted in diagnostics.
    // Keep them deliberately limited to non-identifying status metadata.
    private fun authorizationErrorDetails(phase: String, error: Throwable): Map<String, Any> =
        buildMap {
            put("phase", phase)
            put("errorClass", authorizationErrorClass(error))
            if (error is ApiException) put("status", error.statusCode)
        }

    private fun isCurrentGoogleAuthorization(
        callback: MethodChannel.Result,
        generation: Long,
    ): Boolean =
        !googleAuthorizationCancelled &&
            pendingResult === callback &&
            googleAuthorizationGeneration == generation

    private fun registerGoogleResolution(
        callback: MethodChannel.Result,
        generation: Long,
    ): Int {
        if (nextGoogleResolutionRequestCode > GOOGLE_RESOLUTION_REQUEST_CODE_END) {
            throw IllegalStateException("Google authorization resolution request codes exhausted")
        }
        val requestCode = nextGoogleResolutionRequestCode++
        googleResolutionOperations[requestCode] = GoogleResolutionOperation(callback, generation)
        return requestCode
    }

    private fun removeGoogleResolutions(callback: MethodChannel.Result) {
        googleResolutionOperations.entries.removeAll { it.value.callback === callback }
    }

    private data class GoogleResolutionOperation(
        val callback: MethodChannel.Result,
        val generation: Long,
    )

    private fun authorizationErrorClass(error: Throwable): String = when (error) {
        is ApiException -> "ApiException"
        is IntentSender.SendIntentException -> "SendIntentException"
        else -> "unknown"
    }

    private fun authorizationLogSummary(phase: String, error: Throwable): String =
        buildString {
            append("phase=")
            append(phase)
            append(" status=")
            append(if (error is ApiException) error.statusCode else "unknown")
            append(" class=")
            append(authorizationErrorClass(error))
        }

    companion object {
        private const val TAG = "RealmwiseGoogleAuth"
        private const val CHANNEL = "realmwise/google_drive"
        private const val DROPBOX_CHANNEL = "realmwise/dropbox_oauth"
        private const val ONEDRIVE_CHANNEL = "realmwise/onedrive_oauth"
        private const val DIAGNOSTICS_CHANNEL = "realmwise/diagnostics"
        private const val OAUTH_CONFIG_CHANNEL = "realmwise/oauth_configuration"
        private val ONEDRIVE_REDIRECT_URI = BuildConfig.MICROSOFT_ONEDRIVE_REDIRECT_URI
        private const val DROPBOX_REDIRECT_URI = "com.realmwise.rpg.tracker://oauth2redirect/dropbox"
        private const val DRIVE_APPDATA_SCOPE = "https://www.googleapis.com/auth/drive.appdata"
        // Dedicated monotonic range; deliberately disjoint from diagnostics.
        private const val GOOGLE_RESOLUTION_REQUEST_CODE_START = 4300
        private const val GOOGLE_RESOLUTION_REQUEST_CODE_END = 32767
        private const val DIAGNOSTIC_CREATE_REQUEST_CODE = 4210
    }
}
