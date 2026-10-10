#!/usr/bin/env python3
"""Lists functions and types declared in Sources but never named anywhere else.

Not a verdict — a pointer. A name can be reached through a selector, an `@objc` bridge, a SwiftUI
body-builder, or a protocol requirement, and those do not mention the name textually. Read each hit before
deleting it; last time this reported six, and one was genuinely dead.

    python3 tools/unused-symbols.py
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Sources")
DECLARATION = re.compile(r"\b(?:func|struct|class|enum|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)")
KEYWORDS = {"init", "deinit", "get", "set", "body", "subscript"}


def swift_files():
    for root, _, names in os.walk(ROOT):
        for name in names:
            if name.endswith(".swift"):
                yield os.path.join(root, name)


def main():
    texts = {path: open(path, encoding="utf-8").read() for path in swift_files()}
    declared = {}
    for path, text in texts.items():
        for line_number, line in enumerate(text.splitlines(), 1):
            match = DECLARATION.search(line)
            if not match:
                continue
            name = match.group(1)
            if name in KEYWORDS:
                continue
            declared.setdefault(name, []).append((path, line_number))

    unused = []
    for name, sites in declared.items():
        pattern = re.compile(r"\b" + re.escape(name) + r"\b")
        uses = 0
        for path, text in texts.items():
            for line_number, line in enumerate(text.splitlines(), 1):
                if pattern.search(line) and (path, line_number) not in sites:
                    uses += 1
        if uses == 0:
            unused.append((name, sites[0]))

    for name, (path, line) in sorted(unused):
        print(f"{os.path.relpath(path, ROOT)}:{line}  {name}")
    print(f"\n{len(unused)} из {len(declared)} имён не встречаются больше нигде")
    return 0


if __name__ == "__main__":
    sys.exit(main())
