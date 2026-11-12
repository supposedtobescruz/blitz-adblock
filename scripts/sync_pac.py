#!/usr/bin/env python3
"""Keep the PAC artifacts in sync with the installed Blitz version.

Blitz updates itself in place (electron-updater rewrites
%LOCALAPPDATA%\\Programs\\Blitz\\resources\\app.asar). When the version or the
domain list changes, the PAC files and the data: URL must be rebuilt, otherwise
a stale URL keeps launching Blitz with an outdated block list.

State is kept in build/.state.json. Running this is cheap and idempotent, so the
launcher and a logon scheduled task can both call it.

Usage:
    python sync_pac.py            # regenerate only when needed
    python sync_pac.py --force    # always regenerate
    python sync_pac.py --quiet    # no stdout unless something changed

Exit codes: 0 = up to date or regenerated, 1 = error.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from make_pac import compact_pac, data_url, full_pac, load_domains  # noqa: E402

DEFAULT_ASAR = os.path.join(
    os.environ.get("LOCALAPPDATA", ""), "Programs", "Blitz", "resources", "app.asar"
)


def blitz_version(asar_path: str) -> str:
    """Read package.json out of app.asar without extracting the archive."""
    with open(asar_path, "rb") as fh:
        prefix = fh.read(16)
        _, total, _, raw_len = struct.unpack("<IIII", prefix)
        raw = fh.read(raw_len)
        pad = (total - 8) - raw_len
        fh.read(pad)
        header = json.loads(raw)
        data_start = 16 + (total - 8)

        node = header.get("files", {}).get("package.json")
        if not node:
            raise ValueError("package.json missing from asar")
        fh.seek(data_start + int(node["offset"]))
        package = json.loads(fh.read(int(node["size"])).decode("utf-8"))
    return str(package.get("version", "unknown"))


def file_digest(path: str) -> str:
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--asar", default=DEFAULT_ASAR)
    ap.add_argument("--domains", default=os.path.join(HERE, "..", "domains.txt"))
    ap.add_argument("--out", default=os.path.join(HERE, "..", "build"))
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    def say(message: str) -> None:
        if not args.quiet:
            print(message)

    asar = os.path.abspath(args.asar)
    out_dir = os.path.abspath(args.out)
    state_path = os.path.join(out_dir, ".state.json")

    try:
        version = blitz_version(asar)
    except FileNotFoundError:
        print("ERROR: Blitz app.asar not found: %s" % asar, file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001 - report and let caller continue
        print("ERROR: cannot read Blitz version: %s" % exc, file=sys.stderr)
        return 1

    domains = load_domains(os.path.abspath(args.domains))
    if not domains:
        print("ERROR: domain list empty", file=sys.stderr)
        return 1
    digest = hashlib.sha256("\n".join(domains).encode()).hexdigest()

    state = {}
    if os.path.exists(state_path):
        try:
            with open(state_path, encoding="utf-8") as fh:
                state = json.load(fh)
        except (OSError, ValueError):
            state = {}

    artifacts = ["blitz.pac", "blitz-min.pac", "blitz-pac-url.txt"]
    missing = [a for a in artifacts if not os.path.exists(os.path.join(out_dir, a))]

    if not args.force and not missing and state.get("version") == version and state.get("domains") == digest:
        say("up to date: Blitz %s, %d domains" % (version, len(domains)))
        return 0

    os.makedirs(out_dir, exist_ok=True)

    previous_version = state.get("version")
    pac = full_pac(domains)
    mini = compact_pac(domains)
    url = data_url(mini)
    for name, text in zip(artifacts, (pac, mini, url)):
        with open(os.path.join(out_dir, name), "w", encoding="ascii") as fh:
            fh.write(text)

    with open(state_path, "w", encoding="utf-8") as fh:
        json.dump(
            {
                "version": version,
                "domains": digest,
                "domain_count": len(domains),
                "asar": file_digest(asar),
                "generated": __import__("datetime").datetime.now().isoformat(timespec="seconds"),
            },
            fh,
            indent=2,
        )

    if previous_version and previous_version != version:
        marker = os.path.join(out_dir, ".cache-clear")
        try:
            with open(marker, "w", encoding="utf-8") as fh:
                fh.write(version)
            print("note: Blitz %s -> %s, cache-clear marker written" % (previous_version, version))
        except OSError as exc:
            print("note: could not write %s: %s" % (marker, exc))

    print(
        "regenerated: Blitz %s, %d domains, url %d chars"
        % (version, len(domains), len(url))
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
