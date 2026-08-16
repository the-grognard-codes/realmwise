Add normal structured download diagnostics with the planned logging feature.


Add default and debug level logging feature.
    Any logging built in by default?
    Toggle in the UI
    Add normal structured download diagnostics with the planned logging feature.
    
Find out about Android publication.
    Get a manifest of what is required packages, builds, etc.
    Are we relatively up-to-date?
    Is this code ready for publication?

Fix the file upload on Android for images

Add support for Google Books API, and maybe Library of Congress?
    Complete data enrichment.

P1 — Android releases use the debug signing key and a placeholder app ID. The authored configuration signs release with the debug keystore and uses com.example.rpg_catalog, undermining production provenance and store readiness. build.gradle.kts (line 17)

Additional release-hardening gaps:

Catalog databases, exports, and selected DB paths are unencrypted; document the privacy model and add safeguards appropriate to shared devices/backups.
The debug API is loopback-only and compile-time disabled by default, so it is not a confirmed production exposure; ensure production builds cannot enable it unintentionally. api_debug_harness.dart (line 24)
Owner name/email can be forwarded to OpenLibrary request headers; obtain consent or remove/redact it.
Add dependency/SBOM and vulnerability scanning to release CI.




Yes. I’d split it into narrow, independently testable features in this order:
Portable backup bundle
Package the SQLite database into a versioned archive/manifest. Validate it before restore, checkpoint SQLite first, and preserve the current local backup flow.
Test: create → package → validate → restore; reject corrupted or incompatible bundles.

Image classification and portability
Distinguish user-uploaded images/catalog icons from cacheable remote covers. Store portable relative asset identifiers rather than absolute device paths.
Test: migration of existing records; restored user images resolve correctly; remote covers are excluded and still render/re-download from URL.

Optional personal-image inclusion
Add a user setting to include uploaded images and icons in the backup bundle. Default to database-only.
Test: database-only bundle contains no assets; enabled bundle includes only qualifying assets; missing optional assets yield a clear result.

Sync domain model and local state
Define provider-agnostic interfaces plus persisted sync metadata: provider, remote folder/file ID, bundle revision/hash, last successful sync, and error state. Keep secrets in secure storage.
Test: state transitions, metadata serialization, and tokens never enter the database/bundle.

Manual local import/export UX
Expose “Export sync bundle” and “Import sync bundle” locally before cloud integration. This proves the bundle contract and recovery UI independently.
Test: UI/controller behavior for success, cancellation, invalid file, and restore confirmation.

Google Drive provider
Implement OAuth connection and explicit upload/download of a single versioned bundle in a Realmwise folder. Start with a manual “Sync now” action only.
Test: mocked auth, folder creation, upload/download, network failure, and remote version mismatch.

OneDrive provider
Implement the same provider contract using Microsoft OAuth and Microsoft Graph storage endpoints.
Test: run the provider contract test suite against mocked OneDrive responses, plus provider-specific authentication/permission failures.

Dropbox provider
Implement the same contract with Dropbox OAuth and file APIs.
Test: reuse the provider contract suite and cover Dropbox-specific conflict/error responses.

Conflict and overwrite policy
Add remote revision comparison. For the first release, stop on divergence and let the user choose download/replace remote/cancel—do not attempt SQLite record merging.
Test: local-only change, remote-only change, equal revision, divergent revisions, and interrupted uploads.

Sync settings and operational hardening

   Add provider management, sync status, disconnect/revoke-local-credentials, retry messaging, cancellation, and remote retention/version cleanup. Consider background sync only after manual sync is reliable.
   Test: disconnected state, account switch, retry/cancel, token removal, and quota/offline handling.
The key boundary is: build a reliable portable bundle before touching any cloud provider, then integrate each provider behind the same tested interface.
