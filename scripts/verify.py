#!/usr/bin/env python3
"""Launch Blitz with the PAC for a short window and report what happened.

Kills any running Blitz, starts a test instance with --log-net-log, waits, then
stops it again and analyses the netlog. Restarts Blitz with the PAC at the end,
so the user is left with a working, blocked app.

Output (human readable):
    ad requests failed:   17
    ad requests refused:  0
    blitz CDN requests:   572
    result: PASS

Exit codes: 0 = pass, 1 = ad requests succeeded or blitz CDN broken, 2 = error.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time

LOCALAPPDATA = os.environ.get("LOCALAPPDATA", "")
EXE = os.path.join(LOCALAPPDATA, "Programs", "Blitz", "Blitz.exe")
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "build"))
DOMAINS = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "domains.txt"))
NETLOG = os.path.join(ROOT, "verify-netlog.json")


def kill_blitz(timeout: int = 15) -> None:
    subprocess.run(["taskkill", "/F", "/T", "/IM", "Blitz.exe"], capture_output=True, timeout=timeout)
    for _ in range(20):
        out = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq Blitz.exe", "/FO", "CSV", "/NH"],
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout
        if "Blitz.exe" not in out:
            return
        time.sleep(0.5)


def blocked_domain(host: str) -> bool:
    with open(DOMAINS, encoding="utf-8") as fh:
        domains = {d.strip().lower() for d in fh if d.strip()}
    parts = host.lower().split(".")
    for i in range(len(parts)):
        if ".".join(parts[i:]) in domains:
            return True
    return False


def analyze(path: str) -> dict:
    with open(path, encoding="utf-8", errors="replace") as fh:
        data = fh.read()
    ids: dict[str, str] = {}
    for line in data.splitlines():
        if '"url":"' not in line:
            continue
        # source type 1 is URL_REQUEST; the same URL also appears under the
        # proxy resolution service (type 23), which is not a fetch
        m_id = re.search(r'"source":\{"id":(\d+),"start_time":"[^"]+","type":1\}', line)
        m_url = re.search(r'"url":"([^"]+)"', line)
        if m_id and m_url:
            ids[m_id.group(1)] = m_url.group(1)

    ad_fail = ad_102 = blitz = 0
    ad_failing_ids = set()
    ad_ids = {}
    for src_id, url in ids.items():
        try:
            host = url.split("/")[2].split(":")[0]
        except IndexError:
            continue
        if blocked_domain(host):
            ad_ids[src_id] = url
        elif host.endswith(("blitz.gg", "blitzapp.gg", "iesdev.com")):
            blitz += 1

    for line in data.splitlines():
        m = re.search(r'"source":\{"id":(\d+),"start_time":"[^"]+","type":1\}', line)
        if not m:
            continue
        src_id = m.group(1)
        e = re.search(r'"net_error":(-?\d+)', line)
        if e and src_id in ad_ids:
            ad_failing_ids.add(src_id)
            if e.group(1) in ("-102", "-130", "-105"):
                ad_102 += 1

    ad_success = len(ad_ids) - len(ad_failing_ids)
    return {"ad_total": len(ad_ids), "ad_failed": len(ad_failing_ids),
            "ad_refused": ad_102, "ad_success": ad_success, "blitz_requests": blitz}


def launch(netlog: str | None):
    with open(os.path.join(ROOT, "blitz-pac-url.txt"), encoding="ascii") as fh:
        url = fh.read().strip()
    args = [f"--proxy-pac-url={url}", "--disable-quic"]
    if netlog:
        args.append(f"--log-net-log={netlog}")
    subprocess.Popen([EXE, *args], close_fds=True,
                      creationflags=getattr(subprocess, "DETACHED_PROCESS", 0))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--wait", type=int, default=60)
    ap.add_argument("--keep-log", action="store_true")
    args = ap.parse_args()

    os.makedirs(ROOT, exist_ok=True)
    if not os.path.exists(EXE):
        print(f"Blitz.exe not found: {EXE}", file=sys.stderr)
        return 2
    try:
        kill_blitz()
        try:
            subprocess.run(
                ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                 os.path.join(os.path.dirname(__file__), "clear_cache.ps1"), "-Force"],
                capture_output=True, timeout=120)
        except Exception as exc:  # noqa: BLE001
            print(f"cache clear failed (continuing): {exc}")
        if os.path.exists(NETLOG):
            os.remove(NETLOG)
        launch(NETLOG)
        print(f"launched Blitz, collecting netlog for {args.wait}s...")
        time.sleep(args.wait)
    finally:
        kill_blitz()

    try:
        result = analyze(NETLOG)
    except Exception as exc:  # noqa: BLE001
        print(f"netlog analysis failed: {exc}", file=sys.stderr)
        return 2

    print(f"ad requests seen:     {result['ad_total']}")
    print(f"ad requests blocked:  {result['ad_failed']}")
    print(f"ad requests succeeded:{result['ad_success']}")
    print(f"blitz CDN/app requests: {result['blitz_requests']}")

    ok = result["ad_success"] == 0 and result["blitz_requests"] > 0
    print("result:", "PASS" if ok else "FAIL")

    if not args.keep_log:
        try:
            os.remove(NETLOG)
        except OSError:
            pass

    # Leave a working, blocked Blitz running for the user.
    launch(None)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
