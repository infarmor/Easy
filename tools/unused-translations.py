#!/usr/bin/env python3
"""Lists English translations whose Russian text no longer appears anywhere in Sources or Harness.

When an interface string is reworded, its old entry stays in Translations.swift and nothing notices. Keys with
interpolations ({0}, {1}…) are skipped: in code they are spelled with \\(…), not as the key.

    python3 tools/unused-translations.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TRANSLATIONS = os.path.join(ROOT, "Sources", "SwiftLite", "Support", "Translations.swift")
KEY = re.compile(r'^        "((?:[^"\\]|\\.)*)": "', re.M)


def code():
    parts = []
    for folder in ("Sources", "Harness"):
        for root, _, names in os.walk(os.path.join(ROOT, folder)):
            for name in names:
                path = os.path.join(root, name)
                if name.endswith(".swift") and path != TRANSLATIONS:
                    with open(path, encoding="utf-8") as f:
                        parts.append(f.read())
    return "\n".join(parts)


def main():
    with open(TRANSLATIONS, encoding="utf-8") as f:
        keys = KEY.findall(f.read())
    text = code()
    unused = [k for k in keys if "{" not in k and k not in text]
    for key in unused:
        print(key)
    print(f"\n{len(unused)} из {len(keys)} переводов не используются", file=sys.stderr)
    return 1 if unused else 0


if __name__ == "__main__":
    sys.exit(main())
