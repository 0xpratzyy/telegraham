#!/usr/bin/env python3
"""Redacted credential-pattern gate. No matched bytes are ever printed."""
import argparse
from pathlib import Path
import re
import subprocess
import sys

PATTERNS = {
    'provider key': re.compile(rb'(?:sk-(?:ant-)?[A-Za-z0-9_-]{40,}|AIza[0-9A-Za-z_-]{35}|sntrys_[A-Za-z0-9+/=_-]{20,})'),
    'Slack token': re.compile(rb'xox[baprs]-[A-Za-z0-9-]{24,}'),
    'private key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'Telegram hash': re.compile(rb'(?i)(?:api_?hash|PIDGY_TG_API_HASH)\s*[=:]\s*[\"\x27]?[a-f0-9]{32}'),
}
SAMPLE_HASH = b'abcdef0123456789abcdef0123456789'

def findings(data, path):
    if b'\x00' in data: return []
    hits = []
    for label, pattern in PATTERNS.items():
        for match in pattern.finditer(data):
            if label == 'Telegram hash' and path.endswith('.template') and SAMPLE_HASH in match.group(): continue
            hits.append((data.count(b'\n', 0, match.start()) + 1, label))
    return hits

def candidates(root):
    if (root / '.git').exists():
        result = subprocess.run(['git', '-C', str(root), 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], check=True, capture_output=True)
        return sorted(set(result.stdout.decode().split('\0')) - {''})
    return [str(p.relative_to(root)) for p in root.rglob('*') if p.is_file() and not p.is_symlink()]

def scan(root):
    hits = []
    for relative in candidates(root):
        path = root / relative
        if not path.is_file() or path.is_symlink(): continue
        for line, label in findings(path.read_bytes(), relative): hits.append((relative, line, label))
    return hits

def history(root):
    listing = subprocess.run(['git', '-C', str(root), 'rev-list', '--objects', '--all'], check=True, capture_output=True).stdout.decode().splitlines()
    hits = []; count = 0
    process = subprocess.Popen(['git', '-C', str(root), 'cat-file', '--batch'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        for item in listing:
            parts = item.split(' ', 1)
            if len(parts) != 2: continue
            oid, path = parts
            process.stdin.write((oid + '\n').encode()); process.stdin.flush()
            header = process.stdout.readline().decode().split()
            size = int(header[2]); data = process.stdout.read(size); process.stdout.read(1)
            if header[1] != 'blob': continue
            count += 1
            for line, label in findings(data, path): hits.append((oid[:12] + ':' + path, line, label))
    finally:
        process.stdin.close(); process.wait()
    print(f'History scan: {count} blobs; {len(hits)} credential-pattern findings (content redacted).')
    return hits

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--history', action='store_true')
    args = parser.parse_args(); root = args.root.resolve()
    hits = history(root) if args.history else scan(root)
    for path, line, label in hits: print(f'{path}:{line}: {label} [REDACTED]', file=sys.stderr)
    print(f'Credential-pattern scan: {len(hits)} findings. This is a pattern gate, not a guarantee of no secrets.')
    sys.exit(bool(hits))
