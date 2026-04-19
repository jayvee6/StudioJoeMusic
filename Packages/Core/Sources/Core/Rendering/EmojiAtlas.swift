import Metal
import CoreGraphics
import CoreText
import Foundation
import UIKit

public final class EmojiAtlas {
    public let texture: MTLTexture
    public let emojis: [String]
    public let columns: Int
    public let rows: Int
    public let cellSize: Int

    public static let defaultEmojis: [String] = [
        "🎵", "🎶", "🎧", "🎤",
        "🎸", "🎹", "🥁", "🎺",
        "🪩", "💿", "🎷", "✨"
    ]

    public enum Error: Swift.Error {
        case contextCreationFailed
        case textureCreationFailed
    }

    public init(device: MTLDevice,
                emojis: [String] = EmojiAtlas.defaultEmojis,
                columns: Int = 4,
                cellSize: Int = 128) throws {
        self.emojis = emojis
        self.columns = columns
        self.cellSize = cellSize
        let rows = Int(ceil(Double(emojis.count) / Double(columns)))
        self.rows = rows

        let width = columns * cellSize
        let height = rows * cellSize
        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        var buffer = [UInt8](repeating: 0, count: byteCount)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = buffer.withUnsafeMutableBufferPointer({ ptr -> CGContext? in
            CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            )
        }) else {
            throw Error.contextCreationFailed
        }

        ctx.setFillColor(UIColor.clear.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let fontSize = CGFloat(cellSize) * 0.72
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, fontSize, nil)

        for (i, glyph) in emojis.enumerated() {
            let col = i % columns
            let row = i / columns
            let cellX = col * cellSize
            // Flip row so index 0 is top-left in the final texture (CG origin is bottom-left)
            let cellY = (rows - 1 - row) * cellSize

            let attributed = NSAttributedString(
                string: glyph,
                attributes: [.font: font])
            let line = CTLineCreateWithAttributedString(attributed)
            let bounds = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])

            let drawX = CGFloat(cellX) + (CGFloat(cellSize) - bounds.width) / 2 - bounds.minX
            let drawY = CGFloat(cellY) + (CGFloat(cellSize) - bounds.height) / 2 - bounds.minY

            ctx.textPosition = CGPoint(x: drawX, y: drawY)
            CTLineDraw(line, ctx)
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false)
        desc.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: desc) else {
            throw Error.textureCreationFailed
        }

        buffer.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                                mipmapLevel: 0,
                                withBytes: base,
                                bytesPerRow: bytesPerRow)
            }
        }

        self.texture = texture
    }
}
