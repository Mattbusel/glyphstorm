import AVFoundation
import CoreGraphics
import Foundation
import Metal
import simd
import SwiftUI
import UIKit

/// What the user picked.
enum Source {
    case photo(CGImage)
    case video(VideoSource)

    var pixelSize: CGSize {
        switch self {
        case .photo(let image):
            return CGSize(width: image.width, height: image.height)
        case .video(let source):
            return source.naturalSize == .zero
                ? CGSize(width: 1080, height: 1920)
                : source.naturalSize
        }
    }

    var isVideo: Bool {
        if case .video = self { return true }
        return false
    }
}

/// Reads a video's frames in order, for export.
///
/// The preview uses AVPlayer, which is the right tool for looping on screen and
/// the wrong one for export: it runs on the display's clock, so an export driven
/// by it would drop or repeat frames depending on how fast the encoder happened
/// to be. A reader hands over every frame exactly once, in order, as fast as it
/// is asked, which is what a deterministic export needs.
final class ExportFrameReader {
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    /// The last frame handed out, reused when the encoder wants a frame the
    /// source has not reached yet.
    private(set) var latest: CVPixelBuffer?

    init(asset: AVAsset) {
        guard let reader = try? AVAssetReader(asset: asset) else { return }
        guard let track = asset.tracks(withMediaType: .video).first else { return }

        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return }
        reader.add(output)
        guard reader.startReading() else { return }

        self.reader = reader
        self.output = output
    }

    /// Pull the next frame. Returns nil once the source is exhausted, at which
    /// point the caller should keep using `latest` so the export finishes on a
    /// held frame rather than on black.
    func next() -> CVPixelBuffer? {
        guard let output, reader?.status == .reading else { return nil }
        guard let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample)
        else { return nil }
        latest = buffer
        return buffer
    }
}

/// Everything the editor screen needs, in one place.
///
/// Deliberately one object rather than a stack of small ones. The whole app is
/// two screens and a render loop; splitting this across a coordinator, a view
/// model and a service would be more files to read and exactly as much
/// behaviour.
@MainActor
final class EditorModel: ObservableObject {
    @Published var style: MotionStyle = .fluid {
        didSet { renderer?.style = style }
    }

    /// The amount slider, 0 to 1.
    @Published var amount: Double = 0.5 {
        didSet { renderer?.amount = Float(amount) }
    }

    /// Character size in points. The grid is rebuilt when this changes.
    @Published var cellSize: Double = 9 {
        didSet { rebuildForPreview() }
    }

    /// While true the live preview is paused and the export task owns the field
    /// exclusively. This is the whole of the concurrency story: the renderer is
    /// not thread safe and does not need to be, because exactly one of the two
    /// is ever running.
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: Double = 0
    @Published var exportedURL: URL?
    @Published var errorMessage: String?

    private(set) var renderer: GlyphRenderer?
    private var source: Source?
    private let sampler = ImageSampler()

    /// The preview's size in points, once SwiftUI has laid it out.
    private var viewSize: CGSize = .zero
    private var built = false

    // MARK: - Setup

    /// The renderer is built here rather than in `prepare`.
    ///
    /// `prepare` runs from `.onAppear`, which happens *after* SwiftUI has
    /// already called `MetalView.makeUIView` and asked for a device. Building it
    /// there left the MTKView with a nil device on the first pass, and an MTKView
    /// with no device never draws anything at all.
    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            let made = GlyphRenderer(device: device)
            made?.style = style
            made?.amount = Float(amount)
            renderer = made
        }
    }

    func prepare(with source: Source) {
        self.source = source
        if renderer == nil {
            errorMessage = "Renderer unavailable: "
                + (GlyphRenderer.lastFailure ?? "unknown")
            return
        }
        rebuildForPreview()
        if case .video(let video) = source {
            video.play()
        }
    }

    func setViewSize(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        guard abs(size.width - viewSize.width) > 0.5
            || abs(size.height - viewSize.height) > 0.5 else { return }
        viewSize = size
        rebuildForPreview()
    }

    private func rebuildForPreview() {
        guard !isExporting else { return }
        guard let renderer, let source, viewSize.width > 1 else { return }
        build(renderer: renderer, source: source, size: viewSize, cell: Float(cellSize))
        built = true
    }

    /// Lay out the grid and load the first picture into it.
    private func build(renderer: GlyphRenderer, source: Source, size: CGSize, cell: Float) {
        renderer.field.build(
            viewSize: size,
            imageSize: source.pixelSize,
            targetCell: cell,
            atlasAspect: renderer.atlasAspect
        )
        if case .photo(let image) = source {
            apply(image: image, to: renderer)
        }
    }

    private func apply(image: CGImage, to renderer: GlyphRenderer) {
        let field = renderer.field
        guard !field.isEmpty else { return }
        if let pixels = sampler.sample(image: image, columns: field.columns, rows: field.rows) {
            field.apply(pixels: pixels)
        }
    }

    /// Pull the next video frame into the field, if there is one.
    ///
    /// Called from the display loop. Cheap when the video has not advanced,
    /// because `currentFrame` returns nil and nothing is resampled.
    func pumpVideo() {
        guard built, !isExporting,
              let renderer,
              case .video(let video) = source,
              let buffer = video.currentFrame()
        else { return }

        let field = renderer.field
        guard !field.isEmpty else { return }
        if let pixels = sampler.sample(
            pixelBuffer: buffer,
            columns: field.columns,
            rows: field.rows
        ) {
            field.apply(pixels: pixels)
        }
    }

    // MARK: - Export

    /// Render the artwork and hand back a file for the share sheet.
    ///
    /// A photo becomes a short video of its motion, because the motion is the
    /// product. A video becomes a video of the same length, capped.
    func export() {
        guard !isExporting else { return }
        guard let renderer, let source, built, !renderer.field.isEmpty else {
            errorMessage = "Nothing to export yet."
            return
        }

        // Pausing the preview happens here, on the main thread, before the
        // export task exists. MTKView drives its draws from the main run loop,
        // so once this is set no draw can be in flight and the export task has
        // the field to itself.
        isExporting = true
        exportProgress = 0

        // Twice the preview's points, capped, so the artwork is sharp on a
        // retina screen without asking a phone to encode 4K.
        let previewSize = viewSize
        let scale: CGFloat = 2
        let pixels = CGSize(
            width: min(previewSize.width * scale, 1440),
            height: min(previewSize.height * scale, 2560)
        )
        let viewport = SIMD2<Float>(Float(previewSize.width), Float(previewSize.height))

        let seconds: Double
        var reader: ExportFrameReader?
        if case .video(let video) = source {
            let duration = video.durationSeconds
            seconds = duration.isFinite && duration > 0
                ? min(duration, Exporter.maxSeconds)
                : Exporter.stillMotionSeconds
            video.pause()
            reader = ExportFrameReader(asset: video.asset)
        } else {
            seconds = Exporter.stillMotionSeconds
        }

        let field = renderer.field
        let sampler = self.sampler
        let capturedReader = reader

        Task.detached(priority: .userInitiated) { [weak self] in
            var result: URL?
            var failure: String?

            do {
                result = try await Exporter.exportVideo(
                    renderer: renderer,
                    size: pixels,
                    viewport: viewport,
                    seconds: seconds,
                    frameSource: { _ in
                        guard let capturedReader else { return }
                        // One source frame per output frame. When the source
                        // runs out, the last frame is held rather than going
                        // black, so a short clip still fills its export.
                        let buffer = capturedReader.next() ?? capturedReader.latest
                        guard let buffer, !field.isEmpty else { return }
                        if let px = sampler.sample(
                            pixelBuffer: buffer,
                            columns: field.columns,
                            rows: field.rows
                        ) {
                            field.apply(pixels: px)
                        }
                    },
                    progress: { p in
                        Task { @MainActor in self?.exportProgress = p }
                    }
                )
            } catch {
                failure = "Export failed. Try a shorter clip or a larger character size."
            }

            await MainActor.run {
                guard let self else { return }
                self.isExporting = false
                if let result {
                    self.exportedURL = result
                } else {
                    self.errorMessage = failure ?? "Export failed."
                }
                // Put the field back the way the preview wants it, and start
                // the video playing again.
                self.rebuildForPreview()
                if case .video(let video) = self.source { video.play() }
            }
        }
    }
}
