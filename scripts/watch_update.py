#!/usr/bin/env python3
"""Watch a Blitz launch for a self-update and restart it with a fresh PAC.

Started (hidden) by launch_noads.ps1 right after Blitz is launched. It tails the
Blitz app log for the updater verdict:

  * "Update ... is not available"  -> no update, exit immediately (typically
     within a few seconds of the launch).
  * "Found version ..." / download -> update in progress, keep watching.

While an update is pending it polls the installed app.asar version. When the
version changes it rebuilds the PAC (sync_pac.py), stops any Blitz process that
was relaunched without our `--proxy-pac-url`, and starts Blitz again with the new
PAC. Only one restart is ever performed.

If no update is pending the process exits and nothing is left running.

Usage (normally called by the launcher):
    python watch_update.py --since-bytes 123456 --log-boot-seconds 120
    python watch_update.py --disable            # no-op
Exit codes: 0 = nothing to do / handled, 1 = error.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
sys.path.insert(0, HERE)

ASAR = os.path.join(
    os.environ.get("LOCALAPPDATA", ""), "Programs", "Blitz", "resources", "app.asar"
)
EXE = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Programs", "Blitz", "Blitz.exe")
APP_LOG = os.path.join(os.environ.get("APPDATA", ""), "Blitz", "app.log")
PAC_URL = os.path.join(ROOT, "build", "blitz-pac-url.txt")
STATE = os.path.join(ROOT, "build", ".state.json")
WATCH_LOG = os.path.join(ROOT, "build", "update-watch.log")

NO_UPDATE = ("is not available", "not available (latest version", "checking for update failed")
UPDATE_FOUND = ("found version", "downloading update", "update downloaded", "update available", "new version")


def log(message: str) -> None:
    try:
        os.makedirs(os.path.dirname(WATCH_LOG), exist_ok=True)
        with open(WATCH_LOG, "a", encoding="utf-8") as fh:
            fh.write("[%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), message))
    except OSError:
        pass


def read_since(path: str, offset: int) -> tuple[list[str], int]:
    """Return appended lines and the new offset. Handles log rotation."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return [], offset
    if size < offset:
        offset = 0
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        fh.seek(offset)
        chunk = fh.read()
        offset = fh.tell()
    return chunk.splitlines(), offset


def classify(lines: list[str]) -> str | None:
    for line in lines:
        low = line.lower()
        if any(marker in low for marker in UPDATE_FOUND):
            return "update"
        if any(marker in low for marker in NO_UPDATE):
            return "none"
    return None


def installed_version(asar_path: str = ASAR) -> str | None:
    try:
        from sync_pac import blitz_version

        return blitz_version(asar_path)
    except Exception:  # noqa: BLE001 - version detection is best effort
        return None


def blitz_pids() -> list[int]:
    try:
        out = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq Blitz.exe", "/FO", "CSV", "/NH"],
            capture_output=True,
            text=True,
            timeout=20,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    pids = []
    for line in out.splitlines():
        match = re.match(r'"Blitz\.exe","(\d+)"', line.strip(), re.IGNORECASE)
        if match:
            pids.append(int(match.group(1)))
    return pids


def stop_blitz() -> None:
    log("stopping Blitz processes before restart")
    subprocess.run(["taskkill", "/F", "/T", "/IM", "Blitz.exe"], capture_output=True, timeout=60)
    for _ in range(20):
        if not blitz_pids():
            return
        time.sleep(1)


def sync_pac() -> bool:
    try:
        result = subprocess.run(
            [sys.executable, os.path.join(HERE, "sync_pac.py"), "--force"],
            capture_output=True,
            text=True,
            timeout=180,
        )
        if result.returncode != 0:
            log("sync_pac failed: %s" % (result.stderr.strip() or result.stdout.strip()))
            return False
        log("pac rebuilt: %s" % result.stdout.strip())
        return True
    except (OSError, subprocess.SubprocessError) as exc:
        log("sync_pac error: %s" % exc)
        return False


def launch_with_pac() -> None:
    try:
        with open(PAC_URL, encoding="ascii") as fh:
            url = fh.read().strip()
    except OSError as exc:
        log("cannot read PAC URL: %s" % exc)
        return
    if not os.path.exists(EXE):
        log("Blitz.exe missing: %s" % EXE)
        return
    subprocess.Popen(
        [EXE, '--proxy-pac-url="%s"' % url],
        close_fds=True,
        creationflags=getattr(subprocess, "DETACHED_PROCESS", 0),
    )
    log("relaunched Blitz with fresh PAC")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--asar", default=ASAR)
    ap.add_argument("--log", default=APP_LOG)
    ap.add_argument("--since-bytes", type=int, default=0)
    ap.add_argument("--boot-seconds", type=int, default=150)
    ap.add_argument("--update-seconds", type=int, default=1800)
    ap.add_argument("--poll", type=int, default=4)
    ap.add_argument("--restart-grace", type=int, default=120)
    ap.add_argument("--disable", action="store_true")
    args = ap.parse_args()

    if args.disable:
        return 0

    started_version = installed_version(args.asar)
    if not started_version:
        log("cannot read installed version, exiting")
        return 0

    log("watching launch, version %s" % started_version)

    # Phase 1: wait for the updater verdict in the app log.
    offset = max(0, args.since_bytes)
    verdict = None
    deadline = time.time() + args.boot_seconds
    while time.time() < deadline:
        lines, offset = read_since(args.log, offset)
        if lines:
            verdict = classify(lines)
            if verdict:
                break
        if not blitz_pids():
            log("Blitz closed before the updater verdict, exiting")
            return 0
        time.sleep(args.poll)

    if verdict != "update":
        log("no pending update (%s), exiting" % (verdict or "no verdict"))
        return 0

    # Phase 2: an update is in progress. Wait for it to land.
    log("update detected, watching for version change")
    deadline = time.time() + args.update_seconds
    changed = False
    app_closed = False
    while time.time() < deadline:
        current = installed_version(args.asar)
        if current and current != started_version:
            log("version changed %s -> %s" % (started_version, current))
            changed = True
            break
        if not blitz_pids():
            # Blitz quit so the installer can replace the app. Keep waiting for
            # the version on disk; the installer may take a while and relaunches
            # Blitz without our PAC argument.
            if not app_closed:
                log("Blitz closed, waiting for the installer to finish")
                app_closed = True
        time.sleep(args.poll)

    if not changed:
        log("update did not complete within %d s, exiting" % args.update_seconds)
        return 0

    if not sync_pac():
        return 1

    # Give the updater a moment to settle, then make sure the running instance
    # carries our PAC argument.
    time.sleep(10)
    if blitz_pids():
        stop_blitz()
    launch_with_pac()
    return 0


if __name__ == "__main__":
    sys.exit(main())
