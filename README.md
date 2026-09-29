# OAuth2SampleApp (iOS)

A minimal SwiftUI app that signs in with X using **OAuth 2.0 Authorization Code + PKCE**, and doubles as the test harness for the X iOS app's **native app-to-app consent** flow (the XDS consent tray, D1302215).

It is a public OAuth client: there is no client secret anywhere in the app. The callback is a custom URL scheme (`oauthsample://callback`), so no Universal Links / associated-domains setup is needed for the redirect back.

## Requirements

- Xcode 16+, iOS 17+ target
- An X developer app (see *Configuration*)
- For the native-consent tests: an X **dogfood** build installed on the same device or simulator

## Configuration

Everything lives at the top of `OAuthState` in `OAuth2SampleApp/OAuth2SampleApp.swift`:

```swift
let clientID = "…"                                   // OAuth 2.0 Client ID from the developer portal
let redirectURI = "oauthsample://callback"           // must be registered on the app's User authentication settings
let scopes = "tweet.read tweet.write users.read …"   // space-delimited
```

In the developer portal (User authentication settings) the app must have:
- Type of App: **Native App** (public client, PKCE)
- Callback URI: `oauthsample://callback`

Ask the repo owner for a client ID configured this way if you don't have one. The `oauthsample` scheme is declared in `Info.plist`; if you change the scheme, update both.

Signing: `DEVELOPMENT_TEAM` is blank on purpose — pick your team in *Signing & Capabilities* (automatic signing is fine for a simulator or a dev device).

## The three modes

| Toggle (in-app) | What it does | Use it for |
|---|---|---|
| **Use normal web flow** (default on) | `ASWebAuthenticationSession` against `https://x.com/i/oauth2/authorize` | What a real third-party app should do; baseline behaviour |
| **Use X app debug scheme** | `UIApplication.open("twitter://oauth2-debug?<oauth params>")` — hands off straight to the X app's native consent coordinator | Testing the X app's native consent tray on any dogfood build, no AASA needed |
| **Use Grok start_flow** | Targets `https://x.com/i/oauth2_start_flow`, the entry point the Grok app uses (server 302s it to `/i/oauth2/authorize`) | Verifying the Grok hand-off path; Universal Link into the X app via the `/*` catch-all |

With *normal web flow* **off** and *debug scheme* **off**, the app does a plain `UIApplication.open` of the https authorize URL — this is the **real app-to-app Universal Link path**, which only reaches the X app once the AASA for that X app ID includes `/i/oauth2/authorize` (dogfood: D1363910, prod: D1341786). Until then it opens in Safari.

## Testing the X app's native consent (dogfood build)

1. Install an X dogfood build that contains D1302215 (feature switch `ios_native_oauth2_consent_enabled` is already on for all iOS clients) and sign in.
2. Install this sample app on the same device/simulator.
3. In the sample app, turn on **Use X app debug scheme** and tap **Sign in with X**.
4. Expected in the X app: the XDS consent tray — "OAuth2 Sample App wants to access permissions on your account", account chip, the will/won't-be-able-to scope lists (7 scopes overflow into *See All Permissions*), **Authorize App** / **Cancel**.
5. **Authorize App** → X app approves with Hawkeye and redirects to `oauthsample://callback?code=…&state=…`; the sample app exchanges the code (PKCE) and shows the signed-in user.
   **Cancel** (or swipe the tray away) → redirect with `error=access_denied`; the sample app shows "denied".
6. Once the dogfood AASA is live, repeat with both toggles **off** to exercise the real Universal Link hand-off. Same expected result.

The trust gates (untrusted-developer checkbox, sensitive-permissions warning, developer terms) are behind `xlinks_native_oauth_consent_trust_gates_enabled`; the tray states can also be previewed without a server from the X dogfood app's *Dev tools → Debug settings → OAuth Consent Sheet Demo*.

## Simulator tip

`xcrun simctl openurl booted "twitter://oauth2-debug?client_id=…&redirect_uri=oauthsample%3A%2F%2Fcallback&response_type=code&scope=tweet.read%20users.read&state=test&code_challenge=<43+ char S256 challenge>&code_challenge_method=S256"` opens the X app's consent tray directly without this app installed (the redirect back then has nowhere to go, which is fine for UI checks).

## Android

The Android counterpart lives alongside this repo (`OAuth2SampleApp-Android`) and uses the same client ID, redirect URI, and toggles ("Use Custom Tabs" / "Use debug scheme").
