# Feature: Export to a user-chosen destination

Issue: #106 · Part of #99

## Abstract

Introduce one export module that writes a produced file to a destination the user picks. Callers supply a producer, which writes the content to a given path, plus a suggested file name and MIME type. Behind the module's seam are two adapters:

- **Android:** the Storage Access Framework (SAF), via the existing `DiagnosticBundleExporter.chooseDestination`
- **Desktop (Windows, Linux):** the file picker save dialog

Bundle export, CSV export and diagnostic bundle export all use it.

## Objective

- Remove three copies of the same platform save flow from the settings screen (the largest widget, about 1730 lines, and the top hot spot with 39 commits since June).
- Make sure every export cleans up its temp file on success, failure and cancel, and prove it with tests. No copy has a test today.
- Give the phase 2 settings redesign a settings screen with no platform plumbing.

## Context / Existing Behavior

`lib/screens/settings_screen.dart` repeats this sequence three times:

1. On Android, ask SAF for a destination URI through `DiagnosticBundleExporter().chooseDestination(fileName:, mimeType:)`. Return if the user cancels.
2. Create a temp file under `getTemporaryDirectory()`.
3. Produce the content into it.
4. On Android, copy it to the URI. On desktop, show a save dialog and copy it there.
5. Delete the temp file.

The three copies are:

- Diagnostic bundle: `_generateDiagnosticBundle`, `:126-196`
- Device bundle (`.realmwise`): `_exportDeviceBundle`, `:532-590`
- CSV: `_exportCsv`, `:642-700`

The copies differ in small ways, such as file names, MIME types and the success message. Whether cleanup runs on every path differs between them too, and no test covers it.

## In Scope

- An export module (for example `lib/services/export_destination.dart`) with one entry point. It takes a suggested file name, a MIME type and a producer, and returns a typed result: saved (with a user-facing location description), cancelled, or failed.
- An Android adapter using SAF, reusing the existing `chooseDestination` and copy code.
- A desktop adapter using the file picker save dialog.
- Platform selection in one place, injectable for tests.
- Rewriting the three settings screen export actions to call the module.
- Tests with a fake adapter and a temp directory.

## Out of Scope

- What is exported. The bundle format, CSV columns and diagnostic bundle contents are unchanged.
- Import flows (CSV import, bundle import). Their file-picking stays as is.
- Visual changes to the settings screen.
- Moving the diagnostic export's sanitization. `DiagnosticSanitizer` still runs inside the producer.

## Functional Requirements

- The module asks for the destination before running the producer, so a cancelled picker does no work. This is today's Android order. On desktop, today's order also lets the user cancel before any work is done.
- The producer writes to a temp path the module owns. After the copy to the destination, the temp file is deleted. It is also deleted if the producer throws, if the copy fails, or if the user cancels after production.
- Results:
  - **Saved:** carries a description the UI can show, such as the chosen file name.
  - **Cancelled:** the UI shows no error.
  - **Failed:** carries a user-safe message. No raw `toString()` reaches the UI.
- The three settings actions keep their current file names, MIME types and success messages.
- Platform behavior is unchanged:
  - Android writes through SAF.
  - Windows and Linux show a native save dialog.

## Acceptance Criteria

- `settings_screen.dart` contains no `chooseDestination`, `getTemporaryDirectory` or save-dialog calls for exports.
- `test/export_destination_test.dart` covers each of these paths, and in each one the temp file doesn't exist afterwards:
  - cancel before produce
  - producer throws
  - copy fails
  - success
- Tests prove each settings export action passes the expected file name and MIME type. They use a fake adapter.
- Existing tests (`settings_screen_test.dart`, `diagnostic_bundle_exporter_test.dart`, `export_service_test.dart`) pass.
- CI `validate` passes.

## Constraints

- Ensure the change is supported on Android, Windows, and Linux.
- Realmwise colors, typography, style, and themes shall be preserved. Reuse the existing theme (`lib/theme/app_theme.dart`), shared widgets (`lib/widgets/`), and other UI/UX scaffolding where appropriate.
- Create a new branch for this work.
- Preserve unrelated working-tree changes.
- Follow existing repository conventions.
- Stage and commit the work on that branch, push it, and open a PR that references the originating issue (`Closes #106`). Do not merge the PR or enable auto-merge without the user's explicit consent; Claude reviews every PR first.
- Diagnostic exports must still pass through `DiagnosticSanitizer`. No tokens or keys may appear in any export.
- A change to the Android path usually needs a matching check of the desktop path, and the reverse.

## Implementation Guidance

- Dependency category: ports & adapters, with two real adapters (Android SAF and the desktop picker), so the seam is real.
- Keep the interface to one method, for example `Future<ExportResult> export({required String fileName, required String mimeType, required Future<void> Function(String path) produce})`.
- Move the SAF code out of `DiagnosticBundleExporter` into the Android adapter only if it reads more clearly. Reusing it as is satisfies this spec.
- A typed result here can be the first concrete instance of the phase 1 error model. Keep it simple, so the error-model decision can generalize it later.

## Validation

- Create new or update existing regression tests as required.
- Before handing this back for visual review, check affected catalog-open, sync, restore, and recovery paths, and update assertions tied to the changed appearance or timing. State exactly which checks ran.
- On Android and on Windows or Linux, export a device bundle, a CSV and a diagnostic bundle by hand. Confirm each file opens, and that cancelling the picker shows no error.
- Then re-import the exported bundle with the manual bundle import, and confirm the catalog matches.

## Completion Notes

- Unit, widget, and platform build tests should be performed after code changes are complete.
- Failures in these tests should prompt one or more debug session rounds until the code is clear, a roadblock is encountered, or user input is needed.
