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
| Chromium `--proxy-pac-url` (data URL) | Blitz only | Loaded (`proxy_chain [127.0.0.1:9]` observed), but ad traffic still reached the network |
| `NODE_OPTIONS=--require` hook | Blitz only | Ignored by the packaged app |
| `app.asar` main-bundle injection | Blitz only | Rejected: the app exits when `src/index.js` content changes (integrity/anti-tamper) |
| Blitz Premium | Blitz only | Official ad-free tier, paid |

## Verified numbers

- Hosts block: 410 domains, 820 lines, ad requests failed with `net_error -105`
- Idle CPU after blocking: ~1% of one core (20 s average)
- Ad cookie host keys observed: 341
- Ad request hosts observed in netlog: 24 distinct (Aditude, Kueez, Primis, GAM, InMobi, Criteo, ...)

## Notes on the asar experiment

The asar archive is rebuilt correctly: repacking without content changes produces a working app, and
every file round-trips byte-identically. As soon as the entry file content changes, the app boots,
performs its update check, then exits with `crash.log` containing `E6 Error.`. The asar header carries
per-file SHA-256 integrity metadata, and recomputing it did not help, so the rejection is most likely
an app-level check rather than stock Electron asar integrity.
