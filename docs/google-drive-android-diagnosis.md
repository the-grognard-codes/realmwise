# Android Google Drive connection failure — September 6, 2026

The supplied diagnostic manifest reports app version `1.1.0+3`. Three Google
Drive connection attempts at 13:09 and 13:13 UTC fail with Android API status 8,
including the single automatic retry for each attempt. The screenshot identifies
the native phase as `get_authorization_result`. Authorization fails before the
Drive file lookup or sync begins. Earlier scope events are not evidence of this
Google failure; their provider fields are absent, and newer similar events identify
OneDrive.

Google defines status 8 as `INTERNAL_ERROR`, not a specific configuration diagnosis:
https://developers.google.com/android/reference/com/google/android/gms/common/api/CommonStatusCodes

The native implementation requests `drive.appdata`, launches Google's pending
intent, and parses its result with `getAuthorizationResultFromIntent`, consistent
with https://developer.android.com/identity/authorization. The supplied evidence
does not establish whether the cause is registration, consent/account policy, or
Google Play services. Reproduction on two physical devices makes an emulator-only
explanation inappropriate.

## Confirmed diagnostic fix

The sanitizer redacts strings of 16 or more token-like characters. This erased
`get_authorization_result` and `launch_resolution` from the exported operation
field. Map these fixed native phases to `parse_consent` and `launch_consent` before
logging. Unknown phases still map to `authorize`; raw exception messages remain
excluded. Regression tests exercise persisted log output for all mapped phases.
This improves evidence collection; it does not resolve Google's status 8.

## Next verification

On September 7, the tester confirmed that both the local debug APK and the local
release APK successfully connected to Google Drive on the tablet. The new Android
`1.1.0+3` bundle covers 18:31:50–18:35:18 UTC and contains 40 events:

- Three successful Google authorizations, each with `retryCount: 0`.
- Two completed Google upload cycles, with HTTP 200 for media and properties.
- Successful Drive listing and metadata requests, with one remote bundle listed.
- No warning or error events. OneDrive events retain their separate provider label.

All three manifest file sizes and SHA-256 hashes match the supplied files.
Provider, operation, outcome, and retry-count fields survive export. Because no
authorization failure occurred, this bundle does not exercise the corrected
`parse_consent` or `launch_consent` failure labels; those remain verified by the
persisted-log regression tests, not by this live run.

These results make the Play signing identity/OAuth registration the leading next
check, but do not prove a mismatch. The bundle does not record a signing fingerprint
or build mode, so identification as the local release comes from the tester.

The tester subsequently supplied these Play Console SHA-1 fingerprints:

- Current Play app signing: `86:ED:F7:4B:43:DD:24:C0:FF:06:53:8F:56:01:61:78:4B:E9:B4:7F`.
- Previous Play app signing: `75:96:9F:C9:3E:9E:F1:35:53:50:70:EF:D3:AD:52:87:62:FB:3C:E2`.
- Upload key: `AF:13:80:F5:23:1D:92:64:DE:AC:21:7F:44:5D:6B:98:10:6A:23:60`.

The upload certificate exactly matches the verified working local release APK.
The Play signing certificate is confirmed to differ. Whether the Play fingerprints
are missing from Google Cloud remains unverified. In the same production Cloud
project, check for Android OAuth clients pairing `com.realmwise.rpg.tracker` with
each Play SHA-1, adding missing clients and retaining the existing upload/debug
registrations. Retain coverage for the previous Play key for installations signed
with that key. No embedded client-ID change is needed for this native authorization
flow. After correcting any missing registration, retry the Play-installed app.

References:
https://developers.google.com/android/guides/client-auth
https://developers.google.com/workspace/guides/create-credentials
https://support.google.com/googleplay/android-developer/answer/9842756

1. Both failing installations were confirmed to come from Google Play. Check
   the Play App Signing certificate against the Android OAuth registration.
   The local
   `build/app/outputs/flutter-apk/app-release.apk` verifies successfully and has
   signing certificate SHA-1
   `AF:13:80:F5:23:1D:92:64:DE:AC:21:7F:44:5D:6B:98:10:6A:23:60`.
   This is not proof of the installed APK's identity. The Play-distributed build
   can have a different app-signing certificate. The requested debug APK uses
   the local debug identity, so its result does not independently validate the
   Play signing registration.
2. Compare the installed build's certificate and package
   `com.realmwise.rpg.tracker` with the Android OAuth client in Google Cloud.
   In that same project, check that Drive API is enabled and that the tester is
   allowed by the consent-screen audience/testing configuration.
3. Reproduce with the device connected through ADB and inspect Google Play
   services' authorization failure locally. The app intentionally omits raw
   provider messages from diagnostic exports. Record the relevant cause without
   sharing tokens, account details, or unrestricted logcat output.

No device was connected to the development machine during this investigation,
and Google Cloud configuration was not available for inspection. Local release
authorization and upload are now confirmed by the tester and bundle; the cause
of the Play-distributed build's failure remains unverified.
