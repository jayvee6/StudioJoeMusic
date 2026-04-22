import Foundation
import os

private let log = Logger(subsystem: "dev.studiojoe.Core", category: "PreviewAnalysisService")

/// Synthesizes a full-duration `SpotifyAudioAnalysis` for an Apple Music track
/// by downloading its 30-second preview clip, running it through `FFTCore` /
/// `OnsetBPMDetector` offline, and looping the result across the track.
///
/// Used as the fallback tier when Spotify's ISRC-keyed analysis is unavailable
/// (no Spotify auth, no ISRC, no match). Cache layers mirror
/// `SpotifyAnalysisClient`:
///   1. In-memory (actor-isolated)
///   2. On-disk JSON under `Caches/PreviewAnalysis/{persistentID}.json`
///   3. Fetch + analyze on miss
public actor PreviewAnalysisService {
    private let appleMusicKit: AppleMusicKitClient
    private var memoryCache: [UInt64: SpotifyAudioAnalysis] = [:]
    private let session: URLSession
    private let cacheDir: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(appleMusicKit: AppleMusicKitClient) {
        self.appleMusicKit = appleMusicKit

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)

        let caches = FileManager.default.urls(for: .cachesDirectory,
                                              in: .userDomainMask).first!
        self.cacheDir = caches.appendingPathComponent("PreviewAnalysis",
                                                      isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir,
                                                 withIntermediateDirectories: true)
    }

    public func analysis(for persistentID: UInt64,
                         trackDurationSec: Double,
                         bpmHint: Double?) async throws -> SpotifyAudioAnalysis {
        if let cached = memoryCache[persistentID] {
            return cached
        }

        if let fromDisk = loadFromDisk(persistentID: persistentID) {
            memoryCache[persistentID] = fromDisk
            log.info("disk cache hit for pid=\(persistentID, privacy: .public) — segments=\(fromDisk.segments.count, privacy: .public)")
            return fromDisk
        }

        guard let previewURL = await appleMusicKit.previewURL(for: persistentID) else {
            throw Self.error(code: -1, "No preview URL available for pid=\(persistentID)")
        }

        let (tmpSrc, _) = try await session.download(from: previewURL)
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmpSrc, to: dst)
        defer { try? FileManager.default.removeItem(at: dst) }

        let t0 = Date()
        let analysis = try await Task.detached(priority: .userInitiated) {
            try PreviewAnalyzer.analyze(previewURL: dst,
                                        trackDurationSec: trackDurationSec,
                                        bpmHint: bpmHint)
        }.value
        let elapsedMs = Int(Date().timeIntervalSince(t0) * 1000)
        log.info("PreviewAnalysisService: fetched preview, analyzed in \(elapsedMs, privacy: .public)ms, cached — pid=\(persistentID, privacy: .public)")

        memoryCache[persistentID] = analysis
        saveToDisk(persistentID: persistentID, analysis: analysis)
        return analysis
    }

    public func clearCache() {
        memoryCache.removeAll()
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: cacheDir, includingPropertiesForKeys: nil)
            for f in files { try? FileManager.default.removeItem(at: f) }
            log.info("Cache cleared (memory + \(files.count, privacy: .public) disk files)")
        } catch {
            log.warning("disk cache clear failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Disk

    private func loadFromDisk(persistentID: UInt64) -> SpotifyAudioAnalysis? {
        let url = cacheDir.appendingPathComponent("\(persistentID).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(SpotifyAudioAnalysis.self, from: data)
        } catch {
            log.warning("disk cache decode failed for pid=\(persistentID, privacy: .public): \(error.localizedDescription, privacy: .public) — removing")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    private func saveToDisk(persistentID: UInt64, analysis: SpotifyAudioAnalysis) {
        let url = cacheDir.appendingPathComponent("\(persistentID).json")
        do {
            let data = try encoder.encode(analysis)
            try data.write(to: url, options: .atomic)
        } catch {
            log.warning("disk cache write failed for pid=\(persistentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func error(code: Int, _ message: String) -> NSError {
        NSError(domain: "PreviewAnalysisService", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
