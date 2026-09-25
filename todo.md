# Backlog

## Detect possible duplicate works beyond ISBN-13

- **Current behavior:** When a remote work candidate is selected for adding, intake checks for an existing cataloged work only if the enriched candidate has an ISBN-13. A match offers **Edit existing**, **Add copy**, or **Cancel**. Without an ISBN-13 match, the candidate opens as a new work, even if its provider ID or title and authors match a cataloged work. Metadata refresh in selection-only mode does not run this check.
- **Expected future behavior:** Before creating a work, surface a possible duplicate when another reliable identifier or a strong title-and-author match suggests the work is already cataloged. Let the collector inspect the match and choose to use the existing work, add a copy, or keep a separate work. Do not merge works automatically. Keep selection-only metadata refresh free of the add-flow duplicate prompt.
- **Follow-up decision:** Define match confidence, edition handling, and the precise choices for a possible rather than exact match before implementation.
- **Scope:** Separate from the behavior-preserving book-intake refactor in the [architecture review](docs/architecture-review-20260923-235117.html#book-intake).

## Apply the same ISBN-13 checksum rule to typed and scanned lookup

- **Current behavior:** Camera scanning accepts an ISBN-13 barcode only when its checksum is valid. Typed ISBN lookup accepts any 13 digits and sends them to OpenLibrary, even when the checksum is invalid. ISBN-10 input is checksum-validated before conversion to ISBN-13.
- **Expected future behavior:** Typed and scanned ISBN-13 input use the same checksum validation before remote lookup. An invalid ISBN-13 produces the existing invalid-ISBN feedback and makes no remote request. Valid ISBN-10 input continues to convert to ISBN-13 for lookup.
- **Scope:** Separate from the behavior-preserving book-intake refactor.
