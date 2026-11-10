# Feature: One catalog hierarchy model

Issue: #105 · Part of #99

## Abstract

Replace the two separate implementations of the catalog grouping (game system → setting → book type → title, or game system → book type → setting → title) with one pure hierarchy-tree function. Both the catalog selector widget and the next/previous navigation order would read that one tree.

## Objective

- Make next/previous navigation always match what the selector shows. Today it only works while two independent copies of the grouping and sort rules agree.
- Remove about 150 duplicated lines from `catalog_screen.dart`, one of the three hot spots (20 commits since June).
- Make the tree shape testable without widgets. Phase 2 (UI) will redesign the catalog view, and it needs a stable model to render.

## Context / Existing Behavior

- `lib/screens/catalog_screen.dart`:
  - `:12-117`: `_compareCatalogLabels`, `_sortedCatalogGroups`, `_sortedCatalogRecords` and `flattenCatalogHierarchy` group records by the two `CatalogHierarchyOrder` values, sort every level case-insensitively, keep untyped books after typed groups, and flatten to a list.
  - `:210-215`: `_shown` filters by text and tag, and `_navigationRecords` flattens `_shown` for next/previous.
  - `:695-840`: `_CatalogSelector.build` rebuilds the same grouping with its own `putIfAbsent` maps and fallback labels such as `'Unclassified system'`, then renders `ExpansionTile`s.
- The fallback labels for empty system, setting and type, and the "untyped after typed" rule, exist in both copies. A change to one copy, for example a new fallback label, silently breaks navigation order.
- `test/catalog_navigation_test.dart` covers the flatten order.

## In Scope

- A pure function or small model (for example `lib/catalog/catalog_hierarchy.dart`). Given records and a `CatalogHierarchyOrder`, it returns a tree of nodes: tier, label, a fallback flag and children, with records as leaves.
- Fallback labels and sorting rules defined once, in that model.
- `flattenCatalogHierarchy` reimplemented as a depth-first walk of the tree.
- `_CatalogSelector` rendering from the tree instead of grouping by itself.
- Unit tests for the tree shape.

## Out of Scope

- Visual changes to the selector: its tiles, icons, expansion behavior and catalog icons stay the same. Redesign happens in phase 2, which this unblocks.
- New hierarchy orders, or user-defined hierarchies.
- Filtering semantics (`CatalogRecord.matches`).
- Persisting the expansion state.

## Functional Requirements

- The tree for a given record list and order matches today's grouping exactly. That covers the same groups, the same fallback labels, the same case-insensitive-then-case-sensitive sort, and untyped books after typed groups within their parent.
- `flattenCatalogHierarchy(records, order:)` returns the leaves of the tree in display order, and keeps its current signature for existing callers.
- The selector shows the same group labels in the same order as before for both hierarchy orders, and per-tier catalog icons still resolve by tier and section name.
- Changing the hierarchy order in settings changes both selector and navigation together.

## Acceptance Criteria

- `catalog_screen.dart` contains one grouping implementation. `_CatalogSelector` has no `putIfAbsent` grouping of its own.
- New tests (in `test/catalog_hierarchy_test.dart`, or added to `catalog_navigation_test.dart`) cover both orders, empty-field fallbacks, case-only label differences, and untyped-after-typed. They also check that the flattened order equals a depth-first walk of the tree.
- A widget test shows the selector's visible group order and next/previous order agree for a mixed catalog, in both hierarchy orders.
- Existing tests (`catalog_navigation_test.dart`, `catalog_drawer_test.dart`) pass unchanged, or with deliberate, explained changes.
- CI `validate` passes.

## Constraints

- Ensure the change is supported on Android, Windows, and Linux.
- Realmwise colors, typography, style, and themes shall be preserved. Reuse the existing theme (`lib/theme/app_theme.dart`), shared widgets (`lib/widgets/`), and other UI/UX scaffolding where appropriate.
- Create a new branch for this work.
- Preserve unrelated working-tree changes.
- Follow existing repository conventions.
- Stage and commit the work on that branch, push it, and open a PR that references the originating issue (`Closes #105`). Do not merge the PR or enable auto-merge without the user's explicit consent; Claude reviews every PR first.
- No visible change to the catalog screen.
- Use **work** and **owned copy** as defined in `CONTEXT.md` in names and messages.

## Implementation Guidance

- Dependency category: in-process. This is pure computation, so no seam is needed. Test the function directly.
- Keep the node type small: tier enum, label, `isFallback`, children, and records at the leaf tier. Let the widget decide icons and expansion.
- Move the fallback label strings next to the tree so the UI phase can restyle them in one place.
- This can land before or alongside the phase 2 catalog redesign. If phase 2 starts first, implement it as that redesign's first ticket.

## Validation

- Create new or update existing regression tests as required.
- Before handing this back for visual review, check affected catalog-open, sync, restore, and recovery paths, and update assertions tied to the changed appearance or timing. State exactly which checks ran.
- Check by hand on a phone-width layout (Android) and a desktop layout (Windows or Linux):
  - With both hierarchy orders, step through every book with next/previous and confirm the order matches the selector.
  - Confirm catalog icons still appear on their tiers.

## Completion Notes

- Unit, widget, and platform build tests should be performed after code changes are complete.
- Failures in these tests should prompt one or more debug session rounds until the code is clear, a roadblock is encountered, or user input is needed.
