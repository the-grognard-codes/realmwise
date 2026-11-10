"""Copy the planner/reviewer subset of .agents/skills into .claude/skills.

.agents/skills is the source of truth (managed through skills-lock.json).
Claude Code reads project skills from .claude/skills, so this script mirrors
the skills Claude uses in its planning and review role. Re-run it after
updating .agents/skills.

Codex-only files (agents/openai.yaml) are skipped. The upstream `code-review`
skill is renamed to `two-axis-review` so it does not shadow Claude Code's
built-in /code-review command.
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / ".agents" / "skills"
TARGET = ROOT / ".claude" / "skills"

SKILLS = [
    "ask-matt",
    "claude-handoff",
    "code-review",
    "codebase-design",
    "diagnosing-bugs",
    "domain-modeling",
    "grill-me",
    "grill-with-docs",
    "grilling",
    "handoff",
    "improve-codebase-architecture",
    "prototype",
    "research",
    "retro",
    "tdd",
    "to-questionnaire",
    "to-spec",
    "to-tickets",
    "triage",
    "wait-what",
    "wayfinder",
    "writing-for-agents",
]

RENAMES = {"code-review": "two-axis-review"}

# Text rewrites applied to every copied Markdown file so cross-references
# follow the renames above.
REWRITES = [
    ("name: code-review", "name: two-axis-review"),
    ("/code-review", "/two-axis-review"),
    ("`code-review` skill", "`two-axis-review` skill"),
]

SKIP_DIRS = {"agents"}


def copy_skill(name: str) -> None:
    source = SOURCE / name
    if not (source / "SKILL.md").is_file():
        raise SystemExit(f"Missing source skill: {source}")
    target = TARGET / RENAMES.get(name, name)
    if target.exists():
        shutil.rmtree(target)
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        if relative.parts[0] in SKIP_DIRS or path.is_dir():
            continue
        destination = target / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if path.suffix == ".md":
            text = path.read_text(encoding="utf-8")
            for old, new in REWRITES:
                text = text.replace(old, new)
            destination.write_text(text, encoding="utf-8", newline="\n")
        else:
            shutil.copy2(path, destination)


def main() -> int:
    TARGET.mkdir(parents=True, exist_ok=True)
    managed = {RENAMES.get(name, name) for name in SKILLS}
    for stale in TARGET.iterdir():
        if stale.is_dir() and stale.name not in managed:
            print(f"warning: {stale.relative_to(ROOT)} is not managed by this script")
    for name in SKILLS:
        copy_skill(name)
        print(f"synced {name} -> {RENAMES.get(name, name)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
