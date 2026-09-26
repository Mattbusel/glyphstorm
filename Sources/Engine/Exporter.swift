import AVFoundation
import CoreGraphics
import Foundation
import UIKit
import simd

/// Writes the artwork out.
///
/// Two kinds of output, both rendered through the same `GlyphRenderer` the
/// preview uses, so what lands in the share sheet is what was on screen. A
/// separate export renderer is how apps end up shipping a "why does the saved
/// one look different" bug.
enum Exporter {
    enum ExportError: Error {
        case renderFailed
        case writerFailed
        case cancelled
    }

    /// How long a still becomes, when it becomes a video.
    ///
    /// A photo has no duration of its own, so the motion has to be given one.
    /// Six seconds is long enough to see the field breathe through a full cycle
    /// and short enough to post anywhere without being trimmed.
    static let stillMotionSeconds: Double = 6

    /// The frame rate everything is written at.
    static let fps: Int32 = 30

    /// The longest video the app will produce.
    ///
    /// A cap, and a kind one: a two minute source at this resolution takes long
    /// enough to render that the user would assume the app had hung, and the
    /// result is not better art than the first fifteen seconds.
    static let maxSeconds: Double = 15

    // MARK: - Still

    /// One frame, as a PNG in the temporary directory.
    static func exportStill(
        renderer: GlyphRenderer,
        size: CGSize,
        viewport: SIMD2<Float>
    ) throws -> URL {
        guard let cg = renderer.renderToImage(
            width: Int(size.width),
            height: Int(size.height),
            viewport: viewport
        ) else { throw ExportError.renderFailed }

        let image = UIImage(cgImage: cg)
        guard let data = image.pngData() else { throw ExportError.renderFailed }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ascii-motion-\(Int(Date().timeIntervalSince1970)).png")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Video

    /// Render the field's motion to an MP4.
    ///
    /// `frameSource` is called once per output frame with that frame's time, and
    /// should update the field's characters if there is anything new to show. A
    /// still returns false forever and the motion comes entirely from the
    /// physics; a video returns true each time it lands a new frame.
    ///
    /// Runs off the main thread. `progress` is called on the main queue.
    static func exportVideo(
        renderer: GlyphRenderer,
        size: CGSize,
        viewport: SIMD2<Float>,
        seconds: Double,
        watermark: Bool = false,
        frameSource: @escaping (Double) -> Void,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        // Even dimensions. H.264 will not encode an odd width or height, and
        // the failure arrives as an opaque -12902 rather than as a message
        // about the number being odd.
        let width = max(Int(size.width) / 2 * 2, 2)
        let height = max(Int(size.height) / 2 * 2, 2)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ascii-motion-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: url)

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            throw ExportError.writerFailed
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                // Generous. The output is dense high-contrast detail on a dark
                // ground, which is the worst case for a codec: starve it and
                // every glyph smears into its neighbour.
                AVVideoAverageBitRateKey: width * height * 12,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )

        guard writer.canAdd(input) else { throw ExportError.writerFailed }
        writer.add(input)
        guard writer.startWriting() else { throw ExportError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        let mark = watermark ? Self.watermark(forWidth: width) : nil

        let total = Int(seconds * Double(fps))
        let dt = Float(1.0 / Double(fps))

        for frame in 0..<total {
            let time = Double(frame) / Double(fps)

            // Let the caller advance the source, then advance the physics by a
            // fixed step. Fixed, not wall clock: an export that ran off the
            // real clock would produce different motion depending on how busy
            // the phone was, which is not something anyone should have to think
            // about after pressing Export.
            frameSource(time)
            renderer.advance(by: dt)

            guard let cg = renderer.renderToImage(
                width: width,
                height: height,
                viewport: viewport
            ) else {
                writer.cancelWriting()
                throw ExportError.renderFailed
            }
            guard let pool = adaptor.pixelBufferPool,
                  let buffer = pixelBuffer(from: cg, pool: pool, width: width, height: height, mark: mark)
            else {
                writer.cancelWriting()
                throw ExportError.renderFailed
            }

            // The writer takes frames as fast as it can and then asks for a
            // pause. Yielding rather than spinning keeps the app responsive
            // enough to show the progress bar moving.
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 4_000_000)
            }

            let stamp = CMTime(value: CMTimeValue(frame), timescale: fps)
            if !adaptor.append(buffer, withPresentationTime: stamp) {
                writer.cancelWriting()
                throw ExportError.writerFailed
            }

            let done = Double(frame + 1) / Double(total)
            await MainActor.run { progress(done) }
        }

        input.markAsFinished()
        await writer.finishWriting()

        guard writer.status == .completed else { throw ExportError.writerFailed }
        return url
    }

    /// Copy a rendered CGImage into a pool-backed pixel buffer.
    private static func pixelBuffer(
        from image: CGImage,
        pool: CVPixelBufferPool,
        width: Int,
        height: Int,
        mark: CGImage? = nil
    ) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess,
              let buffer = out
        else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
            .union(.byteOrder32Little)
        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info.rawValue
        ) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        if let mark {
            // Bottom right. CoreGraphics puts the origin at the bottom left.
            let pad = CGFloat(width) * 0.035
            ctx.draw(mark, in: CGRect(x: CGFloat(width) - CGFloat(mark.width) - pad, y: pad,
                                      width: CGFloat(mark.width), height: CGFloat(mark.height)))
        }
        return buffer
    }

    /// The free tier's corner mark: the four accent squares and the name, on a
    /// dark plate so it reads over any artwork. Small, about a quarter of the
    /// frame's width.
    static func watermark(forWidth width: Int) -> CGImage? {
        let w = max(CGFloat(width) * 0.26, 80)
        let h = w * 0.16
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let drawn = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor(red: 0.043, green: 0.039, blue: 0.063, alpha: 0.72).cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let sq = h * 0.28
            let colors: [UIColor] = [
                UIColor(red: 0.98, green: 0.29, blue: 0.24, alpha: 1),
                UIColor(red: 1.00, green: 0.72, blue: 0.16, alpha: 1),
                UIColor(red: 0.93, green: 0.24, blue: 0.62, alpha: 1),
                UIColor(red: 0.20, green: 0.86, blue: 0.90, alpha: 1),
            ]
            for (i, c) in colors.enumerated() {
                cg.setFillColor(c.cgColor)
                cg.fill(CGRect(x: h * 0.3 + CGFloat(i) * sq * 1.25, y: (h - sq) / 2, width: sq, height: sq))
            }
            let text = NSAttributedString(string: "GLYPHSTORM", attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: h * 0.46, weight: .heavy),
                .foregroundColor: UIColor.white.withAlphaComponent(0.92),
                .kern: h * 0.06,
            ])
            let size = text.size()
            text.draw(at: CGPoint(x: w - size.width - h * 0.3, y: (h - size.height) / 2))
        }
        return drawn.cgImage
    }
}
