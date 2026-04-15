# BatteryBar Authentication — Evolution & Security Trade-offs

## The Problem

BatteryBar fetches device battery data from Apple's iCloud Find My web API. This API requires an authenticated session. The core challenge: **how to maintain a persistent session that survives Mac sleep/wake cycles without requiring the user to re-login constantly.**

## Phase 1: WKWebView Login (v1.0–v5.0)

### How it worked
- User signed in via a visible `WKWebView` loading `icloud.com`
- Apple's own login UI handled credentials, 2FA, and session creation
- Cookies stored in `WKWebsiteDataStore.default()` (shared persistent store)
- API calls made through a hidden WKWebView (v1–v4) or URLSession (v5)

### Why it failed after sleep
- `WKWebView` drops session-only cookies during macOS sleep
- The critical `X-APPLE-WEBAUTH-FMIP` cookie (needed for Find My API) is session-only
- After 3-4 hours of sleep, Apple's server expired the FMIP session
- Even with URLSession (v5) preserving cookies client-side, the server-side session died during inactivity
- No way to re-authenticate without showing the login window again

### Security model
- **Zero credential storage** — the app never saw the user's password
- **Apple handled all auth** — 2FA, session tokens, everything
- **Minimal trust required** — same as signing into icloud.com in a browser
- **Downside** — session died every sleep cycle, requiring manual re-login

## Phase 2: Token-based Recovery Attempts (v6.0–v9.0)

### What we tried
- **v6–v8**: Captured `X-APPLE-DS-WEB-SESSION-TOKEN` cookie and used it with `POST /setup/ws/1/accountLogin` to re-establish sessions silently
- **v7**: Injected JavaScript into WKWebView to intercept XHR response headers from `idmsa.apple.com`
- **v9**: Separated header-derived tokens from cookie-derived tokens, tried `accountLogin` on both FMIP 450 and validate 421

### Why it failed
- The `X-APPLE-DS-WEB-SESSION-TOKEN` cookie is NOT the same as `X-Apple-Session-Token` header
- `accountLogin` returned `{"success":false,"error":"Invalid Session Token"}` — wrong token type
- The real `X-Apple-Session-Token` header is returned from XHR calls inside Apple's login SPA — invisible to both WKWebView navigation delegates and JavaScript (blocked by CORS `Access-Control-Expose-Headers`)
- **No way to get the correct token without making the auth calls directly**

### Security model
- Same as Phase 1 — no credentials stored
- Token capture attempted but failed — tokens were inaccessible from WKWebView

## Phase 3: SRP Authentication (v10.0+, current)

### How it works now

The app implements the same authentication flow as [pyicloud](https://github.com/picklepete/pyicloud), the most widely-used open-source iCloud client:

1. **First login**: User enters Apple ID + password in a native macOS dialog
2. **SRP handshake**: 
   - `GET /appleauth/auth/authorize/signin` — gets session cookies + `scnt` + `X-Apple-Auth-Attributes`
   - `POST /appleauth/auth/signin/init` — sends SRP client public key (A)
   - `POST /appleauth/auth/signin/complete` — sends SRP proof (M1/M2)
   - Password is never sent in plaintext — SRP (Secure Remote Password) protocol proves knowledge of the password without transmitting it
3. **2FA via SMS**: 
   - `PUT /appleauth/auth/verify/phone` — triggers SMS to trusted phone
   - `POST /appleauth/auth/verify/phone/securitycode` — verifies code
   - `GET /appleauth/auth/2sv/trust` — gets trust token (~2 month lifetime)
4. **Session establishment**:
   - `POST /setup/ws/1/accountLogin` — exchanges session token + trust token for full iCloud session
   - Returns DSID, Find My service URLs, and all necessary cookies
5. **Credential storage**: Apple ID, password, and trust token stored in macOS Keychain
6. **Silent re-auth on session death**: When the session expires after sleep, the app repeats steps 2-4 automatically using stored credentials + trust token (skips 2FA)

### Why it works
- Creates a **brand new session from scratch** — doesn't try to revive a dead one
- Trust token skips 2FA for ~2 months
- SRP protocol means the password is cryptographically verified without being transmitted
- URLSession gives full cookie control — no WKWebView quirks
- `refreshClient` (not `initClient`) used for ongoing updates — lighter session requirements

### The security trade-off

**What we gained:**
- Sessions survive indefinitely (weeks to months) without user interaction
- Silent re-auth after sleep — no login prompts
- Same auth mechanism used by pyicloud, Home Assistant iCloud integration, and other trusted tools

**What we traded:**

| Aspect | WKWebView (Phase 1) | SRP (Phase 3) |
|---|---|---|
| Password storage | Never stored | **Stored in macOS Keychain** |
| Who handles auth | Apple's web UI | Our code (SRP implementation) |
| 2FA | Apple's native UI | SMS-based, trust token stored |
| Session lifetime | Hours (dies on sleep) | Weeks to months |
| Attack surface | Minimal | Keychain access = full account access |
| User trust required | Low (just a browser) | **High (app stores credentials)** |

### Specific security considerations

1. **Keychain storage**: The Apple ID password is stored in macOS Keychain, encrypted at rest by the OS. Any app running as the same user with Keychain access could theoretically read it. This is the same security model used by mail clients, VPN apps, and other credential-storing macOS apps.

2. **SRP protocol**: The password is NOT sent in plaintext over the network. SRP (Secure Remote Password, RFC 2945/5054) uses a zero-knowledge proof — the server verifies the client knows the password without the password crossing the wire. Apple's implementation uses SHA256 + 2048-bit group + PBKDF2 key derivation.

3. **Trust token**: Stored in Keychain. Valid for ~2 months. Allows skipping 2FA. If compromised, an attacker could authenticate as the user without the 2FA code (but would still need the password).

4. **No App Store distribution**: This app uses private/reverse-engineered Apple APIs and stores iCloud credentials. It would be rejected from the Mac App Store. Distribution is via direct download with Sparkle OTA updates.

5. **Sign-out clears everything**: Signing out deletes all Keychain entries (password, tokens), cookies, and session data.

### Why this trade-off is acceptable

- **User consent**: The user explicitly enters their credentials and accepts the privacy policy
- **Industry precedent**: pyicloud (used by Home Assistant, serving thousands of users) stores credentials the same way
- **Keychain protection**: macOS Keychain provides OS-level encryption, biometric unlock, and per-app access control
- **The alternative is unusable**: Without credential storage, the app requires re-login after every Mac sleep — making it impractical as a menu bar utility
- **Personal use context**: The app is primarily for the developer's own use, with distribution limited to trusted users who understand the trade-off

## Summary

| Version | Auth Method | Session Lifetime | Credential Storage | User Friction |
|---|---|---|---|---|
| v1–v4 | WKWebView cookies | Hours | None | Re-login after every sleep |
| v5 | URLSession + WKWebView login | Hours (improved) | None | Re-login after every sleep |
| v6–v9 | Token recovery attempts | Hours | Tokens only (failed) | Re-login after every sleep |
| v10+ | SRP + stored credentials | Weeks to months | **Password in Keychain** | One-time setup + 2FA |

The shift from WKWebView to SRP was driven by a fundamental limitation: **Apple's web sessions cannot survive prolonged inactivity, and the tokens needed for silent re-authentication are inaccessible from WKWebView.** The only path to persistent sessions is programmatic re-authentication with stored credentials — the same approach every successful iCloud integration uses.
