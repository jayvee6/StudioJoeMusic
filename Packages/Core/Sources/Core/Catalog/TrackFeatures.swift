import Foundation

public struct TrackFeatures: Sendable, Equatable {
    public var tempoBPM: Double?
    public var energy: Double?         // 0..1, Spotify audio-features
    public var valence: Double?        // 0..1, mood (sad → happy)
    public var danceability: Double?   // 0..1
    public var key: Int?               // 0..11 (C..B)
    public var timeSignature: Int?     // usually 4

    public init(tempoBPM: Double? = nil,
                energy: Double? = nil,
                valence: Double? = nil,
                danceability: Double? = nil,
                key: Int? = nil,
                timeSignature: Int? = nil) {
        self.tempoBPM = tempoBPM
        self.energy = energy
        self.valence = valence
        self.danceability = danceability
        self.key = key
        self.timeSignature = timeSignature
    }

    public var hasAnyData: Bool {
        tempoBPM != nil || energy != nil || valence != nil
    }
}

public enum TrackSource: Sendable, Hashable {
    case spotify(id: String)
    case appleWithBPM(Double)
    case appleUnknown
    case appleWithISRC(isrc: String, bpm: Double?)
    case unknown

    public var cacheKey: String {
        switch self {
        case .spotify(let id): return "spotify:\(id)"
        case .appleWithBPM(let b): return "apple-bpm:\(b)"
        case .appleUnknown: return "apple-unknown"
        case .appleWithISRC(let isrc, _): return "apple-isrc:\(isrc)"
        case .unknown: return "unknown"
        }
    }
}
