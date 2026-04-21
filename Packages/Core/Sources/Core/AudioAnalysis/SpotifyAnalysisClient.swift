import Foundation
import os

private let log = Logger(subsystem: "dev.studiojoe.Core", category: "SpotifyAnalysisClient")

/// Decoded Spotify `/v1/audio-analysis/{id}` payload. Field names match the
/// Spotify JSON exactly (snake_case) so the default JSONDecoder succeeds
/// without a custom keyDecodingStrategy — fewer moving parts, fewer failures.
public struct SpotifyAudioAnalysis: Decodable, Sendable {
    public struct Track: Decodable, Sendable {
        public let tempo: Double
        public let duration: Double
        public let time_signature: Int
        public let loudness: Double
    }
    public struct Section: Decodable, Sendable {
        public let start: Double
        public let duration: Double
        public let loudness: Double
        public let tempo: Double
    }
    public struct Segment: Decodable, Sendable {
        public let start: Double
        public let duration: Double
        public let loudness_start: Double
        public let loudness_max: Double
        public let loudness_max_time: Double
        public let pitches: [Double]
        public let timbre: [Double]
    }
    public struct Beat: Decodable, Sendable {
        public let start: Double
        public let duration: Double
        public let confidence: Double
    }
    public let track: Track
    public let sections: [Section]
    public let segments: [Segment]
    public let beats: [Beat]
    public let tatums: [Beat]
    public let bars: [Beat]
}

/// Fetches and caches Spotify audio-analysis payloads.
///
/// An actor to provide serial access to the in-memory cache without locks.
/// `SpotifyAuth` is `@MainActor`-isolated, so token acquisition hops to the
/// main actor via `await`.
public actor SpotifyAnalysisClient {
    private let auth: SpotifyAuth
    private var cache: [String: SpotifyAudioAnalysis] = [:]
    private let session: URLSession

    public init(auth: SpotifyAuth) {
        self.auth = auth
        // Dedicated configuration — we don't want shared caches polluting here,
        // and we want a tight network timeout so a hung request can't block
        // the visualizer indefinitely.
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    public func analysis(for trackID: String) async throws -> SpotifyAudioAnalysis {
        if trackID.isEmpty {
            throw Self.error(code: -1, "Empty trackID")
        }
        if let cached = cache[trackID] {
            return cached
        }

        let token = try await auth.validAccessToken()
        let urlString = "https://api.spotify.com/v1/audio-analysis/\(trackID)"
        guard let url = URL(string: urlString) else {
            throw Self.error(code: -2, "Could not build URL for trackID=\(trackID)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        log.info("GET \(urlString, privacy: .public) track=\(trackID, privacy: .public)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            log.error("Network error for \(trackID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw Self.error(code: -3,
                             "Network error fetching audio analysis: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw Self.error(code: -4, "Non-HTTP response")
        }

        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            let snippet = Self.bodySnippet(data)
            log.error("Auth failure \(http.statusCode, privacy: .public) for \(trackID, privacy: .public): \(snippet, privacy: .public)")
            throw Self.error(code: http.statusCode,
                             "Spotify auth failed (HTTP \(http.statusCode)) — re-authenticate")
        case 404:
            log.info("No analysis for \(trackID, privacy: .public) (404)")
            throw Self.error(code: 404,
                             "No audio analysis available for this track")
        default:
            let snippet = Self.bodySnippet(data)
            log.error("HTTP \(http.statusCode, privacy: .public) for \(trackID, privacy: .public): \(snippet, privacy: .public)")
            throw Self.error(code: http.statusCode,
                             "Spotify returned HTTP \(http.statusCode)")
        }

        let analysis: SpotifyAudioAnalysis
        do {
            analysis = try JSONDecoder().decode(SpotifyAudioAnalysis.self, from: data)
        } catch {
            log.error("Decode failed for \(trackID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw Self.error(code: -5,
                             "Failed to decode audio analysis: \(error.localizedDescription)")
        }

        cache[trackID] = analysis
        log.info("Cached analysis for \(trackID, privacy: .public) — segments=\(analysis.segments.count) beats=\(analysis.beats.count)")
        return analysis
    }

    public func clearCache() {
        cache.removeAll()
        log.info("Cache cleared")
    }

    // MARK: - Helpers

    private static func error(code: Int, _ message: String) -> NSError {
        NSError(domain: "SpotifyAnalysisClient",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Truncate response bodies for logging so we never spill large payloads or
    /// accidentally include tokens echoed by an upstream error page.
    private static func bodySnippet(_ data: Data, limit: Int = 200) -> String {
        guard let s = String(data: data, encoding: .utf8) else { return "<binary body>" }
        if s.count <= limit { return s }
        return String(s.prefix(limit)) + "…"
    }
}
