# Feature: Thin the three sync provider adapters behind a shared sync core

Issue: #103 · Part of #99

## Abstract

Move the protocol code that Google Drive, OneDrive and Dropbox each implement separately into one shared sync core:

- OAuth with PKCE, and token refresh
- the token store
- an HTTP client with timeouts, retry, and `Retry-After`
- the lease protocol
- download verification

Each provider adapter then carries only storage-specific behavior: where the bundle lives, how a conditional write is expressed, and which content hash the provider reports. One contract test suite runs against every adapter.

## Objective

- Fix bugs once instead of three times. Today a fix in one adapter survives as a bug in the other two. For example, the Dropbox lease release does nothing.
- Eliminate two of the sync symptoms collectors report:
  - "Auth drops and reconnects": refresh failures and `invalid_grant` can't be told apart from network errors.
  - "Silent no-sync": no request has a timeout, so a hung call holds the sync lock and every later sync fails with `SyncBusyException`.
- Delete roughly 450–550 duplicated lines.

## Context / Existing Behavior

- Adapter sizes:
  - `lib/services/google_drive_sync.dart`: about 1129 lines
  - `lib/services/onedrive_sync.dart`: about 1115 lines
  - `lib/services/dropbox_sync.dart`: about 651 lines
  - plus a `*_runtime.dart` for each, with platform glue and DEV/PROD client selection
- Each adapter has its own token store, PKCE and refresh, retry loop (OneDrive has two), lease logic, and download verification.
- None of the HTTP calls has a timeout.
- Google's upload and its content-hash write are two separate requests, so they are non-atomic (`google_drive_sync.dart:~910-972`). A failure between them leaves a remote bundle whose recorded hash doesn't match.
- Dropbox lease release is a no-op (`dropbox_sync.dart:~349`), so a handoff waits for the lease TTL.
- A failed Google lease lookup is treated as "no lease", which can let two devices both believe they own automatic sync.
- Token refresh failures (`invalid_grant`, revoked consent) surface as generic errors. The user isn't asked to reconnect.
- Google OAuth clients in Testing mode issue refresh tokens that expire after 7 days. This is an ops issue tracked in #99, but the reconnect UX must handle it.
- The interfaces in `lib/services/sync_contract.dart` (`SyncProvider`, `SyncAuthenticator`, `SyncTransfer`, `SyncLeaseProvider`, `SyncRetentionProvider`) are the existing port.

## In Scope

- A shared sync core under `lib/sync/` (or a similar location) containing:
  - OAuth/PKCE authorization and refresh, with both loopback and Android callback redirects
  - a token store over `TokenStorage`
  - an HTTP client with per-request timeouts, bounded retry with backoff, and `Retry-After` support
  - the lease protocol (acquire, renew, release, lookup), built on adapter primitives
  - download verification (size and content hash)
- A typed auth failure that tells "reconnect required" (`invalid_grant`, revoked, expired refresh token) apart from transient network failure.
- Rewriting the three adapters to supply only storage primitives, including:
  - read with revision
  - conditional write
  - delete
  - list revisions
  - the provider's hash algorithm (Drive `md5Checksum`/appProperties, OneDrive `quickXorHash`, Dropbox `content_hash`)
  - the provider's lease storage
- An atomic Google upload, where the bundle and its hash metadata go in one request.
- A real Dropbox lease release.
- Treating a lease lookup failure as an error, not as "no lease".
- One shared contract test suite run against fakes for all three adapters.

## Out of Scope

- The sync session interface, outcomes and conflict UX. That is [002](002-sync-session-module.md), which this builds on.
- Android background upload work (WorkManager or similar). It is a separate phase 3 decision.
- Resumable or chunked uploads for very large bundles. That is a separate phase 3 decision, unless the shared HTTP client makes it trivial.
- Bundle format v2.
- Adding or removing providers. All three stay.
- Ops changes: the Google consent screen, Play signing SHA-1s.
- Redesigning the Cloud Sync settings UI.

## Functional Requirements

- Every provider HTTP request goes through the shared client.
  - Each call gets a timeout. Defaults: connect 15 s and an overall 60 s for metadata calls, and a longer, progress-aware timeout for bundle transfer.
  - A timed-out request releases the sync lock and returns a typed network failure.
- The client retries only idempotent or precondition-guarded requests:
  - Retry on 429 and 5xx, and on connection errors.
  - Use bounded exponential backoff with jitter.
  - Honor `Retry-After` up to a cap.
- A refresh token rejection (`invalid_grant`, or the provider's equivalent) produces a reconnect-required failure. Then:
  - The stored tokens for that provider are cleared.
  - Sync metadata keeps the binding, so reconnecting resumes the same remote target.
  - The UI can show one reconnect prompt.
- Transient refresh failures never clear tokens.
- Lease behavior is the same for every provider:
  - acquire fails when another device holds an unexpired lease
  - renew extends it
  - release makes it immediately acquirable by another device
  - lookup errors propagate as errors
- Google upload writes the bundle and its content hash in one request, so the remote hash always matches the remote bytes.
- Download verification checks size and the provider's hash before a bundle is handed to the caller, for all three providers.
- Platform redirects keep working:
  - desktop (Windows, Linux) uses loopback
  - Android uses its platform callbacks
- DEV/PROD client selection in `*_runtime.dart` is unchanged.
- Tokens are stored only through `TokenStorage`. They never appear in SQLite, shared preferences, bundles, logs or diagnostic exports.

## Acceptance Criteria

- One contract suite (for example `test/sync_provider_contract_test.dart`) runs the same cases against Google Drive, OneDrive and Dropbox fakes. The cases cover:
  - auth refresh
  - reconnect-required on `invalid_grant`
  - timeout
  - retry with `Retry-After`
  - conditional-write conflict
  - lease acquire, renew, release and contention
  - lookup failure
  - download hash mismatch
- The Dropbox release test proves a second device can acquire immediately after release.
- A Google upload test proves that one request carries both the bundle and its hash, and that a failed upload leaves no hash/bytes mismatch.
- A test with a hanging fake transport proves the sync lock is released after the timeout.
- Combined provider adapter code shrinks by at least 400 lines, measured against `dd52f0d`, and the PR states the measurement.
- Existing provider tests (`google_drive_sync_test.dart`, `onedrive_sync_test.dart`, `dropbox_sync_test.dart`, `sync_lease_test.dart`) pass, or are replaced by contract cases that cover the same behavior. The PR maps each removed test to its replacement.
- `DiagnosticSanitizer` tests confirm that no token value appears in diagnostic output.
- CI `validate` passes.

## Constraints

- Ensure the change is supported on Android, Windows, and Linux.
- Realmwise colors, typography, style, and themes shall be preserved. Reuse the existing theme (`lib/theme/app_theme.dart`), shared widgets (`lib/widgets/`), and other UI/UX scaffolding where appropriate.
- Create a new branch for this work.
- Preserve unrelated working-tree changes.
- Follow existing repository conventions.
- Stage and commit the work on that branch, push it, and open a PR that references the originating issue (`Closes #103`). Do not merge the PR or enable auto-merge without the user's explicit consent; Claude reviews every PR first.
- The sync contract must hold for all three providers and keep the single-active-device lease model. No silent merges.
- Secrets go through `TokenStorage` only.
- A change to one platform's runtime path (`*_runtime.dart`) must be mirrored in the other.
- Network calls still happen only on user action or with sync enabled.
- Lands after [002](002-sync-session-module.md). It belongs to the sync revision phase of #99. Phase 3 grilling may refine this spec before it is marked `ready-for-agent`.

## Implementation Guidance

- Dependency category: ports & adapters, with three real adapters, so the seam is real. Keep the adapter interface narrow: storage primitives plus hash and lease storage. Policy (retry, timeout, lease rules) lives in the core.
- Build the shared HTTP client on `package:http`'s `Client` so existing fake clients in tests keep working. Inject the clock and the delay so retry and timeout tests run instantly.
- Migrate one adapter at a time behind the contract suite. Start with Dropbox, the smallest, then OneDrive, then Google Drive.
- Keep each provider's on-disk token key names, or migrate them on first read, so existing users stay signed in.
- Write an ADR for the core/adapter split and the auth failure taxonomy.

## Validation

- Create new or update existing regression tests as required.
- Before handing this back for visual review, check affected catalog-open, sync, restore, and recovery paths, and update assertions tied to the changed appearance or timing. State exactly which checks ran.
- For each provider and each platform available, run these by hand:
  - connect
  - sync
  - a two-device handoff (release, then acquire on the second device)
  - revoke the app's access in the provider's account settings, then sync, which shows one reconnect prompt
  - reconnect, which resumes the same remote target
  - airplane mode during a sync, which fails with a network message within the timeout, after which the next sync is not busy
- State exactly which provider/platform combinations ran.

## Completion Notes

- Unit, widget, and platform build tests should be performed after code changes are complete.
- Failures in these tests should prompt one or more debug session rounds until the code is clear, a roadblock is encountered, or user input is needed.
