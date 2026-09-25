---
status: accepted
---

# Put book lookup and intake behind a visit-scoped session

`SearchAddScreen` currently coordinates lookup, candidate selection, duplicate choices, editor handoff, and Bulk Add state while the editor reuses its search UI for metadata refresh. A visit-scoped Book Intake module will own the logical search and selection flow through one interface with explicit lookup, catalog, preference, and key dependencies; the screen will keep text focus, camera scanning, dialogs, and navigation, and the editor will keep saving records. This places the changing rules behind one seam without moving provider-specific lookup or catalog persistence into intake.

The same lookup and enrichment flow will serve adding and metadata refresh, but refresh returns a work candidate without duplicate handling. Intake will issue typed requests for duplicate choices and editor handoff, accept the resulting choice or save outcome, and ignore search or selection results superseded by later actions. Existing user-visible behavior remains the baseline; broader duplicate matching and consistent ISBN-13 validation are separate backlog items in `todo.md`.

Tests will exercise the intake interface with controlled dependencies and keep widget coverage for focus, dialogs, navigation, and scanner wiring. This replaces screen-level orchestration tests that require a concrete `AppController` and database for intake decisions.
