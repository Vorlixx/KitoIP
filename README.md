<div align="center">

# KitoIP

**A single-terminal toolkit for Windows that changes your public IP (proxies), your local IP (LAN), and your VPN tunnel (Cloudflare WARP) — all from one animated menu.**

[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6?logo=windows&logoColor=white)](#requirements)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)](#requirements)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![No Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen.svg)](#requirements)

</div>

---

## Overview

**KitoIP** bundles everything into **one launcher and one menu**. The old versions
required several separate `.bat` files; those were removed.

```
KitoIP.bat  ->  KitoMenu.ps1  ->  (single terminal, animated menu)
```

It gives you three independent capabilities from the same window:

| Capability | What it does | Elevation |
|------------|--------------|-----------|
| **Proxy engine** | Finds the lowest-latency working proxy from your pool and applies it as a system proxy for a *foreign* public IP | No admin needed |
| **LAN IP engine** | Changes the local IPv4 address of the active adapter (DHCP renew or random static) | Admin (UAC) |
| **WireGuard / WARP** | Creates a free Cloudflare WARP account and opens a WireGuard tunnel to a chosen country | Admin (UAC) |

> **Note:** changing your *LAN* IP does not change your *public* IP. Use the proxy
> engine or WARP for that.

---

## Features

- **One launcher, one menu.** No more juggling a dozen `.bat` files.
- **Never hangs.** The new scanning engine (`KitoCore.ps1`) runs in real C#
  threads with hard deadlines — a single dead proxy can no longer freeze the UI.
- **Scales to 100,000+ proxies.** Fixed worker pool + `ConcurrentQueue`.
- **Country selection.** `Random`, `ALL`, or `DE`, `NL`, `US`, `DE,NL,US`, …
  remembered between runs.
- **Fast mode.** Connects in seconds from cache without re-scanning.
- **Safe by default.** `List` mode changes nothing; failed operations roll back
  the previous network configuration automatically.
- **Free VPN path.** Cloudflare WARP is free, unlimited, and needs no account
  sign-up — KitoIP registers one for you.

---

## Requirements

- **Windows 10 / 11** (Windows 7+ for PowerShell, but tested on 10/11)
- **Windows PowerShell 5.1** (built in — no install needed)
- **WireGuard for Windows** — only for the WARP module; it is installed
  automatically if missing
- No external NuGet, pip, or npm dependencies

---

## Installation

```bat
git clone https://github.com/<your-user>/KitoIP.git
cd KitoIP
```

Or download the ZIP and extract it anywhere. Then **double-click `KitoIP.bat`**.

If you prefer PowerShell directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File KitoMenu.ps1
```

---

## Quick Start

1. Put your proxy pool into `proxies.txt` — one `ip:port` per line
   (100,000+ lines are fine). See `proxies.txt.example` for accepted formats.
2. Launch `KitoIP.bat` and pick **`[3] Proxy Hunt`** once to build the best list.
3. From then on use **`[2] Fast Connect`** for a quick daily connect.

---

## The Menu

```
============================================================
    K I T O I P     Proxy + IP Toolkit
============================================================
      Country     : DE
      Pool        : 102345 proxies (proxies.txt)
      Best        : 60   |   Cache: 246
      Active proxy: 185.200.188.234:10001  RU/Russian Federation  533 ms

    [1]  Connect to a Foreign IP   (country filter + lowest ms)
    [2]  Fast Connect             (from cache, in seconds)
    [3]  Proxy Hunt               (rebuild the best list)
    [4]  List Proxies             (show fastest candidates)
    [5]  Select Country

    [6]  Proxy Off                (back to normal connection)
    [7]  Status

    [8]  Change LAN IP
    [9]  WireGuard WARP VPN
    [P]  Manage Proxy List        (bulk import / clear cache)
    [0]  Exit
```

### `[1] Connect to a Foreign IP`
Finds proxies matching the country filter and applies the **lowest-latency**
one. Each candidate is verified working *before* it is applied; if it fails,
the next candidate is tried.

### `[2] Fast Connect` *(recommended for daily use)*
Downloads nothing. Picks **400 candidates spread across the whole file** from
the cache, `proxies_best.txt`, and your own list, and connects in ~10 seconds.

### `[3] Proxy Hunt`
Scans the entire pool and writes the best `TopN` proxies to `proxies_best.txt`
and the cache. **Designed for 100,000 proxies.** This can take a few minutes.

### `[4] List Proxies`
Changes **no system settings** — it only prints the fastest candidates as a
table. Use this for a safe test.

### `[5] Select Country`
Accepts `Random` / `ALL` / `DE` / `NL` / `US` / `GB` / `FR` / `RU` / `SG` /
comma-separated multi-selection, or a country code you type yourself. The
choice is saved to `kito_settings.json` and remembered next launch.

### `[P] Manage Proxy List`
Bulk-imports a large list from a file. Accepted formats: `ip:port`,
`ip:port:user:pass`, `http://ip:port`, `https://user:pass@ip:port`, or any text
that merely *contains* an `ip:port`. All matches are de-duplicated into
`proxies.txt`.

---

## Command-Line Usage

Every mode is available without the menu:

```powershell
# Rebuild the best list (scans a 100k pool)
.\KitoVPN.ps1 -Mode Hunt -Country ALL -TopN 100

# List only - do not touch system settings
.\KitoVPN.ps1 -Mode List -Country DE

# Fastest connect
.\KitoVPN.ps1 -Mode Fast -Country Random

# Show the candidate that would be applied, but DO NOT apply it (safe test)
.\KitoVPN.ps1 -Mode Foreign -Country NL -DryRun

# Use a different list file
.\KitoVPN.ps1 -Mode Hunt -ListFile C:\proxies\big_list.txt
```

### Key parameters

| Parameter       | Default | Description                                        |
|-----------------|---------|----------------------------------------------------|
| `-Mode`         | Foreign | `Foreign` / `Fast` / `Hunt` / `List` / `Status` / `Clear` |
| `-Country`      | Random  | `Random` / `ALL` / `DE` / `DE,NL,US`               |
| `-TcpTimeoutMs` | 900     | TCP pre-filter timeout (ms)                        |
| `-TcpWorkers`   | 768     | TCP concurrency                                    |
| `-MaxScanTcp`   | 0       | TCP candidates to scan (0 = all)                   |
| `-MaxTest`      | 3000    | HTTP candidates to test (0 = all)                  |
| `-TimeoutSec`   | 4       | HTTP timeout (s)                                   |
| `-HttpWorkers`  | 256     | HTTP concurrency                                   |
| `-MaxLatencyMs` | 900     | Candidates above this latency are dropped          |
| `-SpeedTest`    | off     | Also measure download speed (KB/s)                 |
| `-DryRun`       | off     | Select only, do not apply                          |

`KitoIP.ps1` (LAN) and `KitoWG.ps1` (WARP) keep their own parameters — see the
comment header at the top of each file.

---

## Architecture

| File                   | Role                                                        |
|------------------------|-------------------------------------------------------------|
| `KitoIP.bat`           | **The only launcher.** Opens the menu.                      |
| `KitoMenu.ps1`         | Animated splash + unified menu (proxy / country / LAN / WARP) |
| `KitoCore.ps1`         | Shared engine: C# thread-pool scanner + helper functions    |
| `KitoVPN.ps1`          | Foreign public-IP engine via proxies (country-aware, 100k)  |
| `KitoIP.ps1`           | Local (LAN) IP engine                                       |
| `KitoWG.ps1`           | WireGuard + Cloudflare WARP engine                          |
| `KitoMotorTest.ps1`    | Read-only self-test of the scanning engine (changes nothing)|
| `proxies.txt`          | Your proxy pool (git-ignored; see `proxies.txt.example`)    |
| `proxies_best.txt`     | Best proxies found by a hunt                                |
| `proxies_ok.json`      | Cache (working proxies + ms + country)                      |
| `kito_settings.json`   | Remembered settings (git-ignored)                           |
| `warp-account.json`    | WARP account (git-ignored) + `wgconf\` tunnel files         |

### Why it no longer hangs

The old engine created a separate PowerShell runspace per proxy and waited for
*all* jobs with **no deadline** — one silent proxy froze the animation forever.
The new engine (`KitoCore.ps1`) scans inside **C# with real threads**:

- Fixed worker count + `ConcurrentQueue` → scales to 100,000 proxies.
- TCP: `BeginConnect` + `WaitOne(timeout)` → a hard timeout per target.
- HTTP: `BeginGetResponse` + `WaitOne(timeout)` + `Abort()` → a hard timeout
  even where .NET does not enforce one.
- Every stage also has a "hard cap" safety limit.
- Live progress is drawn from `[Kito]::Done` / `[Kito]::Total`.

### Measured results (on the test machine)

| Test                                       | Result                         |
|--------------------------------------------|--------------------------------|
| 300 black-hole targets, 800 ms timeout     | **3.0 s** (no hang)            |
| 20 real proxies, TCP pre-filter            | **2.7 s** (9 alive)            |
| 11 live proxies, HTTP/HTTPS verification   | **8.2 s**                      |
| 10,256 candidates: full TCP + HTTP scan    | 1378 alive → 55 fast HTTPS-OK, fastest **427 ms** |
| Fast connect                               | **~7 s** scan (~12 s incl. start) |

---

## Security & Privacy

- **Credit-card-free, account-free WARP:** the WARP account and all keys are
  generated locally and stored in `warp-account.json` / `wgconf\`, which are
  **excluded by `.gitignore`** and never leave your machine.
- Applying a proxy needs **no admin rights** (it writes to `HKCU`). LAN and
  WARP operations do require admin (a UAC prompt appears).
- If any operation fails, the previous network configuration is restored
  automatically.
- Free proxies are unstable — they can die within hours. Re-running a hunt
  (`[3]`) is normal.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `KitoIP.bat` closes instantly / security error | Make sure you run the repo's own `KitoIP.bat` (it clears the Windows "Mark of the Web" flag). Or run `Unblock-File *.ps1` once. |
| "PowerShell was not found" | Enable Windows PowerShell 5.1 (it ships with Windows 10/11). |
| UAC prompt never appears | Right-click `KitoIP.bat` → *Run as administrator* for LAN/WARP modes. |
| No working proxies | Add a larger `proxies.txt`, then run `[3] Proxy Hunt`. |
| WARP won't connect | Run menu `[9]` → *Reset* to regenerate the account, then *Up* again. |

---

## FAQ

**Does changing my LAN IP change my public IP?**
No. LAN IP is local only. Use the proxy engine or WARP for a public IP change.

**Is Cloudflare WARP really free?**
Yes — it is free, unlimited, and requires no sign-up.

**Do I need to install anything?**
No. PowerShell 5.1 is built into Windows; WireGuard is installed on demand
for the WARP module only.

---

## Disclaimer

KitoIP is provided for **educational and lawful use only** — for example,
privacy testing, network research, or accessing content you are authorised to
access. You are solely responsible for how you use it and for complying with
the laws and terms of service that apply to you. The authors accept no
liability for misuse or for any damages arising from its use.

---

## License

Released under the [MIT License](LICENSE).

<div align="center"><sub>Built for Windows. One menu. No hangs.</sub></div>
