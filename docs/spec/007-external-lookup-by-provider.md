# Feature: Split external lookup by provider (deferred, not recommended now)

Issue: #107 · Part of #99

> **Status: not recommended.** The architecture review's deletion test says to leave this module as it is. This spec records the idea, why it is deferred, and the trigger that would reopen it, so future reviews don't re-propose it without new information. Its issue isn't `ready-for-agent`.

## Abstract

Split `ExternalCatalogService` into one adapter per lookup provider (OpenLibrary, RPGGeek) behind a shared lookup interface. A separate module would merge their results into work candidates.

## Objective

Make adding a third lookup provider cheap, and let each provider's parsing be changed and tested on its own.

## Context / Existing Behavior

- `lib/services/external_catalog_service.dart` (about 787 lines) does three things:
  - searches OpenLibrary by ISBN, title or author
  - optionally enriches results from RPGGeek's XML API, where RPGGeek values win
  - merges the results in `enrichWithRpgGeek`
- HTTP is already injected, and 22 tests cover the module (`test/external_catalog_service_test.dart`).
- The module already sits behind `BookIntakeLookup` (ADR 0001). Book intake never sees provider-specific details.
- Deletion test: deleting the module would scatter the cross-provider merge rules into callers. So the module earns its keep, and its depth is in the merge, not in the per-provider HTTP code. Splitting it now would mostly move code without concentrating complexity.

## In Scope

- Only if reopened by the trigger below:
  - a per-provider lookup adapter interface
  - OpenLibrary and RPGGeek adapters
  - a merge module that owns precedence rules
  - a third provider adapter

## Out of Scope

- Any change while there are only two lookup providers.
- Changes to book intake's interfaces (`BookIntakeLookup`).
- Changing RPGGeek-wins precedence.

## Functional Requirements

- Reopen trigger: a third lookup provider is planned, or a provider's parsing changes enough that its tests can't be kept local.
- If reopened:
  - Merge precedence stays explicit and lives in one place.
  - Every existing lookup test still passes against the split modules.
  - Network calls still happen only on user action.

## Acceptance Criteria

- For now: an ADR, or a note in `docs/architecture.md`, records "external lookup stays one module until a third provider arrives". That stops future architecture reviews from re-suggesting the split.
- If reopened: the 22 existing lookup tests pass unchanged against the new modules, and each provider adapter has its own parsing tests.

## Constraints

- Ensure the change is supported on Android, Windows, and Linux.
- Realmwise colors, typography, style, and themes shall be preserved. Reuse the existing theme (`lib/theme/app_theme.dart`), shared widgets (`lib/widgets/`), and other UI/UX scaffolding where appropriate.
- Create a new branch for this work.
- Preserve unrelated working-tree changes.
- Follow existing repository conventions.
- Do not commit or push unless explicitly requested.
- Must stay consistent with ADR 0001: provider-specific lookup stays out of `lib/book_intake/`.
- The RPGGeek key is read only through `TokenStorage`.

## Implementation Guidance

- Don't implement this yet. The action for now is a short ADR, written by Claude, recording the decision and the reopen trigger.
- If reopened, follow "one adapter = hypothetical seam, two = real". With three providers the seam is real.

## Validation

- Create new or update existing regression tests as required.
- Before handing this back for visual review, check affected catalog-open, sync, restore, and recovery paths, and update assertions tied to the changed appearance or timing. State exactly which checks ran.
- If reopened, run the full lookup suite and a manual ISBN and title search on one desktop and one Android device, with and without an RPGGeek key.

## Completion Notes

- Unit, widget, and platform build tests should be performed after code changes are complete.
- Failures in these tests should prompt one or more debug session rounds until the code is clear, a roadblock is encountered, or user input is needed.
