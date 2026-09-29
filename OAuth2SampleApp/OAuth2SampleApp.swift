//
//  OAuth2SampleApp.swift
//  OAuth2SampleApp
//
//  Sample iOS app (SwiftUI) demonstrating OAuth 2.0 Authorization Code + PKCE
//  for "Login with X".
//
//  Three modes (matching the Android OAuth2SampleApp-Android):
//  1. Normal / Recommended: Uses ASWebAuthenticationSession + https authorize URL.
//     This is the production approach most third-party iOS apps should use.
//  2. Debug / X app test mode: Uses UIApplication.open with twitter://oauth2-debug
//     (or the https Universal Link) to exercise the official X app's native consent flow.
//  3. Grok custom start_flow: Targets https://x.com/i/oauth2_start_flow, the custom
//     entry point Grok uses. The server (oauth2MobileRedirect middleware) 302-redirects
//     it to /i/oauth2/authorize, passing all query params through. Useful for verifying
//     the start_flow redirect works for any app (gated by the allow_all_oauth2_mobile_redirect
//     decider), not just the Grok client IDs.
//
//  The callback uses a custom URL scheme (oauthsample://callback) so no Universal Links
//  / App Links configuration is required for the redirect.
//

import SwiftUI
import CryptoKit
import AuthenticationServices

@main
struct OAuth2SampleApp: App {
    @StateObject private var oauthState = OAuthState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(oauthState)
                .onOpenURL { url in
                    oauthState.handleCallback(url: url)
                }
        }
    }
}

// MARK: - OAuth State

@MainActor
final class OAuthState: NSObject, ObservableObject {
    enum AuthStatus {
        case loggedOut
        case authorizing
        case authorized(code: String)
        case denied(message: String)
        case error(message: String)
    }

    @Published var authStatus: AuthStatus = .loggedOut
    @Published var user: UserInfo?

    // PKCE values (generated fresh each flow)
    private(set) var codeVerifier: String = ""
    private(set) var codeChallenge: String = ""
    private(set) var state: String = ""

    // Configuration (kept in sync with Android sample)
    let clientID = "WUlXXzMyWDJZSjJWdEFPMjZuRHU6MTpjaQ"
    let redirectURI = "oauthsample://callback"
    let scopes = "tweet.read tweet.write users.read like.write bookmark.write mute.write offline.access"

    // Normal flow (recommended for production apps) uses ASWebAuthenticationSession
    // against the real https authorize endpoint. This is the iOS equivalent of
    // "Use Custom Tabs" in the Android sample.
    @Published var useNormalWebFlow = true

    // When enabled, forces the twitter://oauth2-debug scheme + plain open so the
    // official X app can take over and show its native OAuth consent screen.
    // Useful for testing changes to the X app's consent UI (side-by-side on simulator or device).
    @Published var useDebugScheme = false

    // When enabled, targets the custom Grok entry point /i/oauth2_start_flow instead of
    // /i/oauth2/authorize. The server-side oauth2MobileRedirect middleware 302-redirects it to
    // /i/oauth2/authorize, forwarding all query params. Lets us confirm the custom start_flow
    // works for arbitrary client IDs (with the allow_all_oauth2_mobile_redirect decider on).
    // Only applies to the https web flow (ignored when the debug scheme is used).
    @Published var useGrokStartFlow = false

    struct UserInfo {
        let name: String
        let username: String
        let avatarURL: URL?
    }

    func startFlow() {
        user = nil
        authStatus = .authorizing

        codeVerifier = generateCodeVerifier()
        codeChallenge = generateCodeChallenge(verifier: codeVerifier)
        state = UUID().uuidString

        let queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        // Decide target URL first (debug scheme for X app native testing vs real https).
        let targetURL: URL
        if useDebugScheme {
            var components = URLComponents()
            components.scheme = "twitter"
            components.host = "oauth2-debug"
            components.queryItems = queryItems
            guard let url = components.url else {
                authStatus = .error(message: "Failed to build authorize URL")
                return
            }
            targetURL = url
        } else {
            var components = URLComponents()
            components.scheme = "https"
            components.host = "x.com"
            // Grok custom flow uses /i/oauth2_start_flow, which the server redirects to
            // /i/oauth2/authorize. Otherwise hit the authorize endpoint directly.
            components.path = useGrokStartFlow ? "/i/oauth2_start_flow" : "/i/oauth2/authorize"
            // Match GrokModel.rearrangeNativeXAuthURL byte-for-byte: Grok appends a trailing
            // dummy_param to its start_flow URL. Mirror it so we exercise the identical request.
            components.queryItems = useGrokStartFlow
                ? queryItems + [URLQueryItem(name: "dummy_param", value: "DUMMY")]
                : queryItems
            guard let url = components.url else {
                authStatus = .error(message: "Failed to build authorize URL")
                return
            }
            targetURL = url
        }

        // Launch method: normal = ASWebAuthenticationSession (recommended / secure),
        // otherwise = plain open (allows X app or Safari to take over more easily).
        // This mirrors the Android sample's useCustomTabs + useDebugScheme independence.
        if useNormalWebFlow && !useDebugScheme {
            // Clean normal path: real https + secure session (ASWebAuthenticationSession is
            // the iOS equivalent of Custom Tabs and resists Universal Link hijacking better).
            startWebAuthSession(authorizeURL: targetURL)
        } else {
            // Plain open path (either because user disabled normal flow, or because we're
            // using the debug scheme so the X app can claim the handoff).
            UIApplication.shared.open(targetURL)
        }
    }

    private var currentWebAuthSession: ASWebAuthenticationSession?

    private func startWebAuthSession(authorizeURL: URL) {
        // Use the custom scheme for the callback. ASWebAuthenticationSession will
        // deliver the matching redirect directly to the completion handler.
        let session = ASWebAuthenticationSession(
            url: authorizeURL,
            callbackURLScheme: "oauthsample"
        ) { [weak self] callbackURL, error in
            guard let self else { return }

            self.currentWebAuthSession = nil

            if let error = error {
                // User cancelled or other session error
                if (error as NSError).domain == ASWebAuthenticationSessionErrorDomain,
                   (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    self.authStatus = .loggedOut
                } else {
                    self.authStatus = .error(message: error.localizedDescription)
                }
                return
            }

            guard let callbackURL else {
                self.authStatus = .error(message: "No callback URL from web auth session")
                return
            }

            self.handleCallback(url: callbackURL)
        }

        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = true  // Good default for sign-in
        session.start()

        currentWebAuthSession = session
    }

    func handleCallback(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            authStatus = .error(message: "Invalid callback URL")
            return
        }

        let params = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        if let errorCode = params["error"] {
            let description = params["error_description"]?.removingPercentEncoding ?? "No description"
            authStatus = .denied(message: "\(errorCode): \(description)")
            return
        }

        guard let code = params["code"] else {
            authStatus = .error(message: "No authorization code in callback")
            return
        }

        let returnedState = params["state"] ?? ""
        if returnedState != state {
            print("[SampleApp] WARNING: State mismatch! Expected=\(state) Got=\(returnedState)")
        }

        authStatus = .authorized(code: code)
        fetchUserProfile(code: code)
    }

    func disconnect() {
        authStatus = .loggedOut
        user = nil
    }

    // MARK: - Token Exchange + User Fetch

    private func fetchUserProfile(code: String) {
        // Exchange auth code for access token (aligned with Android sample)
        var request = URLRequest(url: URL(string: "https://api.x.com/2/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParams = [
            "grant_type=authorization_code",
            "code=\(code)",
            "redirect_uri=\(redirectURI)",
            "client_id=\(clientID)",
            "code_verifier=\(codeVerifier)",
        ]
        request.httpBody = bodyParams.joined(separator: "&").data(using: .utf8)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String else {
                print("[SampleApp] Token exchange failed: \(String(data: data ?? Data(), encoding: .utf8) ?? "nil")")
                return
            }

            DispatchQueue.main.async {
                self?.fetchMe(accessToken: accessToken)
            }
        }.resume()
    }

    private func fetchMe(accessToken: String) {
        var request = URLRequest(url: URL(string: "https://api.x.com/2/users/me?user.fields=profile_image_url,name,username")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let userData = json["data"] as? [String: Any],
                  let name = userData["name"] as? String,
                  let username = userData["username"] as? String else {
                print("[SampleApp] User fetch failed: \(String(data: data ?? Data(), encoding: .utf8) ?? "nil")")
                return
            }

            let avatarURL = (userData["profile_image_url"] as? String).flatMap { URL(string: $0) }
            DispatchQueue.main.async {
                self?.user = UserInfo(name: name, username: username, avatarURL: avatarURL)
            }
        }.resume()
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - ASWebAuthenticationSession Presentation

extension OAuthState: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let windowScene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) else {
            // Fallback (should not normally happen in a foreground app)
            return ASPresentationAnchor()
        }
        return keyWindow
    }
}

// MARK: - UI

struct ContentView: View {
    @EnvironmentObject var oauthState: OAuthState

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            switch oauthState.authStatus {
            case .loggedOut:
                loginView
            case .authorizing:
                ProgressView("Connecting to X...")
                    .font(.headline)
            case .authorized:
                if let user = oauthState.user {
                    loggedInView(user: user)
                } else {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Loading profile...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            case .denied(let message):
                errorView(title: "Access Denied", message: message)
            case .error(let message):
                errorView(title: "Something went wrong", message: message)
            }
        }
    }

    // MARK: - Login

    private var loginView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 24) {
                // App icon
                Image(systemName: "app.connected.to.app.below.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.primary)

                VStack(spacing: 8) {
                    Text("OAuth2 Sample App")
                        .font(.title.bold())

                    Text("Connect your X account to get started.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()

            VStack(spacing: 16) {
                Button(action: { oauthState.startFlow() }) {
                    Text("Sign in with X")
                        .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.black)
                    .foregroundStyle(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 26))
                }

                // Educational toggles (modeled directly after the Android sample)
                VStack(spacing: 12) {
                    Toggle(isOn: $oauthState.useNormalWebFlow) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use secure web session (normal / recommended)")
                                .font(.caption)
                                .fontWeight(.medium)
                            Text("ON = ASWebAuthenticationSession (immune to Universal Links, stays in web). OFF = UIApplication.open, which lets the installed X app claim the link — turn OFF + Grok start_flow ON to mimic Grok's native handoff.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)

                    Toggle(isOn: $oauthState.useGrokStartFlow) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use Grok custom start_flow (/i/oauth2_start_flow)")
                                .font(.caption)
                                .fontWeight(.medium)
                            Text("Hits the custom server entry point that 302-redirects to /i/oauth2/authorize. Tests the start_flow path for any app. Ignored when debug scheme is on.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .disabled(oauthState.useDebugScheme)

                    Toggle(isOn: $oauthState.useDebugScheme) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use debug scheme (twitter://oauth2-debug)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text("For testing the official X app's native OAuth consent screen (side-by-side on simulator).")
                                .font(.caption2)
                                .foregroundStyle(.secondary.opacity(0.7))
                        }
                    }
                    .toggleStyle(.switch)
                }
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
    }

    // MARK: - Logged In

    private func loggedInView(user: OAuthState.UserInfo) -> some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 20) {
                // Avatar
                AsyncImage(url: user.avatarURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 88, height: 88)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(.green, lineWidth: 3)
                )

                VStack(spacing: 4) {
                    Text(user.name)
                        .font(.title2.bold())

                    Text("@\(user.username)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Connected")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.green.opacity(0.1))
                .clipShape(Capsule())
            }

            Spacer()

            VStack(spacing: 12) {
                // Show the auth code (collapsed)
                if case .authorized(let code) = oauthState.authStatus {
                    DisclosureGroup("Authorization Code") {
                        Text(code)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                }

                Button(action: { oauthState.disconnect() }) {
                    Text("Disconnect")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color(.systemGray5))
                        .foregroundStyle(.red)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                }
                .padding(.horizontal, 24)
            }
            .padding(.bottom, 48)
        }
    }

    // MARK: - Error

    private func errorView(title: String, message: String) -> some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.red)

                Text(title)
                    .font(.title3.bold())

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            Button(action: { oauthState.disconnect() }) {
                Text("Try Again")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.black)
                    .foregroundStyle(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 26))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
        }
    }
}
