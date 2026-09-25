# Issue tracker: GitHub

Issues and specs for this repo live in GitHub Issues. Use `gh` from this clone so it selects the repository from the remote.

## Operations

- Create: `gh issue create --title "..." --body-file <file>`
- Read: `gh issue view <number> --comments`
- List: `gh issue list --state open` with the relevant label and state filters
- Comment: `gh issue comment <number> --body-file <file>`
- Label: `gh issue edit <number> --add-label "..."` or `--remove-label "..."`
- Close: `gh issue close <number> --comment "..."`

When a skill says "publish to the issue tracker," create a GitHub issue. When it says "fetch the relevant ticket," read that issue and its comments.

## Pull requests as a triage surface

**PRs as a request surface: no.**

## Wayfinding operations

A wayfinder map is one issue labeled `wayfinder:map`; its tickets are child issues labeled `wayfinder:<type>` (`research`, `prototype`, `grilling`, or `task`). Link children with GitHub sub-issues when available. Otherwise, list them as tasks in the map and put `Part of #<map>` in each child.

Record blocking relationships with GitHub issue dependencies. If unavailable, put `Blocked by: #<number>` at the top of the child. The next ticket is the first open, unassigned child in map order with no open blockers.

Claim a ticket with `gh issue edit <number> --add-assignee @me`. On resolution, comment with the answer, close the ticket, and add a short pointer and link to the map's Decisions-so-far section.
