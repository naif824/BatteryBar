# BatteryBar v3.0 — Progress

## Version History

### v1.0 (original)
- Working app, but data went stale after ~24h with no indication
- Two reported issues: silent staleness + frozen battery values (e.g., 100% when actually 80%)

### v2.0 (first fix round)
Root cause analysis identified 6 issues. Fixed 2 files (ICloudService.swift, AppController.swift):
- **Navigation timeout** — 30s timeout via `withTaskGroup` prevents `isRefreshing` deadlock
- **Hourly re-validation** — `fetchDevices()` calls `setupSession()` every hour instead of caching dsid/findMeRoot forever
- **Broader session expiry detection** — 403/421/450 all treated as session expired; any 4xx from `initClient` clears session; HTML auth pages detected
- **Consecutive failure tracking** — after 3 silent failures, escalates to re-login prompt
- **`defer { isRefreshing = false }`** — guarantees flag resets on any throw
- **Staleness UI** — orange "Data may be outdated" warning after 1h; "Refresh failing (Nx)" counter
- **`parseDevices()` throws** on missing/empty content instead of returning `[]`

### v3.0 (current — soak in progress)
Added 5 changes on top of v2.0:

1. **JSON response validation** — replaced brittle HTML string heuristic (`<!doctype`, `sign in`, etc.) with clean check: if response doesn't start with `{` or `[`, it's not JSON → treat as session expired. Simpler, future-proof.

2. **"Force Refresh Session" menu item** — clears cached session, resets failure counters, triggers immediate refresh. Power user escape hatch without signing out.

3. **Login loop fix** — `LoginWindowController` was auto-completing on stale `X-APPLE-WEBAUTH-TOKEN/USER` cookies from a dead session, causing an infinite open/close loop. Fixed by snapshotting cookie names before loading the page and only firing `onComplete` when genuinely new auth cookies appear.

4. **Thorough `clearAllWebData()`** — wipes all WKWebsiteDataStore data since epoch + HTTPCookieStorage + CookiePersistence in one call. Replaces the old selective icloud/apple filter that missed in-memory and alternate on-disk locations.

5. **Clear stale web data before sign-in** — `signInPressed()` calls `clearAllWebData()` before opening the login window, ensuring a truly fresh login flow. Sign-out also uses the same thorough clear.

## Files Changed (from v1.0)

| File | v2.0 | v3.0 | Status |
|---|---|---|---|
| ICloudService.swift | Changed | Changed | Timeout, revalidation, broad detection, JSON check |
| AppController.swift | Changed | Changed | Failure tracking, staleness UI, Force Refresh Session, clearAllWebData |
| LoginWindowController.swift | — | Changed | Stale cookie detection fix (new-cookie-only detection) |
| main.swift | — | — | Unchanged |
| Models.swift | — | — | Unchanged |
| Persistence.swift | — | — | Unchanged |
| SettingsWindowController.swift | — | — | Unchanged |
| AirPodsBattery.swift | — | — | Unchanged |
| TelemetryService.swift | — | — | Unchanged |

## Current Status

**Soak test in progress.** v3.0 launched with fresh sign-in after full cookie/config/log clear.

### Bug found and fixed during setup
**Login loop:** On first launch after clearing data, the app entered an infinite login open/close cycle. Root cause: stale `X-APPLE-WEBAUTH-TOKEN/USER` cookies survived in `WKWebsiteDataStore.default()` despite deleting `~/Library/WebKit/` dir. `LoginWindowController` detected them immediately and fired `onComplete` → which reset failure counters → `refreshDevices()` failed (450) → reopened login → detected same stale cookies → loop. Fixed with new-cookie-only detection (change #3) and thorough `clearAllWebData()` (changes #4 and #5).

### Refresh intervals
- Device refresh: every 5 minutes (300s)
- Session re-validation: every 1 hour (3600s)
- Also refreshes on: app launch, mac wake, manual Refresh Now, Force Refresh Session

### What to watch during soak
- Battery accuracy at each checkpoint (T+0, T+30m, T+1h, T+6h, T+12h, T+24h, T+30h, T+36h, T+48h)
- "Updated X ago" staying under ~10 minutes
- No orange "Data may be outdated" warning during normal operation
- No login loop
- Log: regular `Got N devices` entries, hourly `validate: HTTP 200`, no repeating errors
- At T+24h: test Force Refresh Session menu item
- At T+30h: test Wi-Fi off for 60s then recovery

### Log location
```
~/Library/Application Support/BatteryBarV7/debug.log
```

### Live monitoring
```bash
tail -f ~/Library/Application\ Support/BatteryBarV7/debug.log | grep -E "(validate|initClient|error|JSON|timed out|Got .* devices)"
```

## Planned v3.1 (if needed after soak)
- Adaptive `/find` recovery — poll cookies for up to 15s instead of fixed 5s sleep
- Exponential backoff on retries (only if soak shows excessive login prompts)

## Known Issues
- One harmless compiler warning: Swift 6 concurrency strictness on `WKNavigationResponse.response` in nonisolated delegate method. Does not affect runtime behavior.
- The `/find` SPA recovery (5s fixed sleep) is still fragile but no longer on the critical path — failures escalate to login prompt instead of silently dying.
