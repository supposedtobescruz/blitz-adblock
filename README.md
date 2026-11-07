# blitz-adblock

Research notes and tooling for blocking the in-app advertising stack of the
[Blitz.gg](https://blitz.gg) desktop client on Windows, **scoped to Blitz only**
(no system-wide DNS or hosts changes are required for the PAC approach).

The motivation is performance, not philosophy: while Blitz idles in the
background it keeps the Aditude / Kueez / Primis / Google Ad Manager stack alive,
spawning dozens of bid requests and cookie-sync pixels per minute. On a machine
that is also running a game this shows up as background CPU load and frame-time
spikes.

## What is in here

| Path | Purpose |
|---|---|
| `domains.txt` | 410 ad, SSP and tracker domains observed in Blitz network traffic and cookies |
| `docs/findings.md` | How the analysis was done, what was measured, what failed and why |
| `scripts/make_pac.py` | Builds PAC files (full + compact) and the `data:` URL variant |
| `scripts/launch_noads.ps1` | Starts Blitz with the PAC, process-scoped |
| `scripts/make_shortcut.ps1` | Creates the desktop launcher shortcut |
| `scripts/hosts_apply.ps1` | System-wide hosts file block (works, but affects every app) |
| `scripts/hosts_revert.ps1` | Removes the managed hosts block |
| `scripts/asar_inject.py` | asar rebuilder / injector; **experimental, rejected**, see findings |

## Status

- PAC blocking is the only Blitz-scoped approach that demonstrably loads. Chromium
  in this build accepts a `data:` PAC URL passed via `--proxy-pac-url`; a `file://`
  PAC URL is ignored because the PAC fetcher runs in the network sandbox.
  Ad requests were then routed to a dead proxy (`127.0.0.1:9`).
- The full end-to-end proof (every ad request failing, Blitz fully functional) was
  not reproduced cleanly in netlog, so treat the PAC path as **best effort**.
- The hosts file approach is verifiably effective (all ad requests fail with
  `net_error -105`) but it is global: it also blocks those domains for your
  browser and every other app.
- Patching `app.asar` does not work. The app exits with `crash.log` = `E6 Error.`
  when the entry bundle changes, even with recomputed integrity metadata.

## Usage

### Blitz-scoped PAC

1. Generate the PAC artifacts from the domain list:

   ```powershell
   python scripts\make_pac.py
   ```

   Output goes to `build\`: `blitz.pac` (readable), `blitz-min.pac` (compact
   regex), `blitz-pac-url.txt` (percent-encoded `data:` URL, ~5.7k characters).

2. Create a desktop shortcut that starts Blitz with the PAC:

   ```powershell
   powershell -ExecutionPolicy Bypass -File scripts\make_shortcut.ps1
   ```

   The shortcut runs `scripts\launch_noads.ps1` with a hidden window and passes
   `--proxy-pac-url="<data URL>"` to `Blitz.exe`. A `.lnk` argument field is
   limited to 260 characters, so the PAC URL is read at launch time instead of
   being stored in the shortcut.

   Launch Blitz through that shortcut. The argument applies to this process tree
   only; nothing else on the system is affected.

3. To verify, resolve a known ad host and check that Blitz traffic to it fails:

   ```powershell
   Resolve-DnsName securepubads.g.doubleclick.net
   ```

   DNS still resolves (the PAC decides, not DNS). Check the app log or a local
   proxy on `127.0.0.1:9` if you want request-level confirmation.

### System-wide hosts block (aggressive, affects everything)

```powershell
# elevated shell
powershell -ExecutionPolicy Bypass -File scripts\hosts_apply.ps1
# revert
powershell -ExecutionPolicy Bypass -File scripts\hosts_revert.ps1
```

The script writes entries between `# BEGIN BLITZ NOADS` / `# END BLITZ NOADS`
markers and backs up the hosts file to `%LOCALAPPDATA%\BlitzNoAds` before
touching it.

## Caveats

- Blitz ships its own DoH configuration to `chrome.cloudflare-dns.com`, so hosts
  file entries are respected only if the app falls back to the system resolver.
  In practice the block worked, but this can change between releases.
- Ad domains rotate. `domains.txt` is a snapshot, not a permanent list.
- Any client-side change breaks when Blitz updates the client or its ad stack.
- Blocking ads may conflict with Blitz's terms of service. The supported ad-free
  path is Blitz Premium. Use this on your own machine, at your own risk.
- `scripts/asar_inject.py` is included only because the analysis is documented
  there; do not expect it to produce a running app.

## License

No license. Research notes published as-is.
