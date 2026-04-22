import Foundation
import MediaPlayer
import MusicKit
import os

private let log = Logger(subsystem: "dev.studiojoe.Core", category: "AppleMusicKitClient")

/// Resolves `MPMediaItem.persistentID` → MusicKit `Song.isrc` and `previewURL`
/// via a library request. Handles auth gracefully: denied/restricted users
/// silently return nil and callers fall back to BPM-only / no-analysis paths.
///
/// ISRC and preview URL share a single lookup — one `MusicLibraryRequest<Song>`
/// populates both. Repeated calls for the same persistentID hit the in-memory
/// cache without re-querying MusicKit.
public actor AppleMusicKitClient {
    private struct SongInfo {
        let isrc: String?
        let previewURL: URL?
    }

    /// persistentID → lookup result. Presence in the dict means "we looked";
    /// `nil` value means the lookup itself failed (unauthorized, catalog miss,
    /// MusicKit error) so neither ISRC nor preview URL is available.
    private var cache: [UInt64: SongInfo?] = [:]
    private var authRequested = false
    private var cachedAuth: MusicAuthorization.Status = .notDetermined

    public init() {}

    /// Returns the Apple Music ISRC for a library item, or nil if unavailable.
    public func isrc(for persistentID: UInt64) async -> String? {
        await fetchSongInfo(for: persistentID)?.isrc
    }

    /// Returns the 30-second preview clip URL for a library item, or nil if
    /// unavailable (non-Apple-Music item, older iTunes purchase, unauthorized).
    public func previewURL(for persistentID: UInt64) async -> URL? {
        await fetchSongInfo(for: persistentID)?.previewURL
    }

    public func clearCache() { cache.removeAll() }

    // MARK: - Private

    private func fetchSongInfo(for persistentID: UInt64) async -> SongInfo? {
        if let hit = cache[persistentID] { return hit }

        if !authRequested {
            cachedAuth = await MusicAuthorization.request()
            authRequested = true
            log.info("MusicKit auth: \(String(describing: self.cachedAuth), privacy: .public)")
        }
        guard cachedAuth == .authorized else {
            cache[persistentID] = nil
            return nil
        }

        do {
            let musicID = MusicItemID(String(persistentID))
            var request = MusicLibraryRequest<Song>()
            request.filter(matching: \.id, equalTo: musicID)
            request.limit = 1
            let response = try await request.response()
            let song = response.items.first
            let info = SongInfo(
                isrc: song?.isrc,
                previewURL: song?.previewAssets?.first?.url
            )
            cache[persistentID] = info
            log.info("pid=\(persistentID, privacy: .public) → isrc=\(info.isrc ?? "nil", privacy: .public) preview=\(info.previewURL != nil ? "yes" : "nil", privacy: .public)")
            return info
        } catch {
            log.warning("MusicKit lookup failed for \(persistentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            cache[persistentID] = nil
            return nil
        }
    }
}
