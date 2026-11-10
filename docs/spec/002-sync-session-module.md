# Feature: Deepen sync session orchestration into a sync session module

Issue: #102 · Part of #99

## Abstract

Pull the manual sync, download and conflict orchestration out of `AppController` (about 600 lines) and the settings screen into one sync session module. Callers run `sync()` or `download()` and get back a typed outcome or a decision request. They answer a decision request with a choice. The module owns bundle export, validation, fingerprinting, classification, the ownership checks, conflict resolution and rebinding. This follows the visit-scoped, typed-outcome shape of book intake ([ADR 0001](../adr/0001-book-intake-session.md)). `SyncProvider` stays the port to the three providers.

## Objective

- Remove a source of the unexpected conflict prompts collectors see: today, a remote-only change raises the same "Catalogs differ" dialog as a real divergence.
- Make the conflict flow a single, testable path instead of two hand-written copies in the settings screen that handle errors differently.
- Shrink `AppController`, the largest hot spot (34 commits since June), so sync changes stop touching unrelated catalog and preference code.
- Give phase 2 (UI) and phase 3 (sync revision) one stable interface to build sync status and error UX on.

## Context / Existing Behavior

- `AppController.syncNow` (`lib/services/app_controller.dart:810-855`) has a fixed sequence:
  1. Export a bundle to a temp file.
  2. Validate it.
  3. Classify it.
  4. If the result is `divergent`, `remoteOnly` or `unknownError`, throw `SyncDecisionRequired` (`lib/services/sync_contract.dart:64`).
  5. Otherwise upload.
- Callers must catch the thrown decision and pass it back to `resolveSyncDecision(choice, decision:, localFingerprint:)` (`:861-940`) with the right fingerprint. `resolveSyncDecision` then:
  1. Re-exports the bundle.
  2. Re-checks the fingerprint.
  3. Takes snapshots.
  4. Downloads or uploads.
- `downloadRemoteBundle` (`:944-1100`) runs a third export-validate-classify sequence, plus OneDrive read retries and a catalog swap.
- In total, export-validate-hash appears about 6 times and ownership checks about 3 times across `_syncNowInternal`, `resolveSyncDecision`, `downloadRemoteBundle`, `_automaticUploadInternal` (`:597`) and `_validateAutomaticRemote` (`:617`).
- `lib/screens/settings_screen.dart` writes the conflict dialog twice. It handles `unknownError` differently in each copy, once by throwing `StateError` and once with a snackbar, and shows raw errors (`'Could not complete sync: $error'`):
  - `_syncNow`, `:290-362`
  - `_downloadRemote`, `:743-844`
- The settings screen reads `syncCoordinator.lastOutcome` (`:356`) directly to choose its success message, and branches on provider IDs to build the label.
- `remoteOnly` (the remote changed and this device didn't) is reported as a conflict, even though the safe action is a plain download.

## In Scope

- A new sync session module (for example `lib/sync/sync_session.dart`) that replaces `syncNow`, `resolveSyncDecision` and `downloadRemoteBundle` as the sync interface for the UI.
- Typed outcomes, for example `SyncUploaded`, `SyncAlreadyInSync`, `SyncDownloaded`, `SyncCancelled` and `SyncFailed(reason)`.
- Typed decision requests, for example:
  - `RemoteNewerDecision`, which offers download or cancel
  - `CatalogsDivergedDecision`, which offers download-replace, upload-replace or cancel
  - `StatusUnknownDecision`, which offers retry or cancel
- One answer method that takes the user's choice for a pending decision request.
- One shared conflict dialog widget, used by every sync entry point in the settings screen.
- Moving the export-validate-fingerprint step behind the module, so it runs once per session.
- Using the catalog recovery module ([001](001-local-catalog-recovery.md)) for every snapshot and catalog swap.

## Out of Scope

- Thinning the provider adapters, shared OAuth, timeouts and retries. That is [003](003-thin-provider-adapters.md).
- The automatic-sync lease timer and `SyncMetadata` field preservation. That is #98.
- Redesigning the automatic-sync scheduler. The module may expose a hook for it, but the scheduler's behavior doesn't change here.
- Visual redesign of the Cloud Sync settings tab. That is phase 3, with impeccable.
- Changing the single-active-device lease model, or adding any merge.
- Changing the bundle format.

## Functional Requirements

- `sync()` exports and fingerprints the local catalog once, classifies it, and returns exactly one result:
  - `noChanges` returns already-in-sync.
  - `localOnly` uploads and returns uploaded.
  - `remoteOnly` returns a remote-newer decision request. It is not a divergence prompt.
  - `divergent` returns a catalogs-diverged decision request.
  - `unknownError` returns a status-unknown decision request, and neither catalog changes.
- A decision request carries everything needed to act on it: classification, observed remote revision, and local fingerprint. Callers never pass a fingerprint back.
- Answering a decision:
  1. Re-checks that the local catalog and the remote revision still match what the request observed. If either changed, it returns a fresh decision request instead of acting.
  2. Takes the snapshots the current code takes: a local snapshot before download-replace, and a copy of the remote bundle before upload-replace.
  3. Performs the transfer.
- Download-replace swaps the catalog through the catalog recovery module and rebinds sync metadata as today.
- Cancellation and `SyncBusyException` map to typed outcomes instead of thrown exceptions reaching widgets.
- A failure result carries a user-safe message and a category: network, auth, conflict-changed, storage or unknown. No raw `toString()` reaches the UI.
- The settings screen shows one conflict dialog widget for every decision request. Its labels and wording stay the same as today, except that the remote-newer request may use download-only wording. The success message comes from the outcome, not from `syncCoordinator.lastOutcome`, and the provider label comes from the provider, not from ID branching in the widget.
- Only one sync session operation runs at a time. Manual sync, download and conflict resolution go through the same lock as automatic sync, so they cannot overlap it.
- The module is testable with fake `SyncProvider`s and the recovery module's test doubles, with no widget or real HTTP.

## Acceptance Criteria

- `AppController` no longer contains `syncNow`'s export/classify logic, `resolveSyncDecision` or `downloadRemoteBundle`. It forwards to the sync session module or exposes it. The controller shrinks by roughly 400–600 lines.
- `SyncDecisionRequired` is no longer caught in any widget.
- `lib/screens/settings_screen.dart` contains one conflict dialog implementation, used from both sync and download entry points.
- A remote-only change produces a remote-newer request, not a "Catalogs differ" prompt. A test proves this.
- Tests in `test/sync_session_test.dart` cover:
  - each classification → outcome or decision mapping
  - answering each decision
  - the "changed since the request" re-check for both local and remote changes
  - busy and cancel outcomes
  - snapshot-before-replace for both directions
- Existing sync tests (`sync_rebind_test.dart`, `sync_lease_test.dart`, `sync_metadata_test.dart`, and the three provider tests) pass. `settings_screen_test.dart` is updated deliberately for the shared dialog.
- CI `validate` passes.

## Constraints

- Ensure the change is supported on Android, Windows, and Linux.
- Realmwise colors, typography, style, and themes shall be preserved. Reuse the existing theme (`lib/theme/app_theme.dart`), shared widgets (`lib/widgets/`), and other UI/UX scaffolding where appropriate.
- Create a new branch for this work.
- Preserve unrelated working-tree changes.
- Follow existing repository conventions.
- Do not commit or push unless explicitly requested.
- The sync contract must hold for all three providers (Google Drive, OneDrive, Dropbox) and keep the single-active-device lease model. No silent merges, and no replacement without an explicit user choice.
- OAuth tokens never appear in outcomes, messages, logs or diagnostic exports.
- Network calls still happen only on user action or with sync enabled.
- Lands after [001](001-local-catalog-recovery.md) and #98.

## Implementation Guidance

- Dependency category: ports & adapters. `SyncProvider` is the existing port with three real adapters. The new module sits in front of `SyncCoordinator`, and may absorb it.
- Model the result types on book intake (`lib/book_intake/book_intake_session.dart`): sealed classes, one per outcome or request, with exhaustive `switch` in the UI.
- Keep the OneDrive bundle-read retry (`app_controller.dart:~985`) inside the module, with its comment, until [003](003-thin-provider-adapters.md) moves it into the OneDrive adapter.
- `importDatabaseCsv` (`app_controller.dart:1403`) never triggers an automatic sync. If the module owns the "catalog changed" hook, wire CSV import through it, or record why not in the PR.
- Consider an ADR (`docs/adr/0002-sync-session.md`) recording the outcome/decision shape, so phase 3 builds on it.

## Validation

- Create new or update existing regression tests as required.
- Before handing this back for visual review, check affected catalog-open, sync, restore, and recovery paths, and update assertions tied to the changed appearance or timing. State exactly which checks ran.
- On each provider you can access, check these by hand:
  - Sync with no changes, which says already synced.
  - A local-only change, which uploads.
  - A remote-only change from a second device, which offers download only.
  - A true divergence, which offers both options.
  - Cancelling a decision, which leaves both catalogs unchanged.
- State which providers and platforms were checked.

## Completion Notes

- Unit, widget, and platform build tests should be performed after code changes are complete.
- Failures in these tests should prompt one or more debug session rounds until the code is clear, a roadblock is encountered, or user input is needed.
