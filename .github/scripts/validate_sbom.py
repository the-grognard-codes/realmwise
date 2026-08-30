"""Validate the checked-in CycloneDX SBOM against Pub's resolved lockfile."""

import json
import re
from pathlib import Path


def lockfile_packages(lockfile: str) -> dict[str, dict[str, str | None]]:
    blocks = re.findall(
        r"^  ([A-Za-z0-9_]+):\r?\n(.*?)(?=^  [A-Za-z0-9_]+:\r?\n|^sdks:)",
        lockfile,
        re.MULTILINE | re.DOTALL,
    )
    packages = {}
    for name, block in blocks:
        version = re.search(r'^    version: "([^"]+)"\r?$', block, re.MULTILINE)
        source = re.search(r"^    source: ([^\r\n]+)\r?$", block, re.MULTILINE)
        checksum = re.search(r'^      sha256: "?([0-9a-f]+)"?\r?$', block, re.MULTILINE)
        if not version or not source:
            raise ValueError(f"Could not parse version/source for {name} in pubspec.lock.")
        packages[name] = {
            "version": version.group(1),
            "source": source.group(1),
            "sha256": checksum.group(1) if checksum else None,
        }
    return packages


root = Path(__file__).parents[2]
bom = json.loads((root / "bom.json").read_text(encoding="utf-8"))
if bom.get("bomFormat") != "CycloneDX" or bom.get("specVersion") != "1.5":
    raise SystemExit("bom.json is not a CycloneDX 1.5 SBOM.")

locked = lockfile_packages((root / "pubspec.lock").read_text(encoding="utf-8"))
components = {component.get("name"): component for component in bom.get("components", [])}
if set(components) != set(locked):
    raise SystemExit("bom.json component names do not match pubspec.lock.")

for name, package in locked.items():
    component = components[name]
    if component.get("version") != package["version"]:
        raise SystemExit(f"bom.json has an incorrect version for {name}.")
    if package["source"] == "hosted":
        hashes = component.get("hashes", [])
        if {item.get("content") for item in hashes} != {package["sha256"]}:
            raise SystemExit(f"bom.json has an incorrect SHA-256 hash for {name}.")

print(f"Validated CycloneDX 1.5 SBOM against {len(locked)} resolved Pub packages.")
