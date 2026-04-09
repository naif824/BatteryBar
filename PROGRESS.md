# BatteryBar — Development Progress

## Overview
macOS menu bar app showing battery levels for all iCloud-connected devices (iPhone, iPad, Mac, Apple Watch, AirPods). Supports Family Sharing with selective device visibility.

**Repo:** https://github.com/naif824/BatteryBar
**Website:** https://icamel.app/product/batterybar/
**Bundle ID:** `cc.naif.batterybar.v7.3`
**Current Version:** 7.3 (Swift native)
**DMG:** Signed + Notarized with Apple Developer ID

---

## Version History

### Phase 1: Python Prototype (v1.0–v3.3.0)

#### v1.0 — Personal Version
- Python + rumps menu bar + pyicloud 2.0.1
- Hardcoded `MY_DEVICES` set to filter Family Sharing
- Password stored in plaintext config
- Worked until pyicloud SRP auth broke against Apple's updated API

#### v2.0 — Public Version
- Removed hardcoded device names
- Configurable device filter via `choose from list` dialog
- Grouped display: My Devices / Family Devices

#### v2.1 — Keychain + Logout
- Password stored in macOS Keychain instead of plaintext
- Logout clears Keychain + cookies
- Auto-migrates v1 plaintext passwords

#### v3.0 — Webview Auth (Abandoned)
- Attempted Apple's icloud.com login in embedded pywebview
- Webview cookies captured but FMIP API returned 450
- **Root cause:** FMIP requires SRP-derived `dsWebAuthToken`, not web session cookies
- Web cookies (`X-APPLE-DS-WEB-SESSION-TOKEN`) and API tokens are different auth layers
- Conclusion: webview-only auth is not viable for Find My access

#### v3.3.0 — Working Python Version
- pyicloud 2.5.0 (timlaing fork) on Python 3.14 via subprocess
- Auto-detects Apple ID from Mac's signed-in account
- SMS-based 2FA (push notifications unreliable from subprocess)
- Session auto-restores from cookies (~2 months)
- Settings attempted via Tkinter (white screen bug under py2app)

### Phase 2: Swift Native Rewrite (v5.0–v7.3)

User rewrote the app in native Swift, resolving all Python/py2app issues.

#### v7.3 — Current Release
- **Pure Swift** — 1,106 lines across 8 source files, no Python dependency
- **Native macOS** — AppKit, WebKit, Security, IOBluetooth frameworks
- **Architecture:**
  - `AppController.swift` — Menu bar, device list, refresh loop
  - `ICloudService.swift` — iCloud auth + Find My API
  - `LoginWindowController.swift` — Native login window
  - `SettingsWindowController.swift` — Native settings with checkboxes
  - `AirPodsBattery.swift` — Local AirPods battery via IOBluetooth
  - `Models.swift` — Device data models
  - `Persistence.swift` — Config + Keychain storage
  - `main.swift` — Entry point
- **Build:** Single `swiftc` command, no Xcode project needed
- **Size:** ~150KB DMG (vs ~24MB for Python py2app)
- **Minimum macOS:** 13.0

---

## Key Technical Learnings

### iCloud Auth Architecture
| Layer | Source | Access Level |
|-------|--------|-------------|
| Web session cookies | Browser/webview login | icloud.com UI, `validate` endpoint only |
| SRP session token (`dsWebAuthToken`) | SRP-6a password auth via `idmsa.apple.com` | Full API (FMIP, contacts, etc.) |

Web cookies cannot access Find My. FMIP requires SRP-derived tokens.

### pyicloud History
- **2.0.1** — SRP broken against Apple's 2025+ API (401 errors)
- **2.5.0** (timlaing fork, April 2026) — Fixed SRP-6a with `s2k_fo` parameter

### Find My Local Cache (macOS)
- Apple encrypts Find My cache with ChaCha20-Poly1305 since macOS 14.4
- Decryption requires temporarily disabling SIP — not viable for distribution
- Path: `~/Library/Group Containers/group.com.apple.findmy.findmylocateagent/`

### 2FA Delivery
- Push notification 2FA doesn't arrive from subprocess/background contexts
- SMS-based 2FA via `_request_sms_2fa_code()` is reliable

---

## Deployment

### Notarization
- Credentials stored via App Store Connect API key (not app-specific password)
- Profile name: `notarytool`
- Key: `AuthKey_A9C6Q7QRPY.p8`, Issuer: `f8bed33a-4194-4840-901c-beb0ed6c2817`

### Website
- **Homepage:** https://icamel.app — BatteryBar card in apps grid
- **Product page:** https://icamel.app/product/batterybar/
- **Privacy:** https://icamel.app/product/batterybar/privacy.html
- **Terms:** https://icamel.app/product/batterybar/terms.html
- **DMG download:** https://icamel.app/product/batterybar/BatteryBar.dmg

### Privacy Policy Highlights
- Password stored in macOS Keychain only (never on our servers)
- App communicates directly with Apple servers (idmsa, setup.icloud, fmipservice)
- No analytics, no tracking, no third-party data sharing
- Device locations not accessed — battery levels only

---

## Project Structure

```
BatteryBarV7.3/
├── Sources/
│   ├── main.swift                  — Entry point
│   ├── AppController.swift         — Menu bar + device list (326 lines)
│   ├── ICloudService.swift         — iCloud auth + FMIP API (372 lines)
│   ├── LoginWindowController.swift — Native login window (100 lines)
│   ├── SettingsWindowController.swift — Device checkboxes (89 lines)
│   ├── AirPodsBattery.swift        — Local AirPods via Bluetooth (67 lines)
│   ├── Models.swift                — Data models (43 lines)
│   └── Persistence.swift           — Config + Keychain (100 lines)
├── Info.plist                      — App metadata
├── build.sh                        — Build script (swiftc + codesign)
├── build/                          — Compiled binary
├── dist/                           — Packaged .app
├── old/                            — Python prototype (v1–v3.3.0)
└── PROGRESS.md                     — This file
```

---

## Config & Storage

| Path | Contents |
|------|----------|
| `~/.batterybar/config.json` | Apple ID, visible devices, preferences |
| macOS Keychain "BatteryBar" | iCloud password (encrypted by OS) |
| `~/.batterybar/*.cookiejar` | Session cookies for auto-restore |
