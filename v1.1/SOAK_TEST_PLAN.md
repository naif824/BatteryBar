# BatteryBar v3.0 — 48-Hour Soak Test Plan

## Goal

Validate that v3.0 fixes the two original issues:
1. Data no longer goes stale silently after ~24h
2. Battery levels stay accurate (no frozen values)

And confirm the new defenses work as expected:
- Hourly re-validation catches session degradation
- Consecutive failure tracking escalates to re-login prompt
- Staleness UI appears when data is old
- Navigation timeout prevents permanent `isRefreshing` deadlock

## Setup

- Machine: Primary MacBook (the one that showed the 100% vs 80% bug)
- Duration: 48 hours minimum, spanning at least 2 sleep/wake cycles
- iCloud account: Same account used during v1.0 testing
- Log file: `~/Library/Application Support/BatteryBarV7/debug.log`

### Pre-test

1. Clear the existing debug log:
   ```
   rm ~/Library/Application\ Support/BatteryBarV7/debug.log
   ```

2. Sign out of v1.0 if still running, quit it

3. Launch v3.0 (`BatteryBar v3.0.app`), sign in fresh

4. Confirm all devices load correctly with accurate battery levels

5. Note the current time and actual battery levels of 2-3 devices (screenshot or write down)

## What to Monitor

### Check at these intervals

| Time | What to check |
|---|---|
| T+0 | All devices load, battery levels match reality. Screenshot the menu. |
| T+30m | Early sanity check — confirm first re-validation hasn't caused issues |
| T+1h | Menu still shows fresh data, "Updated X ago" is recent |
| T+6h | Same check — re-validation should have fired ~5 times by now |
| T+12h | Check after a sleep/wake cycle if one happened naturally. Screenshot. |
| T+24h | **Critical checkpoint** — this is where v1.0 broke. Check battery levels match reality. Test "Force Refresh Session" menu item. Screenshot. |
| T+30h | Turn off Wi-Fi for 60 seconds, turn back on. Check recovery. |
| T+36h | Should have survived another sleep/wake. Check log for any errors. |
| T+48h | Final check. Screenshot. Pull full debug.log for review. |

### At each check, record

1. **Menu state**: Do devices show? Are battery levels plausible? Does "Updated X ago" show a recent time?
2. **Staleness warning**: Is the orange "Data may be outdated" label visible? (It should NOT be during normal operation)
3. **Failure counter**: Is "Refresh failing (Nx)" visible? (It should NOT be during normal operation)
4. **Login prompt**: Did a sign-in window appear unexpectedly?
5. **Actual battery**: Compare at least one device's displayed % against its real Settings > Battery value

## What to Look For in debug.log

After the 48h period, pull the log:

```
cat ~/Library/Application\ Support/BatteryBarV7/debug.log
```

### Healthy log patterns (expected)

```
apiRequest: https://setup.icloud.com/setup/ws/1/validate...
validate: HTTP 200
setupSession: dsid=XXXXX, findMeRoot=https://...
apiRequest: https://.../fmipservice/client/web/initClient...
initClient: HTTP 200
Got N devices from Find My
Saved M cookies to persistence
```

This should repeat roughly every 5 minutes (the refresh interval).

Re-validation (`setupSession` calls) should appear roughly every hour — look for `validate: HTTP 200` entries spaced ~1h apart.

### Problem patterns to flag

| Log pattern | Meaning |
|---|---|
| `validate: HTTP 421` or `HTTP 403` | Session expired, app should have prompted re-login |
| `initClient: HTTP 450` | Session degraded, `/find` recovery attempted |
| `initClient got 450 — attempting /find refresh...` | Recovery in progress — check if retry succeeded |
| `Not JSON response (starts with: "...")` | Non-JSON detection fired — session was dead |
| `Navigation timed out after 30s` | WebView hung, timeout worked (good — it didn't deadlock) |
| `No 'content' in response` | Got non-JSON or unexpected response |
| `refreshDevices error (N/3)` | Failure counting in action — check if it escalated at 3 |
| Repeating errors every 5 min with no success between them | Same as v1.0 bug — investigate immediately |

### Key questions the log answers

1. **Did re-validation fire hourly?** Count `validate: HTTP 200` entries — should be ~1 per hour.
2. **Were there any errors?** Search for `error`, `450`, `421`, `403`, `timed out`, `HTML auth`.
3. **Did the app recover from errors?** After any error, is the next cycle successful?
4. **Did the app ever silently stop updating?** Look for gaps >10 min between `Got N devices` entries.

## Success Criteria

The soak test passes if:

- [ ] Battery levels remain accurate throughout 48h (spot-checked at each interval)
- [ ] "Updated X ago" never exceeds ~10 minutes during normal operation
- [ ] No silent stale data — if errors occurred, the menu showed warnings or prompted re-login
- [ ] The debug log shows regular successful refreshes with no unexplained gaps
- [ ] Sleep/wake cycles recovered automatically (refresh succeeded after wake)
- [ ] If session expired, the app detected it and prompted re-login (not silently stuck)

## Failure Scenarios and Next Steps

| Observed behavior | Likely cause | Next step |
|---|---|---|
| Data stale, no warning shown, no login prompt | Error slipping past both `.sessionExpired` catch and consecutive failure threshold | Pull log, identify which error path isn't escalating |
| Login prompt appeared repeatedly (every few hours) | Session lifetime shorter than expected, or re-validation too aggressive | Check log for 421/450 frequency, consider longer revalidation interval |
| "Navigation timed out" appearing frequently | Network issues or WebView in bad state | Check if recovery works after timeout, consider if 30s is too short |
| App works for 24h then breaks at exactly ~24h mark | Same root cause as v1.0 not fully fixed | Pull log around the 24h mark, compare error pattern to v1.0 |
| App works perfectly for 48h | Ship it |

## v3.0-Specific Tests

### Force Refresh Session (at T+24h)

1. Open the menu
2. Click "Force Refresh Session"
3. Open the menu again within 10 seconds
4. Verify: "Updated X ago" shows a fresh timestamp, battery levels updated, no login prompt appeared
5. Check debug.log — should see `clearSession` followed by a fresh `setupSession` + `initClient` cycle

### Network Interruption (at T+30h)

1. Turn off Wi-Fi
2. Wait 60 seconds (one refresh cycle will fail)
3. Turn Wi-Fi back on
4. Wait 5 minutes for next refresh
5. Verify: menu shows fresh data again, "Refresh failing" label disappeared, no login prompt

### Useful log monitoring command

Run this in a terminal during the test to watch key events live:

```bash
tail -f ~/Library/Application\ Support/BatteryBarV7/debug.log | grep -E "(validate|initClient|error|JSON|timed out|Got .* devices)"
```

## After the Test

Share the full `debug.log`, checkpoint screenshots, and notes for review. The log is the ground truth — it will confirm whether the fixes are working or reveal exactly where they aren't.
