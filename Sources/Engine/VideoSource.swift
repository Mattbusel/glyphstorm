import AVFoundation
import CoreVideo
import Foundation

/// A looping video, handing out whatever frame is showing right now.
///
/// Built on AVPlayer rather than on a reader, because the preview needs to loop
/// forever and stay in step with the display without anyone managing a clock.
/// The physics reads frames at whatever rate it draws; if the video is 24fps
/// and the screen is 120, the same frame is simply read five times, and the
/// glyphs keep moving in between because their motion does not come from the
/// video in the first place.
final class VideoSource {
    let asset: AVAsset
    private let player: AVPlayer
    private let item: AVPlayerItem
    private let output: AVPlayerItemVideoOutput
    private var looper: NSObjectProtocol?

    /// Pixel size of the video, for laying out the grid.
    private(set) var naturalSize: CGSize = .zero
    /// How long it runs. Loaded up front because the synchronous
    /// `AVAsset.duration` is deprecated and blocks on a device.
    private(set) var durationSeconds: Double = 0

    init?(url: URL) {
        let asset = AVURLAsset(url: url)
        self.asset = asset

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        self.output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        self.item = AVPlayerItem(asset: asset)
        self.item.add(output)
        self.player = AVPlayer(playerItem: item)
        // Nothing in this app plays sound, and a video that starts talking when
        // you pick it is a surprise nobody wants.
        self.player.isMuted = true

        looper = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.player.seek(to: .zero)
            self?.player.play()
        }
    }

    deinit {
        if let looper { NotificationCenter.default.removeObserver(looper) }
        player.pause()
    }

    /// Read the video's dimensions, which is an async load on modern AVFoundation.
    func loadNaturalSize() async {
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            durationSeconds = seconds.isFinite ? seconds : 0
        }
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
        guard let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return }
        // Applying the transform matters: a video shot in portrait on a phone
        // is stored landscape with a rotation, and a grid built from the raw
        // size comes out sideways.
        let oriented = size.applying(transform)
        naturalSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
    }

    func play() { player.play() }
    func pause() { player.pause() }

    /// The frame showing now, or nil if the next one is not ready yet.
    func currentFrame() -> CVPixelBuffer? {
        let time = item.currentTime()
        guard output.hasNewPixelBuffer(forItemTime: time) else { return nil }
        return output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
    }
}
