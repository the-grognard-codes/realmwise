import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
lock_path = root / 'pubspec.lock'
bom_path = root / 'bom.json'

lock_text = lock_path.read_text(encoding='utf-8')
blocks = re.findall(
    r'^  ([A-Za-z0-9_]+):\r?\n(.*?)(?=^  [A-Za-z0-9_]+:\r?\n|^sdks:)',
    lock_text,
    re.MULTILINE | re.DOTALL,
)
locked = {}
for name, block in blocks:
    version = re.search(r'^    version: "([^"]+)"\r?$', block, re.MULTILINE)
    source = re.search(r'^    source: ([^\r\n]+)\r?$', block, re.MULTILINE)
    sha = re.search(r'^      sha256: "?([0-9a-f]+)"?\r?$', block, re.MULTILINE)
    if version and source:
        locked[name] = {
            'version': version.group(1),
            'source': source.group(1),
            'sha256': sha.group(1) if sha else None,
        }

bom = json.loads(bom_path.read_text(encoding='utf-8'))
components = {c.get('name'): c for c in bom.get('components', []) if c.get('name')}
updated = 0
for name, pkg in locked.items():
    if name not in components:
        raise SystemExit(f'missing component in bom.json: {name}')

    component = components[name]
    if component.get('version') != pkg['version']:
        component['version'] = pkg['version']
        updated += 1

    if pkg['source'] == 'hosted':
        expected_hashes = [{'alg': 'SHA-256', 'content': pkg['sha256']}]
        if component.get('hashes') != expected_hashes:
            component['hashes'] = expected_hashes
            updated += 1
    else:
        if 'hashes' in component:
            del component['hashes']
            updated += 1

bom_path.write_text(json.dumps(bom, indent=2) + '\n', encoding='utf-8')
print(f'Updated {updated} BOM fields from {len(locked)} lockfile packages.')
