import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import UIKit

/// Reduces a picture to one pixel per glyph.
///
/// The obvious implementation walks the full-resolution image and averages
/// blocks by hand, which is both slow and worse: Core Graphics already box
/// filters when it scales, in optimised code, on the GPU where it can. So the
/// whole job is one draw into a tiny context, and the tiny context *is* the
/// answer. A four thousand pixel photo becomes a hundred and twenty numbers
/// wide in about a millisecond.
final class ImageSampler {
    /// Reused across frames of a video. Building one per frame is the single
    /// most expensive mistake available here.
    private lazy var ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Sample `image` down to `columns` by `rows`, tightly packed RGBA8.
    func sample(image: CGImage, columns: Int, rows: Int) -> [UInt8]? {
        guard columns > 0, rows > 0 else { return nil }

        let bytesPerRow = columns * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * rows)

        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue

        let drawn: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                      data: base,
                      width: columns,
                      height: rows,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: space,
                      bitmapInfo: info
                  )
            else { return false }

            // Low, not high. High interpolation on a reduction this extreme
            // sharpens edges into ringing, and every ring becomes a wrong
            // character. A box average is what the medium wants.
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }

        return drawn ? buffer : nil
    }

    /// The same, for a video frame.
    func sample(pixelBuffer: CVPixelBuffer, columns: Int, rows: Int) -> [UInt8]? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return sample(image: cg, columns: columns, rows: rows)
    }

    /// Pixel dimensions of a video frame, for laying the grid out.
    static func size(of pixelBuffer: CVPixelBuffer) -> CGSize {
        CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
    }
}
