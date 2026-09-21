#!/usr/bin/env python3
"""Summarise what a built package actually carries.

Reads the ``.naps_metric.json`` the publisher emits beside a package.  Its
``files`` key is a table whose first row is the header; rows whose ``state`` is
not ``unchanged`` are the files the package carries, and ``new-cbytes`` is what
each contributes.  Everything else is referenced from the reference image.

This is the only honest way to answer "is this really just the backport?" - the
package's size on disk is dominated by PFS and PlayGo metadata for the whole
title and says nothing useful about the payload.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("metric", type=Path, help="path to <package>.naps_metric.json")
    parser.add_argument("--json", action="store_true", help="emit JSON instead of a table")
    args = parser.parse_args()

    if not args.metric.is_file():
        raise SystemExit(f"error: not a file: {args.metric}")

    data = json.loads(args.metric.read_text(encoding="utf-8-sig"))
    rows = data.get("files") or []
    if not rows:
        raise SystemExit("error: metric file has no 'files' table")

    header = rows[0]
    name_at = 0
    state_at = header.index("state")
    new_at = header.index("new-cbytes")

    carried = [r for r in rows[1:] if r[state_at] != "unchanged"]
    carried.sort(key=lambda r: -r[new_at])
    referenced = len(rows) - 1 - len(carried)
    deleted = len(data.get("files-deleted") or [])
    payload = sum(r[new_at] for r in carried)

    if args.json:
        json.dump({
            "carried": [{"name": r[name_at], "state": r[state_at], "bytes": r[new_at]}
                        for r in carried],
            "payloadBytes": payload,
            "referencedFromBase": referenced,
            "deleted": deleted,
        }, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return

    for row in carried:
        print(f"{row[name_at]:<34} {row[state_at]:<9} {row[new_at]:>12,}")
    print(f"{'payload total':<34} {'':<9} {payload:>12,}")
    print(f"referenced from base: {referenced}   deleted: {deleted}")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as error:  # noqa: BLE001
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
