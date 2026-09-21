#!/usr/bin/env python3
"""Introspect a Prospero package.

Reports the container magic, the package digest the patch machinery validates
against (FIH header +0x30) and the root param.json fields, as JSON on stdout.

The digest matters more than it looks: a delta package built with
``img_create --ref_pkg_path`` records the reference package's digest, and the
installed ``app.pkg`` on the console preserves its source package's digest in
the same place.  If they differ the console refuses the update with
CE-107891-6 and logs ``[DbgInstall][ERROR] [0x80b21165][DigestErr]``.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

DIGEST_OFFSET = 0x30
DIGEST_LENGTH = 32
# param.json sits ~99.7% into a package, never at the head.  Walk back from EOF
# in windows rather than scanning forward through gigabytes of PFS payload.
TAIL_WINDOW = 64 * 1024 * 1024
MAX_TAIL = 1024 * 1024 * 1024
MAX_OBJECT = 64 * 1024

MAGICS = {
    b"\x7fFIH": "ps5",           # Prospero package
    b"\x7fLIH": "ps5-delta",     # compact patch / delta against a reference
    b"\x7fCNT": "ps4",           # Orbis package
}


def container(data: bytes) -> tuple[str, str]:
    magic = data[:4]
    return magic.decode("latin-1"), MAGICS.get(magic, "unknown")


def digest(handle) -> str:
    handle.seek(DIGEST_OFFSET)
    return handle.read(DIGEST_LENGTH).hex().upper()


def _root_object(window: bytes) -> dict | None:
    """Recover the root param.json object from a window of package bytes.

    The entry-name table continues past ``param.json`` with other filenames, so
    anchoring on the filename fails.  Anchor on the root-level ``titleId`` key
    and walk back over candidate opening braces until one parses whole.
    """
    start = 0
    best: dict | None = None
    while True:
        marker = window.find(b'"titleId"', start)
        if marker < 0:
            return best
        start = marker + 1
        for open_brace in range(marker, max(0, marker - MAX_OBJECT), -1):
            if window[open_brace : open_brace + 1] != b"{":
                continue
            depth = 0
            end = -1
            for cursor in range(open_brace, min(open_brace + MAX_OBJECT, len(window))):
                char = window[cursor : cursor + 1]
                if char == b"{":
                    depth += 1
                elif char == b"}":
                    depth -= 1
                    if depth == 0:
                        end = cursor
                        break
            if end < 0:
                continue
            try:
                parsed = json.loads(window[open_brace : end + 1].decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            if isinstance(parsed, dict) and "titleId" in parsed:
                best = parsed
                break
    return best


def param_json(path: Path) -> dict | None:
    size = path.stat().st_size
    with path.open("rb") as handle:
        window = TAIL_WINDOW
        while window <= MAX_TAIL:
            offset = max(0, size - window)
            handle.seek(offset)
            found = _root_object(handle.read())
            if found is not None:
                return found
            if offset == 0:
                return None
            window *= 2
    return None


def contains(path: Path, needle: bytes) -> int:
    """Count occurrences of a byte string, streaming so huge files are fine."""
    hits = 0
    overlap = len(needle) - 1
    tail = b""
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(8 * 1024 * 1024)
            if not chunk:
                break
            buffer = tail + chunk
            hits += buffer.count(needle)
            tail = buffer[-overlap:] if overlap else b""
    return hits


def describe(path: Path, want_param: bool = True) -> dict:
    with path.open("rb") as handle:
        head = handle.read(64)
        magic, kind = container(head)
        result: dict = {
            "path": str(path),
            "size": path.stat().st_size,
            "magic": magic,
            "kind": kind,
            # Only a full FIH package carries its digest here.  A delta uses a
            # different header layout, so reporting +0x30 for one would be a
            # meaningless number that looks authoritative.
            "digest": digest(handle) if kind == "ps5" else None,
        }
    if want_param:
        param = param_json(path)
        if param:
            result["param"] = {
                key: param.get(key)
                for key in (
                    "titleId",
                    "contentId",
                    "contentVersion",
                    "originContentVersion",
                    "targetContentVersion",
                    "requiredSystemSoftwareVersion",
                )
            }
            localized = param.get("localizedParameters") or {}
            default = localized.get(localized.get("defaultLanguage") or "", {})
            result["param"]["titleName"] = default.get("titleName")
        else:
            result["param"] = None
    return result


def next_version(current: str | None) -> str | None:
    """Bump the last field of an ``NN.NNN.NNN`` content version."""
    if not current:
        return None
    parts = current.split(".")
    if len(parts) != 3 or not all(p.isdigit() for p in parts):
        return None
    major, minor, patch = parts
    patch_value = int(patch) + 1
    if patch_value < 10 ** len(patch):
        return f"{major}.{minor}.{patch_value:0{len(patch)}d}"
    minor_value = int(minor) + 1
    return f"{major}.{minor_value:0{len(minor)}d}.{'0' * len(patch)}"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--no-param", action="store_true",
                        help="report only the container and digest")
    parser.add_argument("--contains-digest", metavar="HEX",
                        help="also count occurrences of this digest in the file")
    parser.add_argument("--next-version", action="store_true",
                        help="include the next usable contentVersion")
    args = parser.parse_args()

    if not args.package.is_file():
        raise SystemExit(f"error: not a file: {args.package}")

    info = describe(args.package, want_param=not args.no_param)
    if args.contains_digest:
        raw = args.contains_digest.strip()
        try:
            needle = bytes.fromhex(raw)
        except ValueError:
            raise SystemExit(f"error: not hex: {raw}")
        info["digestOccurrences"] = contains(args.package, needle)
    if args.next_version:
        current = (info.get("param") or {}).get("contentVersion")
        info["nextContentVersion"] = next_version(current)
    json.dump(info, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # noqa: BLE001 - surface a clean message to the GUI
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
