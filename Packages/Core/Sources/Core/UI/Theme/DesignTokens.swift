import SwiftUI

public enum StudioJoeColors {
    public static let accent = Color(red: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255)

    public static let label1 = Color.white.opacity(0.92)
    public static let label2 = Color.white.opacity(0.55)
    public static let label3 = Color.white.opacity(0.25)

    public static let fill1 = Color.white.opacity(0.06)
    public static let fill2 = Color.white.opacity(0.11)
    public static let sep   = Color.white.opacity(0.12)

    public static let bgBase = Color.black

    public static let bgStop0 = Color(red: 0x1A / 255, green: 0x23 / 255, blue: 0x7E / 255)
    public static let bgStop1 = Color(red: 0x19 / 255, green: 0x19 / 255, blue: 0x70 / 255)
    public static let bgStop2 = Color(red: 0x0D / 255, green: 0x0D / 255, blue: 0x3A / 255)
    public static let bgStop3 = Color(red: 0x05 / 255, green: 0x05 / 255, blue: 0x10 / 255)
}

public struct BlueHourBackground: View {
    public init() {}

    public var body: some View {
        ZStack {
            StudioJoeColors.bgBase
            GeometryReader { geo in
                let size = geo.size
                let center = UnitPoint(x: 0.35, y: 0.15)
                RadialGradient(
                    gradient: Gradient(stops: [
                        .init(color: StudioJoeColors.bgStop0, location: 0.00),
                        .init(color: StudioJoeColors.bgStop1, location: 0.28),
                        .init(color: StudioJoeColors.bgStop2, location: 0.58),
                        .init(color: StudioJoeColors.bgStop3, location: 1.00)
                    ]),
                    center: center,
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 1.15
                )
            }
        }
        .ignoresSafeArea()
    }
}
