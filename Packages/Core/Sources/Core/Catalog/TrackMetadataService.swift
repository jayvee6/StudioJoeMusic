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
        case .appleWithISRC(let isrc, let bpm):
            fetched = await fetchAppleISRC(isrc: isrc, fallbackBPM: bpm)
        case .appleUnknown, .unknown:
            fetched = TrackFeatures()
        }
        cache[key] = fetched
        return fetched
    }

    public func reset() {
        cache.removeAll(keepingCapacity: true)
    }

    public func resolveSpotifyTrackID(for source: TrackSource) async -> String? {
        switch source {
        case .spotify(let id): return id
        case .appleWithISRC(let isrc, _):
            do { return try await spotify.searchByISRC(isrc)?.id }
            catch { return nil }
        case .appleWithBPM, .appleUnknown, .unknown: return nil
        }
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

    private func fetchAppleISRC(isrc: String, fallbackBPM: Double?) async -> TrackFeatures {
        do {
            guard let track = try await spotify.searchByISRC(isrc) else {
                log.info("isrc \(isrc, privacy: .public): no spotify match, using fallback bpm=\(fallbackBPM ?? -1)")
                return TrackFeatures(tempoBPM: fallbackBPM)
            }
            do {
                let sf = try await spotify.audioFeatures(trackID: track.id)
                let preferred = sf.tempoBPM ?? fallbackBPM
                log.info("isrc \(isrc, privacy: .public) -> \(track.id, privacy: .public): bpm=\(preferred ?? -1)")
                return TrackFeatures(
                    tempoBPM: preferred,
                    energy: sf.energy,
                    valence: sf.valence,
                    danceability: sf.danceability,
                    key: sf.key,
                    timeSignature: sf.timeSignature
                )
            } catch {
                log.warning("isrc \(isrc, privacy: .public) audio-features failed: \(error.localizedDescription, privacy: .public)")
                return TrackFeatures(tempoBPM: fallbackBPM)
            }
        } catch {
            log.warning("isrc \(isrc, privacy: .public) search failed: \(error.localizedDescription, privacy: .public)")
            return TrackFeatures(tempoBPM: fallbackBPM)
        }
    }
}
