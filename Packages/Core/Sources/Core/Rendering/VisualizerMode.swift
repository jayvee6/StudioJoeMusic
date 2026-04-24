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
    case ferrofluid
    case rorschach
    case lunar
    case kaleidoScope
    case dvdMode
    case fireworks
    case spectrogram
    case siriWaveform
    case wireTerrain
    case neonOscilloscope

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .bars:          return "Bars"
        case .blob:          return "Blob"
        case .mandala:       return "Mandala"
        case .hypnoRings:    return "Rings"
        case .spiral:        return "Spiral"
        case .subwoofer:     return "Sub"
        case .emojiVortex:   return "Vortex"
        case .emojiWaves:    return "Waves"
        case .ferrofluid:    return "Ferro"
        case .rorschach:     return "Inkblot"
        case .lunar:         return "Lunar"
        case .kaleidoScope:  return "Kaleido"
        case .dvdMode:       return "DVD"
        case .fireworks:     return "Fireworks"
        case .spectrogram:   return "Spectrogram"
        case .siriWaveform:  return "Siri"
        case .wireTerrain:   return "Terrain"
        case .neonOscilloscope: return "Neon Osc"
        }
    }

    public var symbol: String {
        switch self {
        case .bars:          return "chart.bar.fill"
        case .blob:          return "circle.hexagongrid.fill"
        case .mandala:       return "seal.fill"
        case .hypnoRings:    return "circle.circle.fill"
        case .spiral:        return "tornado"
        case .subwoofer:     return "hifispeaker.fill"
        case .emojiVortex:   return "sparkles"
        case .emojiWaves:    return "wave.3.right"
        case .ferrofluid:    return "waveform.path.ecg"
        case .rorschach:     return "oval.fill"
        case .lunar:         return "moon.fill"
        case .kaleidoScope:  return "hexagon.fill"
        case .dvdMode:       return "tv.fill"
        case .fireworks:     return "party.popper.fill"
        case .spectrogram:   return "waveform.path.ecg.rectangle"
        case .siriWaveform:  return "waveform"
        case .wireTerrain:   return "square.grid.3x3"
        case .neonOscilloscope: return "waveform.circle"
        }
    }

    public var isMetal: Bool {
        self != .bars && self != .dvdMode && self != .fireworks
    }

    public var needsEmojiAtlas: Bool {
        self == .emojiVortex || self == .emojiWaves
    }
}
