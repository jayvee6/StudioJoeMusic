import Foundation
import MediaPlayer
import MusicKit
import os

private let log = Logger(subsystem: "dev.studiojoe.Core", category: "AppleMusicKitClient")

/// Resolves `MPMediaItem.persistentID` → MusicKit `Song.isrc` via a library
/// request. Handles auth gracefully: denied/restricted users silently return
/// nil and the caller falls back to BPM-only metadata.
public actor AppleMusicKitClient {
    /// persistentID → isrc. `nil` value means "we looked and there's no ISRC".
    /// Using `Optional<Optional<String>>` via sentinel trick: we read
    /// `cache[id]` to a double-optional — presence-in-dict means "looked up",
    /// and the inner optional carries the result.
    private var cache: [UInt64: String?] = [:]
    private var authRequested = false
    private var cachedAuth: MusicAuthorization.Status = .notDetermined

    public init() {}

    /// Returns the Apple Music ISRC for a library item, or nil if unavailable.
    public func isrc(for persistentID: UInt64) async -> String? {
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
            let isrc = response.items.first?.isrc
            cache[persistentID] = isrc   // Optional<String>; stores nil if missing
            log.info("persistentID=\(persistentID, privacy: .public) → isrc=\(isrc ?? "nil", privacy: .public)")
            return isrc
        } catch {
            log.warning("MusicKit lookup failed for \(persistentID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            cache[persistentID] = nil
            return nil
        }
    }

    public func clearCache() { cache.removeAll() }
}
