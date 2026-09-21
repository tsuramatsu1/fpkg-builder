#!/usr/bin/env python3
"""Talk to a jailbroken PS5 over the payload FTP server (default port 2121).

Subcommands
-----------
info    read an installed title's app.json and the digest of its app.pkg
pull    copy a file off the console (e.g. the base package on USB)
push    copy a file onto the console (e.g. the finished update)
ls      list a directory

``info`` exists to answer one question before a build: is the reference package
on the PC the same image the console actually installed?  A delta built against
any other copy fails with CE-107891-6.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from ftplib import FTP
from pathlib import Path

DIGEST_OFFSET = 0x30
DIGEST_LENGTH = 32
DEFAULT_PORT = 2121


def connect(host: str, port: int, timeout: float) -> FTP:
    ftp = FTP()
    ftp.connect(host, port, timeout=timeout)
    ftp.login()
    return ftp


def read_range(ftp: FTP, path: str, length: int) -> bytes:
    """Read the first ``length`` bytes, aborting the transfer once satisfied."""
    buffer = bytearray()

    class _Enough(Exception):
        pass

    def collect(chunk: bytes) -> None:
        buffer.extend(chunk)
        if len(buffer) >= length:
            raise _Enough

    try:
        ftp.retrbinary(f"RETR {path}", collect, blocksize=4096)
    except _Enough:
        # The control channel is now out of step; reconnecting is the caller's job.
        pass
    return bytes(buffer[:length])


def read_text(ftp: FTP, path: str) -> str | None:
    buffer = bytearray()
    try:
        ftp.retrbinary(f"RETR {path}", buffer.extend)
    except Exception:
        return None
    return buffer.decode("utf-8", "replace")


def cmd_info(args: argparse.Namespace) -> int:
    root = f"/user/app/{args.title_id}"
    result: dict = {"host": args.host, "titleId": args.title_id, "installed": False}

    ftp = connect(args.host, args.port, args.timeout)
    listing: list[str] = []
    try:
        ftp.retrlines(f"LIST {root}", listing.append)
    except Exception as error:
        result["error"] = f"{root}: {error}"
        json.dump(result, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 1

    entries = {}
    for line in listing:
        parts = line.split(None, 8)
        if len(parts) >= 9 and parts[8] not in (".", ".."):
            entries[parts[8]] = int(parts[4])
    result["installed"] = "app.pkg" in entries
    result["entries"] = entries

    raw = read_text(ftp, f"{root}/app.json")
    ftp.close()
    if raw:
        try:
            app = json.loads(raw)
        except json.JSONDecodeError:
            app = None
        if app:
            result["appJson"] = app
            pieces = app.get("pieces") or []
            if pieces:
                result["installedFrom"] = pieces[0].get("url")

    if result["installed"]:
        # Fresh connection: read_range leaves the previous one mid-transfer.
        ftp = connect(args.host, args.port, args.timeout)
        head = read_range(ftp, f"{root}/app.pkg", DIGEST_OFFSET + DIGEST_LENGTH)
        ftp.close()
        result["magic"] = head[:4].decode("latin-1")
        result["digest"] = head[DIGEST_OFFSET : DIGEST_OFFSET + DIGEST_LENGTH].hex().upper()

    if args.expect_digest and result.get("digest"):
        want = args.expect_digest.strip().upper()
        result["expectedDigest"] = want
        result["digestMatches"] = result["digest"] == want

    json.dump(result, sys.stdout, indent=2)
    sys.stdout.write("\n")
    if args.expect_digest:
        return 0 if result.get("digestMatches") else 3
    return 0


def _progress(label: str, done: int, total: int, started: float) -> None:
    elapsed = max(time.time() - started, 1e-6)
    rate = done / elapsed / 1e6
    if total:
        pct = done * 100.0 / total
        sys.stderr.write(f"\r{label} {pct:5.1f}%  {done/1e6:8.1f} MB  {rate:6.1f} MB/s")
    else:
        sys.stderr.write(f"\r{label} {done/1e6:8.1f} MB  {rate:6.1f} MB/s")
    sys.stderr.flush()


def cmd_pull(args: argparse.Namespace) -> int:
    ftp = connect(args.host, args.port, args.timeout)
    try:
        total = ftp.size(args.remote) or 0
    except Exception:
        total = 0
    destination = Path(args.local)
    destination.parent.mkdir(parents=True, exist_ok=True)
    started = time.time()
    done = [0]
    with destination.open("wb") as handle:
        def collect(chunk: bytes) -> None:
            handle.write(chunk)
            done[0] += len(chunk)
            _progress("pull", done[0], total, started)
        ftp.retrbinary(f"RETR {args.remote}", collect, blocksize=1 << 20)
    ftp.close()
    sys.stderr.write("\n")
    print(json.dumps({"pulled": args.remote, "to": str(destination), "bytes": done[0]}, indent=2))
    return 0


def cmd_push(args: argparse.Namespace) -> int:
    source = Path(args.local)
    if not source.is_file():
        raise SystemExit(f"error: not a file: {source}")
    total = source.stat().st_size
    ftp = connect(args.host, args.port, args.timeout)
    started = time.time()
    done = [0]
    with source.open("rb") as handle:
        class _Reader:
            def read(self, size: int = 1 << 20) -> bytes:
                chunk = handle.read(size)
                done[0] += len(chunk)
                _progress("push", done[0], total, started)
                return chunk
        ftp.storbinary(f"STOR {args.remote}", _Reader(), blocksize=1 << 20)
    sys.stderr.write("\n")

    verified = None
    if args.verify:
        head = read_range(ftp, args.remote, 4)
        verified = head[:4].decode("latin-1")
    ftp.close()
    print(json.dumps({"pushed": str(source), "to": args.remote,
                      "bytes": done[0], "magic": verified}, indent=2))
    return 0


def cmd_ls(args: argparse.Namespace) -> int:
    ftp = connect(args.host, args.port, args.timeout)
    lines: list[str] = []
    ftp.retrlines(f"LIST {args.remote}", lines.append)
    ftp.close()
    for line in lines:
        parts = line.split(None, 8)
        if len(parts) >= 9 and parts[8] not in (".", ".."):
            print(line)
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--timeout", type=float, default=30.0)
    sub = parser.add_subparsers(dest="command", required=True)

    info = sub.add_parser("info", help="inspect an installed title")
    info.add_argument("--title-id", required=True)
    info.add_argument("--expect-digest", help="exit 3 unless the installed digest matches")
    info.set_defaults(func=cmd_info)

    pull = sub.add_parser("pull", help="copy a file off the console")
    pull.add_argument("--remote", required=True)
    pull.add_argument("--local", required=True)
    pull.set_defaults(func=cmd_pull)

    push = sub.add_parser("push", help="copy a file onto the console")
    push.add_argument("--local", required=True)
    push.add_argument("--remote", required=True)
    push.add_argument("--verify", action="store_true")
    push.set_defaults(func=cmd_push)

    listing = sub.add_parser("ls", help="list a directory")
    listing.add_argument("--remote", required=True)
    listing.set_defaults(func=cmd_ls)

    args = parser.parse_args()
    raise SystemExit(args.func(args))


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as error:  # noqa: BLE001 - keep GUI output readable
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
