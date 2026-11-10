"""Reconcile the checked-in CycloneDX SBOM with Pub's resolved packages."""

import copy
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4


def lockfile_packages(text: str) -> dict[str, dict[str, str | None]]:
    blocks = re.findall(
        r"^  ([A-Za-z0-9_]+):\r?\n(.*?)(?=^  [A-Za-z0-9_]+:\r?\n|^sdks:)",
        text, re.MULTILINE | re.DOTALL,
    )
    packages = {}
    for name, block in blocks:
        fields = {}
        for field in ("version", "source", "dependency"):
            match = re.search(rf'^    {field}: "?([^"\r\n]+)"?\r?$', block, re.MULTILINE)
            if not match:
                raise ValueError(f"Missing {field} for {name} in pubspec.lock.")
            fields[field] = match.group(1)
        if fields["source"] not in ("hosted", "sdk"):
            raise ValueError(f"Unsupported package source for {name}: {fields['source']}")
        checksum = re.search(r'^      sha256: "?([0-9a-f]{64})"?\r?$', block, re.MULTILINE)
        if fields["source"] == "hosted" and not checksum:
            raise ValueError(f"Missing SHA-256 for hosted package {name}.")
        fields["sha256"] = checksum.group(1) if checksum else None
        packages[name] = fields
    if not packages:
        raise ValueError("No packages found in pubspec.lock.")
    return packages


def reconcile(bom: dict, lockfile: str) -> dict:
    result = copy.deepcopy(bom)
    packages = lockfile_packages(lockfile)
    components = {
        component["name"]: component
        for component in result.get("components", [])
        if component.get("name") in packages
    }
    for name, package in packages.items():
        component = components.setdefault(name, {"name": name})
        hosted = package["source"] == "hosted"
        component.setdefault("type", "library" if hosted else "framework")
        component["version"] = package["version"]
        component["scope"] = "excluded" if package["dependency"] == "direct dev" else "required"
        component["purl"] = f"pkg:{'dart' if hosted else 'generic'}/{name}@{package['version']}"
        properties = {prop["name"]: prop["value"] for prop in component.get("properties", [])}
        properties.update({"pub:dependency": package["dependency"], "pub:source": package["source"]})
        component["properties"] = [{"name": key, "value": value} for key, value in properties.items()]
        if hosted:
            component["hashes"] = [{"alg": "SHA-256", "content": package["sha256"]}]
            component.setdefault("externalReferences", [
                {"type": "distribution", "url": f"https://pub.dev/packages/{name}"}
            ])
        else:
            component.pop("hashes", None)
    result["components"] = list(components.values())
    return result


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    path = root / "bom.json"
    original = json.loads(path.read_text(encoding="utf-8"))
    bom = reconcile(original, (root / "pubspec.lock").read_text(encoding="utf-8"))
    pubspec = (root / "pubspec.yaml").read_text(encoding="utf-8")
    version = re.search(r"^version: (\S+)", pubspec, re.MULTILINE).group(1)
    dart = re.search(r"^  sdk: ['\"]([^'\"]+)['\"]", pubspec, re.MULTILINE).group(1)
    flutter = json.loads((root / ".fvmrc").read_text(encoding="utf-8"))["flutter"]
    bom["metadata"]["component"]["version"] = version
    properties = {item["name"]: item["value"] for item in bom["metadata"]["properties"]}
    properties.update({"dart-sdk-constraint": dart, "flutter-sdk-constraint": f">={flutter}"})
    bom["metadata"]["properties"] = [{"name": key, "value": value} for key, value in properties.items()]
    if bom != original:
        bom["serialNumber"] = f"urn:uuid:{uuid4()}"
        bom["metadata"]["timestamp"] = datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
        path.write_text(json.dumps(bom, indent=2) + "\n", encoding="utf-8")
    print(f"Reconciled CycloneDX SBOM with {len(bom['components'])} resolved Pub packages.")


if __name__ == "__main__":
    main()
