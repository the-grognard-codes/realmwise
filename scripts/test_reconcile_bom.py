"""Regression tests for SBOM reconciliation across dependency graph changes."""

import unittest
from reconcile_bom import reconcile


def package(name, *, source="hosted", dependency="transitive", version="2.0.0"):
    return (
        f"  {name}:\n"
        f'    dependency: "{dependency}"\n'
        "    description:\n"
        f'      sha256: "{"a" * 64}"\n'
        f"    source: {source}\n"
        f'    version: "{version}"\n'
    )


class ReconcileBomTest(unittest.TestCase):
    def test_adds_and_removes_packages_and_preserves_metadata(self):
        original = {
            "metadata": {"component": {"name": "realmwise"}},
            "components": [{"name": "removed"}],
        }
        result = reconcile(original, "packages:\n" + package("added") + "sdks:\n")
        self.assertEqual([c["name"] for c in result["components"]], ["added"])
        added = result["components"][0]
        self.assertEqual(added["purl"], "pkg:dart/added@2.0.0")
        self.assertEqual(added["hashes"], [{"alg": "SHA-256", "content": "a" * 64}])
        self.assertEqual(result["metadata"], original["metadata"])
        self.assertEqual(original["components"], [{"name": "removed"}])

    def test_updates_version_identity_and_preserves_custom_fields(self):
        original = {"components": [{
            "name": "existing", "version": "1.0.0", "purl": "pkg:dart/existing@1.0.0",
            "licenses": [{"license": {"id": "MIT"}}],
            "properties": [{"name": "custom", "value": "retained"}],
        }]}
        lockfile = "packages:\n" + package("existing", dependency="direct dev") + "sdks:\n"
        result = reconcile(original, lockfile)
        component = result["components"][0]
        self.assertEqual(component["version"], "2.0.0")
        self.assertEqual(component["purl"], "pkg:dart/existing@2.0.0")
        self.assertEqual(component["scope"], "excluded")
        self.assertEqual(component["licenses"], original["components"][0]["licenses"])
        self.assertIn({"name": "custom", "value": "retained"}, component["properties"])
        self.assertEqual(reconcile(result, lockfile), result)

    def test_sdk_packages_have_no_hosted_hash(self):
        original = {"components": [{"name": "flutter", "hashes": [{"content": "stale"}]}]}
        result = reconcile(original, "packages:\n" + package("flutter", source="sdk") + "sdks:\n")
        component = result["components"][0]
        self.assertEqual(component["purl"], "pkg:generic/flutter@2.0.0")
        self.assertNotIn("hashes", component)

    def test_rejects_empty_malformed_or_unsupported_lockfiles(self):
        invalid = [
            "packages:\nsdks:\n",
            "packages:\n" + package("broken").replace("    version:", "    missing:"),
            "packages:\n" + package("broken").replace('a' * 64, "bad"),
            "packages:\n" + package("unsupported", source="git"),
        ]
        for lockfile in invalid:
            with self.subTest(lockfile=lockfile), self.assertRaises(ValueError):
                reconcile({"components": []}, lockfile)


if __name__ == "__main__":
    unittest.main()
