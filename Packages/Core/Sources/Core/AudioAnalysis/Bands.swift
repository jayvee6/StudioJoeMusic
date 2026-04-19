import Foundation

public struct Bands: Sendable, Equatable {
    public var bass: Float
    public var mid: Float
    public var treble: Float
    public var beatPulse: Float

    public init(bass: Float = 0, mid: Float = 0, treble: Float = 0, beatPulse: Float = 0) {
        self.bass = bass
        self.mid = mid
        self.treble = treble
        self.beatPulse = beatPulse
    }

    public static let zero = Bands()
}

public struct Spectrum: Sendable, Equatable {
    public var magnitudes: [Float]
    public var bands: Bands
    public var sampleHostTimeSec: Double

    public init(binCount: Int = 32) {
        self.magnitudes = Array(repeating: 0, count: binCount)
        self.bands = .zero
        self.sampleHostTimeSec = 0
    }
}
