# Blitz ad-block research notes

## Target

- App: Blitz.gg desktop (Electron 31.2.1, app version 3.0.20)
- Install path: `%LOCALAPPDATA%\Programs\Blitz`
- User data: `%APPDATA%\Blitz`
- Six processes while idle: main, GPU, network service, audio, renderer, crashpad

## Why the app is heavy

1. **Programmatic ad stack in the renderer**
   - Ad manager: Aditude (`tudeserve`), Kueez RTB, Primis video
   - Google Ad Manager via `securepubads.g.doubleclick.net/tag/js/gpt.js`
   - Prebid.js (`edge.aditude.io/prebid/9.19.0.js`) fans out bid requests to dozens of SSPs
   - Consent management: InMobi CMP (`cmp.inmobi.com`)
   - Cookie sync pixels: Criteo, ID5, 33Across, Amazon APS, LiveRamp, Quantcast, ...
2. **Large tracking surface**
   - `Network/Cookies` contained 341 distinct ad/tracker host keys after normal use
3. **Secure DNS**
   - Netlog showed DoH to `chrome.cloudflare-dns.com` with plain fallback to 1.1.1.1/1.0.0.1
4. **In-game overlay**
   - Offscreen-rendered overlay (`partition: "overlay"`, `offscreen: true`) is injected into the
     game window and re-navigates to `https://blitzapp.gg/<version>/<game>/overlay/...`
   - Log shows repeated re-navigation and 1920x1080 buffer resizes during matches
   - This is a plausible additional source of frame-time spikes, independent of ads

## Approaches evaluated

| Approach | Scope | Result |
|---|---|---|
| Windows hosts file (`0.0.0.0` entries) | System-wide | Works. Ad requests fail with `net_error -105`. Drawback: affects every app |
| Chromium `--host-resolver-rules` | Blitz only | Partially honoured. Some requests still resolved |
| Chromium `--proxy-pac-url` (file) | Blitz only | Ignored; PAC file fetch is blocked for the network sandbox |
| Chromium `--proxy-pac-url` (data URL) | Blitz only | Works. Loaded via `proxy_chain [127.0.0.1:10009]`; ad requests then fail (`net_error -130`/`-102`) instead of succeeding. Note: `127.0.0.1:9` was rejected because TCPSVCS (Simple TCP/IP Services) listens on port 9 on some machines, which silently swallows proxy CONNECT requests |
| `NODE_OPTIONS=--require` hook | Blitz only | Ignored by the packaged app |
| `app.asar` main-bundle injection | Blitz only | Rejected: the app exits when `src/index.js` content changes (integrity/anti-tamper) |
| Blitz Premium | Blitz only | Official ad-free tier, paid |

## 2026-11-12: client 3.0.20 -> 3.0.24 and ads returning

After the automatic 3.0.24 update, the app relaunched itself as
`Blitz.exe --updated` without the PAC argument, so the block silently stopped
while the app kept working. That is why "ads came back after a while": the block
was not reset, only lost on the unmanaged relaunch.

Fixes and observations:

- Launcher now restarts a running Blitz instance that lacks the PAC argument or
  uses a PAC older than the current `blitz-pac-url.txt`. All Blitz entries
  (desktop shortcut, Start Menu, pinned taskbar icon, `Run\com.blitz.app`
  autostart) were retargeted to the launcher.
- The update watcher now keeps waiting while the installer replaces the app
  (Blitz quits first), detects the version swap and relaunches with a fresh PAC.
- netlog with the PAC still applied shows the ad stack failing:
  `securepubads.g.doubleclick.net`, `cmp.inmobi.com`, `raven-edge.aditude.io`,
  `live.primis.tech`, `static.kueezrtb.com`, `track.kueezrtb.com` all fail with
  `net_error -7`, while `blitz-cdn.blitz.gg` / `blitzapp.gg` keep working.
- 3.0.24 added new ad-stack bootstrap hosts not in the original list (fetched at
  app boot, initiated by `https://blitzapp.gg`):
  - `dn0qt3r0xannq.cloudfront.net` (`prebid-load.js`, `prebid-wrapper.js`)
  - `cdn.hadronid.net` (`hadron.js`, Amazon partner)
  - `cadmus.script.ac` (ad script)
  - `i.clean.gg` (ad script; blocked, `net_error -7`)
  These were added to `domains.txt`.
- `--disable-quic` is passed by the launcher so UDP traffic cannot bypass the
  HTTP proxy.
- Blitz HTTP cache and Service Worker code cache were moved aside to drop stale
  ad creatives served from cache.

Remaining known gap: domains in `domains.txt` rotate. When Blitz adds another
SSP, ads will return until the list is regenerated from a fresh cookie/netlog
sample.

## Verified numbers

- Hosts block: 410 domains (now 427 with the 3.0.24 additions), 820+ lines, ad requests fail with `net_error -105`
- Ad requests under the PAC fail with `net_error -7` (proxy/timed out), app traffic unaffected
- Idle CPU after blocking: ~1% of one core (20 s average)
- Ad cookie host keys observed: 341
- Ad request hosts observed in netlog: 24 distinct (Aditude, Kueez, Primis, GAM, InMobi, Criteo, ...)

## Notes on the asar experiment

The asar archive is rebuilt correctly: repacking without content changes produces a working app, and
every file round-trips byte-identically. As soon as the entry file content changes, the app boots,
performs its update check, then exits with `crash.log` containing `E6 Error.`. The asar header carries
per-file SHA-256 integrity metadata, and recomputing it did not help, so the rejection is most likely
an app-level check rather than stock Electron asar integrity.
