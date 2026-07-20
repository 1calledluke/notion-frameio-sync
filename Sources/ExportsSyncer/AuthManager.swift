import Foundation
import AppKit
import CryptoKit

/// Manages the Adobe IMS OAuth 2.0 PKCE flow for Frame.io V4 (SPA credential).
///
/// Flow:
///   1. startOAuthFlow() → builds auth URL, opens browser
///   2. Adobe IMS redirects to https://indexvideoproduction.com/frameio-callback?code=...
///   3. That page runs JS: window.location = 'exportsyncer://auth' + window.location.search
///   4. macOS routes exportsyncer:// back to this app via AppDelegate → handleCallbackURL()
///   5. Code exchanged for tokens; refresh token stored in Keychain
///   6. validAccessToken() silently refreshes before each API call
@MainActor
final class AuthManager: NSObject {

    static let shared = AuthManager()

    private let clientID    = Config.load().frameioClientID
    private let authURL     = "https://ims-na1.adobelogin.com/ims/authorize/v2"
    private let tokenURL    = "https://ims-na1.adobelogin.com/ims/token/v3"
    private let scope       = "openid,offline_access,email,profile,additional_info.roles"
    private let redirectURI = "https://indexvideoproduction.com/frameio-callback"

    private let keychainRefreshKey = "frameio_refresh_token"

    private var accessToken: String?
    private var tokenExpiry: Date = .distantPast
    private var codeVerifier: String?
    private var pendingCode: CheckedContinuation<String, Error>?
    private var refreshTask: Task<String, Error>?

    var onAuthCompleted: (() -> Void)?
    var onAuthFailed: ((String) -> Void)?

    // MARK: - Public API

    var hasRefreshToken: Bool {
        Keychain.load(key: keychainRefreshKey) != nil
    }

    func validAccessToken() async throws -> String {
        if let token = accessToken, tokenExpiry > Date().addingTimeInterval(60) {
            return token
        }
        // Coalesce concurrent callers onto a single refresh so Adobe IMS only
        // rotates the refresh token once (a second concurrent refresh would use
        // a stale token and fail, triggering unnecessary re-auth).
        if let task = refreshTask { return try await task.value }
        let task = Task { try await self.refresh() }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    func startOAuthFlow() {
        // Clear in-memory token but keep the keychain refresh token —
        // signOut() is only called when the user explicitly disconnects.
        accessToken = nil
        tokenExpiry = .distantPast

        let verifier  = generateCodeVerifier()
        let challenge = codeChallenge(from: verifier)
        codeVerifier  = verifier

        Task { @MainActor in
            do {
                var comps = URLComponents(string: self.authURL)!
                comps.queryItems = [
                    .init(name: "client_id",             value: self.clientID),
                    .init(name: "redirect_uri",          value: self.redirectURI),
                    .init(name: "scope",                 value: self.scope),
                    .init(name: "response_type",         value: "code"),
                    .init(name: "code_challenge",        value: challenge),
                    .init(name: "code_challenge_method", value: "S256"),
                    .init(name: "state",                 value: UUID().uuidString)
                ]
                guard let authURL = comps.url else {
                    throw AuthError.serverError("Could not build auth URL")
                }
                Log("AuthManager: opening \(authURL.absoluteString)")
                NSWorkspace.shared.open(authURL)

                // Wait for the callback page to bounce to exportsyncer:// and
                // AppDelegate to deliver it via handleCallbackURL()
                let code = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                    self.pendingCode = cont
                }
                try await self.exchangeCode(code)
                Log("AuthManager: OAuth complete")
                self.onAuthCompleted?()
            } catch {
                self.pendingCode = nil
                Log("AuthManager: auth flow error — \(error)")
                self.onAuthFailed?(error.localizedDescription)
            }
        }
    }

    /// Called by AppDelegate when macOS routes the exportsyncer:// callback URI back to us.
    func handleCallbackURL(_ url: URL) {
        Log("AuthManager: got callback URL — \(url.absoluteString)")
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            pendingCode?.resume(throwing: AuthError.noCode)
            pendingCode = nil
            return
        }
        if let code = items.first(where: { $0.name == "code" })?.value {
            pendingCode?.resume(returning: code)
        } else {
            let errDesc = items.first(where: { $0.name == "error_description" })?.value
                ?? items.first(where: { $0.name == "error" })?.value
                ?? "missing code"
            pendingCode?.resume(throwing: AuthError.serverError(errDesc))
        }
        pendingCode = nil
    }

    func signOut() {
        accessToken = nil
        tokenExpiry = .distantPast
        Keychain.delete(key: keychainRefreshKey)
        Log("AuthManager: signed out")
    }

    // MARK: - Token operations

    private func exchangeCode(_ code: String) async throws {
        guard let verifier = codeVerifier else { throw AuthError.missingVerifier }
        codeVerifier = nil

        let body: [String: String] = [
            "grant_type":    "authorization_code",
            "client_id":     clientID,
            "redirect_uri":  redirectURI,
            "code":          code,
            "code_verifier": verifier
        ]
        let tokens = try await postToken(body: body)
        store(tokens: tokens)
    }

    private func refresh() async throws -> String {
        guard let refreshToken = Keychain.load(key: keychainRefreshKey) else {
            throw AuthError.noRefreshToken
        }
        let body: [String: String] = [
            "grant_type":    "refresh_token",
            "client_id":     clientID,
            "refresh_token": refreshToken
        ]
        do {
            let tokens = try await postToken(body: body)
            store(tokens: tokens)
            return tokens.accessToken
        } catch {
            // Don't call signOut() here — a transient network error shouldn't
            // destroy a valid refresh token. The next validAccessToken() call
            // will retry. Only signOut() explicitly clears the token.
            Log("AuthManager: refresh failed — \(error)")
            throw AuthError.refreshFailed(error.localizedDescription)
        }
    }

    private func postToken(body: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)"
        }.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            Log("AuthManager: token endpoint returned: \(msg)")
            throw AuthError.httpError(msg)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func store(tokens: TokenResponse) {
        accessToken = tokens.accessToken
        tokenExpiry = Date().addingTimeInterval(TimeInterval(tokens.expiresIn - 60))
        if let refresh = tokens.refreshToken {
            Keychain.save(key: keychainRefreshKey, value: refresh)
        }
    }

    // MARK: - PKCE

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func codeChallenge(from verifier: String) -> String {
        let data = verifier.data(using: .ascii)!
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Models

private struct TokenResponse: Decodable {
    let accessToken:  String
    let expiresIn:    Int
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case expiresIn    = "expires_in"
        case refreshToken = "refresh_token"
    }
}

enum AuthError: LocalizedError {
    case noRefreshToken
    case missingVerifier
    case refreshFailed(String)
    case httpError(String)
    case noCode
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .noRefreshToken:         return "No Frame.io login found — re-authenticate in Settings"
        case .missingVerifier:        return "PKCE verifier missing — restart auth flow"
        case .refreshFailed(let m):   return "Frame.io login expired: \(m)"
        case .httpError(let m):       return "Auth HTTP error: \(m)"
        case .noCode:                 return "OAuth callback missing authorization code"
        case .serverError(let m):     return "Local auth server error: \(m)"
        }
    }
}
