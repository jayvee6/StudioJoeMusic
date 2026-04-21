import Foundation
import os

private let log = Logger(subsystem: "dev.studiojoe.Core", category: "SpotifyCatalog")

public struct SpotifyTrack: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let artists: [Artist]
    public let album: Album
    public let preview_url: String?
    public let duration_ms: Int
    public let explicit: Bool

    public struct Artist: Codable, Sendable { public let id: String; public let name: String }
    public struct Album: Codable, Sendable {
        public let id: String
        public let name: String
        public let images: [Image]
        public struct Image: Codable, Sendable { public let url: String; public let width: Int?; public let height: Int? }
    }

    public var primaryArtist: String { artists.first?.name ?? "Unknown" }
    public var artworkURL: URL? {
        guard let s = album.images.first?.url else { return nil }
        return URL(string: s)
    }
    public var previewURL: URL? {
        guard let s = preview_url else { return nil }
        return URL(string: s)
    }
}

public actor SpotifyCatalog {
    private let auth: SpotifyAuth

    public init(auth: SpotifyAuth) {
        self.auth = auth
    }

    public func savedTracks(limit: Int = 50, offset: Int = 0) async throws -> [SpotifyTrack] {
        struct Page: Decodable {
            struct Item: Decodable { let track: SpotifyTrack }
            let items: [Item]
        }
        var comps = URLComponents(string: "https://api.spotify.com/v1/me/tracks")!
        comps.queryItems = [
            .init(name: "limit", value: String(limit)),
            .init(name: "offset", value: String(offset)),
            .init(name: "market", value: "from_token")
        ]
        let page: Page = try await getJSON(url: comps.url!)
        return page.items.map(\.track)
    }

    public func searchTracks(query: String, limit: Int = 25) async throws -> [SpotifyTrack] {
        struct SearchResult: Decodable { let tracks: TrackPage }
        struct TrackPage: Decodable { let items: [SpotifyTrack] }
        var comps = URLComponents(string: "https://api.spotify.com/v1/search")!
        comps.queryItems = [
            .init(name: "q", value: query),
            .init(name: "type", value: "track"),
            .init(name: "limit", value: String(limit)),
            .init(name: "market", value: "from_token")
        ]
        let result: SearchResult = try await getJSON(url: comps.url!)
        return result.tracks.items
    }

    public func searchByISRC(_ isrc: String) async throws -> SpotifyTrack? {
        struct SearchResult: Decodable { let tracks: TrackPage }
        struct TrackPage: Decodable { let items: [SpotifyTrack] }
        var comps = URLComponents(string: "https://api.spotify.com/v1/search")!
        comps.queryItems = [
            .init(name: "q", value: "isrc:\(isrc)"),
            .init(name: "type", value: "track"),
            .init(name: "limit", value: "1"),
            .init(name: "market", value: "from_token")
        ]
        do {
            let result: SearchResult = try await getJSON(url: comps.url!)
            let hit = result.tracks.items.first
            log.info("spotify isrc search \(isrc, privacy: .public): \(hit?.id ?? "no-match", privacy: .public)")
            return hit
        } catch {
            let ns = error as NSError
            if ns.code == 404 {
                log.info("spotify isrc search \(isrc, privacy: .public): 404 no-match")
                return nil
            }
            throw error
        }
    }

    public func audioFeatures(trackID: String) async throws -> TrackFeatures {
        struct AudioFeaturesPayload: Decodable {
            let tempo: Double?
            let energy: Double?
            let valence: Double?
            let danceability: Double?
            let key: Int?
            let time_signature: Int?
        }
        let url = URL(string: "https://api.spotify.com/v1/audio-features/\(trackID)")!
        let raw: AudioFeaturesPayload = try await getJSON(url: url)
        return TrackFeatures(
            tempoBPM: raw.tempo,
            energy: raw.energy,
            valence: raw.valence,
            danceability: raw.danceability,
            key: raw.key,
            timeSignature: raw.time_signature
        )
    }

    // MARK: - HTTP helper

    private func getJSON<T: Decodable>(url: URL) async throws -> T {
        let accessToken = try await auth.validAccessToken()
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw NSError(domain: "SpotifyCatalog",
                          code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
