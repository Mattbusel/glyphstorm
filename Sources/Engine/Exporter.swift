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
                  let buffer = pixelBuffer(from: cg, pool: pool, width: width, height: height)
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
        height: Int
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
        return buffer
    }
}
