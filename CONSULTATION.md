# BatteryBar — Full Technical Consultation Brief

## What BatteryBar Is

A macOS menu bar app that displays battery levels for all Apple devices linked to an iCloud account. Shows battery %, charging status, and online/offline state for iPhones, iPads, Watches, Macs, and AirPods. AirPods battery is read locally via Bluetooth; all other devices are fetched from iCloud's Find My service.

Built in pure Swift (no Xcode project), compiled with `swiftc`, targets arm64 macOS 13.0+.

## The Core Problem

**Data goes stale after the Mac sleeps.** The app fetches device battery data from iCloud's Find My web API. While the Mac is awake, refreshes work perfectly every 5 minutes. After the Mac sleeps for a few hours, the server-side session expires and the app can no longer fetch data — it shows frozen battery values with no recovery.

## The Fundamental Challenge

There is **no public Apple SDK or framework** that provides persistent access to other devices' battery levels via iCloud. Apple locks this data behind:

1. **The native Find My app** — uses private frameworks (`FMIPCore`, `FindMyDevice`, `FindMyCore`) + system-level iCloud authentication via `findmydeviced` daemon. Requires Apple-only entitlements (`com.apple.icloud.findmydevice*`). Cannot be used by third-party apps.

2. **The iCloud Find My web API** — reverse-engineered endpoints (`/fmipservice/client/web/initClient`, `/refreshClient`). Works but sessions expire after extended inactivity. This is what BatteryBar uses.

3. **MDM (Mobile Device Management)** — `StatusDeviceBatteryHealth` API. Enterprise only, requires device enrollment.

4. **CloudKit sync** — requires a companion app installed on every device. Not passive.

5. **Local only** — Wi-Fi sync (Finder) + Bluetooth. Requires same network. Limited to paired devices.

We investigated reading data locally from the Mac (Find My app's cache, daemon memory, local databases, AppleScript, Shortcuts, AppIntents). **No local data store contains device battery levels accessible to third-party apps.** The daemon memory is protected by SIP, hardened runtime, and entitlement gates.

## Version History

### v1.0 — Original (the starting point)

**Architecture:** All iCloud API calls made through a hidden `WKWebView` (page navigations, not URLSession). Login via visible WKWebView to `icloud.com`. Cookies shared via `WKWebsiteDataStore.default()`.

**Issues identified (RCA):**
1. **Silent error swallowing** — `refreshDevices()` caught all non-`.sessionExpired` errors, logged them to a file, and kept showing old `allDevices` data indefinitely
2. **Narrow session expiry detection** — only HTTP 421 and 450 triggered re-auth; other failures (403, HTML redirect, bad JSON) fell through silently
3. **Cached `dsid`/`findMeRoot` never re-validated** — once set from first `/validate` call, reused forever even after session died
4. **`isRefreshing` deadlock risk** — if WKWebView navigation never completed, the flag stayed `true` forever, blocking all future refreshes
5. **No staleness visibility** — app showed stale data with no warning to user
6. **Fragile `/find` SPA recovery** — loaded `icloud.com/find` in hidden WebView with 5-second sleep hoping JavaScript would refresh cookies; never worked in practice

### v2.0 — First fix round

**Changes (ICloudService.swift + AppController.swift):**
- 30-second navigation timeout via `withTaskGroup` to prevent `isRefreshing` deadlock
- Hourly re-validation — `fetchDevices()` calls `setupSession()` every hour instead of caching forever
- Broader session expiry detection — 403/421/450 all treated as session expired; any 4xx clears cached session
- HTML auth page detection in responses
- Consecutive failure tracking — after 3 silent failures, escalates to re-login prompt
- `defer { isRefreshing = false }` for guaranteed flag reset
- Staleness UI — orange "Data may be outdated" warning after 1 hour; "Refresh failing (Nx)" counter
- `parseDevices()` throws on missing/empty content instead of returning `[]`

**Result:** Improved error visibility. Session still died after sleep, but user could see it.

### v3.0 — Login loop fix + polish

**Bug discovered:** After clearing cookies and relaunching, the app entered an infinite login open/close loop. The login WKWebView detected stale `X-APPLE-WEBAUTH-TOKEN` cookies from a previous dead session and immediately fired `onComplete`, which reset failure counters, tried to refresh, failed, opened login again.

**Changes:**
- JSON response validation — replaced HTML string heuristic with `hasPrefix("{")` / `hasPrefix("[")` check
- "Force Refresh Session" menu item — clears session and retries immediately
- Login loop fix — `LoginWindowController` snapshots cookie names before loading; only fires `onComplete` on genuinely new cookies
- Thorough `clearAllWebData()` — wipes all `WKWebsiteDataStore` data + `HTTPCookieStorage` + `CookiePersistence`
- Clear stale data before every sign-in

**Result:** Login loop fixed. Session still died after sleep.

### v4.0 — `refreshClient` instead of `initClient`

**Key discovery:** Every open-source iCloud client (pyicloud, Home Assistant) uses `/fmipservice/client/web/refreshClient` for ongoing updates, not `initClient`. `initClient` is meant to be called once to establish the FMIP session; `refreshClient` is lighter and designed for repeated polling.

BatteryBar was calling `initClient` on every 5-minute refresh, which required the `X-APPLE-WEBAUTH-FMIP` session cookie. This cookie is session-only and gets dropped by WebKit during sleep.

**Changes:**
- `initClient` called once after sign-in to establish FMIP session
- `refreshClient` used for all ongoing 5-minute refreshes
- `sessionEstablished` flag tracks whether `initClient` has succeeded
- Fallback: if `refreshClient` fails, re-validates and tries `initClient`
- Removed `/find` SPA recovery (never worked)
- Version label in menu

**Result:** `refreshClient` worked perfectly while awake. Session still died after prolonged sleep.

### v5.0 — URLSession replaces WKWebView for API calls

**Key insight:** WKWebView drops session-only cookies during sleep, has unpredictable cookie persistence, and returns stale cached DOM content after wake. URLSession with `HTTPCookieStorage` gives full cookie control.

**Changes:**
- All API calls (`/validate`, `initClient`, `refreshClient`) switched from hidden WKWebView navigation to `URLSession` POST requests
- WKWebView kept only for login UI
- Cookie transfer: after login, `importCookiesFromWebView()` copies all iCloud/Apple cookies from WKWebView to URLSession's cookie jar
- Manual cookie persistence via `CookiePersistence` (UserDefaults) for session-only cookies
- `macDidWake` no longer clears session — URLSession cookies survive sleep
- Removed WKWebView navigation timeout (no longer needed)
- Network offline errors (`NSURLErrorDomain -1009`) handled separately — don't count toward failure escalation

**Result:** Best performance yet — 12+ hours of uninterrupted `refreshClient: HTTP 200` while awake. URLSession cookies survived sleep perfectly. But Apple's server expired the session after ~3-4 hours of inactivity during sleep. On wake, `refreshClient` returned 450, `initClient` returned 450, then `validate` returned 421. Full session dead server-side.

### v6.0 — Silent re-auth via `accountLogin`

**Key discovery from pyicloud research:** pyicloud survives for months because when a session dies, it re-authenticates programmatically using stored tokens. The `/setup/ws/1/accountLogin` endpoint accepts a `dsWebAuthToken` + `trustToken` and returns a fresh full session without requiring password or 2FA.

**Changes:**
- `LoginWindowController` captures auth tokens from HTTP response headers during login (`X-Apple-Session-Token`, `X-Apple-TwoSV-Trust-Token`, `scnt`, `X-Apple-ID-Session-Id`)
- Tokens stored in Keychain via `AuthTokenStore`
- Recovery cascade: `validate` fails → `silentReauth()` via `accountLogin` → only prompt login if that also fails
- `accountLogin` payload matches pyicloud: `{dsWebAuthToken, trustToken, accountCountryCode, extended_login}`

**Result:** `accountLogin` returned HTTP 421 — the stored `sessionToken` was rejected. Investigation revealed the `X-Apple-Session-Token` header is returned from `idmsa.apple.com` XHR calls inside Apple's login SPA, which WKWebView's navigation delegate cannot intercept (it only sees page navigations, not JavaScript XHR responses).

### v7.0 — JavaScript XHR interception

**Attempt to capture the correct tokens:** Injected a `WKUserScript` at document start that monkey-patches `XMLHttpRequest` and `fetch` to capture response headers from `idmsa.apple.com` and `setup.icloud.com` XHR responses. Headers posted to Swift via `webkit.messageHandlers`.

**Result:** No tokens captured. Apple's `idmsa.apple.com` doesn't expose `X-Apple-Session-Token` or `X-Apple-TwoSV-Trust-Token` via `Access-Control-Expose-Headers`. JavaScript's `getResponseHeader()` can only read CORS-exposed headers. The tokens are browser-internal, invisible to page JavaScript.

**Alternative found:** The `X-APPLE-DS-WEB-SESSION-TOKEN` cookie IS visible in the WKWebView cookie store. It's a persistent cookie that contains the `dsWebAuthToken` value `accountLogin` needs. Successfully captured and stored.

**Result:** `accountLogin` returned HTTP 400 (Bad Request) instead of 421. Progress — Apple received the token but rejected the request format. The 49-byte response body likely contained an error message, but wasn't logged.

### v8.0 — Diagnostic logging

**Changes:** Added response body logging to `silentReauth` to see Apple's exact error message when `accountLogin` fails.

**Soak test result:**
- 12+ hours of perfect `refreshClient: HTTP 200` while awake
- Mac slept ~4 hours
- On wake: `validate: HTTP 200` (general session alive), `refreshClient: HTTP 450` (FMIP session dead), `initClient: HTTP 450`
- `accountLogin` was never triggered — because `validate` returned 200, the code path that calls `silentReauth` (triggered by validate 421) was never reached
- Later when `validate` finally returned 421: `accountLogin: HTTP 400` — token rejected

## What We Learned

### What works reliably
- **URLSession** for API calls — full cookie control, survives sleep, no WebKit quirks
- **`refreshClient`** for ongoing updates — lighter than `initClient`, works perfectly while awake
- **Cookie persistence** — session-only cookies manually saved and restored across launches
- **Error detection** — staleness UI, consecutive failure tracking, network-offline handling all work correctly
- **AirPods local Bluetooth** — always works, independent of iCloud session

### The hard wall
- **Apple expires the FMIP server-side session after ~3-4 hours of inactivity** (Mac sleep with no network). No client-side cookie or token persistence can prevent this.
- **`/validate` and FMIP endpoints use different auth levels.** The general iCloud session (`validate`) can be alive while the FMIP session (`initClient`/`refreshClient`) is dead. They expire independently.
- **`accountLogin` with `dsWebAuthToken`** returns HTTP 400, suggesting the token format or required headers don't match what Apple expects from a non-browser client.
- **WKWebView cannot intercept XHR response headers** — the auth tokens pyicloud captures (`X-Apple-Session-Token`, `X-Apple-TwoSV-Trust-Token`) are invisible to JavaScript due to CORS restrictions.
- **No local data source exists** — Find My app data is in daemon memory, protected by SIP + entitlements. No file, database, or API exposes device battery levels to third-party apps.

### What pyicloud does differently
pyicloud doesn't try to keep a session alive. When a session dies, it **creates a brand new one from scratch** using:
1. **SRP (Secure Remote Password) authentication** — Apple ID + password sent via cryptographic handshake to `idmsa.apple.com`
2. **Stored trust token** — skips 2FA for ~2 months
3. **Direct HTTP requests** — no WebView, full control over all headers and response parsing

This requires storing the user's Apple ID password. pyicloud does this as a Python library where the user provides credentials. A consumer macOS app doing this raises security and trust concerns.

## Options for External Review

### Option A: Accept re-login after prolonged sleep
The app (v5.0 architecture) works perfectly while awake. After prolonged sleep, it detects the dead session and prompts the user to sign in. This takes ~10 seconds. For daily use (Mac sleeps overnight, user opens it in the morning), this means signing in once per day at most.

**Pros:** Simple, secure, no credentials stored, already working
**Cons:** User friction after sleep

### Option B: Implement SRP authentication in Swift
Store Apple ID + password in Keychain (with user consent). When session dies, re-authenticate programmatically using SRP protocol + stored trust token. This is the pyicloud approach.

**Pros:** Sessions survive indefinitely (up to trust token expiry of ~2 months)
**Cons:** Requires storing password, implementing Apple's custom SRP variant (2048-bit, SHA256, PBKDF2, Apple-specific deviations), handling 2FA, maintaining compatibility with Apple's auth changes

### Option C: Fix the `accountLogin` approach
The `X-APPLE-DS-WEB-SESSION-TOKEN` cookie value was successfully captured. `accountLogin` returned 400, not 421, suggesting the request is close but malformed. With the right headers and payload format (potentially matching pyicloud's exact structure more closely), this might work without needing full SRP.

**Pros:** No password storage needed, moderate effort
**Cons:** HTTP 400 might indicate the token itself is wrong type, not just formatting. Needs investigation of the exact error response.

### Option D: Companion app (CloudKit approach)
Build a lightweight iOS companion app that reports its own battery level to CloudKit. Mac app reads from CloudKit. No web API, no session expiry, persistent forever.

**Pros:** Most reliable, uses public Apple APIs, no reverse engineering
**Cons:** Requires app on every device, can't passively detect devices

## Recommendation for External Expert

The most productive areas for review are:

1. **Option C investigation** — what exactly does `accountLogin` HTTP 400 mean? Is the `X-APPLE-DS-WEB-SESSION-TOKEN` cookie value the correct `dsWebAuthToken`, or is it a different token? What headers does `accountLogin` require beyond `Content-Type`?

2. **Can `accountLogin` be called right after wake** (when `validate` still returns 200 but FMIP is dead) to proactively re-establish the FMIP session before it's needed?

3. **Is there a lighter re-auth endpoint** that refreshes just the FMIP session without requiring full `accountLogin`?

4. **Any approach to keep the FMIP session alive during sleep** — perhaps via a scheduled background task that pings `refreshClient` before the Mac fully sleeps?
