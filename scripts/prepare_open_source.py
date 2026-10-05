#!/usr/bin/env python3
"""Export a curated source snapshot, excluding private Git history and experiments."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
from datetime import datetime, timezone
from scan_secrets import scan

TREES = ('Sources', 'Tests', 'script', 'scripts', '.github', 'infra/ai-proxy', 'tools/WhatsAppBridge')
FILES = (
    'README.md', 'LICENSE', 'CONTRIBUTING.md', 'SECURITY.md', 'THIRD_PARTY_NOTICES.md',
    'project.yml', '.gitignore', '.gitattributes', 'Config/BetaSecrets.xcconfig',
    'Config/BetaSecrets.local.xcconfig.template',
    'Pidgy.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
    'docs/architecture.md', 'docs/multi-source-architecture.md', 'docs/predictive-search.md',
    'docs/chatgpt-sign-in.md', 'evals/product_prompt_oracle_v1.json',
    'tools/query_routing_probe.py', 'tools/product_prompt_oracle_bench.py',
    'tools/source_triage_gold_eval.py', 'tools/test_source_triage_gold_eval.py',
)
BLOCKED = {'.git', '.wrangler', '__pycache__', 'node_modules', 'bin', 'build', 'dist', '.build'}

def selected(root):
    files = set()
    for tree in TREES:
        for p in (root / tree).rglob('*'):
            rel = p.relative_to(root)
            if not p.is_file() or p.is_symlink() or set(rel.parts) & BLOCKED: continue
            if '.local.' in p.name or p.suffix in {'.db', '.sqlite', '.pyc', '.log', '.xcresult'}: continue
            files.add(rel)
    for item in FILES:
        p = root / item
        if p.is_file() and not p.is_symlink(): files.add(Path(item))
    return sorted(files)

def export(root, destination):
    root = root.resolve(); destination = destination.resolve()
    if destination.exists(): raise ValueError('Destination exists; choose a new snapshot path.')
    destination.mkdir(parents=True)
    for rel in selected(root):
        target = destination / rel; target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / rel, target)
    # Infrastructure identifiers belong to a deployment, not the source release.
    config = destination / 'infra/ai-proxy/wrangler.toml'
    if config.exists():
        import re
        config.write_text(re.sub(r'(?m)^id = "[a-f0-9]{32}"$', 'id = ""', config.read_text()))
    oss_config = destination / "Config/BetaSecrets.xcconfig"
    if oss_config.exists():
        oss_config.write_text(oss_config.read_text().replace("PIDGY_CHATGPT_OSS_ENABLED = NO", "PIDGY_CHATGPT_OSS_ENABLED = YES"))
    findings = scan(destination)
    if findings:
        shutil.rmtree(destination)
        raise ValueError(f'Snapshot rejected: {len(findings)} redacted credential-pattern findings.')
    manifest = {str(p.relative_to(destination)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted(destination.rglob('*')) if p.is_file()}
    (destination / 'SOURCE_MANIFEST.json').write_text(json.dumps({
        'createdAt': datetime.now(timezone.utc).isoformat(),
        'scope': 'Working-tree source snapshot. No Git history, local credentials, databases, or private evaluation corpus.',
        'credentialPatternFindings': 0, 'filesSHA256': manifest,
    }, indent=2) + '\n')
    archive = destination.with_suffix('.tar.gz')
    if archive.exists(): raise ValueError('Archive exists; choose a new snapshot path.')
    with tarfile.open(archive, 'w:gz') as tar:
        for name in [*manifest, 'SOURCE_MANIFEST.json']:
            tar.add(destination / name, arcname='Pidgy-source/' + name, recursive=False)
    return archive, len(manifest)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('Build/OpenSourceAudit/source-' + datetime.now().strftime('%Y%m%d-%H%M%S')))
    args = parser.parse_args()
    archive, count = export(Path(__file__).resolve().parents[1], args.output)
    print(f'Exported {count} audited source files: {archive}')
    print('Publish this snapshot as a fresh repository; the existing private Git history is not included or cleared for publication.')
