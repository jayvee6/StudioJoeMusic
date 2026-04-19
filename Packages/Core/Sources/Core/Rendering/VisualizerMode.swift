import Foundation

public enum VisualizerMode: Int, CaseIterable, Identifiable, Sendable {
    case bars = 0
    case blob = 1

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .bars: return "Bars"
        case .blob: return "Blob"
        }
    }

    public var symbol: String {
        switch self {
        case .bars: return "chart.bar.fill"
        case .blob: return "circle.hexagongrid.fill"
        }
    }
}
