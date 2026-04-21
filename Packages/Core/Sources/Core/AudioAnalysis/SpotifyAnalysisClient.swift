import Foundation
import os

private let log = Logger(subsystem: "dev.studiojoe.Core", category: "SpotifyAnalysisClient")

/// Decoded Spotify `/v1/audio-analysis/{id}` payload. Field names match the
/// Spotify JSON exactly (snake_case) so the default JSONDecoder succeeds
/// without a custom keyDecodingStrategy — fewer moving parts, fewer failures.
///
/// `Codable` (not just `Decodable`) so we can round-trip to the on-disk cache
/// via `JSONEncoder`. Spotify's audio analysis for a given track ID is the
/// deterministic output of a fixed DSP pipeline — it never changes for a
/// released recording — so persisting these blobs verbatim is safe.
public struct SpotifyAudioAnalysis: Codable, Sendable {
    public struct Track: Codable, Sendable {
        public let tempo: Double
        public let duration: Double
        public let time_signature: Int
        public let loudness: Double
    }
    public struct Section: Codable, Sendable {
        public let start: Double
        public let duration: Double
        public let loudness: Double
        public let tempo: Double
    }
    public struct Segment: Codable, Sendable {
        public let start: Double
        public let duration: Double
        public let loudness_start: Double
        public let loudness_max: Double
        public let loudness_max_time: Double
        public let pitches: [Double]
        public let timbre: [Double]
    }
    public struct Beat: Codable, Sendable {
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
///
/// Cache layers, checked in order on every `analysis(for:)` call:
///   1. In-memory dictionary — fastest, cleared on process death.
///   2. On-disk JSON under `Caches/SpotifyAnalysis/{trackID}.json` — survives
///      app relaunches; iOS may auto-evict under storage pressure, which is
///      the intended behaviour (no LRU or TTL needed, since the analysis for
///      a given track ID is immutable).
///   3. Network fetch from the Spotify Web API. On success the result is
///      written to both layers.
public actor SpotifyAnalysisClient {
    private let auth: SpotifyAuth
    private var memoryCache: [String: SpotifyAudioAnalysis] = [:]
    private let session: URLSession
    private let cacheDir: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

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

        // Caches directory is the correct home for regeneratable data on iOS:
        // the system may evict it under storage pressure, and it's excluded
        // from iCloud backups by default. `createDirectory` with
        // `withIntermediateDirectories: true` is a no-op if the directory
        // already exists, so we can call it unconditionally on every init.
        let caches = FileManager.default.urls(for: .cachesDirectory,
                                              in: .userDomainMask).first!
        self.cacheDir = caches.appendingPathComponent("SpotifyAnalysis",
                                                      isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir,
                                                 withIntermediateDirectories: true)
    }

    public func analysis(for trackID: String) async throws -> SpotifyAudioAnalysis {
        if trackID.isEmpty {
            throw Self.error(code: -1, "Empty trackID")
        }

        // 1. In-memory cache — the hot path.
        if let cached = memoryCache[trackID] {
            return cached
        }

        // 2. Disk cache — survives relaunches. Populates memory on hit so
        //    subsequent calls in this process don't re-read/decode.
        if let fromDisk = loadFromDisk(trackID: trackID) {
            memoryCache[trackID] = fromDisk
            log.info("disk cache hit for \(trackID, privacy: .public) — segments=\(fromDisk.segments.count) beats=\(fromDisk.beats.count)")
            return fromDisk
        }

        // 3. Network fetch — authoritative source. Writes through to both
        //    cache layers on success.
        let fresh = try await fetchFromNetwork(trackID: trackID)
        memoryCache[trackID] = fresh
        saveToDisk(trackID: trackID, analysis: fresh)
        log.info("Cached analysis for \(trackID, privacy: .public) — segments=\(fresh.segments.count) beats=\(fresh.beats.count)")
        return fresh
    }

    public func clearCache() {
        memoryCache.removeAll()
        do {
            let files = try FileManager.default.contentsOfDirectory(at: cacheDir,
                                                                    includingPropertiesForKeys: nil)
            for f in files {
                try? FileManager.default.removeItem(at: f)
            }
            log.info("Cache cleared (memory + \(files.count, privacy: .public) disk files)")
        } catch {
            log.warning("disk cache clear failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Disk cache

    private func loadFromDisk(trackID: String) -> SpotifyAudioAnalysis? {
        let url = cacheDir.appendingPathComponent("\(trackID).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(SpotifyAudioAnalysis.self, from: data)
        } catch {
            // A corrupt or schema-drifted cache file is an `INPUT_INVALID` on
            // the disk-cache contract. Nuke it so the next call falls through
            // to the network and writes a valid blob.
            log.warning("disk cache decode failed for \(trackID, privacy: .public): \(error.localizedDescription, privacy: .public) — removing")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private func saveToDisk(trackID: String, analysis: SpotifyAudioAnalysis) {
        let url = cacheDir.appendingPathComponent("\(trackID).json")
        do {
            let data = try encoder.encode(analysis)
            // `.atomic` writes to a temp file and renames into place, so a
            // crash mid-write can't leave a half-written JSON that the next
            // launch would treat as a valid cache hit.
            try data.write(to: url, options: .atomic)
            log.info("disk cache wrote \(trackID, privacy: .public) (\(data.count, privacy: .public) bytes)")
        } catch {
            // Disk write failures are non-fatal — the caller already has the
            // analysis in memory, and a future launch will just refetch.
            log.warning("disk cache write failed for \(trackID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Network

    private func fetchFromNetwork(trackID: String) async throws -> SpotifyAudioAnalysis {
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

        do {
            return try decoder.decode(SpotifyAudioAnalysis.self, from: data)
        } catch {
            log.error("Decode failed for \(trackID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw Self.error(code: -5,
                             "Failed to decode audio analysis: \(error.localizedDescription)")
        }
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
