import Foundation
import os

private let log = Logger(subsystem: "dev.studiojoe.Core", category: "TrackMetadataService")

public actor TrackMetadataService {
    private let spotify: SpotifyCatalog
    private var cache: [String: TrackFeatures] = [:]

    public init(spotifyCatalog: SpotifyCatalog) {
        self.spotify = spotifyCatalog
    }

    public func features(for source: TrackSource) async -> TrackFeatures {
        let key = source.cacheKey
        if let hit = cache[key] { return hit }

        let fetched: TrackFeatures
        switch source {
        case .spotify(let id):
            fetched = await fetchSpotify(id: id)
        case .appleWithBPM(let bpm):
            fetched = TrackFeatures(tempoBPM: bpm)
        case .appleUnknown, .unknown:
            fetched = TrackFeatures()
        }
        cache[key] = fetched
        return fetched
    }

    public func reset() {
        cache.removeAll(keepingCapacity: true)
    }

    private func fetchSpotify(id: String) async -> TrackFeatures {
        do {
            let f = try await spotify.audioFeatures(trackID: id)
            log.info("spotify audio-features \(id, privacy: .public): bpm=\(f.tempoBPM ?? -1)")
            return f
        } catch {
            log.error("spotify audio-features failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return TrackFeatures()
        }
    }
}
