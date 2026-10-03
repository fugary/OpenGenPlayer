#!/usr/bin/env python3
"""Audit GenPlayer Localizable.strings files against the English key set."""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
from collections import OrderedDict


ENTRY_RE = re.compile(r'^\s*"((?:\\"|[^"])*)"\s*=\s*"((?:\\"|[^"])*)"\s*;\s*$')


def parse_strings_file(path: pathlib.Path) -> OrderedDict[str, str]:
    entries: OrderedDict[str, str] = OrderedDict()
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("//") or line.startswith("/*") or line.startswith("*") or line.startswith("*/"):
            continue
        match = ENTRY_RE.match(line)
        if not match:
            continue
        key = match.group(1).replace('\\"', '"')
        value = match.group(2).replace('\\"', '"')
        entries[key] = value
    return entries


def find_locale_files(resources_dir: pathlib.Path) -> list[pathlib.Path]:
    return sorted(resources_dir.glob("*.lproj/Localizable.strings"))


def audit(resources_dir: pathlib.Path, base_locale: str) -> int:
    locale_files = find_locale_files(resources_dir)
    if not locale_files:
        print(f"No Localizable.strings files found under {resources_dir}", file=sys.stderr)
        return 2

    base_path = resources_dir / f"{base_locale}.lproj" / "Localizable.strings"
    if not base_path.exists():
        print(f"Base locale file not found: {base_path}", file=sys.stderr)
        return 2

    base_entries = parse_strings_file(base_path)
    base_keys = list(base_entries.keys())
    failed = False

    print(f"Base locale: {base_locale}")
    print(f"Base file: {base_path}")
    print(f"Base key count: {len(base_keys)}")
    print("")

    for locale_path in locale_files:
        locale = locale_path.parent.name.replace(".lproj", "")
        entries = parse_strings_file(locale_path)
        keys = set(entries.keys())
        missing = [key for key in base_keys if key not in keys]
        extra = sorted(keys - set(base_keys))
        empty = [key for key, value in entries.items() if value == ""]
        placeholders = [key for key, value in entries.items() if key.startswith("Onboarding ") and value == key]

        print(f"[{locale}] total={len(entries)} missing={len(missing)} extra={len(extra)} empty={len(empty)} placeholders={len(placeholders)}")
        if missing:
            failed = True
            print("  Missing:")
            for key in missing[:20]:
                print(f"    - {key}")
            if len(missing) > 20:
                print(f"    ... and {len(missing) - 20} more")
        if extra:
            failed = True
            print("  Extra:")
            for key in extra[:20]:
                print(f"    - {key}")
            if len(extra) > 20:
                print(f"    ... and {len(extra) - 20} more")
        if empty:
            failed = True
            print("  Empty:")
            for key in empty[:20]:
                print(f"    - {key}")
            if len(empty) > 20:
                print(f"    ... and {len(empty) - 20} more")
        if placeholders:
            failed = True
            print("  Onboarding keys used as display text:")
            for key in placeholders[:20]:
                print(f"    - {key}")
            if len(placeholders) > 20:
                print(f"    ... and {len(placeholders) - 20} more")
        print("")

    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", default=".", help="Path to the GenPlayer project root.")
    parser.add_argument("--resources-dir", help="Optional explicit path to the Resources directory.")
    parser.add_argument("--base-locale", default="en", help="Base locale used as the canonical key set.")
    args = parser.parse_args()

    if args.resources_dir:
        resources_dir = pathlib.Path(args.resources_dir).resolve()
    else:
        resources_dir = pathlib.Path(args.project_root).resolve() / "GenPlayer" / "Source" / "Resources"

    return audit(resources_dir, args.base_locale)


if __name__ == "__main__":
    raise SystemExit(main())
