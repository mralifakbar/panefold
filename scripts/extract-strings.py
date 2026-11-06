#!/usr/bin/env python3
"""Lists every interface string in Sources/Panefold as Localizable.strings keys (English).

    python3 scripts/extract-strings.py > build/en.strings

Interpolations become format specifiers the way Swift builds localization keys:
whole numbers become %lld, everything else %@. Keep translations' specifiers identical.
"""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent / "Sources" / "Panefold"
# Calls whose first string literal SwiftUI or Foundation localize.
CALLS = r'(?:String\(localized:\s*|Text\(|Label\(|Button\(|Toggle\(|Picker\(|TextField\(|Menu\(|\.help\(|action\(|Link\()'
LITERAL = r'"((?:[^"\\]|\\.)*)"'
INT_HINT = re.compile(r'^(n|count|actual|moved|fewer|i|Int\(.*\)|.*\.count|.*capacity.*|LayoutBuilder\.hardLimit.*|\$0|runner\.secondsLeft)$')

def keyify(s):
    out, i = "", 0
    while i < len(s):
        if s.startswith("\\(", i):
            depth, j = 1, i + 2
            while depth and j < len(s):
                depth += {"(": 1, ")": -1}.get(s[j], 0)
                j += 1
            expr = s[i + 2:j - 1].strip()
            out += "%lld" if INT_HINT.match(expr) else "%@"
            i = j
        else:
            out += s[i]
            i += 1
    return out

keys = {}
for path in sorted(ROOT.rglob("*.swift")):
    text = path.read_text()
    for m in re.finditer(CALLS + LITERAL, text):
        raw = m.group(1)
        if not raw.strip() or raw.startswith("x-apple") or raw in ("", "Panefold"):
            continue
        key = keyify(raw)
        if re.fullmatch(r'[\W\d%@ld]*', key):  # symbols only, like "⌃⌥" or "%lld"
            continue
        keys.setdefault(key, path.name)

for key in sorted(keys):
    k = key.replace('"', '\\"') if '\\"' not in key else key
    print(f'"{k}" = "{k}";')
print(f"/* {len(keys)} strings */", file=sys.stderr)
