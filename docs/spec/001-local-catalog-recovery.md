# Feature: Concentrate local catalog recovery in one module

Issue: #101 · Part of #99

## Abstract

Move every way of recovering or replacing the local catalog into one deep module. That module would own snapshots and their naming, retention, the list of restore points, and the quiesce → swap → rollback sequence for replacing the catalog database. The callers are the settings screen, the database gateway, manual bundle import and sync download. Each would ask the module to "snapshot", "list restore points" or "replace the catalog with this file" without knowing the folder layout or swap order.

## Objective

Protect collectors' data and make recovery testable:

- A pre-import or pre-download snapshot must not be trimmed away by routine 10-minute snapshots.
- Replacing the catalog must never race an in-flight sync.
- Retention and naming rules live in one place, so they cannot drift between four modules.
- This module is the foundation for the sync session module ([002](002-sync-session-module.md)): every sync download ends in a catalog swap.

## Context / Existing Behavior

Today one "recover my catalog" concept is spread over four modules and five code paths. They share an implicit `backups/` folder and naming scheme:

- `lib/services/backup_service.dart`:
  - Periodic snapshots every 10 minutes while a catalog is open (`start`, `:13`).
  - `createBackup` (`:62`) names snapshots `<db>_<stamp>.backup.db` (`:79`), then calls `_trimBackups`.
  - `_trimBackups` (`:135-146`) deletes every `*.backup.db` file except the newest 12, regardless of kind.
  - `scrubLegacyTokens` (`:87`) handles legacy tokens.
- `lib/services/app_controller.dart`:
  - `restoreDeviceBundle` (`:1171-1255`) stages the bundle's database, then writes a pre-import snapshot named `<db>_pre-import-<micros>.backup.db` (`:1180`). That name ends in `.backup.db`, so the next 12 routine snapshots trim it away. It then calls `_quiesceForBundleSwap`, and does the copy → rename → open → rollback sequence by hand.
  - `_quiesceForBundleSwap` (`:1261-1264`) only runs `backups.stop()` and `database.close()`. It doesn't wait for `_syncFuture` or `_automaticFuture`, even though `_cancelAndAwaitSync` (`:180`) exists for exactly that.
  - `restoreFromBackup` (`:1127-1133`) restores a snapshot through a different mechanism: it copies the snapshot to `restored_<millis>.db` in the documents folder and opens that file.
  - `resolveSyncDecision` (`:861-940`) writes a third snapshot kind, `_pre-remote-overwrite-<micros>.realmwise`, into the same folder, using its own temp-and-rename code.
  - `downloadRemoteBundle` (`:944-1100`) runs its own swap after an optional `backup` callback.
- `lib/services/catalog_service.dart` `listBackups` (`:130-145`) rebuilds the `backups/` path and the `.backup.db` filter on its own.
- `lib/screens/settings_screen.dart` (`:1599-1706`) calls `backups.createBackup(databaseHandle)` directly, reaching past the controller.

## In Scope

- A new catalog recovery module (for example `lib/services/catalog_recovery.dart`). It owns:
  - snapshot creation and naming, with a snapshot kind (routine, pre-import, pre-download, pre-remote-overwrite, manual)
  - retention per kind
  - listing restore points
  - the quiesce → swap → reopen → rollback sequence for replacing the active catalog database with a staged file
- Routing these callers through the module: `restoreDeviceBundle`, `restoreFromBackup`, the sync download swap in `downloadRemoteBundle`, `resolveSyncDecision`'s snapshots, `CatalogService.listBackups`, and the settings screen's direct `createBackup` call.
- Making the swap wait for any in-flight manual or automatic sync before closing the database.
- Moving legacy-token scrubbing into the module, or keeping it callable from the module.

## Out of Scope

- Redesigning sync orchestration, conflict handling or the sync metadata model. That is [002](002-sync-session-module.md) and #98.
- Changing the bundle format (`.realmwise`) or `CatalogBundleService` beyond what the swap needs.
- Changing the database schema.
- UI redesign of the backup/restore settings. Labels and layout stay as they are.
- Cloud-side retention of remote revisions.

## Functional Requirements

- Every snapshot is created through the recovery module and records its kind.
- Routine snapshots are trimmed to the newest 12 routine snapshots only. Pre-import, pre-download and pre-remote-overwrite snapshots are never deleted by routine trimming. Each of these kinds has its own retention: keep at least the newest 5 of each kind. A different number is fine if the PR states it.
- Existing snapshot files on disk keep working:
  - Files named `<db>_<stamp>.backup.db` are treated as routine snapshots.
  - Files named `<db>_pre-import-<micros>.backup.db` are treated as pre-import snapshots.
  - Existing `_pre-remote-overwrite-*.realmwise` files are listed as remote-overwrite restore points.
- Listing restore points returns them newest first. Each one carries its kind, timestamp and path, so the settings screen no longer parses filenames.
- Replacing the active catalog follows this order:
  1. Validate the staged file.
  2. Wait for any in-flight manual or automatic sync to finish or cancel.
  3. Stop periodic snapshots.
  4. Take a pre-replace snapshot of the right kind.
  5. Close the database.
  6. Swap the files.
  7. Reopen the catalog.
  8. Rehydrate missing images.
  9. Restart periodic snapshots.
- If any step after the database closes fails, the original catalog file is restored and reopened, and the error propagates to the caller. On failure, staged database files and staged image folders are removed.
- Restoring a snapshot from the settings screen uses the same replace sequence, so the active catalog file is replaced in place. A new `restored_<millis>.db` is not created. Sync metadata for the catalog identity follows the existing rebind-after-restore behavior (`test/sync_rebind_test.dart`).
- No caller outside the module builds a path under `backups/` or matches `.backup.db`.

## Acceptance Criteria

- After a manual bundle import, the pre-import snapshot still exists after 13 or more routine snapshots have been taken. A test proves this with a fake clock.
- A catalog swap started while a sync is in flight waits for that sync before closing the database. A test proves this with a fake sync that completes on demand.
- A swap that fails after the original file was moved leaves the original catalog open and intact. Tests cover failure at the copy, rename and reopen steps.
- `restoreDeviceBundle`, `restoreFromBackup` and the sync download path all call one replace method on the module. A grep for `backups` and `.backup.db` outside the module and its tests finds no path construction.
- The settings screen lists restore points from the module, with their kind, and no longer calls `backups.createBackup` directly.
- Existing tests (`manual_bundle_import_test.dart`, `sync_rebind_test.dart`, `catalog_service_test.dart`, `settings_screen_test.dart`) pass. Any change to them is deliberate and explained in the PR.
- CI `validate` passes.

## Constraints

- Ensure the change is supported on Android, Windows, and Linux.
- Realmwise colors, typography, style, and themes shall be preserved. Reuse the existing theme (`lib/theme/app_theme.dart`), shared widgets (`lib/widgets/`), and other UI/UX scaffolding where appropriate.
- Create a new branch for this work.
- Preserve unrelated working-tree changes.
- Follow existing repository conventions.
- Stage and commit the work on that branch, push it, and open a PR that references the originating issue (`Closes #101`). Do not merge the PR or enable auto-merge without the user's explicit consent; Claude reviews every PR first.
- Existing catalogs and existing snapshot folders must keep working with no manual step.
- Snapshots must not contain OAuth tokens or the RPGGeek key (keep the legacy-token scrub).
- Do not add new responsibilities to `AppController`. It should lose code in this change.

## Implementation Guidance

- Dependency category: local-substitutable. The module depends on the file system and SQLite. Tests can use a temp directory and `sqflite_common_ffi`'s in-memory or temp-file database, so no new seam is needed for those.
- Give the module a small interface. A shape that fits: `snapshot(kind)`, `restorePoints()`, `replaceCatalog(stagedPath, {snapshotKind})`. Keep naming, retention and swap order private.
- The "wait for sync" dependency should be passed in, as a callback or a small interface the controller satisfies with `_cancelAndAwaitSync`. That way the module doesn't import sync code.
- Put the kind in the filename so retention survives restarts without an index file. Keep the `.backup.db` suffix for database snapshots so the old routine-trim pattern stays recognizable during migration.
- The swap logic in `restoreDeviceBundle` (`app_controller.dart:1210-1254`) is the best existing version. Move it rather than rewrite it.
- Coordinate with #98, which edits `app_controller.dart` sync code. Rebase on it if it lands first.

## Validation

- Create new or update existing regression tests as required.
- Before handing this back for visual review, check affected catalog-open, sync, restore, and recovery paths, and update assertions tied to the changed appearance or timing. State exactly which checks ran.
- Add `test/catalog_recovery_test.dart` covering retention per kind, legacy filename recognition, swap ordering, rollback at each step, and wait-for-sync.
- Manually, on at least Windows and one other platform:
  - Import a bundle, then confirm the pre-import snapshot is listed.
  - Restore from a snapshot, then confirm the catalog reopens with the same path.
  - Start a sync and immediately import a bundle, then confirm no "database is closed" error.

## Completion Notes

- Unit, widget, and platform build tests should be performed after code changes are complete.
- Failures in these tests should prompt one or more debug session rounds until the code is clear, a roadblock is encountered, or user input is needed.
