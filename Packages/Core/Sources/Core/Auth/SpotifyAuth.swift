import Foundation
import AuthenticationServices
import CryptoKit
import Observation
import os

private let log = Logger(subsystem: "dev.studiojoe.Core", category: "SpotifyAuth")

public struct SpotifyToken: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var tokenType: String
    public var scope: String
    public var expiresAt: Date

    public var isValid: Bool { Date() < expiresAt.addingTimeInterval(-60) }
}

@MainActor
@Observable
public final class SpotifyAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    public private(set) var token: SpotifyToken?
    public private(set) var isAuthorizing = false
    public private(set) var profile: SpotifyProfile?
    public private(set) var lastError: String?

    public var isConnected: Bool { token?.isValid == true }

    private static let tokenKey = "spotify.token.json"

    public override init() {
        super.init()
        loadFromKeychain()
    }

    // MARK: - Public flow

    public func connect() async {
        guard AppConfig.isSpotifyConfigured else {
            lastError = "Spotify not configured — set SPOTIFY_CLIENT_ID in Info.plist."
            return
        }
        isAuthorizing = true
        defer { isAuthorizing = false }
        do {
            let verifier = Self.generateCodeVerifier()
            let challenge = Self.codeChallenge(for: verifier)
            let authURL = try makeAuthURL(challenge: challenge)

            let callbackURL = try await startAuthSession(url: authURL)
            guard let code = Self.queryItem(name: "code", in: callbackURL) else {
                if let err = Self.queryItem(name: "error", in: callbackURL) {
                    throw NSError(domain: "SpotifyAuth", code: -2,
                                  userInfo: [NSLocalizedDescriptionKey: "Spotify returned error: \(err)"])
                }
                throw NSError(domain: "SpotifyAuth", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "No authorization code in callback"])
            }

            let newToken = try await exchangeCode(code, verifier: verifier)
            self.token = newToken
            saveToKeychain(newToken)
            await refreshProfile()
            lastError = nil
            log.info("Spotify connected")
        } catch {
            lastError = (error as NSError).localizedDescription
            log.error("Connect failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func signOut() {
        token = nil
        profile = nil
        try? KeychainStore.delete(forKey: Self.tokenKey)
    }

    /// Return a valid access token, refreshing transparently if the current one is near expiry.
    public func validAccessToken() async throws -> String {
        guard let token else {
            throw NSError(domain: "SpotifyAuth", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "Not connected to Spotify"])
        }
        if token.isValid { return token.accessToken }
        guard let refresh = token.refreshToken else {
            throw NSError(domain: "SpotifyAuth", code: -11,
                          userInfo: [NSLocalizedDescriptionKey: "Token expired and no refresh token"])
        }
        let refreshed = try await refreshToken(refresh)
        self.token = refreshed
        saveToKeychain(refreshed)
        return refreshed.accessToken
    }

    public func refreshProfile() async {
        guard let t = try? await validAccessToken() else { return }
        do {
            let url = URL(string: "https://api.spotify.com/v1/me")!
            var req = URLRequest(url: url)
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: req)
            self.profile = try JSONDecoder().decode(SpotifyProfile.self, from: data)
        } catch {
            log.error("Profile fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - PKCE helpers

    private static func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncodedString()
    }

    private func makeAuthURL(challenge: String) throws -> URL {
        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: AppConfig.spotifyClientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: AppConfig.spotifyRedirectURI),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "scope", value: AppConfig.spotifyAuthScopes.joined(separator: " ")),
            .init(name: "show_dialog", value: "true")
        ]
        guard let url = comps.url else {
            throw NSError(domain: "SpotifyAuth", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot build authorize URL"])
        }
        return url
    }

    private func startAuthSession(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: AppConfig.spotifyCallbackScheme
            ) { callbackURL, error in
                if let error = error {
                    continuation.resume(throwing: error); return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: NSError(domain: "SpotifyAuth", code: -4,
                        userInfo: [NSLocalizedDescriptionKey: "No callback URL"]))
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    private func exchangeCode(_ code: String, verifier: String) async throws -> SpotifyToken {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": AppConfig.spotifyRedirectURI,
            "client_id": AppConfig.spotifyClientID,
            "code_verifier": verifier
        ]
        req.httpBody = Self.formEncode(body).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.throwIfHTTPError(response: response, data: data, domain: "token exchange")
        return try Self.decodeToken(data: data)
    }

    private func refreshToken(_ refresh: String) async throws -> SpotifyToken {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": AppConfig.spotifyClientID
        ]
        req.httpBody = Self.formEncode(body).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.throwIfHTTPError(response: response, data: data, domain: "refresh")
        var newToken = try Self.decodeToken(data: data)
        if newToken.refreshToken == nil { newToken.refreshToken = refresh }
        return newToken
    }

    // MARK: - Keychain persistence

    private func saveToKeychain(_ t: SpotifyToken) {
        if let data = try? JSONEncoder().encode(t),
           let str = String(data: data, encoding: .utf8) {
            try? KeychainStore.set(str, forKey: Self.tokenKey)
        }
    }

    private func loadFromKeychain() {
        if let str = try? KeychainStore.get(forKey: Self.tokenKey),
           let data = str.data(using: .utf8),
           let t = try? JSONDecoder().decode(SpotifyToken.self, from: data) {
            self.token = t
        }
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    // MARK: - Helpers

    private static func formEncode(_ dict: [String: String]) -> String {
        dict.map { "\($0.key)=\(Self.urlEncoded($0.value))" }
            .joined(separator: "&")
    }

    private static func urlEncoded(_ s: String) -> String {
        var cs = CharacterSet.urlQueryAllowed
        cs.remove(charactersIn: "+&=?")
        return s.addingPercentEncoding(withAllowedCharacters: cs) ?? s
    }

    private static func queryItem(name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    private static func throwIfHTTPError(response: URLResponse,
                                          data: Data,
                                          domain: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200...299).contains(http.statusCode) else { return }
        let body = String(data: data, encoding: .utf8) ?? "<no body>"
        throw NSError(domain: "SpotifyAuth.\(domain)", code: http.statusCode,
                      userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
    }

    private static func decodeToken(data: Data) throws -> SpotifyToken {
        struct TokenResponse: Decodable {
            let access_token: String
            let token_type: String
            let expires_in: Int
            let refresh_token: String?
            let scope: String?
        }
        let r = try JSONDecoder().decode(TokenResponse.self, from: data)
        return SpotifyToken(
            accessToken: r.access_token,
            refreshToken: r.refresh_token,
            tokenType: r.token_type,
            scope: r.scope ?? "",
            expiresAt: Date().addingTimeInterval(TimeInterval(r.expires_in))
        )
    }
}

public struct SpotifyProfile: Codable, Sendable {
    public let id: String
    public let display_name: String?
    public let email: String?
    public let product: String?   // "premium" | "free" | "open"
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
