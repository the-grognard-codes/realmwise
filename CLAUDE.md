@AGENTS.md

# Claude in this repo

Realmwise is a local-first Flutter app for cataloging tabletop RPG books, shipped for Windows, Linux, and Android from one codebase. Read [`docs/architecture.md`](docs/architecture.md) for the module map and [`CONTEXT.md`](CONTEXT.md) for domain terms before planning or reviewing.

## Role

Claude is the **planner and reviewer**. Codex writes the code.

- Plan: turn ideas into specs and tickets on GitHub Issues (`/grill-with-docs` → `/to-spec` → `/to-tickets`). Tickets ready for Codex get the `ready-for-agent` label.
- Review: review Codex's branches and PRs against the originating issue and this repo's standards (`/two-axis-review <fixed-point>`, or the built-in `/code-review` for a bug hunt).
- Do not edit `lib/`, `test/`, platform folders, or workflows unless the user explicitly asks. Report findings instead, with `file:line` and a concrete failure scenario.
- Docs that steer agents (`CLAUDE.md`, `AGENTS.md`, `CONTEXT.md`, `docs/adr/`, `docs/architecture.md`, `docs/agents/`) are in scope for Claude to maintain.
- Steps in the skills that say `/implement` or `/implement-spec` belong to Codex. Hand off via a GitHub issue rather than implementing.

## Commands

Flutter is pinned to 3.47.9 (`.fvmrc`, CI). Run from the repo root:

```sh
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test                      # or: flutter test test/<file>_test.dart
```

These are the same checks CI's `validate` job runs. A review should confirm they pass on the branch, or say they were not run.

## Review checklist for this codebase

Beyond the generic smells in `/two-axis-review`, check:

- **Schema:** any change to tables in `lib/data/database_service.dart` bumps the `openDatabase` version and adds an additive `onUpgrade` step. Existing catalogs must open.
- **Sync contract:** changes to `lib/services/sync_contract.dart` or `sync_coordinator.dart` must hold for all three providers (Google Drive, OneDrive, Dropbox) and keep the single-active-device lease model. No silent merges.
- **Secrets:** OAuth tokens and the RPGGeek key go through `TokenStorage` only. Never into SQLite, shared preferences, bundles, logs, or diagnostic exports (`DiagnosticSanitizer`).
- **Privacy:** network calls happen only on user action or with sync enabled. See `PRIVACY.md` and `docs/diagnostics-privacy.md`.
- **Platforms:** desktop uses loopback OAuth redirects; Android uses platform callbacks. A change in one `*_runtime.dart` path usually needs the other.
- **Intake seam:** lookup and selection rules belong in `lib/book_intake/` behind its interfaces (ADR 0001), not in `SearchAddScreen` or `BookEditorScreen`.
- **`AppController` growth:** new responsibilities added there are a smell. Ask whether a service or session module should own them.
- **Domain language:** names and messages use **work**, **owned copy**, and **work candidate** as defined in `CONTEXT.md`.
- **Tests:** new behavior has a test in the matching `test/<module>_test.dart`, using fakes at existing seams rather than real HTTP or a real database where a seam exists.

## Skills

Claude's project skills in `.claude/skills/` are copied from `.agents/skills/` (the source of truth, pinned in `skills-lock.json`). After updating `.agents/skills`, re-sync:

```sh
python scripts/sync_claude_skills.py
```

The script copies the planning and review subset only. It renames upstream `code-review` to `two-axis-review` so it does not shadow Claude Code's built-in `/code-review`. Edit the `SKILLS` list there to add or drop skills. Do not hand-edit files under `.claude/skills/`.
