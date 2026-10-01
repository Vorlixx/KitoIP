# Security Policy

## Reporting a vulnerability

Please report security issues privately through GitHub's
["Report a vulnerability"](https://github.com/Vorlixx/KitoIP/security/advisories/new)
feature. Do **not** open a public issue for anything you believe is exploitable.

Include what you can:

- Affected file(s) and menu option / `-Mode`
- Steps to reproduce or a proof of concept
- Expected vs. actual behaviour
- Your Windows version (10 / 11) and PowerShell edition

## Response

- Initial response target: **72 hours**
- Fix or mitigation target: **14 days** for critical issues, best effort otherwise
- Credit is given in the release notes unless you prefer to stay anonymous

## Supported versions

| Version | Supported |
| --- | --- |
| latest `main` | ✅ |
| older commits / forks | ❌ — please update |

## What the codebase guarantees

- Every shipped file is plain, readable text: `.ps1` and `.bat` only. No compiled binaries, DLLs, packed payloads or base64 blobs.
- Nothing is downloaded and executed; no `Invoke-Expression` of remote content, no telemetry, no phone-home.
- The scanning engine is self-testable without touching your system: run `.\KitoMotorTest.ps1` (read-only) to verify it behaves as documented.
- Network changes are snapshot-protected: a failed operation restores the previous configuration automatically.
- Personal state (`proxies.txt`, `proxies_ok.json`, `kito_settings.json`, `warp-account.json`, `wgconf/`) is git-ignored and never uploaded.
