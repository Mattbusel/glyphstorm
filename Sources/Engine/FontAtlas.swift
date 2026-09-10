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
        let cell = FontAtlas.cellPixels

        let size = CGSize(width: cell * CGFloat(cols), height: cell * CGFloat(rows))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        // A monospace face, so every cell is filled the same way and the grid
        // does not wobble. The system monospaced font is guaranteed present,
        // which a bundled font file would not be without shipping it.
        let font = UIFont.monospacedSystemFont(ofSize: cell * 0.78, weight: .medium)

        let image = renderer.image { ctx in
            ctx.cgContext.setFillColor(UIColor.clear.cgColor)
            ctx.cgContext.fill(CGRect(origin: .zero, size: size))

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                // White, so the fragment shader can tint it to any colour by
                // multiplying. A coloured atlas could only ever be one palette.
                .foregroundColor: UIColor.white,
            ]

            for (i, ch) in Ramp.characters.enumerated() {
                let col = i % cols
                let row = i / cols
                let s = String(ch)
                let bounds = s.size(withAttributes: attributes)
                // Centred in its cell, so a glyph's drawn position is its
                // centre and the physics can rotate or scale around it without
                // the character sliding off its own anchor.
                let origin = CGPoint(
                    x: CGFloat(col) * cell + (cell - bounds.width) / 2,
                    y: CGFloat(row) * cell + (cell - bounds.height) / 2
                )
                s.draw(at: origin, withAttributes: attributes)
            }
        }

        guard let cgImage = image.cgImage else { return nil }

        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        ]
        guard let tex = try? loader.newTexture(cgImage: cgImage, options: options) else {
            return nil
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
