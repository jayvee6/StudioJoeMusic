import Foundation

public enum VisualizerMode: Int, CaseIterable, Identifiable, Sendable {
    case bars = 0
    case blob
    case mandala
    case hypnoRings
    case spiral
    case subwoofer
    case emojiVortex
    case emojiWaves

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .bars:        return "Bars"
        case .blob:        return "Blob"
        case .mandala:     return "Mandala"
        case .hypnoRings:  return "Rings"
        case .spiral:      return "Spiral"
        case .subwoofer:   return "Sub"
        case .emojiVortex: return "Vortex"
        case .emojiWaves:  return "Waves"
        }
    }

    public var symbol: String {
        switch self {
        case .bars:        return "chart.bar.fill"
        case .blob:        return "circle.hexagongrid.fill"
        case .mandala:     return "seal.fill"
        case .hypnoRings:  return "circle.circle.fill"
        case .spiral:      return "tornado"
        case .subwoofer:   return "hifispeaker.fill"
        case .emojiVortex: return "sparkles"
        case .emojiWaves:  return "wave.3.right"
        }
    }

    public var isMetal: Bool {
        self != .bars
    }

    public var needsEmojiAtlas: Bool {
        self == .emojiVortex || self == .emojiWaves
    }
}
