import Foundation
import Metal
import MetalKit
import UIKit

/// The characters an image is drawn with, darkest coverage last.
///
/// Ordered by how much ink each one puts on the page, so mapping luminance to
/// an index is a straight lookup and the result reads as a tonal image rather
/// than as noise. Kept short on purpose: a seventy-character ramp has more
/// levels than the eye can separate at this size and turns dense areas into
/// mush, while a ten-step ramp keeps every glyph individually legible, which is
/// the entire point of the medium.
///
/// The leading space matters. It is the darkest level and it draws nothing,
/// which is what gives the output its holes and stops it reading as a solid
/// rectangle of text.
enum Ramp {
    static let characters: [Character] = Array(" .:-=+*#%@$&8WM")

    static var count: Int { characters.count }

    /// Which glyph a given brightness lands on, 0 (empty) to count - 1.
    @inline(__always)
    static func index(forLuminance l: Float) -> Int {
        let clamped = min(max(l, 0), 1)
        let i = Int(clamped * Float(count - 1) + 0.5)
        return min(max(i, 0), count - 1)
    }
}

/// Every ramp character, drawn once into a single Metal texture.
///
/// Built at runtime rather than shipped as an asset. A prebaked atlas has to be
/// generated for every scale factor and goes stale the moment the ramp changes;
/// drawing it on launch costs a few milliseconds once and is always correct for
/// the device it is running on.
final class FontAtlas {
    /// One texture holding every glyph, laid out in a grid.
    let texture: MTLTexture
    /// How many glyph cells across the texture is.
    let columns: Int
    /// Size of one cell in texture coordinates, for the shader to offset by.
    let cellUV: SIMD2<Float>
    /// Aspect ratio of a glyph cell, width over height.
    ///
    /// Monospace type is taller than it is wide, and a grid that ignores that
    /// stretches the source image horizontally. The field uses this to space
    /// its columns and rows so the picture keeps its proportions.
    let cellAspect: Float

    /// Pixels per glyph cell in the atlas. Generous: the glyphs are drawn small
    /// on screen and sampling down from a larger cell is what keeps their edges
    /// clean when the physics moves them off the pixel grid.
    private static let cellPixels: CGFloat = 64

    init?(device: MTLDevice) {
        let n = Ramp.count
        let cols = 8
        let rows = Int(ceil(Double(n) / Double(cols)))
        let cell = Int(FontAtlas.cellPixels)
        let width = cell * cols
        let height = cell * rows

        // Drawn into a byte buffer and uploaded by hand rather than going
        // through MTKTextureLoader.
        //
        // The loader version failed on the simulator and reported nothing but
        // nil, which cost a full screenshot cycle to even locate. It negotiates
        // pixel formats and storage modes on your behalf, and `.private`
        // storage in particular is not reliably supported there. Doing it
        // manually is twenty more lines and has exactly one behaviour on every
        // device: a known RGBA8 buffer, copied into a shared texture.
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        let font = UIFont.monospacedSystemFont(ofSize: FontAtlas.cellPixels * 0.78, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            // White, so the fragment shader can tint it to any colour by
            // multiplying. A coloured atlas could only ever be one palette.
            .foregroundColor: UIColor.white,
        ]

        let drew: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }

            // A CGContext has its origin at the bottom left and UIKit text
            // drawing assumes the top left, so without this flip every glyph
            // renders upside down.
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)

            UIGraphicsPushContext(ctx)
            defer { UIGraphicsPopContext() }

            for (i, ch) in Ramp.characters.enumerated() {
                let col = i % cols
                let row = i / cols
                let s = String(ch)
                let bounds = s.size(withAttributes: attributes)
                // Centred in its cell, so a glyph's drawn position is its
                // centre and the physics can move it without the character
                // sliding off its own anchor.
                let origin = CGPoint(
                    x: CGFloat(col) * FontAtlas.cellPixels + (FontAtlas.cellPixels - bounds.width) / 2,
                    y: CGFloat(row) * FontAtlas.cellPixels + (FontAtlas.cellPixels - bounds.height) / 2
                )
                s.draw(at: origin, withAttributes: attributes)
            }
            return true
        }
        guard drew else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: descriptor) else { return nil }

        pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            tex.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: bytesPerRow
            )
        }

        self.texture = tex
        self.columns = cols
        self.cellUV = SIMD2<Float>(1.0 / Float(cols), 1.0 / Float(rows))

        // Measured off the face actually being used rather than assumed, since
        // the system monospaced font is not the same on every OS version.
        let advance = "M".size(withAttributes: [.font: font]).width
        let lineHeight = font.lineHeight
        let aspect = lineHeight > 0 ? Float(advance / lineHeight) : 0.6
        self.cellAspect = min(max(aspect, 0.35), 1.0)
    }
}
