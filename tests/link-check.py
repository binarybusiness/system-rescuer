#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Mikael Moghadam (Binary Business)
"""Check that every relative link and image target in a tree's Markdown files
resolves to a file or directory inside the tree.

    tests/link-check.py <dir>

External links (any scheme) and bare anchors are ignored; anchors and queries
are stripped, not checked. Code spans and fenced blocks are skipped.
stdout: one "<file>\t<target>" line per broken link. Exit: 0 none, 1 some,
2 usage error.
"""
import os
import re
import sys
from urllib.parse import unquote

INLINE = re.compile(r'!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)')
REFDEF = re.compile(r'^\s{0,3}\[[^\]]+\]:\s*<?(\S+?)>?(?:\s+.*)?$')
HTML = re.compile(r'<(?:a|img)\b[^>]*?\b(?:href|src)=["\']([^"\']+)["\']', re.I)
SCHEME = re.compile(r'^[A-Za-z][A-Za-z0-9+.-]*:')


def targets(text):
    fence = None
    for line in text.splitlines():
        m = re.match(r'^\s*(```+|~~~+)', line)
        if m:
            if fence is None:
                fence = m.group(1)[0]
            elif m.group(1)[0] == fence:
                fence = None
            continue
        if fence:
            continue
        line = re.sub(r'`[^`]*`', '', line)
        yield from INLINE.findall(line)
        yield from HTML.findall(line)
        m = REFDEF.match(line)
        if m:
            yield m.group(1)


def main():
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        print("usage: tests/link-check.py <dir>", file=sys.stderr)
        return 2
    root = os.path.realpath(sys.argv[1])
    broken = 0
    for base, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d != '.git']
        for name in sorted(names):
            if not name.lower().endswith('.md'):
                continue
            path = os.path.join(base, name)
            rel = os.path.relpath(path, root)
            with open(path, encoding='utf-8', errors='replace') as fh:
                text = fh.read()
            for target in targets(text):
                if SCHEME.match(target) or target.startswith('#') or target.startswith('//'):
                    continue
                clean = unquote(re.split(r'[#?]', target, maxsplit=1)[0])
                if not clean:
                    continue
                full = os.path.join(root if clean.startswith('/') else base, clean.lstrip('/'))
                full = os.path.realpath(full)
                inside = full == root or full.startswith(root + os.sep)
                if not (inside and os.path.exists(full)):
                    print(f"{rel}\t{target}")
                    broken += 1
    return 1 if broken else 0


sys.exit(main())
