import Foundation
import os

private let log = Logger(subsystem: "dev.studiojoe.Core", category: "PreviewAnalysisService")

/// Synthesizes a full-duration `SpotifyAudioAnalysis` for an Apple Music track
/// by downloading its 30-second preview clip, running it through `FFTCore` /
/// `OnsetBPMDetector` offline, and looping the result across the track.
///
/// Used as the fallback tier when Spotify's ISRC-keyed analysis is unavailable
/// (no Spotify auth, no ISRC, no match). The two-tier (memory + disk) cache
/// lives in the shared `JSONDiskCache` actor; this type owns the preview
/// fetch + offline analysis pipeline.
public actor PreviewAnalysisService {
    private let appleMusicKit: AppleMusicKitClient
    private let cache = JSONDiskCache<UInt64, SpotifyAudioAnalysis>(name: "PreviewAnalysis")
    private let session: URLSession

    public init(appleMusicKit: AppleMusicKitClient) {
        self.appleMusicKit = appleMusicKit

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    public func analysis(for persistentID: UInt64,
                         trackDurationSec: Double,
                         bpmHint: Double?) async throws -> SpotifyAudioAnalysis {
        if let cached = await cache.get(persistentID) {
            return cached
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
        log.info("fetched preview, analyzed in \(elapsedMs, privacy: .public)ms, cached — pid=\(persistentID, privacy: .public)")

        await cache.put(persistentID, analysis)
        return analysis
    }

    public func clearCache() async {
        await cache.clear()
    }

    private static func error(code: Int, _ message: String) -> NSError {
        NSError(domain: "PreviewAnalysisService", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
