#!/usr/bin/env python3
"""Rebuild Blitz app.asar with optional code prepended to src/index.js.

Status: EXPERIMENTAL / REJECTED. Kept for documentation.
The archive round-trips byte-identically and a no-op rebuild runs fine, but any
change to the content of src/index.js makes Blitz boot, run its update check,
then exit with crash.log containing "E6 Error.". Recomputing the per-file
SHA-256 integrity metadata does not help, so the check is app-level, not stock
Electron asar integrity.

Usage:
    python asar_inject.py --check                       # verify rebuild fidelity
    python asar_inject.py --inject payload.js --apply   # patch app.asar
    python asar_inject.py --restore                     # copy backup back

Paths default to the standard Blitz install and are overridable.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import struct
import sys

DEFAULT_ASAR = os.path.join(
    os.environ.get("LOCALAPPDATA", ""), "Programs", "Blitz", "resources", "app.asar"
)
MARK = "/*BLITZ_NOADS*/"
BLOCK_SIZE = 4194304


def load(path):
    """Parse an asar archive into (header dict, data section bytes)."""
    with open(path, "rb") as fh:
        pre = fh.read(16)
        _, total, _, raw_len = struct.unpack("<IIII", pre)
        raw = fh.read(raw_len)
        pad = (total - 8) - raw_len
        fh.read(pad)
        header = json.loads(raw)
        data = fh.read()
    return header, data


def walk(node, path, out):
    for name, child in node.get("files", {}).items():
        current = path + "/" + name if path else name
        if "files" in child:
            walk(child, current, out)
        elif "link" in child or child.get("unpacked"):
            continue
        elif "size" in child:
            out.append((int(child["offset"]), current, child))
    return out


def integrity(data):
    blocks = [
        hashlib.sha256(data[i : i + BLOCK_SIZE]).hexdigest()
        for i in range(0, len(data), BLOCK_SIZE)
    ]
    return {
        "algorithm": "SHA256",
        "hash": hashlib.sha256(data).hexdigest(),
        "blockSize": BLOCK_SIZE,
        "blocks": blocks,
    }


def write_archive(path, header, blob):
    raw = json.dumps(header, separators=(",", ":")).encode("utf-8")
    padded = raw + b"\x00" * ((4 - len(raw) % 4) % 4)
    head = (
        struct.pack("<I", 4)
        + struct.pack("<I", len(padded) + 8)
        + struct.pack("<I", len(padded) + 4)
        + struct.pack("<I", len(raw))
    )
    tmp = path + ".new"
    with open(tmp, "wb") as fh:
        fh.write(head)
        fh.write(padded)
        fh.write(blob)
    os.replace(tmp, path)


def build(source, target, prefix=None, target_file="src/index.js"):
    header, data = load(source)
    entries = sorted(walk(header, "", []), key=lambda e: e[0])
    found = [e for e in entries if e[1] == target_file]
    if not found:
        raise SystemExit("target %s not found in archive" % target_file)

    node = found[0][2]
    size = int(node["size"])
    original = data[int(node["offset"]) : int(node["offset"]) + size]
    if prefix and MARK.encode() in original:
        raise SystemExit("archive already patched")

    blob = bytearray()
    for offset, name, meta in entries:
        content = data[offset : offset + int(meta["size"])]
        if name == target_file:
            if prefix:
                content = prefix.encode("utf-8") + content
                meta["size"] = len(content)
                meta["integrity"] = integrity(content)
        meta["offset"] = str(len(blob))
        blob += content

    write_archive(target, header, bytes(blob))
    return len(blob)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--asar", default=DEFAULT_ASAR)
    ap.add_argument("--backup")
    ap.add_argument("--check", action="store_true", help="rebuild and compare file payloads")
    ap.add_argument("--inject", help="JavaScript file to prepend to src/index.js")
    ap.add_argument("--apply", action="store_true", help="actually overwrite app.asar")
    ap.add_argument("--restore", action="store_true")
    args = ap.parse_args()

    asar = os.path.abspath(args.asar)
    backup = args.backup or asar + ".backup"
    if not os.path.exists(backup) and not args.restore:
        raise SystemExit("backup missing: %s (create one before patching)" % backup)

    if args.restore:
        shutil.copy2(backup, asar)
        print("restored %s from %s" % (asar, backup))
        return 0

    if args.check:
        out = asar + ".check"
        build(backup, out)
        head_a, data_a = load(backup)
        head_b, data_b = load(out)
        left = {p: data_a[o : o + int(m["size"])] for o, p, m in walk(head_a, "", [])}
        bad = 0
        for o, p, m in walk(head_b, "", []):
            chunk = data_b[o : o + int(m["size"])]
            if chunk != left.get(p):
                bad += 1
        os.remove(out)
        print("files=%d mismatched=%d" % (len(left), bad))
        return 0 if bad == 0 else 1

    prefix = None
    if args.inject:
        with open(args.inject, encoding="utf-8") as fh:
            prefix = fh.read()
    elif not args.apply:
        ap.error("pass --inject FILE, --check or --restore")

    out = os.path.join(os.path.dirname(asar), "app.patched.asar")
    size = build(backup, out, prefix)
    print("built %s (data=%d bytes)" % (out, size))
    if args.apply:
        shutil.copy2(out, asar)
        print("applied to %s" % asar)
    return 0


if __name__ == "__main__":
    sys.exit(main())
