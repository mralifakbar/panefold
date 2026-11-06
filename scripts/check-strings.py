#!/usr/bin/env python3
"""Checks every translation: same keys as the source, and the same format specifiers in each value.

A value whose specifiers don't match its key can crash the app when it's formatted, so CI runs this.
"""
import pathlib, re, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPEC = re.compile(r'%(?:\d+\$)?(@|lld|ld|d|lf|f)')
LINE = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')

def specs(s):
    return sorted(m.group(1) for m in SPEC.finditer(s.replace("%%", "")))

source = subprocess.run([sys.executable, str(ROOT / "scripts/extract-strings.py")], capture_output=True, text=True, check=True).stdout
want = {m.group(1) for line in source.splitlines() if (m := LINE.match(line))}
failed = False
for f in sorted(ROOT.glob("Resources/*.lproj/Localizable.strings")):
    have = {}
    for n, line in enumerate(f.read_text().splitlines(), 1):
        if not line.strip() or line.startswith("/*") or line.startswith("//"):
            continue
        m = LINE.match(line)
        if not m:
            print(f"{f}:{n}: can't read this line"); failed = True; continue
        k, v = m.groups()
        have[k] = v
        if specs(k) != specs(v):
            print(f"{f}:{n}: format specifiers differ from the key"); failed = True
    missing = want - set(have)
    if missing:
        print(f"{f}: {len(missing)} strings not translated (they show in English), e.g. {sorted(missing)[:3]}")
    print(f"{f.parent.name}: {len(have)} strings")
sys.exit(1 if failed else 0)
