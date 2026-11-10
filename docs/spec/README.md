# Feature specs

Each file in this folder is one feature or improvement, written in the standard work item template below. A spec is mirrored as a GitHub issue (see [`docs/agents/issue-tracker.md`](../agents/issue-tracker.md)). The issue is where work is tracked and labeled; this folder keeps the spec reviewable next to the code.

Claude writes specs. Codex implements specs whose issue is labeled `ready-for-agent`.

## Index

| Spec | Strength | Issue | Phase |
| --- | --- | --- | --- |
| [001 · Local catalog recovery](001-local-catalog-recovery.md) | Strong | #101 | Before UI |
| [002 · Sync session module](002-sync-session-module.md) | Strong | #102 | Before UI |
| [003 · Thin provider adapters](003-thin-provider-adapters.md) | Strong | #103 | Sync revision |
| [004 · Catalog record editing](004-catalog-record-editing.md) | Strong | #104 | Before UI |
| [005 · Catalog hierarchy model](005-catalog-hierarchy-model.md) | Worth exploring | #105 | With UI |
| [006 · Export to a chosen destination](006-export-destination.md) | Worth exploring | #106 | Before UI |
| [007 · External lookup by provider](007-external-lookup-by-provider.md) | Speculative (not recommended) | #107 | Deferred |

Source: the architecture review of `main` at `dd52f0d` (2026-11-10). Suggested order: 001 → 002 → 004 before the UI phase, 005 with the UI phase, 003 in the sync phase. All are part of the overhaul map, #99.

## Picking up a `ready-for-agent` issue

Codex works one issue at a time:

1. Claim the issue (`gh issue edit <n> --add-assignee @me`). Skip issues with open blockers (`Blocked by:` at the top of the body).
2. Read the issue and its spec file in this folder. If they disagree, the issue wins; note the difference in the PR.
3. Create a branch from `main` named `<type>/<n>-<slug>`, for example `refactor/101-catalog-recovery`.
4. Implement, then run the checks listed under Completion Notes and debug until they pass.
5. Stage and commit, push the branch, and open a PR (not a draft) whose body starts with `Closes #<n>` and states exactly which checks ran.
6. Stop there. Do not merge or enable auto-merge. Claude reviews the PR against the issue, and the user merges or explicitly approves a merge. Address review comments with new commits on the same branch.

## Template

Every spec uses these sections, in this order. Read top to bottom, they answer: What is it? → Why do we want it? → How does it work now? → What are we changing? → Exactly how should it behave? → How do we know we're done? → What rules must we obey? → Any hints about how to build it? → How should you prove it works?

```markdown
# Feature: Summary

## Abstract

## Objective

## Context / Existing Behavior

## In Scope
- In scope 1
- In scope 2

## Out of Scope
- Out of scope 1
- Out of scope 2

## Functional Requirements
- requirement 1
- requirement 2

## Acceptance Criteria
- ac 1
- ac 2

## Constraints
- Ensure the change is supported on Android, Windows, and Linux.
- Realmwise colors, typography, style, and themes shall be preserved. Reuse the existing theme (`lib/theme/app_theme.dart`), shared widgets (`lib/widgets/`), and other UI/UX scaffolding where appropriate.
- Create a new branch for this work.
- Preserve unrelated working-tree changes.
- Follow existing repository conventions.
- Stage and commit the work on that branch, push it, and open a PR that references the originating issue (`Closes #<n>`). Do not merge the PR or enable auto-merge without the user's explicit consent; Claude reviews every PR first.

## Implementation Guidance
- freeform guidance 1

## Validation
- Create new or update existing regression tests as required.
- Before handing this back for visual review, check affected catalog-open, sync, restore, and recovery paths, and update assertions tied to the changed appearance or timing. State exactly which checks ran.

## Completion Notes
- Unit, widget, and platform build tests should be performed after code changes are complete.
- Failures in these tests should prompt one or more debug session rounds until the code is clear, a roadblock is encountered, or user input is needed.
```

### Section notes

- **Abstract** is the one-paragraph "what is it". **Objective** is the "why".
- **Context / Existing Behavior** cites code as `path:line` so a reviewer can check it.
- **Functional Requirements** say how the change must behave. **Acceptance Criteria** are checkable statements a reviewer ticks off.
- Keep the standard **Constraints**, **Validation**, and **Completion Notes** bullets in every spec, then add spec-specific bullets below them.
- In this repo, "unit, widget, and platform build tests" means `dart format --output=none --set-exit-if-changed .`, `flutter analyze`, `flutter test`, and the Windows, Linux, and Android smoke builds that CI runs.
- Use the domain terms in [`CONTEXT.md`](../../CONTEXT.md) (**work**, **owned copy**, **work candidate**).
