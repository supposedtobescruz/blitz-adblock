#!/usr/bin/env python3
"""Generate proxy auto-config (PAC) files from a domain list.

Outputs:
  build/blitz.pac          full PAC, one array entry per domain
  build/blitz-min.pac      compact regex PAC
  build/blitz-pac-url.txt  data: URL wrapping blitz-min.pac (for --proxy-pac-url)

Usage:
    python make_pac.py [-d ../domains.txt] [-o build]

Note: Chromium in the Blitz build ignores file:// PAC URLs (the fetcher is
blocked by the network sandbox) but accepts data: URLs. That is why the compact
PAC is percent-encoded into a data: URL.
"""

from __future__ import annotations

import argparse
import os
import re
import urllib.parse

BLOCK_PROXY = "PROXY 127.0.0.1:9"


def load_domains(path: str) -> list[str]:
    with open(path, encoding="utf-8") as fh:
        seen = {}
        for line in fh:
            d = line.strip().lower()
            if not d or d.startswith("#"):
                continue
            seen[d] = None
    return list(seen)


def base_domains(domains: list[str]) -> list[str]:
    """Collapse hostnames to base domains so a single regex covers subdomains."""
    bases = set()
    for host in domains:
        parts = host.split(".")
        bases.add(".".join(parts[-2:]) if len(parts) >= 2 else host)
    return sorted(bases)


def full_pac(domains: list[str]) -> str:
    arr = ",\n  ".join('"%s"' % d for d in domains)
    return (
        "// Blitz ad block - only effective when passed via --proxy-pac-url\n"
        "var BLOCKED = [\n  %s\n];\n"
        "function FindProxyForURL(url, host) {\n"
        "  host = host.toLowerCase();\n"
        "  for (var i = 0; i < BLOCKED.length; i++) {\n"
        "    var d = BLOCKED[i];\n"
        "    if (host === d || host.slice(-(d.length + 1)) === \".\" + d) {\n"
        '      return "%s";\n'
        "    }\n"
        "  }\n"
        '  return "DIRECT";\n'
        "}\n" % (arr, BLOCK_PROXY)
    )


def compact_pac(domains: list[str]) -> str:
    alt = "|".join(re.escape(b) for b in base_domains(domains))
    return (
        "function FindProxyForURL(u,h){return/(^|\\.)(%s)$/.test(h)"
        '?"%s":"DIRECT"}' % (alt, BLOCK_PROXY)
    )


def data_url(pac: str) -> str:
    return "data:application/x-ns-proxy-autoconfig," + urllib.parse.quote(
        pac, safe="-._~!$&'()*+,;=:@/?"
    )


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("-d", "--domains", default=os.path.join(here, "..", "domains.txt"))
    ap.add_argument("-o", "--out", default=os.path.join(here, "..", "build"))
    args = ap.parse_args()

    domains = load_domains(args.domains)
    if not domains:
        print("no domains in %s" % args.domains)
        return 1

    os.makedirs(args.out, exist_ok=True)
    pac = full_pac(domains)
    mini = compact_pac(domains)
    url = data_url(mini)

    targets = {
        "blitz.pac": pac,
        "blitz-min.pac": mini,
        "blitz-pac-url.txt": url,
    }
    for name, text in targets.items():
        path = os.path.join(args.out, name)
        with open(path, "w", encoding="ascii") as fh:
            fh.write(text)
        print("%-18s %6d bytes" % (name, len(text)))

    print("domains=%d bases=%d" % (len(domains), len(base_domains(domains))))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
