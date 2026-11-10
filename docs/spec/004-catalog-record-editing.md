# Feature: Make catalog record editing a deep module

Issue: #104 · Part of #99

## Abstract

Introduce a catalog record editing module that stages every change to a work, its owned copies and its images while the editor is open. It commits image files and database rows together when the user saves, and discards staged files when the user cancels. One image normalization rule (order and exactly one cover) applies to every path that writes a record: editor save, CSV import and bundle import.

## Objective

- Make cancel safe. Today, cancelling the editor after changing images can leave the saved owned copy pointing at image files that were renamed or deleted.
- Remove the divergence between save and import cover rules, so a record looks the same however it entered the catalog.
- Give `CatalogService`, which today mostly passes calls through, a reason to exist (the deletion test). Alternatively, replace it with the new module.
- Prepare the editor for the UI phase: the screen should only render state and send intents.

## Context / Existing Behavior

- `lib/screens/book_editor_screen.dart` calls `widget.controller.imageStorage` directly, and each call takes effect on disk at once:
  - `_importImages` → `importFile` (`:~602`)
  - `_setCover` → `setCover`, which renames files (`:~653-662`)
  - `_removeImage` → `deleteImage` (`:~668-678`)
  - `_loadRemoteCover` downloads a cover before save (`:192-212`)

  These take effect before the record is saved. If the user then leaves without saving, the database still references the old file names, or deleted files, and new files are orphaned.
- `lib/services/catalog_service.dart` (`:20-125`) is mostly a pass-through to `DatabaseService`. Its one piece of behavior is the remote cover download at save (`:20-35`).
- `lib/data/database_service.dart` applies two different cover rules:
  - `saveRecord` (`:371-442`) normalizes images: `sortOrder` follows list order, and exactly one image is the cover (the first, if none is marked) (`:379-385`).
  - `importRecords` (`:446-531`) only rewrites `sortOrder` (`:~512`) and keeps each image's `isCover` as given. An imported record can have zero or several covers.

## In Scope

- A record editing module, for example `CatalogRecordEditor` or a deepened `CatalogService`. It provides:
  - "begin editing" for a record (new or existing)
  - staged image operations: add from file, add downloaded cover, set cover, remove, reorder
  - field updates
  - `save()` and `discard()`
- Staging new and renamed image files in a staging location, and making them final only on save.
- Deferring image deletions until save.
- One image normalization function used by `saveRecord`, `importRecords` and the editing module.
- Moving the editor screen's image file operations behind the module.
- Cleaning up orphaned staging files left by a crash, on next open.

## Out of Scope

- Visual redesign of the editor. That is phase 2.
- Changing the image file naming scheme for final files, beyond what staging needs.
- The image storage location setting and folder migration.
- Duplicate detection rules and intake lookup. Those stay in `lib/book_intake/` (ADR 0001).
- Database schema changes, unless a staging marker truly needs one. If so, see Constraints.

## Functional Requirements

- Opening the editor starts an edit session for one record. Until save, no file in the managed image folder that the saved record references is renamed, moved or deleted.
- Adding an image (from a file or a downloaded cover) writes it to staging. Setting a cover, reordering or removing updates only the staged state.
- On save, the module:
  1. Normalizes images (list order sets `sortOrder`; exactly one cover, the first if none is marked).
  2. Moves staged files to their final names.
  3. Writes rows in one database transaction.
  4. Deletes files the user removed, only after the transaction commits.

  If the transaction fails, final-named files created by this save are removed, and the record on disk is unchanged.
- On discard (cancel, back navigation, or the editor being disposed without save), staged files are deleted and the saved record is unchanged.
- The remote cover download at save (`CatalogService.save`) is kept. Its result goes through the same staging and commit path.
- `importRecords` uses the same normalization rule as save. An imported record always has exactly one cover when it has any images.
- At app start or catalog open, staging files older than the current process are removed.
- The editor screen gets the staged record state from the module and calls module methods only. It no longer calls `imageStorage` directly.

## Acceptance Criteria

- Tests prove that for an existing owned copy with images, the files referenced by the saved record are unchanged after discard. They cover each of:
  - set cover, then cancel
  - remove image, then cancel
  - add image, then cancel
- A test proves save after set cover renames files and updates rows consistently, and a failed transaction leaves both unchanged.
- A test proves `importRecords` given zero covers, or two covers, stores exactly one cover.
- `book_editor_screen.dart` contains no `imageStorage.` calls.
- Existing tests (`book_editor_screen_test.dart`, `catalog_service_test.dart`, `database_service_test.dart`, `image_storage_service_test.dart`) pass. Changes are deliberate and explained.
- CI `validate` passes.

## Constraints

- Ensure the change is supported on Android, Windows, and Linux.
- Realmwise colors, typography, style, and themes shall be preserved. Reuse the existing theme (`lib/theme/app_theme.dart`), shared widgets (`lib/widgets/`), and other UI/UX scaffolding where appropriate.
- Create a new branch for this work.
- Preserve unrelated working-tree changes.
- Follow existing repository conventions.
- Do not commit or push unless explicitly requested.
- If any table in `lib/data/database_service.dart` changes, bump the `openDatabase` version and add an additive `onUpgrade` step. Existing catalogs must open.
- Use **work** and **owned copy** as defined in `CONTEXT.md` in names and messages.
- Network calls (remote cover download) happen only on user action.

## Implementation Guidance

- Dependency category: local-substitutable. The file system and SQLite can both run in tests (temp dir, `sqflite_common_ffi`). No new seam is needed for them.
- Keep the module's interface small. The editor needs only: the current record state, a handful of intents, `save()`, and `discard()`. Staging layout and normalization are private.
- Put staging inside the managed image folder (for example `.staging/<session-id>/`) so the final move is a same-volume rename on every platform, including Android app storage.
- Prefer deepening `CatalogService` over adding a parallel class. Book intake already depends on `BookIntakeCatalog`, so keep that adapter working.
- The editor's `dispose` must call `discard()` when no save happened.

## Validation

- Create new or update existing regression tests as required.
- Before handing this back for visual review, check affected catalog-open, sync, restore, and recovery paths, and update assertions tied to the changed appearance or timing. State exactly which checks ran.
- Check by hand on Windows and Android:
  - Edit an owned copy, change the cover, then cancel. Reopen it: the images are as before.
  - Change the cover, then save. Reopen it: the new cover shows.
  - Import a CSV or bundle with multiple covers marked. One cover shows.
- Confirm that a sync upload after an edit includes the right images when personal images are enabled.

## Completion Notes

- Unit, widget, and platform build tests should be performed after code changes are complete.
- Failures in these tests should prompt one or more debug session rounds until the code is clear, a roadblock is encountered, or user input is needed.
