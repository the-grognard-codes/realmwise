## Roles

Codex implements: it writes code and tests, and opens PRs. Claude plans and reviews: it writes specs and tickets on GitHub Issues and reviews branches and PRs. Claude's instructions are in `CLAUDE.md`. The module map is in `docs/architecture.md`.

Before opening a PR, run the same checks as CI's `validate` job: `dart format --output=none --set-exit-if-changed .`, `flutter analyze`, and `flutter test`. Reference the originating issue in the PR body so review can check the change against it.

## Agent skills

### Issue tracker

Issues and specs live in GitHub Issues. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the five default triage labels. See `docs/agents/triage-labels.md`.

### Domain docs

Use a single-context layout. See `docs/agents/domain.md`.
